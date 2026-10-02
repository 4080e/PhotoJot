import Foundation
import SwiftData

nonisolated struct MetadataTarget: Sendable {
    let id: UUID
    let libraryID: UUID
    let generation: UUID
    let file: ScannedMedia
}
nonisolated struct MetadataUpdate: Sendable {
    let target: MetadataTarget
    let outcome: MetadataOutcome
}
nonisolated struct MetadataSelection: Sendable {
    let libraryID: UUID
    let count: Int
}
nonisolated enum MetadataServiceError: LocalizedError {
    case noLibrary, interruptedRead, staleIndex
    var errorDescription: String? {
        switch self {
        case .noLibrary: "保存済みの接続先に対応するindexがありません。先に走査してください。"
        case .interruptedRead: "SMB読み込み・終了処理、または未分類の解析処理に失敗しました。未完了分は次回再試行します。ファイルが変わった場合は先に再走査してください。"
        case .staleIndex: "処理中にindexが変更されました。再走査後に解析してください。"
        }
    }
}

extension MediaRepository {
    private func metadataLibrary(_ id: UUID, context: ModelContext) throws -> Library {
        guard let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == id })).first else {
            throw MetadataServiceError.noLibrary
        }
        return library
    }

    private func pendingMetadata(libraryID: UUID, completed: Int64, version: Int) -> FetchDescriptor<MediaEntry> {
        let extensions = ["jpg", "jpeg", "heic", "mov", "mp4"]
        let present = #Predicate<MediaEntry> {
            $0.libraryID == libraryID && $0.lastSeenSequence >= completed && extensions.contains($0.fileExtension)
        }
        let absentGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let pending = #Predicate<MediaEntry> {
            $0.metadataCompletedAt == nil || ($0.metadataGeneration ?? absentGeneration) != $0.generation || $0.metadataVersion != version
        }
        return FetchDescriptor<MediaEntry>(predicate: #Predicate {
            present.evaluate($0) && pending.evaluate($0)
        }, sortBy: [SortDescriptor(\MediaEntry.pathKey)])
    }

    func selectMetadata(settings: SMBConnectionSettings, version: Int = MetadataPolicy.version) throws -> MetadataSelection {
        let context = context()
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        guard let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.scopeKey == scope })).first else {
            throw MetadataServiceError.noLibrary
        }
        let count = try context.fetchCount(pendingMetadata(libraryID: library.id, completed: library.completedScanSequence, version: version))
        return MetadataSelection(libraryID: library.id, count: count)
    }

    func metadataBatch(libraryID: UUID, version: Int = MetadataPolicy.version) throws -> [MetadataTarget] {
        try Task.checkCancellation()
        let context = context()
        let library = try metadataLibrary(libraryID, context: context)
        var fetch = pendingMetadata(libraryID: libraryID, completed: library.completedScanSequence, version: version)
        fetch.fetchLimit = MetadataPolicy.batchSize
        return try context.fetch(fetch).map {
            MetadataTarget(id: $0.id, libraryID: $0.libraryID, generation: $0.generation,
                file: ScannedMedia(path: $0.relativePath, size: $0.fileSize, creation: $0.smbCreationTime, modified: $0.smbLastWriteTime))
        }
    }

    func saveMetadata(_ updates: [MetadataUpdate], version: Int = MetadataPolicy.version) throws {
        guard !updates.isEmpty else { return }
        guard updates.count <= MetadataPolicy.batchSize else { throw IndexFailure.invalidState }
        let context = context()
        let ids = updates.map { $0.target.id }
        let entries = try context.fetch(FetchDescriptor<MediaEntry>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var completedSequences: [UUID: Int64] = [:]
        for id in Set(updates.map { $0.target.libraryID }) {
            completedSequences[id] = try metadataLibrary(id, context: context).completedScanSequence
        }
        var changedLibraries = Set<UUID>()
        for update in updates {
            let target = update.target
            guard let entry = byID[target.id], entry.libraryID == target.libraryID,
                  entry.generation == target.generation, entry.pathKey == target.file.pathKey else {
                throw MetadataServiceError.staleIndex
            }
            guard let completed = completedSequences[entry.libraryID] else { throw MetadataServiceError.noLibrary }
            let before = timelineItem(entry, completed: completed)
            defer {
                TimelineDates.apply(to: entry)
                if before != timelineItem(entry, completed: completed) {
                    changedLibraries.insert(entry.libraryID)
                }
            }
            entry.clearMetadata()
            let outcome = update.outcome, result = outcome.resolution
            entry.metadataState = outcome.state
            entry.metadataDiagnostic = String(result.diagnostics.map { "\($0.kind.rawValue): \($0.message)" }.joined(separator: "\n").prefix(1024))
            // 一時的失敗のSMB fallbackを「解析完了」として固定しない。
            if outcome.requiresRetry { continue }
            switch result.displayDate {
            case .absolute(let date): entry.resolvedInstant = date
            case .floating(let raw): entry.resolvedFloatingDate = raw
            case nil: break
            }
            entry.dateSource = result.source?.rawValue; entry.dateQuality = result.quality?.rawValue
            entry.dateFallback = result.fallback
            entry.originalDateValue = result.originalValue; entry.utcOffset = result.utcOffset; entry.subsecond = result.subsecond
            entry.metadataGeneration = target.generation; entry.metadataVersion = version
            entry.metadataCompletedAt = Date()
        }
        for libraryID in changedLibraries {
            try advanceTimelineRevision(libraryID, context: context)
        }
        try Task.checkCancellation()
        try context.save()
    }
}
