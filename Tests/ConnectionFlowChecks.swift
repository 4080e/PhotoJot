import Foundation

@MainActor private final class Fixture {
    let defaults: UserDefaults
    var events: [String] = []
    var failCheck = false
    var failSave = false
    var checkGate: CheckedContinuation<Void, Never>?
    var pauseCheck = false
    var scanGate: CheckedContinuation<Void, Never>?
    var pauseScan = false
    var secret: String?
    enum Failure: Error { case expected }
    lazy var update = LibraryUpdateController(connection: {
        self.events.append("update")
        let data = self.defaults.data(forKey: SMBConnectionSettings.storageKey)!
        return LibraryUpdateConnection(settings: try JSONDecoder().decode(SMBConnectionSettings.self, from: data), password: self.secret ?? "")
    }, scan: { connection, _ in
        self.events.append("scan:\(connection.settings.share)")
        if self.pauseScan { await withCheckedContinuation { self.scanGate = $0 } }
        try Task.checkCancellation()
        return 0
    }, metadata: { _, _ in self.events.append("metadata") })
    init() { defaults = UserDefaults(suiteName: "PhotoJot.ConnectionChecks.\(UUID())")! }
    func controller() -> ConnectionSettingsController {
        ConnectionSettingsController(defaults: defaults, update: update,
            readPassword: { _ in self.secret },
            savePassword: { _, value in
                self.events.append("save")
                if self.failSave { throw Failure.expected }
                self.secret = value
            }, deletePassword: { _ in }, check: { _, _ in
                self.events.append("check")
                if self.pauseCheck { await withCheckedContinuation { self.checkGate = $0 } }
                if self.failCheck { throw Failure.expected }
            })
    }
}

@main struct ConnectionFlowChecks {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        fatalError("timeout")
    }
    @MainActor static func main() async throws {
        let fixture = Fixture(), settings = SMBConnectionSettings(host: "nas", username: "user", share: "photos")
        let model = fixture.controller()
        precondition(model.savedSettings == nil)
        fixture.update.scenePhaseChanged(.active)
        precondition(!fixture.update.isRunning && fixture.events.isEmpty)
        model.draft = settings; model.password = "secret"
        fixture.failCheck = true
        let failed = await model.save()
        precondition(!failed && model.savedSettings == nil && model.draft == settings && model.password == "secret")
        precondition(fixture.defaults.data(forKey: SMBConnectionSettings.storageKey) == nil)
        fixture.failCheck = false; fixture.failSave = true
        let saveFailed = await model.save()
        precondition(!saveFailed && model.savedSettings == nil && model.password == "secret")
        fixture.failSave = false; fixture.events = []
        let saved = await model.save { fixture.events.append("navigate") }
        precondition(saved && model.savedSettings == settings)
        await wait { !fixture.update.isRunning }
        precondition(fixture.events == ["check", "save", "navigate", "update", "scan:photos", "metadata"])
        fixture.secret = nil // Keychain欠落でも設定済み、ローカル表示を許可。
        precondition(fixture.controller().savedSettings == settings)
        fixture.defaults.set(Data("broken".utf8), forKey: SMBConnectionSettings.storageKey)
        let broken = fixture.controller()
        precondition(broken.savedSettings == nil && broken.message != nil)
        fixture.defaults.set(try JSONEncoder().encode(SMBConnectionSettings()), forKey: SMBConnectionSettings.storageKey)
        precondition(fixture.controller().savedSettings == nil)

        // 旧更新の終了待ち→接続確認→新設定で更新。確認中activeも重複開始しない。
        fixture.defaults.set(try JSONEncoder().encode(settings), forKey: SMBConnectionSettings.storageKey)
        let changing = fixture.controller()
        fixture.pauseScan = true
        fixture.update.requestUpdate()
        await wait { fixture.scanGate != nil }
        changing.draft.share = "other"
        fixture.pauseCheck = true
        let saving = Task { await changing.save() }
        await wait { fixture.update.isCheckingConnection }
        precondition(fixture.checkGate == nil && fixture.update.state == .cancelling)
        fixture.pauseScan = false
        fixture.scanGate?.resume(); fixture.scanGate = nil
        await wait { fixture.checkGate != nil }
        fixture.update.scenePhaseChanged(.background)
        fixture.update.scenePhaseChanged(.active)
        fixture.update.requestUpdate()
        precondition(!fixture.update.isRunning && !fixture.update.restartRequested)
        fixture.checkGate?.resume(); fixture.checkGate = nil
        let changed = await saving.value
        precondition(changed && changing.savedSettings?.share == "other")
        await wait { !fixture.update.isRunning }
        precondition(fixture.events.suffix(3) == ["update", "scan:other", "metadata"])
        precondition(!fixture.update.isCheckingConnection)
        fixture.pauseCheck = false; fixture.failCheck = true
        changing.draft.share = "failed"
        let rejected = await changing.save()
        precondition(!rejected && changing.savedSettings?.share == "other" && changing.draft.share == "failed")
        print("PASS: absent/corrupt/invalid/saved routing, missing password, retained input, save failure, navigate-before-update, connection drain and active suppression, library setting change")
    }
}
