import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var assembling = false
    @State private var dependencies: Result<Dependencies, Error>?

    var body: some Scene {
        WindowGroup {
            Group { switch dependencies {
            case .some(.success(let value)):
                ContentView(update: value.update, connection: value.connection, timelineRepository: value.timeline, thumbnails: value.thumbnails)
                    .environment(value.viewer)
            case .some(.failure(let error)):
                ContentUnavailableView("indexを開けません", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            case .none:
                ProgressView("ライブラリを確認中…")
            } }
            .task {
                guard dependencies == nil, !assembling else { return }
                assembling = true
                do {
                    let value = try await Self.assemble()
                    dependencies = .success(value)
                    value.update.scenePhaseChanged(scenePhase)
                    value.thumbnails.scenePhaseChanged(scenePhase)
                    value.viewer.scenePhaseChanged(scenePhase)
                } catch { dependencies = .failure(error) }
            }
        }
        // AppのscenePhaseを使用する。画面遷移や個別windowの消失では更新を止めない。
        .onChange(of: scenePhase, initial: true) { _, phase in
            if case .some(.success(let value)) = dependencies {
                value.viewer.scenePhaseChanged(phase)
                value.update.scenePhaseChanged(phase)
                value.thumbnails.scenePhaseChanged(phase)
            }
        }
    }

    private struct Dependencies {
        let update: LibraryUpdateController
        let connection: ConnectionSettingsController
        let timeline: TimelineRepository
        let thumbnails: ThumbnailSession
        let viewer: MediaViewerController
    }

    private static func currentSettings() throws -> SMBConnectionSettings {
        if let data = UserDefaults.standard.data(forKey: LibraryConnectionProfile.storageKey) {
            return try JSONDecoder().decode(LibraryConnectionProfile.self, from: data).validated().settings
        }
        guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else { throw ScanFailure.noSettings }
        return try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
    }

    // アプリで使う保存先・Repository・SMB接続制御をここだけで生成する。
    private static func assemble() async throws -> Dependencies {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoJot", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try MediaRepository(url: directory.appendingPathComponent("index.store"))
        let credentials = CredentialStore()
        let defaults = UserDefaults.standard
        var profile: LibraryConnectionProfile?
        if let data = defaults.data(forKey: LibraryConnectionProfile.storageKey) {
            let saved = try JSONDecoder().decode(LibraryConnectionProfile.self, from: data).validated()
            try await repository.validateBinding(saved)
            profile = saved
        } else if let data = defaults.data(forKey: SMBConnectionSettings.storageKey) {
            let legacy = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
            let migrated = try await repository.migrationProfile(legacy: legacy)
            try LibraryConnectionMigration.persist(migrated, legacy: legacy, defaults: defaults,
                read: { try credentials.password(account: $0) },
                write: { try credentials.save(password: $1, account: $0) })
            profile = migrated
        }
        if let profile { await repository.setActiveSettings(profile.settings) }
        let access = SMBAccessCoordinator()
        await access.configureRoute(profile?.revision)
        let scan = ScanService(access: access, repository: repository)
        let metadata = MetadataService(access: access, repository: repository)
        let update = LibraryUpdateController(connection: {
            let settings = try Self.currentSettings()
            guard let password = try CredentialStore().password(account: settings.credentialAccount) else {
                throw ScanFailure.noPassword
            }
            return LibraryUpdateConnection(settings: settings, password: password)
        }, scan: { connection, progress in
            try await scan.scan(settings: connection.settings, password: connection.password, progress: progress)
        }, metadata: { connection, progress in
            try await metadata.complete(settings: connection.settings, password: connection.password, progress: progress)
        }, prepareInitialUpdate: {
            let settings = try Self.currentSettings()
            return try await repository.prepareInitialUpdate(settings: settings)
        }, saveSuccess: { connection in
            try await repository.saveSuccessfulUpdate(settings: connection.settings)
        })
        let thumbnails = ThumbnailSession(cache: .applicationCache(), resolve: { id, libraryID in
            try await repository.thumbnailTarget(id: id, libraryID: libraryID)
        }, generate: { key in
            guard let target = try await repository.thumbnailTarget(id: key.mediaEntryID, libraryID: key.libraryID),
                  target.key == key else { throw CancellationError() }
            guard let password = try await MainActor.run(body: { try credentials.password(account: target.settings.credentialAccount) }) else {
                throw ScanFailure.noPassword
            }
            let data = try await access.thumbnail(target: target, password: password)
            guard try await repository.thumbnailTarget(id: key.mediaEntryID, libraryID: key.libraryID)?.key == key else {
                throw CancellationError()
            }
            return data
        }, disconnect: { await access.disconnectWhenAvailable() })
        let viewer = MediaViewerController(resolve: { id, libraryID in
            try await repository.thumbnailTarget(id: id, libraryID: libraryID)
        }, loadRotation: { try await repository.rotationQuarterTurns(id: $0, libraryID: $1) },
           saveRotation: { try await repository.saveRotationQuarterTurns($0, id: $1, libraryID: $2) }, open: { target in
            guard let password = try credentials.password(account: target.settings.credentialAccount) else { throw ScanFailure.noPassword }
            let handle = try await access.openViewer(target: target, password: password)
            return MediaViewerStream(read: { try await access.readViewer(handle, offset: $0, count: $1) },
                                     close: { await access.closeViewer(handle) })
        })
        let connection = ConnectionSettingsController(update: update, profile: profile,
            makeProbe: { operationID in
                let probe = SMBAccessCoordinator(probeOperationID: operationID)
                return ConnectionProbe(check: { settings, password in
                    try await probe.checkProbe(operationID: operationID, settings: settings, password: password)
                }, disconnect: { await probe.expireProbe(operationID: operationID) },
                   finish: { await probe.finishProbe(operationID: operationID) })
            },
            pauseRequests: { await access.pauseRouteRequests() },
            abortOldRoute: { await access.abortRoute() },
            drainOldRoute: { await access.disconnectWhenAvailable() },
            establishRoute: { try await access.establishRoute(settings: $0, password: $1) },
            activateRoute: { settings in
                await repository.setActiveSettings(settings)
                await access.resumeRouteRequests(version: settings.routeVersion)
            },
            readPassword: { try credentials.password(account: $0) },
            savePassword: { try credentials.save(password: $1, account: $0) },
            deletePassword: { try credentials.delete(account: $0) },
            check: { settings, password in
                // Independent probe: no shared gate, readers, or main-session mutation.
                let probe = SMBAccessCoordinator()
                do {
                    _ = try await probe.checkConnection(settings: settings, password: password)
                    await probe.disconnectWhenAvailable()
                } catch {
                    await probe.disconnectWhenAvailable()
                    throw error
                }
            }, editingChanged: { viewer.setEditing($0); thumbnails.setEditing($0) },
            beginThumbnailCheck: { await viewer.stop(); await thumbnails.beginConnectionCheck() },
            endThumbnailCheck: { thumbnails.endConnectionCheck() },
            lastSuccessfulUpdate: { try await repository.lastSuccessfulUpdate(settings: $0) })
        return Dependencies(update: update, connection: connection,
                            timeline: TimelineRepository(store: repository), thumbnails: thumbnails, viewer: viewer)
    }
}
