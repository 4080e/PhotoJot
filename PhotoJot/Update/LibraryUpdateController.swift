import Foundation
import Observation
import SwiftUI

nonisolated struct LibraryUpdateConnection: Sendable {
    let settings: SMBConnectionSettings
    let password: String
}

// 実処理は既存Serviceへ委譲する。注入した処理で中断終了待ちも検証できる。
@MainActor @Observable final class LibraryUpdateController {
    enum State { case idle, running, cancelling, completed, cancelled, failed }
    enum Phase { case preparing, scanning, metadata }

    #if DEBUG
    @ObservationIgnored private var diagnosticUpdate: UUID?
    @ObservationIgnored private var diagnosticCancel: UUID?
    #endif
    private(set) var state = State.idle {
        didSet {
            #if DEBUG
            SMBDiagnostics.shared.event("update state \(oldValue) -> \(state)", id: diagnosticUpdate)
            #endif
        }
    }
    private(set) var phase: Phase? {
        didSet {
            #if DEBUG
            SMBDiagnostics.shared.event("update phase \(phase.map { String(describing: $0) } ?? "none")", id: diagnosticUpdate)
            #endif
        }
    }
    private(set) var scanProgress = ScanProgress()
    private(set) var metadataProgress = MetadataProgress()
    private(set) var missingCount: Int?
    private(set) var errorMessage: String?
    private(set) var libraryName: String?
    private(set) var executionID: UUID?
    private(set) var recoveryAttempt = 0
    private(set) var recoveryMessage: String?
    @ObservationIgnored private let retryDelay: () async throws -> Void
    private(set) var restartRequested = false
    var isRunning: Bool { state == .running || state == .cancelling }
    private(set) var isCheckingConnection = false
    private(set) var isEditingSettings = false
    @ObservationIgnored private var deferredUpdateRequested = false
    @ObservationIgnored private var connectionConfigured = true
    @ObservationIgnored private var startupChecked = false
    @ObservationIgnored private var savedUpdatePending = false
    @ObservationIgnored private let prepareInitialUpdate: () async throws -> Bool
    @ObservationIgnored private let saveSuccess: (LibraryUpdateConnection) async throws -> Void

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastScenePhase: ScenePhase?
    @ObservationIgnored private let connection: () throws -> LibraryUpdateConnection
    @ObservationIgnored private let scan: (LibraryUpdateConnection, @Sendable @escaping (ScanProgress) async -> Void) async throws -> Int
    @ObservationIgnored private let metadata: (LibraryUpdateConnection, @Sendable @escaping (MetadataProgress) async -> Void) async throws -> Void

    init(connection: @escaping () throws -> LibraryUpdateConnection,
         scan: @escaping (LibraryUpdateConnection, @Sendable @escaping (ScanProgress) async -> Void) async throws -> Int,
         metadata: @escaping (LibraryUpdateConnection, @Sendable @escaping (MetadataProgress) async -> Void) async throws -> Void,
         prepareInitialUpdate: @escaping () async throws -> Bool = { false },
         saveSuccess: @escaping (LibraryUpdateConnection) async throws -> Void = { _ in },
         retryDelay: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.retryDelay = retryDelay
        self.prepareInitialUpdate = prepareInitialUpdate
        self.saveSuccess = saveSuccess
        self.connection = connection
        self.scan = scan
        self.metadata = metadata
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard lastScenePhase != phase else { return }
        lastScenePhase = phase
        switch phase {
        case .active:
            if savedUpdatePending { requestUpdate() }
            else if !startupChecked, connectionConfigured, !isEditingSettings, !isCheckingConnection {
                startupChecked = true
                startUpdate(initialOnly: true)
            }
        case .background: cancel()
        case .inactive: break
        @unknown default: break
        }
    }

    func requestUpdate() {
        guard connectionConfigured, lastScenePhase != .background else { return }
        if isEditingSettings || isCheckingConnection {
            deferredUpdateRequested = true
            return
        }
        deferredUpdateRequested = false
        if task != nil {
            if state == .cancelling { restartRequested = true }
            return
        }
        startupChecked = true
        savedUpdatePending = false
        startUpdate(initialOnly: false)
    }

    private func startUpdate(initialOnly: Bool) {
        guard task == nil else { return }
        #if DEBUG
        diagnosticUpdate = SMBDiagnostics.shared.begin("library update")
        #endif
        recoveryAttempt = 0; recoveryMessage = nil
        state = .running; phase = .preparing
        errorMessage = nil; missingCount = nil; libraryName = nil
        scanProgress = ScanProgress(); metadataProgress = MetadataProgress()
        task = Task { [self] in
            defer {
                // Serviceの終了・切断・保存が戻るまでtaskを解放しない。
                #if DEBUG
                if let id = diagnosticCancel { SMBDiagnostics.shared.end(id, outcome: "cancel cleanup finished") }
                diagnosticCancel = nil
                if let id = diagnosticUpdate { SMBDiagnostics.shared.end(id, outcome: "update task finished") }
                diagnosticUpdate = nil
                #endif
                executionID = nil
                recoveryMessage = nil
                task = nil
                phase = nil
                let restart = restartRequested
                restartRequested = false
                if restart { requestUpdate() }
            }
            do {
                if initialOnly {
                    guard try await prepareInitialUpdate() else { state = .idle; return }
                }
                try Task.checkCancellation()
                let snapshot = try connection()
                libraryName = snapshot.settings.share + (snapshot.settings.rootPath.isEmpty ? "" : "/" + snapshot.settings.rootPath)
                while true {
                    let runID = UUID()
                    executionID = runID
                    scanProgress = ScanProgress(); metadataProgress = MetadataProgress(); missingCount = nil
                    do {
                        try Task.checkCancellation()
                        phase = .scanning
                        missingCount = try await scan(snapshot) { [weak self] value in
                            await self?.setScanProgress(value, runID: runID)
                        }
                        try Task.checkCancellation()
                        phase = .metadata
                        try await metadata(snapshot) { [weak self] value in
                            await self?.setMetadataProgress(value, runID: runID)
                        }
                        try Task.checkCancellation()
                        try await saveSuccess(snapshot)
                        recoveryMessage = nil
                        break
                    } catch is SMBRecoveryError {
                        executionID = nil
                        // scan has already persisted its incomplete ticket before returning here.
                        try Task.checkCancellation()
                        guard recoveryAttempt < 2, lastScenePhase != .background,
                              !isEditingSettings, !isCheckingConnection else {
                            throw UpdateRecoveryFailure.exhausted
                        }
                        recoveryAttempt += 1
                        recoveryMessage = "接続を再確立して更新を再試行します（\(recoveryAttempt)/2）"
                        phase = .preparing
                        try await retryDelay()
                        try Task.checkCancellation()
                        guard !isEditingSettings, !isCheckingConnection, lastScenePhase != .background else {
                            throw UpdateRecoveryFailure.exhausted
                        }
                    }
                }
                state = .completed
            } catch is CancellationError {
                state = .cancelled
            } catch {
                // 保存失敗などの実エラーは、中断要求中でも隠さない。
                errorMessage = error.localizedDescription
                state = .failed
            }
        }
    }

    func cancel() {
        restartRequested = false
        deferredUpdateRequested = false
        guard task != nil else { return }
        #if DEBUG
        if diagnosticCancel == nil { diagnosticCancel = SMBDiagnostics.shared.begin("update cancellation wait") }
        SMBDiagnostics.shared.event("cancel requested", id: diagnosticUpdate)
        #endif
        state = .cancelling
        task?.cancel()
    }

    // 保存成功による未開始要求だけはbackgroundを越えて保持する。
    func requestUpdateAfterSaving() {
        startupChecked = true
        savedUpdatePending = true
        requestUpdate()
    }

    func setConnectionConfigured(_ configured: Bool) { connectionConfigured = configured }

    func beginSettingsEditing() {
        isEditingSettings = true
        // 中断終了待ち中に開いた場合も、旧設定による再開をsheet内で始めない。
        if restartRequested { deferredUpdateRequested = true; restartRequested = false }
    }

    func endSettingsEditing() {
        isEditingSettings = false
        if deferredUpdateRequested || savedUpdatePending { requestUpdate() }
    }

    // 保存操作中だけ更新開始を抑止。古い接続設定のTaskが終了してから接続確認する。
    func beginConnectionCheck() async {
        isCheckingConnection = true
        savedUpdatePending = false
        cancel()
        await task?.value
    }

    func endConnectionCheck() { isCheckingConnection = false }

    private func setScanProgress(_ value: ScanProgress, runID: UUID) {
        guard executionID == runID else { return }; scanProgress = value
    }
    private func setMetadataProgress(_ value: MetadataProgress, runID: UUID) {
        guard executionID == runID else { return }; metadataProgress = value
    }
}

nonisolated private enum UpdateRecoveryFailure: LocalizedError {
    case exhausted
    var errorDescription: String? { "自動復旧を停止しました。保存済みの結果は保持しています。接続を確認し、手動で更新してください。" }
}
