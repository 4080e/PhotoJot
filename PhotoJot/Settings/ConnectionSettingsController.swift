import Foundation
import Observation

// Each instance owns a single independent probe. Cleanup must join its real I/O.
@MainActor struct ConnectionProbe {
    let check: (SMBConnectionSettings, String) async throws -> Void
    let disconnect: () async -> Void
    let finish: () async -> Void
}

private enum ProbeFailure: Error { case timedOut }


@MainActor @Observable final class ConnectionSettingsController {
    private(set) var savedSettings: SMBConnectionSettings?
    var draft = SMBConnectionSettings()
    var password = ""
    private(set) var profile: LibraryConnectionProfile?
    var homeHost = ""
    var awayHost = "100.92.22.5"
    private(set) var useAway = false
    private(set) var switchStatus: String?
    @ObservationIgnored private let makeProbe: (UUID) -> ConnectionProbe
    @ObservationIgnored private let probeNow: () -> TimeInterval
    @ObservationIgnored private let probeSleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private var routeTransaction: Task<Bool, Never>?
    @ObservationIgnored private let pauseRequests: () async -> Void
    @ObservationIgnored private let abortOldRoute: () async -> Void
    @ObservationIgnored private let drainOldRoute: () async -> Void
    @ObservationIgnored private let establishRoute: (SMBConnectionSettings, String) async throws -> Void
    @ObservationIgnored private let activateRoute: (SMBConnectionSettings) async -> Void

    private(set) var isSaving = false
    private(set) var isEditing = false
    private(set) var message: String?
    private(set) var lastSuccessfulUpdateAt: Date?
    var updateState: LibraryUpdateController.State { update.state }
    @ObservationIgnored private let lastSuccessfulUpdate: (SMBConnectionSettings) async throws -> Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let update: LibraryUpdateController
    @ObservationIgnored private let readPassword: (String) throws -> String?
    @ObservationIgnored private let savePassword: (String, String) throws -> Void
    @ObservationIgnored private let deletePassword: (String) throws -> Void
    @ObservationIgnored private let check: (SMBConnectionSettings, String) async throws -> Void

    @ObservationIgnored private let editingChanged: (Bool) -> Void
    @ObservationIgnored private let beginThumbnailCheck: () async -> Void
    @ObservationIgnored private let endThumbnailCheck: () -> Void

    init(defaults: UserDefaults = .standard, update: LibraryUpdateController,
         profile: LibraryConnectionProfile? = nil,
         makeProbe: ((UUID) -> ConnectionProbe)? = nil,
         probeNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         probeSleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         pauseRequests: @escaping () async -> Void = {},
         abortOldRoute: @escaping () async -> Void = {},
         drainOldRoute: @escaping () async -> Void = {},
         establishRoute: @escaping (SMBConnectionSettings, String) async throws -> Void = { _, _ in },
         activateRoute: @escaping (SMBConnectionSettings) async -> Void = { _ in },
         readPassword: @escaping (String) throws -> String?,
         savePassword: @escaping (String, String) throws -> Void,
         deletePassword: @escaping (String) throws -> Void,
         check: @escaping (SMBConnectionSettings, String) async throws -> Void,
         editingChanged: @escaping (Bool) -> Void = { _ in },
         beginThumbnailCheck: @escaping () async -> Void = {},
         endThumbnailCheck: @escaping () -> Void = {},
         lastSuccessfulUpdate: @escaping (SMBConnectionSettings) async throws -> Date? = { _ in nil }) {
        self.profile = profile
        self.makeProbe = makeProbe ?? { _ in ConnectionProbe(check: check, disconnect: {}, finish: {}) }
        self.probeNow = probeNow; self.probeSleep = probeSleep
        self.pauseRequests = pauseRequests; self.abortOldRoute = abortOldRoute
        self.drainOldRoute = drainOldRoute; self.establishRoute = establishRoute; self.activateRoute = activateRoute
        self.lastSuccessfulUpdate = lastSuccessfulUpdate
        self.editingChanged = editingChanged
        self.beginThumbnailCheck = beginThumbnailCheck; self.endThumbnailCheck = endThumbnailCheck
        self.defaults = defaults; self.update = update
        self.readPassword = readPassword; self.savePassword = savePassword
        self.deletePassword = deletePassword; self.check = check
        if let data = defaults.data(forKey: SMBConnectionSettings.storageKey) {
            do { savedSettings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated() }
            catch { message = "保存済みの接続設定を読み込めません。接続先を設定し直してください。" }
        }
        if let profile {
            savedSettings = profile.settings
            homeHost = profile.homeHost; awayHost = profile.awayHost; useAway = profile.useAway
        }
        update.setConnectionConfigured(savedSettings != nil)
        draft = savedSettings ?? SMBConnectionSettings()
        loadPassword()
    }

    func prepareDraft() {
        guard !isSaving else { return }
        draft = savedSettings ?? SMBConnectionSettings()
        message = nil
        if let profile { homeHost = profile.homeHost; awayHost = profile.awayHost; useAway = profile.useAway }
        loadPassword()
    }

    // アプリ共通の編集session。別windowから同じdraftを同時編集しない。
    func beginEditing() -> Bool {
        guard !isEditing, !isSaving else { return false }
        isEditing = true
        if profile == nil { editingChanged(true) }
        update.beginSettingsEditing()
        prepareDraft()
        return true
    }

    func endEditing() {
        guard isEditing, !isSaving else { return }
        isEditing = false
        editingChanged(false)
        update.endSettingsEditing()
    }

    func loadLastSuccessfulUpdate() async {
        let settings = savedSettings
        lastSuccessfulUpdateAt = nil
        guard let settings else { return }
        do {
            let date = try await lastSuccessfulUpdate(settings)
            guard savedSettings == settings else { return }
            lastSuccessfulUpdateAt = date
        } catch { message = error.localizedDescription }
    }

    func loadPassword() {
        password = ""
        do { password = try readPassword(draft.credentialAccount) ?? "" }
        catch { message = error.localizedDescription }
    }

    // The transaction belongs to the controller, not a transient SwiftUI task.
    // Only the final successful connection publishes the new profile.
    @discardableResult
    func switchEndpoint(useAway requested: Bool) async -> Bool {
        guard !isSaving, let previous = profile else { return false }
        isSaving = true; useAway = requested; message = nil
        let operationID = UUID(), acceptedAt = probeNow()
        #if DEBUG
        SMBDiagnostics.shared.begin("toggle connection probe", id: operationID)
        #endif
        let task = Task { await self.performSwitch(previous: previous, requested: requested,
                                                   operationID: operationID, acceptedAt: acceptedAt) }
        routeTransaction = task
        let result = await task.value
        routeTransaction = nil; isSaving = false; switchStatus = nil
        return result
    }

    private func performSwitch(previous: LibraryConnectionProfile, requested: Bool,
                               operationID: UUID, acceptedAt: TimeInterval) async -> Bool {
        #if DEBUG
        defer { SMBDiagnostics.shared.end(operationID, outcome: "toggle transaction ended") }
        #endif
        var next = previous
        next.homeHost = homeHost; next.awayHost = awayHost; next.useAway = requested; next.revision = UUID()
        let secret = password
        var oldStopped = false
        var oldPassword: String?
        var probeStarted = false
        defer {
            useAway = profile?.useAway ?? previous.useAway
            if probeStarted { update.endConnectionCheck() }
        }
        do {
            next = try next.validated()
            oldPassword = try readPassword(previous.credentialReference)
            // Publish a new credential reference only with the new settings. A crash or
            // failed save must never overwrite the password used by the old profile.
            if oldPassword != secret { next.credentialID = UUID() }
            let data = try JSONEncoder().encode(next)
            switchStatus = "切り替え先を確認中…"
            update.beginConnectionProbe(); probeStarted = true
            await pauseRequests()
            try await checkWithDeadline(next.settings, password: secret, previous: previous,
                                        operationID: operationID, acceptedAt: acceptedAt)
            // Probe succeeded and has been disconnected. Only now stop the old session.
            oldStopped = true
            switchStatus = "旧接続の終了待ち…"
            update.cancel()
            await abortOldRoute()
            editingChanged(true)
            await update.beginConnectionCheck()
            await beginThumbnailCheck()
            await drainOldRoute()
            switchStatus = "新しい接続を確立中…"
            try await establishRoute(next.settings, secret)
            if oldPassword != secret {
                try savePassword(next.credentialReference, secret)
                guard try readPassword(next.credentialReference) == secret else { throw LibraryBindingError.invalidProfile }
            }
            defaults.set(data, forKey: LibraryConnectionProfile.storageKey)
            profile = next; savedSettings = next.settings; draft = next.settings
            homeHost = next.homeHost; awayHost = next.awayHost
            await activateRoute(next.settings)
            endThumbnailCheck(); editingChanged(false)
            return true
        } catch {
            let inputError = error as? LibraryBindingError
            if oldStopped {
                switchStatus = "元の接続へ復帰中…"
                await abortOldRoute()
                await drainOldRoute()
                do {
                    guard let oldPassword else { throw LibraryBindingError.invalidProfile }
                    try await establishRoute(previous.settings, oldPassword)
                    message = "切り替えに失敗しました。元の接続へ復帰しました。接続先と認証設定を確認してください。"
                } catch {
                    message = "切り替えに失敗し、元の接続への再接続にも失敗しました。選択状態と保存済みデータは維持しています。接続を確認して再試行してください。"
                }
            } else {
                message = error is ProbeFailure ? "接続確認がタイムアウトしました" : inputError?.localizedDescription ?? "切り替え先に接続できませんでした。IPアドレス・認証情報・Tailscaleの接続状態を確認してください。元の選択状態を維持しています。"
            }
            homeHost = previous.homeHost; awayHost = previous.awayHost; draft = previous.settings
            if let oldPassword { password = oldPassword }
            await activateRoute(previous.settings)
            #if DEBUG
            SMBDiagnostics.shared.event("previous route re-enabled; library unchanged", id: operationID)
            #endif
            if oldStopped { endThumbnailCheck(); editingChanged(false) }
            return false
        }
    }

    // All outcome decisions are serialized on MainActor. A cancelled timer is not
    // trusted: it also checks the attempt state before disconnecting its probe.
    private final class ProbeAttempt {
        enum State { case pending, finished, expired }
        var state = State.pending
        var abort: Task<Void, Never>?
    }

    private func checkWithDeadline(_ settings: SMBConnectionSettings, password: String,
                                   previous: LibraryConnectionProfile, operationID: UUID,
                                   acceptedAt: TimeInterval) async throws {
        let probe = makeProbe(operationID), attempt = ProbeAttempt()
        let deadline = acceptedAt + 5
        let expire: () -> Void = { [self] in
            guard attempt.state == .pending else { return }
            attempt.state = .expired
            useAway = previous.useAway
            message = "接続確認がタイムアウトしました"
            switchStatus = "接続確認を終了中…"
            #if DEBUG
            SMBDiagnostics.shared.event("probe deadline exceeded; toggle restored", id: operationID)
            #endif
            attempt.abort = Task { await probe.disconnect() }
        }
        let timer = Task {
            do { try await probeSleep(max(0, deadline - probeNow())) }
            catch { return }
            expire()
        }
        let outcome: Result<Void, Error>
        if probeNow() >= deadline {
            expire()
            outcome = .failure(ProbeFailure.timedOut)
        } else {
            do { try await probe.check(settings, password); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        // Even if the timer was delayed by scheduling, a late result cannot win.
        if attempt.state == .pending {
            if probeNow() >= deadline { expire() }
            else { attempt.state = .finished }
        }
        timer.cancel()
        await attempt.abort?.value
        // Never race cleanup against a timer or abandon an unfinished SMB task.
        await probe.finish()
        #if DEBUG
        SMBDiagnostics.shared.event("probe cleanup complete; gate drained", id: operationID)
        #endif
        if attempt.state == .expired { throw ProbeFailure.timedOut }
        try outcome.get()
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
            await beginThumbnailCheck()
            do {
                defer { update.endConnectionCheck(); endThumbnailCheck() }
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
            update.requestUpdateAfterSaving()
            return true
        } catch is CancellationError {
            message = "接続確認を中断しました。もう一度お試しください。"
        } catch { message = error.localizedDescription }
        return false
    }
}
