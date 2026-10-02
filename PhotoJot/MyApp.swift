import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies: Result<Dependencies, Error> = Result { try Self.assemble() }

    var body: some Scene {
        WindowGroup {
            switch dependencies {
            case .success(let value):
                ContentView(update: value.update, connection: value.connection, timelineRepository: value.timeline, thumbnails: value.thumbnails)
            case .failure(let error):
                ContentUnavailableView("indexを開けません", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            }
        }
        // AppのscenePhaseを使用する。画面遷移や個別windowの消失では更新を止めない。
        .onChange(of: scenePhase, initial: true) { _, phase in
            if case .success(let value) = dependencies {
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
    }

    // アプリで使う保存先・Repository・SMB接続制御をここだけで生成する。
    private static func assemble() throws -> Dependencies {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoJot", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try MediaRepository(url: directory.appendingPathComponent("index.store"))
        let access = SMBAccessCoordinator()
        let scan = ScanService(access: access, repository: repository)
        let metadata = MetadataService(access: access, repository: repository)
        let update = LibraryUpdateController(connection: {
            guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else {
                throw ScanFailure.noSettings
            }
            let settings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
            guard let password = try CredentialStore().password(account: settings.credentialAccount) else {
                throw ScanFailure.noPassword
            }
            return LibraryUpdateConnection(settings: settings, password: password)
        }, scan: { connection, progress in
            try await scan.scan(settings: connection.settings, password: connection.password, progress: progress)
        }, metadata: { connection, progress in
            try await metadata.complete(settings: connection.settings, password: connection.password, progress: progress)
        })
        let credentials = CredentialStore()
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
        let connection = ConnectionSettingsController(update: update,
            readPassword: { try credentials.password(account: $0) },
            savePassword: { try credentials.save(password: $1, account: $0) },
            deletePassword: { try credentials.delete(account: $0) },
            check: { settings, password in
                _ = try await access.checkConnection(settings: settings, password: password)
            }, editingChanged: { thumbnails.setEditing($0) },
            beginThumbnailCheck: { await thumbnails.beginConnectionCheck() },
            endThumbnailCheck: { thumbnails.endConnectionCheck() })
        return Dependencies(update: update, connection: connection,
                            timeline: TimelineRepository(store: repository), thumbnails: thumbnails)
    }
}
