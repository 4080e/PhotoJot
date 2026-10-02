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

    private(set) var state = State.idle
    private(set) var phase: Phase?
    private(set) var scanProgress = ScanProgress()
    private(set) var metadataProgress = MetadataProgress()
    private(set) var missingCount: Int?
    private(set) var errorMessage: String?
    private(set) var libraryName: String?
    private(set) var restartRequested = false
    var isRunning: Bool { state == .running || state == .cancelling }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastScenePhase: ScenePhase?
    @ObservationIgnored private let connection: () throws -> LibraryUpdateConnection
    @ObservationIgnored private let scan: (LibraryUpdateConnection, @Sendable @escaping (ScanProgress) async -> Void) async throws -> Int
    @ObservationIgnored private let metadata: (LibraryUpdateConnection, @Sendable @escaping (MetadataProgress) async -> Void) async throws -> Void

    init(connection: @escaping () throws -> LibraryUpdateConnection,
         scan: @escaping (LibraryUpdateConnection, @Sendable @escaping (ScanProgress) async -> Void) async throws -> Int,
         metadata: @escaping (LibraryUpdateConnection, @Sendable @escaping (MetadataProgress) async -> Void) async throws -> Void) {
        self.connection = connection
        self.scan = scan
        self.metadata = metadata
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard lastScenePhase != phase else { return }
        lastScenePhase = phase
        switch phase {
        case .active: requestUpdate()
        case .background: cancel()
        case .inactive: break
        @unknown default: break
        }
    }

    func requestUpdate() {
        guard lastScenePhase != .background else { return }
        if task != nil {
            if state == .cancelling { restartRequested = true }
            return
        }
        state = .running; phase = .preparing
        errorMessage = nil; missingCount = nil; libraryName = nil
        scanProgress = ScanProgress(); metadataProgress = MetadataProgress()
        task = Task { [self] in
            defer {
                // Serviceの終了・切断・保存が戻るまでtaskを解放しない。
                task = nil
                phase = nil
                let restart = restartRequested
                restartRequested = false
                if restart { requestUpdate() }
            }
            do {
                try Task.checkCancellation()
                let snapshot = try connection()
                libraryName = snapshot.settings.share + (snapshot.settings.rootPath.isEmpty ? "" : "/" + snapshot.settings.rootPath)
                phase = .scanning
                missingCount = try await scan(snapshot) { [weak self] value in
                    await self?.setScanProgress(value)
                }
                try Task.checkCancellation()
                phase = .metadata
                try await metadata(snapshot) { [weak self] value in
                    await self?.setMetadataProgress(value)
                }
                try Task.checkCancellation()
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
        guard task != nil else { return }
        state = .cancelling
        task?.cancel()
    }

    private func setScanProgress(_ value: ScanProgress) { scanProgress = value }
    private func setMetadataProgress(_ value: MetadataProgress) { metadataProgress = value }
}
