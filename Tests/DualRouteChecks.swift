import Foundation
import SwiftData

extension MediaRepository {
    func cacheKeysForRouteChecks() throws -> [ThumbnailKey] {
        try context().fetch(FetchDescriptor<MediaEntry>()).map {
            ThumbnailKey(libraryID: $0.libraryID, mediaEntryID: $0.id, generation: $0.generation,
                         specificationVersion: "fixture", pixelSize: 256)
        }.sorted { $0.filename < $1.filename }
    }
    func snapshotForRouteChecks() throws -> String {
        let c = context()
        let libraries = try c.fetch(FetchDescriptor<Library>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let media = try c.fetch(FetchDescriptor<MediaEntry>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let runs = try c.fetch(FetchDescriptor<ScanRun>()).sorted { $0.id.uuidString < $1.id.uuidString }
        return libraries.map { "\($0.id):\($0.completedScanSequence):\($0.lastSuccessfulUpdateAt?.timeIntervalSince1970 ?? 0)" }.joined() +
            media.map { "\($0.id):\($0.libraryID):\($0.generation):\($0.lastSeenSequence)" }.joined() +
            runs.map { "\($0.id):\($0.libraryID):\($0.state)" }.joined()
    }
}

@MainActor private final class RouteFixture {
    let defaults = UserDefaults(suiteName: "PhotoJot.DualRoute.\(UUID())")!
    var events: [String] = []
    var secrets: [String: String] = [:]
    var failCredentialWrite = false
    var scanGate: CheckedContinuation<Void, Never>?
    var pauseScan = false
    var successfulUpdates = 0
    var activeSettings = SMBConnectionSettings(host: "192.168.10.18", username: "test", share: "photos")
    var failProbe = false
    var failMain = false
    var failRollback = false
    var pauseProbe = false
    var pauseDrain = false
    var probeGate: CheckedContinuation<Void, Never>?
    var drainGate: CheckedContinuation<Void, Never>?
    var scans = 0
    enum Failure: Error { case expected }
    lazy var update = LibraryUpdateController(connection: {
        LibraryUpdateConnection(settings: self.activeSettings, password: "test-secret")
    }, scan: { _, _ in
        self.scans += 1
        if self.pauseScan {
            await withCheckedContinuation { self.scanGate = $0 }
            throw SMBRecoveryError.interrupted
        }
        return 0
    }, metadata: { _, _ in }, saveSuccess: { _ in self.successfulUpdates += 1 })
    func controller(_ profile: LibraryConnectionProfile) -> ConnectionSettingsController {
        secrets[profile.credentialReference] = "test-secret"
        activeSettings = profile.settings
        return ConnectionSettingsController(defaults: defaults, update: update, profile: profile,
            pauseRequests: { self.events.append("pause") },
            abortOldRoute: {
                self.events.append("abort")
                self.scanGate?.resume(); self.scanGate = nil
            },
            drainOldRoute: {
                self.events.append("drain")
                if self.pauseDrain { await withCheckedContinuation { self.drainGate = $0 } }
            }, establishRoute: { settings, _ in
                self.events.append(settings.host == profile.homeHost ? "connect-home" : "connect-away")
                if (settings.host == profile.homeHost && self.failRollback) || (settings.host != profile.homeHost && self.failMain) { throw Failure.expected }
            }, activateRoute: { settings in self.events.append("activate:\(settings.host)") },
            readPassword: { self.secrets[$0] }, savePassword: { account, value in
                self.secrets[account] = value
                if self.failCredentialWrite { throw Failure.expected }
            },
            deletePassword: { _ in fatalError("must retain old credentials") },
            check: { _, _ in
                self.events.append("probe")
                if self.pauseProbe { await withCheckedContinuation { self.probeGate = $0 } }
                if self.failProbe { throw Failure.expected }
            }, editingChanged: { if $0 { self.events.append("stop-viewer") } },
            beginThumbnailCheck: { self.events.append("join-streams") })
    }
}

@main struct DualRouteChecks {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        fatalError("timeout")
    }
    @MainActor static func main() async throws {
        let store = try MediaRepository(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let home = SMBConnectionSettings(host: "192.168.10.18", username: "test", share: "photos")
        var away = home; away.host = "100.92.22.5"
        let run = try await store.begin(settings: home)
        let files = (0..<120).map { ScannedMedia(path: "\($0).jpg", size: 3, creation: .distantPast, modified: .distantPast) }
        try await store.ingest(files, ticket: run, progress: ScanProgress())
        _ = try await store.finish(run, progress: ScanProgress(), completed: true)
        try await store.saveSuccessfulUpdate(settings: home)
        let other = try await store.begin(settings: away)
        _ = try await store.finish(other, progress: ScanProgress(), completed: false)
        let before = try await store.snapshotForRouteChecks()
        let originalDate = try await store.lastSuccessfulUpdate(settings: home)
        let originalKeys = try await store.cacheKeysForRouteChecks()
        let cacheDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cacheURL = cacheDirectory.appendingPathComponent(originalKeys[0].filename)
        let existingCache = Data("existing-cache-bytes".utf8)
        try existingCache.write(to: cacheURL)
        var profile = try await store.migrationProfile(legacy: away)
        precondition(profile.libraryID == run.libraryID && profile.libraryID != other.libraryID)
        precondition(profile.useAway)
        try await store.validateBinding(profile)
        await store.setActiveSettings(profile.settings)
        let lookup = try await store.timelineLibraryID(settings: profile.settings)
        precondition(lookup == run.libraryID)
        let metadata = try await store.selectMetadata(settings: profile.settings)
        precondition(metadata.libraryID == run.libraryID)
        let snapshot1 = try await store.snapshotForRouteChecks()
        precondition(snapshot1 == before)

        let defaults = UserDefaults(suiteName: "PhotoJot.Migration.\(UUID())")!
        let legacyData = try JSONEncoder().encode(away)
        defaults.set(legacyData, forKey: SMBConnectionSettings.storageKey)
        var keys = [away.credentialAccount: "test-secret"]
        var interrupt = true
        do {
            try LibraryConnectionMigration.persist(profile, legacy: away, defaults: defaults, read: { keys[$0] }, write: {
                keys[$0] = $1
                if interrupt { throw RouteFixture.Failure.expected }
            })
            fatalError("expected interrupted migration")
        } catch RouteFixture.Failure.expected {}
        precondition(defaults.data(forKey: LibraryConnectionProfile.storageKey) == nil)
        interrupt = false
        try LibraryConnectionMigration.persist(profile, legacy: away, defaults: defaults, read: { keys[$0] }, write: { keys[$0] = $1 })
        try LibraryConnectionMigration.persist(profile, legacy: away, defaults: defaults, read: { keys[$0] }, write: { keys[$0] = $1 })
        precondition(defaults.data(forKey: SMBConnectionSettings.storageKey) == legacyData)
        precondition(keys[away.credentialAccount] == "test-secret" && keys[profile.credentialReference] == "test-secret")
        let decoded = try JSONDecoder().decode(LibraryConnectionProfile.self, from: defaults.data(forKey: LibraryConnectionProfile.storageKey)!)
        precondition(decoded == profile)
        let snapshot2 = try await store.snapshotForRouteChecks()
        precondition(snapshot2 == before)
        let migratedKeys = try await store.cacheKeysForRouteChecks()
        precondition(migratedKeys == originalKeys)
        let retainedCache = try Data(contentsOf: cacheURL)
        precondition(retainedCache == existingCache)

        profile.useAway = false
        let fixture = RouteFixture(), controller = fixture.controller(profile)
        fixture.pauseProbe = true
        let on = Task { await controller.switchEndpoint(useAway: true) }
        await wait { fixture.probeGate != nil }
        precondition(controller.isSaving && controller.useAway)
        let duplicate = await controller.switchEndpoint(useAway: false)
        precondition(!duplicate && fixture.events == ["pause", "probe"])
        fixture.pauseDrain = true
        fixture.probeGate?.resume(); fixture.probeGate = nil
        await wait { fixture.drainGate != nil }
        precondition(!fixture.events.contains("connect-away"))
        fixture.pauseDrain = false; fixture.drainGate?.resume(); fixture.drainGate = nil
        let onResult = await on.value
        precondition(onResult)
        precondition(controller.savedSettings?.libraryID == run.libraryID && controller.useAway)
        precondition(fixture.events.prefix(6) == ["pause", "probe", "abort", "stop-viewer", "join-streams", "drain"])
        precondition(fixture.scans == 0)
        fixture.pauseProbe = false
        let restartProfile = try JSONDecoder().decode(LibraryConnectionProfile.self, from: fixture.defaults.data(forKey: LibraryConnectionProfile.storageKey)!)
        precondition(restartProfile.useAway && restartProfile.libraryID == run.libraryID)
        let offResult = await controller.switchEndpoint(useAway: false)
        precondition(offResult)
        fixture.events = []; fixture.failProbe = true
        controller.awayHost = "100.92.22.6"
        let failed0 = await controller.switchEndpoint(useAway: true)
        precondition(!failed0)
        precondition(!controller.useAway && !fixture.events.contains("abort"))
        precondition(controller.awayHost == profile.awayHost && controller.homeHost == profile.homeHost)
        fixture.failProbe = false; fixture.failMain = true
        let failed1 = await controller.switchEndpoint(useAway: true)
        precondition(!failed1)
        precondition(!controller.useAway && controller.message?.contains("復帰しました") == true)
        fixture.failRollback = true
        let failed2 = await controller.switchEndpoint(useAway: true)
        precondition(!failed2)
        precondition(!controller.useAway && controller.message?.contains("再接続にも失敗") == true)
        precondition(fixture.scans == 0)

        let credentialFixture = RouteFixture(), credentialController = credentialFixture.controller(profile)
        credentialController.password = "new-test-secret"
        credentialFixture.failCredentialWrite = true
        let credentialFailure = await credentialController.switchEndpoint(useAway: true)
        precondition(!credentialFailure && !credentialController.useAway)
        precondition(credentialFixture.secrets[profile.credentialReference] == "test-secret")
        precondition(credentialFixture.defaults.data(forKey: LibraryConnectionProfile.storageKey) == nil)
        credentialFixture.failCredentialWrite = false
        credentialController.password = "new-test-secret"
        let credentialSuccess = await credentialController.switchEndpoint(useAway: true)
        precondition(credentialSuccess)
        precondition(credentialController.profile?.credentialReference != profile.credentialReference)
        precondition(credentialFixture.secrets[profile.credentialReference] == "test-secret")
        precondition(credentialFixture.secrets[credentialController.profile!.credentialReference] == "new-test-secret")

        let runningFixture = RouteFixture(), runningController = runningFixture.controller(profile)
        runningFixture.pauseScan = true
        runningFixture.update.requestUpdate()
        await wait { runningFixture.scanGate != nil }
        let interruptedSwitch = await runningController.switchEndpoint(useAway: true)
        precondition(interruptedSwitch && runningFixture.scans == 1)
        precondition(runningFixture.update.state == .cancelled && runningFixture.successfulUpdates == 0)
        precondition(runningFixture.update.recoveryAttempt == 0 && !runningFixture.update.restartRequested)
        runningFixture.update.endSettingsEditing()
        for _ in 0..<100 { await Task.yield() }
        precondition(runningFixture.scans == 1)

        let incomplete = try await store.begin(settings: profile.settings)
        do {
            _ = try await store.finish(incomplete, progress: ScanProgress(), completed: true)
            fatalError("must not confirm massive missing")
        } catch LibraryBindingError.excessiveMissing {}
        _ = try await store.finish(incomplete, progress: ScanProgress(), completed: false)
        let afterDate = try await store.lastSuccessfulUpdate(settings: profile.settings)
        precondition(afterDate == originalDate)
        let selection = try await store.selectMetadata(settings: profile.settings)
        precondition(selection.count == 120)
        var another = home; another.host = "192.168.10.19"
        _ = try await store.prepareInitialUpdate(settings: another)
        do { _ = try await store.migrationProfile(legacy: away); fatalError("ambiguous must stop") }
        catch LibraryBindingError.ambiguous {}
        print("PASS: changed-password transactional references, failure preserves old credential, switch/update cancellation defeats recovery, cache keys/files unchanged")
        print("PASS: UUID/media/history retention, LAN migration selection/ambiguity, Keychain interruption/retry/legacy retention, ON/OFF, probe failure, rollback failure, double toggle, drain ordering, no auto update, restart persistence, massive missing protection")
    }
}
