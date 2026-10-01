import Foundation

nonisolated struct MetadataProgress: Sendable {
    var total = 0
    var completed = 0
    var unknown = 0
}

actor MetadataService {
    private let repository: MediaRepository
    private let access: SMBAccessCoordinator
    private var active = false
    private var counts = MetadataProgress()

    init(access: SMBAccessCoordinator, storeURL: URL) throws {
        self.access = access
        repository = try MediaRepository(url: storeURL)
    }

    func complete(settings: SMBConnectionSettings, password: String,
                  progress: @Sendable (MetadataProgress) async -> Void) async throws {
        guard !active else { throw IndexFailure.invalidState }
        active = true
        defer { active = false }
        let selection = try await repository.selectMetadata(settings: settings)
        counts = MetadataProgress(total: selection.count)
        await progress(counts)
        guard selection.count > 0 else { return }
        try await access.completeMetadata(settings: settings, password: password, next: {
            try await self.repository.metadataBatch(libraryID: selection.libraryID)
        }, save: { updates in
            try await self.persist(updates)
            await progress(self.snapshot())
        })
    }

    private func persist(_ updates: [MetadataUpdate]) async throws {
        try await repository.saveMetadata(updates)
        counts.completed += updates.filter { !$0.outcome.requiresRetry }.count
        counts.unknown += updates.filter { !$0.outcome.requiresRetry && $0.outcome.resolution.displayDate == nil }.count
    }
    private func snapshot() -> MetadataProgress { counts }
}
