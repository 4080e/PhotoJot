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
        })
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
        lifecycle.scenePhaseChanged(.active)
        await wait { lifecycleWork.scanGate != nil }
        precondition(lifecycleWork.scanSnapshots.count == 1)
        lifecycle.scenePhaseChanged(.inactive)
        precondition(lifecycle.state == .running) // inactiveだけでは止めない。
        lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.background)
        precondition(lifecycle.state == .cancelling && lifecycle.isRunning)
        lifecycle.requestUpdate() // background中に更新を開始・予約しない。
        precondition(!lifecycle.restartRequested)
        lifecycle.scenePhaseChanged(.active)
        lifecycle.scenePhaseChanged(.active)
        precondition(lifecycle.restartRequested && lifecycleWork.scanSnapshots.count == 1)
        lifecycleWork.releaseScan()
        await wait { lifecycleWork.scanGate != nil }
        precondition(lifecycleWork.scanSnapshots.count == 2 && lifecycleWork.metadataSnapshots.isEmpty)
        lifecycleWork.releaseScan()
        await wait { lifecycleWork.metadataGate != nil }
        lifecycle.scenePhaseChanged(.background)
        lifecycleWork.releaseMetadata()
        await wait { !lifecycle.isRunning }
        precondition(lifecycle.state == .cancelled && lifecycleWork.scanSnapshots.count == 2)
        lifecycle.scenePhaseChanged(.active)
        await wait { lifecycleWork.scanGate != nil }
        precondition(lifecycleWork.scanSnapshots.count == 3)
        lifecycleWork.releaseScan()
        await wait { lifecycleWork.metadataGate != nil }
        lifecycleWork.releaseMetadata()
        await wait { !lifecycle.isRunning }
        lifecycle.scenePhaseChanged(.active) // 完了後も重複通知で再実行しない。
        precondition(lifecycle.state == .completed && lifecycleWork.scanSnapshots.count == 3)

        lifecycle.scenePhaseChanged(.inactive)
        lifecycle.scenePhaseChanged(.active)
        await wait { lifecycleWork.scanGate != nil }
        lifecycle.scenePhaseChanged(.background)
        lifecycle.scenePhaseChanged(.active)
        precondition(lifecycle.restartRequested)
        lifecycle.scenePhaseChanged(.background) // 再開待ち中に再度background。
        precondition(!lifecycle.restartRequested)
        lifecycleWork.releaseScan()
        await wait { !lifecycle.isRunning }
        precondition(lifecycle.state == .cancelled && lifecycleWork.scanSnapshots.count == 4)

        // yield前からの中断要求を、次の処理へ通さない。
        let checkpoint = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await UpdateCheckpoint.yield(); fatalError("cancelled checkpoint passed") }
            catch is CancellationError { }
        }
        try await checkpoint.value
        try await UpdateCheckpoint.yield()
        print("PASS: lifecycle active/inactive/background, duplicate active, drain/restart, re-background, checkpoints")
        print("PASS: serial update, duplicate suppression, snapshots, progress, cancellation drain, coalesced restart, restart cancellation, errors")
    }
}
