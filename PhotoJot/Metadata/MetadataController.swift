import Foundation
import Observation

@MainActor @Observable final class MetadataController {
    var isProcessing = false
    var status: String?
    var progress = MetadataProgress()
    private var task: Task<Void, Never>?
    private var service: MetadataService?

    func start(access: SMBAccessCoordinator) {
        guard !isProcessing else { return }
        isProcessing = true; status = "解析対象を確認中…"; progress = MetadataProgress()
        task = Task {
            defer { isProcessing = false; task = nil }
            do {
                guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else { throw ScanFailure.noSettings }
                let settings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
                guard let password = try CredentialStore().password(account: settings.credentialAccount) else { throw ScanFailure.noPassword }
                if service == nil {
                    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                        .appendingPathComponent("PhotoJot", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    service = try MetadataService(access: access, storeURL: directory.appendingPathComponent("index.store"))
                }
                guard let service else { throw IndexFailure.invalidState }
                try await service.complete(settings: settings, password: password) { [weak self] counts in
                    await self?.update(counts)
                }
                status = progress.total == 0 ? "解析が必要な対象はありません。" : "撮影日時の解析が完了しました。"
            } catch is CancellationError {
                status = "解析を中断しました。保存済みの結果は残り、次回は未完了分から再開します。"
            } catch {
                status = "解析を停止しました。\n\(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        guard isProcessing else { return }
        task?.cancel(); status = "中断待ち…"
    }
    private func update(_ value: MetadataProgress) {
        progress = value
        if task?.isCancelled != true { status = "撮影日時を解析中…" }
    }
}
