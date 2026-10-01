import Foundation
import Observation

@MainActor @Observable final class ScanController {
    var isScanning = false
    var status: String?
    var progress = ScanProgress()
    var libraryName: String?
    private var task: Task<Void, Never>?
    private var service: ScanService?

    func start(access: SMBAccessCoordinator) {
        guard !isScanning else { return }
        isScanning = true
        status = "走査中…"; progress = ScanProgress()
        task = Task {
            defer { isScanning = false; task = nil }
            do {
                guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else {
                    throw ScanFailure.noSettings
                }
                let settings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
                libraryName = settings.share + (settings.rootPath.isEmpty ? "" : "/" + settings.rootPath)
                guard let password = try CredentialStore().password(account: settings.credentialAccount) else {
                    throw ScanFailure.noPassword
                }
                if service == nil {
                    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                        .appendingPathComponent("PhotoJot", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    service = try ScanService(access: access, storeURL: directory.appendingPathComponent("index.store"))
                }
                guard let service else { throw IndexFailure.invalidState }
                let missing = try await service.scan(settings: settings, password: password) { [weak self] counts in
                    await self?.update(counts)
                }
                status = "走査完了\n未確認（missing）：\(missing)件"
            } catch is CancellationError {
                status = "走査を中断しました。missing判定は行っていません。"
            } catch {
                status = "走査失敗\n\(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        guard isScanning else { return }
        task?.cancel()
        status = "中断待ち…"
    }

    private func update(_ counts: ScanProgress) { progress = counts }
}
