import Foundation
import SwiftData

nonisolated struct TimelineItem: Sendable, Identifiable, Equatable {
    let id: UUID
    let libraryID: UUID
    let relativePath: String
    let mediaType: String
    let fileExtension: String
    let generation: UUID
    let date: TimelineDate
    let sortKey: String
    // parser非対応と「内部日時なし」を区別できるよう、既存状態をそのまま渡す。
    let metadataState: String?
    let metadataIsCurrent: Bool
}

nonisolated struct TimelineCursor: Sendable {
    let libraryID: UUID
    let revision: Int64
    let keyVersion: Int
    let lastKey: String
}
nonisolated struct TimelinePage: Sendable {
    let items: [TimelineItem]
    let next: TimelineCursor?
    let revision: Int64
}
nonisolated enum TimelineError: LocalizedError {
    case noLibrary, needsPreparation, changedDuringRead
    var errorDescription: String? {
        switch self {
        case .noLibrary: "保存済み接続先のindexがありません。"
        case .needsPreparation: "timeline用の日付キーを準備してください。"
        case .changedDuringRead: "indexが更新されました。timelineを先頭から取得し直してください。"
        }
    }
}

// UIへSwiftDataモデルやModelContextを渡さない。書き込みも同じMediaRepositoryへ委譲する。
actor TimelineRepository {
    private let store: MediaRepository
    init(store: MediaRepository) { self.store = store }
    init(url: URL) throws { store = try MediaRepository(url: url) }

    #if DEBUG
    func originalDateValue(id: UUID, libraryID: UUID) async throws -> String? {
        try await store.savedOriginalDateValue(id: id, libraryID: libraryID)
    }
    #endif

    @discardableResult
    func prepare(settings: SMBConnectionSettings,
                 progress: @Sendable (Int) async -> Void = { _ in }) async throws -> UUID {
        let libraryID = try await store.timelineLibraryID(settings: settings)
        var total = 0
        while true {
            try Task.checkCancellation()
            let count = try await store.buildTimelineBatch(libraryID: libraryID)
            if count == 0 { return libraryID }
            total += count
            await progress(total)
        }
    }

    func page(libraryID: UUID, after cursor: TimelineCursor? = nil) async throws -> TimelinePage {
        try await store.timelinePage(libraryID: libraryID, after: cursor)
    }

    func page(libraryID: UUID, startingAt month: TimelineMonth) async throws -> TimelinePage {
        try await store.timelinePage(libraryID: libraryID, after: nil, startingAt: month)
    }

    func page(libraryID: UUID, around item: TimelineItem) async throws -> TimelinePage {
        try await store.timelinePageAtItem(libraryID: libraryID, item: item)
    }

    func newerPage(libraryID: UUID, before cursor: TimelineCursor) async throws -> TimelinePage {
        try await store.timelinePage(libraryID: libraryID, after: cursor, newer: true)
    }

    func months(libraryID: UUID) async throws -> [TimelineMonth] {
        var result: [TimelineMonth] = []
        var before = "2"
        // 月ごとに1件だけ取得し、その月の全entryを読み飛ばす。
        while let month = try await store.timelineMonth(libraryID: libraryID, before: before) {
            try Task.checkCancellation()
            result.append(month)
            before = month.lowerBound
        }
        return result
    }

    func diagnostics(settings: SMBConnectionSettings,
                     progress: @Sendable (Int) async -> Void = { _ in }) async throws -> TimelineDiagnostics {
        let before = try await store.selectMetadata(settings: settings).count
        let libraryID = try await prepare(settings: settings, progress: progress)
        var result = TimelineDiagnostics()
        var cursor: TimelineCursor?
        repeat {
            let page = try await page(libraryID: libraryID, after: cursor)
            for item in page.items { result.include(item) }
            cursor = page.next
            try Task.checkCancellation()
        } while cursor != nil
        result.pendingMetadataBefore = before
        result.pendingMetadataAfter = try await store.selectMetadata(settings: settings).count
        return result
    }
}

extension MediaRepository {
    private func timelineLibrary(_ id: UUID, context: ModelContext) throws -> Library {
        guard let value = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == id })).first else {
            throw TimelineError.noLibrary
        }
        return value
    }

    func timelineLibraryID(settings: SMBConnectionSettings) throws -> UUID {
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        guard let library = try context().fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.scopeKey == scope })).first else {
            throw TimelineError.noLibrary
        }
        return library.id
    }

    func advanceTimelineRevision(_ id: UUID, context: ModelContext) throws {
        let library = try timelineLibrary(id, context: context)
        library.timelineRevision = (library.timelineRevision ?? 0) + 1
    }

    // 保存前後でUIへ渡す値を比較する。走査sequence・診断文・処理完了時刻は含めない。
    func timelineItem(_ entry: MediaEntry, completed: Int64) -> TimelineItem? {
        guard !entry.isMissing(completedScanSequence: completed),
              ScannedMedia.isSupported(entry.relativePath),
              entry.timelineKeyVersion == TimelinePolicy.version, !entry.timelineSortKey.isEmpty else { return nil }
        return TimelineItem(id: entry.id, libraryID: entry.libraryID, relativePath: entry.relativePath,
                            mediaType: entry.mediaType, fileExtension: entry.fileExtension, generation: entry.generation,
                            date: TimelineDates.resolve(entry), sortKey: entry.timelineSortKey,
                            metadataState: entry.metadataState, metadataIsCurrent: TimelineDates.hasCurrentMetadata(entry))
    }

    private func unpreparedTimeline(_ libraryID: UUID) -> FetchDescriptor<MediaEntry> {
        let version = TimelinePolicy.version
        return FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.libraryID == libraryID && ($0.timelineKeyVersion == nil || $0.timelineKeyVersion != version || $0.timelineSortKey == "")
        })
    }

    // Optional列とdefault値付き列の軽量migration後、旧entryを500件ずつ構築。中断後は未構築分だけ再開。
    // missingもローカル構築しておけば再出現時に利用できる。metadata列には触れない。
    func buildTimelineBatch(libraryID: UUID) throws -> Int {
        try Task.checkCancellation()
        let context = context()
        let library = try timelineLibrary(libraryID, context: context)
        if library.timelinePreparedVersion == TimelinePolicy.version { return 0 }
        var fetch = unpreparedTimeline(libraryID)
        fetch.fetchLimit = TimelinePolicy.buildBatchSize
        let entries = try context.fetch(fetch)
        guard !entries.isEmpty else {
            library.timelinePreparedVersion = TimelinePolicy.version
            try Task.checkCancellation()
            try context.save()
            return 0
        }
        var changed = false
        for entry in entries {
            let before = timelineItem(entry, completed: library.completedScanSequence)
            TimelineDates.apply(to: entry)
            if before != timelineItem(entry, completed: library.completedScanSequence) { changed = true }
        }
        if changed { try advanceTimelineRevision(libraryID, context: context) }
        try Task.checkCancellation()
        try context.save()
        return entries.count
    }

    private func presentTimeline(_ library: Library) -> Predicate<MediaEntry> {
        let libraryID = library.id
        let completed = library.completedScanSequence
        let version = TimelinePolicy.version
        let extensions = ["jpg", "jpeg", "heic", "mov", "mp4"]
        return #Predicate<MediaEntry> {
            $0.libraryID == libraryID && $0.lastSeenSequence >= completed
                && $0.timelineKeyVersion == version && $0.timelineSortKey != "" && extensions.contains($0.fileExtension)
        }
    }

    func timelineMonth(libraryID: UUID, before: String) throws -> TimelineMonth? {
        try Task.checkCancellation()
        let context = context()
        let library = try timelineLibrary(libraryID, context: context)
        guard library.timelinePreparedVersion == TimelinePolicy.version else { throw TimelineError.needsPreparation }
        let present = presentTimeline(library)
        var fetch = FetchDescriptor<MediaEntry>(predicate: #Predicate {
            present.evaluate($0) && $0.timelineSortKey > "1" && $0.timelineSortKey < before
        }, sortBy: [SortDescriptor(\MediaEntry.timelineSortKey, comparator: .lexical, order: .reverse)])
        fetch.fetchLimit = 1
        guard let key = try context.fetch(fetch).first?.timelineSortKey,
              let year = Int(key.dropFirst().prefix(4)),
              let month = Int(key.dropFirst(6).prefix(2)) else { return nil }
        return TimelineMonth(year: year, month: month)
    }

    func timelinePageAtItem(libraryID: UUID, item: TimelineItem) throws -> TimelinePage {
        let id = item.id
        var fetch = FetchDescriptor<MediaEntry>(predicate: #Predicate { $0.id == id && $0.libraryID == libraryID })
        fetch.fetchLimit = 1
        let key = try context().fetch(fetch).first?.timelineSortKey
        // UUID末尾より後の境界にし、基準entry自身を含める。削除時は旧キー直後の項目を使う。
        return try timelinePage(libraryID: libraryID, after: nil, startingKey: (key?.isEmpty == false ? key! : item.sortKey) + "~")
    }

    func timelinePage(libraryID: UUID, after cursor: TimelineCursor?, startingAt month: TimelineMonth? = nil, newer: Bool = false, startingKey: String? = nil) throws -> TimelinePage {
        try Task.checkCancellation()
        let context = context()
        let library = try timelineLibrary(libraryID, context: context)
        let revision = library.timelineRevision ?? 0
        if let cursor {
            guard cursor.libraryID == libraryID, cursor.revision == revision, cursor.keyVersion == TimelinePolicy.version else {
                throw TimelineError.changedDuringRead
            }
        }
        guard library.timelinePreparedVersion == TimelinePolicy.version else { throw TimelineError.needsPreparation }
        let version = TimelinePolicy.version
        let present = presentTimeline(library)
        var fetch: FetchDescriptor<MediaEntry>
        if newer, let cursor {
            let first = cursor.lastKey
            // 最も近い新しい200件を取る。降順で取得すると途中の項目が抜ける。
            fetch = FetchDescriptor(predicate: #Predicate {
                present.evaluate($0) && $0.timelineSortKey > first
            }, sortBy: [SortDescriptor(\MediaEntry.timelineSortKey, comparator: .lexical, order: .forward)])
        } else if let last = cursor?.lastKey ?? startingKey ?? month?.upperBound {
            fetch = FetchDescriptor(predicate: #Predicate {
                present.evaluate($0) && $0.timelineSortKey < last
            }, sortBy: [SortDescriptor(\MediaEntry.timelineSortKey, comparator: .lexical, order: .reverse)])
        } else {
            fetch = FetchDescriptor(predicate: present, sortBy: [SortDescriptor(\MediaEntry.timelineSortKey, comparator: .lexical, order: .reverse)])
        }
        // 1件先読みして最終ページを判断。深いページでもoffsetや全件Swift sortを使わない。
        fetch.fetchLimit = TimelinePolicy.pageSize + 1
        let rows = try context.fetch(fetch)
        var items = rows.prefix(TimelinePolicy.pageSize).map { entry in
            TimelineItem(id: entry.id, libraryID: entry.libraryID, relativePath: entry.relativePath,
                         mediaType: entry.mediaType, fileExtension: entry.fileExtension, generation: entry.generation,
                         date: TimelineDates.resolve(entry), sortKey: entry.timelineSortKey,
                         metadataState: entry.metadataState, metadataIsCurrent: TimelineDates.hasCurrentMetadata(entry))
        }
        if newer { items.reverse() }
        let boundary = newer ? items.first : items.last
        let next = rows.count > TimelinePolicy.pageSize ? boundary.map {
            TimelineCursor(libraryID: libraryID, revision: revision, keyVersion: version, lastKey: $0.sortKey)
        } : nil
        return TimelinePage(items: items, next: next, revision: revision)
    }
}

nonisolated struct TimelineDiagnostics: Sendable {
    var total = 0
    var kinds: [TimelineDateKind: Int] = [:]
    var offsets: [String: Int] = [:]
    var withOffset = 0
    var withoutOffset = 0
    var pendingMetadataBefore = 0
    var pendingMetadataAfter = 0

    mutating func include(_ item: TimelineItem) {
        total += 1
        kinds[item.date.kind, default: 0] += 1
        if let offset = item.date.recordedOffset {
            withOffset += 1; offsets[offset, default: 0] += 1
        } else { withoutOffset += 1 }
    }
}

#if DEBUG
extension MediaRepository {
    func savedOriginalDateValue(id: UUID, libraryID: UUID) throws -> String? {
        var fetch = FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.id == id && $0.libraryID == libraryID
        })
        fetch.fetchLimit = 1
        return try context().fetch(fetch).first?.originalDateValue
    }
}
#endif
