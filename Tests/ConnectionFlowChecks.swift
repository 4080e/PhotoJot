import Foundation

@MainActor private final class Fixture {
    let defaults: UserDefaults
    var events: [String] = []
    var failCheck = false
    var failSave = false
    var failUpdate = false
    var failReadPassword = false
    var checkGate: CheckedContinuation<Void, Never>?
    var pauseCheck = false
    var scanGate: CheckedContinuation<Void, Never>?
    var pauseScan = false
    var secret: String?
    enum Failure: Error { case expected }
    lazy var update = LibraryUpdateController(connection: {
        self.events.append("update")
        if self.failUpdate { throw Failure.expected }
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
            readPassword: { _ in
                if self.failReadPassword { throw Failure.expected }
                return self.secret
            },
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
        // 設定画面の開閉・active復帰だけでは更新しない。
        fixture.failCheck = false
        precondition(changing.beginEditing())
        precondition(!changing.beginEditing()) // 同じdraftの同時編集は開始しない。
        changing.draft.share = "unsaved"
        let beforeEditing = fixture.events.count
        fixture.update.scenePhaseChanged(.background)
        fixture.update.scenePhaseChanged(.active)
        fixture.update.scenePhaseChanged(.active)
        precondition(!fixture.update.isRunning && fixture.events.count == beforeEditing)
        changing.endEditing()
        await wait { !fixture.update.isRunning }
        precondition(changing.savedSettings?.share == "other")
        precondition(fixture.events.count == beforeEditing)

        fixture.pauseScan = true
        fixture.update.requestUpdate()
        await wait { fixture.scanGate != nil }
        precondition(changing.beginEditing())
        precondition(fixture.update.state == .running)
        fixture.update.scenePhaseChanged(.background)
        fixture.update.scenePhaseChanged(.active)
        precondition(fixture.update.state == .cancelling && !fixture.update.restartRequested)
        let duringDrain = fixture.events.count
        changing.endEditing()
        precondition(!fixture.update.restartRequested && fixture.events.count == duringDrain)
        fixture.pauseScan = false
        fixture.scanGate?.resume(); fixture.scanGate = nil
        await wait { !fixture.update.isRunning }
        precondition(fixture.update.state == .cancelled)

        precondition(changing.beginEditing())
        changing.draft.share = "new-saved"
        fixture.update.scenePhaseChanged(.background)
        fixture.update.scenePhaseChanged(.active)
        let savedInSheet = await changing.save()
        precondition(savedInSheet && changing.savedSettings?.share == "new-saved" && !fixture.update.isRunning)
        changing.endEditing()
        await wait { !fixture.update.isRunning }
        precondition(fixture.events.suffix(3) == ["update", "scan:new-saved", "metadata"])

        // 保存成功がbackground中なら未開始要求だけを次のactiveで実行。
        fixture.update.scenePhaseChanged(.background)
        changing.draft.share = "background-save"
        let backgroundSaved = await changing.save()
        precondition(backgroundSaved && !fixture.update.isRunning)
        let pendingCount = fixture.events.count
        fixture.update.scenePhaseChanged(.background)
        fixture.update.scenePhaseChanged(.active)
        await wait { !fixture.update.isRunning }
        precondition(fixture.events.count == pendingCount + 3)
        fixture.update.scenePhaseChanged(.inactive)
        fixture.update.scenePhaseChanged(.active)
        precondition(fixture.events.count == pendingCount + 3)

        // 更新失敗はローカルtimelineへ伝播させない。indexあり／なしの両方を確認。
        let repository = try MediaRepository(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let timeline = TimelineRepository(store: repository)
        let savedSettings = changing.savedSettings!
        let scan = try await repository.begin(settings: savedSettings)
        let file = ScannedMedia(path: "local.jpg", size: 100, creation: Date(), modified: Date())
        try await repository.ingest([file], ticket: scan, progress: .init())
        _ = try await repository.finish(scan, progress: .init(), completed: true)
        let local = TimelineController(source: .local(repository: timeline, settings: savedSettings))
        await local.loadInitial()
        let localIDs = local.blocks.flatMap(\.items).map(\.id)
        let display = local.displayGeneration
        fixture.failUpdate = true
        fixture.update.requestUpdate()
        await wait { !fixture.update.isRunning }
        await local.reloadIfEmpty()
        precondition(fixture.update.state == .failed && fixture.update.errorMessage != nil)
        precondition(local.loadedCount == 1 && local.displayGeneration == display && local.blocks.flatMap(\.items).map(\.id) == localIDs)
        let nextRun = try await repository.begin(settings: savedSettings)
        let newer = ScannedMedia(path: "new.jpg", size: 100, creation: Date().addingTimeInterval(60), modified: Date())
        try await repository.ingest([file, newer], ticket: nextRun, progress: .init())
        _ = try await repository.finish(nextRun, progress: .init(), completed: true)
        await local.reloadAfterUpdate()
        precondition(local.loadedCount == 2 && local.displayGeneration != display && local.selectedMonth == nil)
        var absentSettings = savedSettings; absentSettings.share = "no-index"
        let empty = TimelineController(source: .local(repository: timeline, settings: absentSettings))
        await empty.loadInitial(); await empty.reloadIfEmpty()
        precondition(empty.hasLoaded && empty.blocks.isEmpty && empty.errorMessage == nil && fixture.update.state == .failed)
        precondition(changing.savedSettings == savedSettings)
        fixture.failReadPassword = true
        let keychainUnavailable = fixture.controller()
        precondition(keychainUnavailable.savedSettings == savedSettings && keychainUnavailable.message != nil)
        precondition(local.loadedCount == 2)
        fixture.failReadPassword = false


        precondition(changing.beginEditing())
        changing.draft.share = "rejected"
        fixture.failCheck = true
        let failedInSheet = await changing.save()
        precondition(!failedInSheet && changing.draft.share == "rejected" && changing.savedSettings == savedSettings)
        precondition(local.loadedCount == 2)
        changing.endEditing()
        fixture.failUpdate = false; fixture.failCheck = false
        fixture.pauseScan = true
        fixture.update.requestUpdate()
        await wait { fixture.scanGate != nil }
        let manualStartCount = fixture.events.count
        for _ in 0..<10 { fixture.update.requestUpdate() }
        precondition(fixture.events.count == manualStartCount)
        precondition(changing.beginEditing())
        fixture.failCheck = true
        let failedWhileRunning = Task { await changing.save() }
        await wait { fixture.update.isCheckingConnection }
        fixture.pauseScan = false; fixture.scanGate?.resume(); fixture.scanGate = nil
        let rejectedWhileRunning = await failedWhileRunning.value
        precondition(!rejectedWhileRunning)
        let afterRejected = fixture.events.count
        changing.endEditing()
        precondition(!fixture.update.isRunning && fixture.events.count == afterRejected)
        print("PASS: settings-sheet lifecycle, discard/retain old settings, no automatic drain restart, save/new settings, local timeline with update failure, empty index/failure, failed check retention, manual deduplication")
        print("PASS: absent/corrupt/invalid/saved routing, missing password, retained input, save failure, navigate-before-update, connection drain and active suppression, library setting change")
    }
}
