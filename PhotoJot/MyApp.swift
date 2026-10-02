import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies: Result<Dependencies, Error> = Result { try Self.assemble() }

    var body: some Scene {
        WindowGroup {
            switch dependencies {
            case .success(let value):
                ContentView(update: value.update, coordinator: value.access, timelineRepository: value.timeline)
            case .failure(let error):
                ContentUnavailableView("indexを開けません", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            }
        }
        // AppのscenePhaseを使用する。画面遷移や個別windowの消失では更新を止めない。
        .onChange(of: scenePhase, initial: true) { _, phase in
            if case .success(let value) = dependencies { value.update.scenePhaseChanged(phase) }
        }
    }

    private struct Dependencies {
        let update: LibraryUpdateController
        let access: SMBAccessCoordinator
        let timeline: TimelineRepository
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
        return Dependencies(update: update, access: access, timeline: TimelineRepository(store: repository))
    }
}
