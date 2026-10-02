import Foundation

actor ScanService {
    private let repository: MediaRepository
    private let access: SMBAccessCoordinator
    private var active = false
    private var currentProgress = ScanProgress()

    init(access: SMBAccessCoordinator, repository: MediaRepository) {
        self.access = access
        self.repository = repository
    }

    func scan(settings: SMBConnectionSettings, password: String,
              progress: @Sendable (ScanProgress) async -> Void) async throws -> Int {
        guard !active else { throw IndexFailure.invalidState }
        active = true
        currentProgress = ScanProgress()
        defer { active = false }
        let ticket = try await repository.begin(settings: settings)
        do {
            let final = try await access.scan(settings: settings, password: password) { values, counts in
                try await self.consume(values, counts: counts, ticket: ticket)
                await progress(counts)
            }
            try Task.checkCancellation()
            return try await repository.finish(ticket, progress: final, completed: true) ?? 0
        } catch {
            do { _ = try await repository.finish(ticket, progress: currentProgress, completed: false) }
            catch {
                // 保存不能でもcompletedSequenceは進まない。次のbeginでinterruptedへ回復する。
                throw ScanFailure.finishFailed
            }
            throw error
        }
    }

    private func consume(_ values: [ScannedMedia], counts: ScanProgress, ticket: ScanTicket) async throws {
        currentProgress = counts
        try Task.checkCancellation()
        if !values.isEmpty { try await repository.ingest(values, ticket: ticket, progress: counts) }
    }
}

nonisolated enum ScanFailure: LocalizedError {
    case noSettings, noPassword, finishFailed
    var errorDescription: String? {
        switch self {
        case .noSettings: "接続確認に成功した設定が必要です。先に接続確認を実行してください。"
        case .noPassword: "保存済みパスワードがありません。接続確認を再実行してください。"
        case .finishFailed: "走査を終了しましたが、indexの終了状態を保存できませんでした。missing判定は確定していません。再走査してください。"
        }
    }
}
