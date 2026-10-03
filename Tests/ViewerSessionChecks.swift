import Foundation

private func check(_ value: Bool, _ label: String) { precondition(value, label) }

private actor ViewerFeed {
    var items: [TimelineItem]
    var revision: Int64 = 1
    var reads = 0
    init(_ items: [TimelineItem]) { self.items = items }
    func read(cursor: TimelineCursor?, anchor: TimelineItem? = nil, newer: Bool = false) throws -> TimelinePage {
        reads += 1
        if let cursor, cursor.revision != revision { throw TimelineError.changedDuringRead }
        let filtered: [TimelineItem]
        if let anchor {
            filtered = Array(items.drop(while: { $0.id != anchor.id }))
        } else if let cursor {
            filtered = items.filter { newer ? $0.sortKey > cursor.lastKey : $0.sortKey < cursor.lastKey }
        } else { filtered = items }
        let page = newer ? Array(filtered.suffix(200)) : Array(filtered.prefix(200))
        let boundary = newer ? page.first : page.last
        let next = filtered.count > 200 ? boundary.map {
            TimelineCursor(libraryID: $0.libraryID, revision: revision, keyVersion: TimelinePolicy.version, lastKey: $0.sortKey)
        } : nil
        return TimelinePage(items: page, next: next, revision: revision)
    }
    func replace(_ item: TimelineItem) {
        items = items.map { $0.id == item.id ? item : $0 }; revision += 1
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; revision += 1 }
    nonisolated func source() -> TimelinePageSource {
        TimelinePageSource(prepare: { UUID() }, page: { _, c in try await self.read(cursor: c) },
                           newerPage: { _, c in try await self.read(cursor: c, newer: true) },
                           anchorPage: { _, i in try await self.read(cursor: nil, anchor: i) })
    }
}

@main struct ViewerSessionChecks {
    @MainActor static func main() async throws {
        let library = UUID()
        func item(_ n: Int, generation: UUID? = nil) -> TimelineItem {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            let date = TimelineDate(calendarDateTime: n == 0 ? nil : "2024-08-31T12:00:00", recordedOffset: nil,
                                    kind: n == 0 ? .unknown : .internalMetadata, source: nil, quality: nil)
            return TimelineItem(id: id, libraryID: library, relativePath: "\(n).\(n % 2 == 0 ? "jpg" : "mov")",
                                mediaType: n % 2 == 0 ? "photo" : "video", fileExtension: n % 2 == 0 ? "jpg" : "mov",
                                generation: generation ?? id, date: date, sortKey: date.sortKey(id: id),
                                metadataState: "complete", metadataIsCurrent: true)
        }
        let all = (0..<1600).reversed().map { item($0) }
        let feed = ViewerFeed(all)
        let session = ViewerSession(item: item(800), source: feed.source())
        session.begin(); await session.waitForSupply()
        check(session.currentItem.id == item(800).id && session.items.contains(item(800)), "anchor retained")
        check(session.items.first == item(1000) && session.items.last == item(601), "both initial directions from anchor")
        func validate() {
            check(session.items.count <= 600, "bounded window")
            check(Set(session.items.map(\.id)).count == session.items.count, "unique IDs")
            check(session.items.map(\.sortKey) == session.items.map(\.sortKey).sorted(by: >), "stable same-date UUID ordering")
            let start = all.firstIndex(where: { $0.id == session.items[0].id })!
            check(session.items.map(\.id) == all[start..<(start + session.items.count)].map(\.id), "no gaps at window or page boundaries")
        }
        // Walk across multiple windows in both directions, including the unknown-date tail.
        for n in stride(from: 800, through: 0, by: -1) {
            guard let target = session.items.first(where: { $0.id == item(n).id }) else { fatalError("missing older neighbour") }
            session.commit(target); await session.waitForSupply(); validate()
        }
        check(!session.hasOlder && session.currentItem.date.calendarDateTime == nil, "oldest / unknown preserved")
        for n in 0..<1600 {
            guard let target = session.items.first(where: { $0.id == item(n).id }) else { fatalError("missing newer neighbour") }
            session.commit(target); await session.waitForSupply(); validate()
        }
        check(!session.hasNewer && session.currentItem == item(1599), "newest reached")

        let changedFeed = ViewerFeed(all)
        let changed = ViewerSession(item: item(800), source: changedFeed.source())
        changed.begin(); await changed.waitForSupply()
        let refreshed = item(990, generation: UUID())
        await changedFeed.replace(refreshed)
        changed.commit(item(990)); await changed.waitForSupply()
        check(changed.currentItem == refreshed && changed.errorMessage == nil, "revision rebase refreshes current generation by ID")
        check(changed.items.filter { $0.id == refreshed.id } == [refreshed], "no mixed generations")

        let missingFeed = ViewerFeed(all)
        await missingFeed.remove(item(800).id)
        let missing = ViewerSession(item: item(800), source: missingFeed.source())
        missing.begin(); await missing.waitForSupply()
        check(missing.currentItem.id == item(800).id && missing.errorMessage != nil, "missing anchor never silently selects another media")
        let stopped = ViewerSession(item: item(800), source: feed.source())
        stopped.begin(); stopped.close(); await stopped.waitForSupply()
        stopped.commit(item(1))
        check(stopped.currentItem.id == item(800).id && !stopped.isLoading, "closed session cannot adopt selection")
        // Exercise the same provider against actual SwiftData/keyset queries, not only a feed.
        let repo = try MediaRepository(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        var settings = SMBConnectionSettings(); settings.host = "test"; settings.share = "photos"; settings.username = "test"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let scan = try await repo.begin(settings: settings)
        try await repo.ingest((0..<450).map { .init(path: "\($0).jpg", size: 1, creation: date, modified: date) }, ticket: scan, progress: .init())
        _ = try await repo.finish(scan, progress: .init(), completed: true)
        let repository = TimelineRepository(store: repo)
        let lib = try await repository.prepare(settings: settings)
        let origin = try await repository.page(libraryID: lib).items[100]
        let changedScan = try await repo.begin(settings: settings)
        try await repo.ingest([.init(path: origin.relativePath, size: 2, creation: date, modified: date)], ticket: changedScan, progress: .init())
        _ = try await repo.finish(changedScan, progress: .init(), completed: false)
        let real = ViewerSession(item: origin, source: .local(repository: repository, settings: settings))
        real.begin(); await real.waitForSupply()
        check(real.currentItem.id == origin.id && real.currentItem.generation != origin.generation, "real repository refreshes generation without changing anchor ID")
        var walked = [origin.id]
        while let index = real.items.firstIndex(where: { $0.id == real.currentItem.id }), index + 1 < real.items.count {
            real.commit(real.items[index + 1]); await real.waitForSupply(); walked.append(real.currentItem.id)
        }
        check(walked.count == 350 && Set(walked).count == 350 && !real.hasOlder, "real keyset queries cross older page boundary without gaps")
        real.close()
        print("ViewerSessionChecks passed: bounded bidirectional windows, boundaries, stable UUID order, revision/generation, missing and close")
    }
}
