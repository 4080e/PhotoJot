import Foundation
import SwiftUI

@MainActor private final class Work {
    var events: [String] = []
    var scanGate: CheckedContinuation<Void, Never>?
    var metadataGate: CheckedContinuation<Void, Never>?
    var failScan = false
    var failMetadata = false
    var scanSnapshots: [String] = []
    var metadataSnapshots: [String] = []
    var password = "first"
    var successes = 0
    enum Failure: Error { case expected }

    func controller() -> LibraryUpdateController {
        LibraryUpdateController(connection: {
            self.events.append("prepare")
            return LibraryUpdateConnection(settings: SMBConnectionSettings(host: "nas", share: "photos"), password: self.password)
        }, scan: { connection, progress in
            self.events.append("scan")
            self.scanSnapshots.append(connection.password)
            await progress(ScanProgress(files: 3, folders: 1, media: 2))
            await withCheckedContinuation { self.scanGate = $0 }
            self.events.append("scan-end")
            try Task.checkCancellation()
            if self.failScan { throw Failure.expected }
            return 1
        }, metadata: { connection, progress in
            self.events.append("metadata")
            self.metadataSnapshots.append(connection.password)
            await progress(MetadataProgress(total: 2, completed: 1, unknown: 0))
            await withCheckedContinuation { self.metadataGate = $0 }
            self.events.append("metadata-end")
            try Task.checkCancellation()
            if self.failMetadata { throw Failure.expected }
        }, saveSuccess: { _ in self.successes += 1 })
    }
    func releaseScan() { let gate = scanGate; scanGate = nil; gate?.resume() }
    func releaseMetadata() { let gate = metadataGate; metadataGate = nil; gate?.resume() }
}

@main struct UpdateControllerChecks {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Timed out waiting for update state")
    }

    @MainActor static func main() async throws {
        var attempts = 0, saved = 0
        let recovered = LibraryUpdateController(connection: {
            LibraryUpdateConnection(settings: SMBConnectionSettings(), password: "test")
        }, scan: { _, _ in
            attempts += 1
            if attempts <= 2 { throw SMBRecoveryError.interrupted }
            return 0
        }, metadata: { _, _ in }, saveSuccess: { _ in saved += 1 }, retryDelay: {})
        recovered.requestUpdate()
        await wait { !recovered.isRunning }
        precondition(recovered.state == .completed && attempts == 3 && saved == 1 && recovered.recoveryAttempt == 2)
        attempts = 0
        let exhausted = LibraryUpdateController(connection: {
            LibraryUpdateConnection(settings: SMBConnectionSettings(), password: "test")
        }, scan: { _, _ in attempts += 1; throw SMBRecoveryError.interrupted }, metadata: { _, _ in }, retryDelay: {})
        exhausted.requestUpdate()
        await wait { !exhausted.isRunning }
        precondition(exhausted.state == .failed && attempts == 3 && exhausted.errorMessage != nil)
        var delay: CheckedContinuation<Void, Never>?
        attempts = 0
        let cancelledRetry = LibraryUpdateController(connection: {
            LibraryUpdateConnection(settings: SMBConnectionSettings(), password: "test")
        }, scan: { _, _ in attempts += 1; throw SMBRecoveryError.interrupted }, metadata: { _, _ in }, retryDelay: {
            await withCheckedContinuation { delay = $0 }
        })
        cancelledRetry.requestUpdate()
        await wait { delay != nil }
        cancelledRetry.cancel(); delay?.resume(); delay = nil
        await wait { !cancelledRetry.isRunning }
        precondition(cancelledRetry.state == .cancelled && attempts == 1)
        print("PASS: update recovery bounded to two retries, success saved once, cancellation during retry never restarts")
        let work = Work(), controller: LibraryUpdateController
        controller = work.controller()
        controller.requestUpdate(); controller.requestUpdate()
        precondition(controller.isRunning)
        await wait { work.scanGate != nil }
        precondition(work.events == ["prepare", "scan"] && controller.phase == .scanning)
        precondition(controller.scanProgress.media == 2)
        work.password = "second"
        controller.requestUpdate()
        work.releaseScan()
        await wait { work.metadataGate != nil }
        precondition(work.events == ["prepare", "scan", "scan-end", "metadata"])
        precondition(controller.phase == .metadata && controller.missingCount == 1)
        precondition(controller.metadataProgress.completed == 1)
        precondition(work.metadataSnapshots == ["first"]) // 同じ更新内では設定を固定。
        controller.requestUpdate()
        work.releaseMetadata()
        await wait { !controller.isRunning }
        precondition(controller.state == .completed && controller.phase == nil && controller.errorMessage == nil)
        precondition(work.scanSnapshots.count == 1)

        controller.requestUpdate()
        await wait { work.scanGate != nil }
        controller.cancel()
        controller.requestUpdate(); controller.requestUpdate()
        precondition(controller.isRunning && controller.state == .cancelling && controller.restartRequested)
        #if DEBUG
        precondition(SMBDiagnostics.shared.snapshot().active.contains { $0.kind == "update cancellation wait" })
        #endif
        precondition(work.scanSnapshots.count == 2) // 終了処理の戻り前には再開しない。
        work.releaseScan()
        await wait { work.scanGate != nil }
        precondition(work.scanSnapshots.count == 3 && !controller.restartRequested)
        precondition(work.metadataSnapshots.count == 1) // 中断した走査から解析へ進まない。
        work.releaseScan()
        await wait { work.metadataGate != nil }
        controller.cancel(); controller.requestUpdate(); controller.cancel() // 再開予約も取消。
        precondition(controller.isRunning && !controller.restartRequested)
        work.releaseMetadata()
        await wait { !controller.isRunning }
        precondition(controller.state == .cancelled && controller.errorMessage == nil)
        #if DEBUG
        precondition(!SMBDiagnostics.shared.snapshot().active.contains { $0.kind == "update cancellation wait" })
        #endif
        precondition(work.scanSnapshots.count == 3)

        work.failScan = true
        controller.requestUpdate()
        await wait { work.scanGate != nil }
        work.releaseScan()
        await wait { !controller.isRunning }
        precondition(controller.state == .failed && controller.errorMessage != nil)
        precondition(work.metadataSnapshots.count == 2)
        work.failScan = false; work.failMetadata = true
        controller.requestUpdate()
        await wait { work.scanGate != nil }
        precondition(controller.errorMessage == nil)
        work.releaseScan()
        await wait { work.metadataGate != nil }
        work.releaseMetadata()
        await wait { !controller.isRunning }
        precondition(controller.state == .failed && controller.errorMessage != nil)

        let broken = LibraryUpdateController(connection: { throw Work.Failure.expected },
            scan: { _, _ in fatalError("scan after configuration error") },
            metadata: { _, _ in fatalError("metadata after configuration error") })
        broken.requestUpdate()
        await wait { !broken.isRunning }
        precondition(broken.state == .failed)
        let lifecycleWork = Work(), lifecycle: LibraryUpdateController
        lifecycle = lifecycleWork.controller()
        lifecycle.scenePhaseChanged(.active)
        await wait { !lifecycle.isRunning }
        precondition(lifecycleWork.scanSnapshots.isEmpty)
        lifecycle.requestUpdate()
        await wait { lifecycleWork.scanGate != nil }
        lifecycle.scenePhaseChanged(.inactive)
        precondition(lifecycle.state == .running)
        lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.active)
        precondition(!lifecycle.restartRequested)
        lifecycleWork.releaseScan()
        await wait { !lifecycle.isRunning }
        lifecycle.scenePhaseChanged(.inactive)
        lifecycle.scenePhaseChanged(.active)
        precondition(lifecycle.state == .cancelled && lifecycleWork.scanSnapshots.count == 1)
        precondition(work.successes == 1 && lifecycleWork.successes == 0)

        let repository = try MediaRepository(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let settings = SMBConnectionSettings(host: "nas", share: "initial")
        var initialScans = 0
        func initialController() -> LibraryUpdateController {
            LibraryUpdateController(connection: { .init(settings: settings, password: "") },
                scan: { _, _ in initialScans += 1; throw Work.Failure.expected },
                metadata: { _, _ in fatalError("metadata after failed initial scan") },
                prepareInitialUpdate: { try await repository.prepareInitialUpdate(settings: settings) })
        }
        let initial = initialController()
        initial.scenePhaseChanged(.active)
        await wait { !initial.isRunning }
        precondition(initial.state == .failed && initialScans == 1)
        let relaunched = initialController()
        relaunched.scenePhaseChanged(.active)
        await wait { !relaunched.isRunning }
        precondition(relaunched.state == .idle && initialScans == 1)
        let interruptedSettings = SMBConnectionSettings(host: "nas", share: "interrupted")
        let interrupted = LibraryUpdateController(connection: { .init(settings: interruptedSettings, password: "") },
            scan: { _, _ in fatalError("cancelled initial scan") }, metadata: { _, _ in },
            prepareInitialUpdate: { try await repository.prepareInitialUpdate(settings: interruptedSettings) })
        interrupted.scenePhaseChanged(.active)
        interrupted.scenePhaseChanged(.background)
        await wait { !interrupted.isRunning }
        let shouldRetry = try await repository.prepareInitialUpdate(settings: interruptedSettings)
        precondition(!shouldRetry && interrupted.state == .cancelled)
        let before = try await repository.lastSuccessfulUpdate(settings: settings)
        precondition(before == nil)
        try await repository.saveSuccessfulUpdate(settings: settings)
        let completedDate = try await repository.lastSuccessfulUpdate(settings: settings)
        precondition(completedDate != nil)
        let run = try await repository.begin(settings: settings)
        _ = try await repository.finish(run, progress: .init(), completed: false)
        let after = try await repository.lastSuccessfulUpdate(settings: settings)
        precondition(after == completedDate)
        let other = SMBConnectionSettings(host: "nas", share: "other")
        let otherDate = try await repository.lastSuccessfulUpdate(settings: other)
        precondition(otherDate == nil)

        // yield前からの中断要求を、次の処理へ通さない。
        let checkpoint = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await UpdateCheckpoint.yield(); fatalError("cancelled checkpoint passed") }
            catch is CancellationError { }
        }
        try await checkpoint.value
        try await UpdateCheckpoint.yield()
        print("PASS: manual lifecycle, initial failure/cancellation persistence, per-library success date, checkpoints")
        print("PASS: serial update, duplicate suppression, snapshots, progress, cancellation drain, coalesced restart, restart cancellation, errors")
    }
}
