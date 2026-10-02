import Foundation
import Observation

@MainActor @Observable final class ConnectionSettingsController {
    private(set) var savedSettings: SMBConnectionSettings?
    var draft = SMBConnectionSettings()
    var password = ""
    private(set) var isSaving = false
    private(set) var isEditing = false
    private(set) var message: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let update: LibraryUpdateController
    @ObservationIgnored private let readPassword: (String) throws -> String?
    @ObservationIgnored private let savePassword: (String, String) throws -> Void
    @ObservationIgnored private let deletePassword: (String) throws -> Void
    @ObservationIgnored private let check: (SMBConnectionSettings, String) async throws -> Void

    init(defaults: UserDefaults = .standard, update: LibraryUpdateController,
         readPassword: @escaping (String) throws -> String?,
         savePassword: @escaping (String, String) throws -> Void,
         deletePassword: @escaping (String) throws -> Void,
         check: @escaping (SMBConnectionSettings, String) async throws -> Void) {
        self.defaults = defaults; self.update = update
        self.readPassword = readPassword; self.savePassword = savePassword
        self.deletePassword = deletePassword; self.check = check
        if let data = defaults.data(forKey: SMBConnectionSettings.storageKey) {
            do { savedSettings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated() }
            catch { message = "保存済みの接続設定を読み込めません。接続先を設定し直してください。" }
        }
        update.setConnectionConfigured(savedSettings != nil)
        draft = savedSettings ?? SMBConnectionSettings()
        loadPassword()
    }

    func prepareDraft() {
        guard !isSaving else { return }
        draft = savedSettings ?? SMBConnectionSettings()
        message = nil
        loadPassword()
    }

    // アプリ共通の編集session。別windowから同じdraftを同時編集しない。
    func beginEditing() -> Bool {
        guard !isEditing, !isSaving else { return false }
        isEditing = true
        update.beginSettingsEditing()
        prepareDraft()
        return true
    }

    func endEditing() {
        guard isEditing, !isSaving else { return }
        isEditing = false
        update.endSettingsEditing()
    }

    func loadPassword() {
        password = ""
        do { password = try readPassword(draft.credentialAccount) ?? "" }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func save(onSaved: () -> Void = {}) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; message = nil
        defer { isSaving = false }
        do {
            let settings = try draft.validated()
            let data = try JSONEncoder().encode(settings)
            let secret = password
            await update.beginConnectionCheck()
            do {
                defer { update.endConnectionCheck() }
                try Task.checkCancellation()
                try await check(settings, secret)
                try Task.checkCancellation()
                try savePassword(settings.credentialAccount, secret)
                defaults.set(data, forKey: SMBConnectionSettings.storageKey)
                let previous = savedSettings
                savedSettings = settings
                draft = settings
                update.setConnectionConfigured(true)
                // 旧credential削除の失敗で、保存済み新設定を未保存として扱わない。
                if let previous, previous.credentialAccount != settings.credentialAccount {
                    try? deletePassword(previous.credentialAccount)
                }
            }
            onSaved()
            update.requestUpdate()
            return true
        } catch is CancellationError {
            message = "接続確認を中断しました。もう一度お試しください。"
        } catch { message = error.localizedDescription }
        return false
    }
}
