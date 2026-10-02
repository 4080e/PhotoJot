import Foundation
import Observation

// 段階4の実機確認専用。timeline UI / 自動更新はここには実装しない。
@MainActor @Observable final class TimelineDiagnosticsController {
    var isRunning = false
    var status: String?
    var result: TimelineDiagnostics?
    private var task: Task<Void, Never>?
    private let repository: TimelineRepository

    init(repository: TimelineRepository) { self.repository = repository }

    func start() {
        guard !isRunning else { return }
        isRunning = true; result = nil; status = "保存済みindexを確認中…"
        task = Task {
            defer { isRunning = false; task = nil }
            do {
                guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else {
                    throw ScanFailure.noSettings
                }
                let settings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
                result = try await repository.diagnostics(settings: settings) { [weak self] count in
                    await self?.update(count)
                }
                status = "timeline診断完了（SMB通信なし）"
            } catch is CancellationError {
                status = "中断しました。保存済みの日付キーは次回利用します。"
            } catch { status = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    private func update(_ count: Int) { status = "日付キー構築済み：\(count)件。続いて集計します…" }
}
