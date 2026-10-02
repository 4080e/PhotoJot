import Foundation
import SwiftData

private func check(_ value: Bool, _ label: String) { precondition(value, label) }

// 実際のControllerへpage単位の入力を渡す。ネットワーク・SwiftUIなしで重複triggerを検証。
private actor PageFeed {
    let libraryID = UUID()
    var pages: [TimelinePage]
    var requests: [String?] = []
    var preparations = 0
    var invalidateNext = false
    var failNext = false
    var suspended = false
    var waiter: CheckedContinuation<Void, Never>?
    var began: CheckedContinuation<Void, Never>?
    var didBegin = false

    init(pages: [TimelinePage]) { self.pages = pages }
    func prepare() -> UUID { preparations += 1; return libraryID }
    func read(after cursor: TimelineCursor?) async throws -> TimelinePage {
        requests.append(cursor?.lastKey)
        if suspended {
            didBegin = true; began?.resume(); began = nil
            await withCheckedContinuation { waiter = $0 }
        }
        if invalidateNext { invalidateNext = false; throw TimelineError.changedDuringRead }
        if failNext { failNext = false; throw TimelineError.needsPreparation }
        return pages.removeFirst()
    }
    func suspend() { suspended = true; didBegin = false }
    func waitForRead() async {
        if !didBegin { await withCheckedContinuation { began = $0 } }
    }
    func release() { suspended = false; waiter?.resume(); waiter = nil }
    func invalidate(with replacement: TimelinePage) { invalidateNext = true; pages = [replacement] }
    func fail() { failNext = true }
    func requestCount() -> Int { requests.count }
    func prepareCount() -> Int { preparations }
    nonisolated func source() -> TimelinePageSource {
        TimelinePageSource(prepare: { await self.prepare() }, page: { _, cursor in try await self.read(after: cursor) })
    }
}

@main struct TimelineUIChecks {
    @MainActor static func main() async throws {
        let lib = UUID()
        func item(_ number: Int, date: String? = "2026-01-02T12:00:00", offset: String? = "+09:00", video: Bool = false) -> TimelineItem {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
            let value = TimelineDate(calendarDateTime: date, recordedOffset: offset, kind: date == nil ? .unknown : .internalMetadata,
                                     source: nil, quality: nil)
            return TimelineItem(id: id, libraryID: lib, relativePath: "\(number).\(video ? "mov" : "jpg")",
                                mediaType: video ? "video" : "photo", fileExtension: video ? "mov" : "jpg",
                                generation: id, date: value, sortKey: value.sortKey(id: id), metadataState: "complete", metadataIsCurrent: true)
        }
        func page(_ items: [TimelineItem], more: Bool) -> TimelinePage {
            let cursor = more ? TimelineCursor(libraryID: lib, revision: 1, keyVersion: TimelinePolicy.version, lastKey: items.last!.sortKey) : nil
            return TimelinePage(items: items, next: cursor, revision: 1)
        }
        let first = (201...400).reversed().map { item($0, video: $0 % 2 == 0) }
        let second = [item(200, offset: nil), item(199, offset: "-05:00"), item(198), item(197, offset: nil),
                      item(196, date: nil, offset: nil)]
        let third = [item(195, date: nil, offset: nil)]
        let feed = PageFeed(pages: [page(first, more: true), page(second, more: true), page(third, more: false)])
        let model = TimelineController(source: feed.source())
        await model.loadInitial()
        check(model.loadedCount == 200 && model.blocks.count == 1 && model.hasMore, "initial 200 only")
        check(await feed.requestCount() == 1, "no eager load of all pages")
        check(model.heading(for: model.blocks[0]) == "2026年1月2日", "single offset hidden, includes year")
        check(Set(model.blocks[0].items.map(\.mediaType)) == ["photo", "video"], "mixed placeholders")
        await model.loadInitial()
        check(await feed.requestCount() == 1, "initial trigger duplicate ignored")
        await model.loadMoreIfNeeded(visibleID: first[0].id)
        check(await feed.requestCount() == 1, "not near end")

        await feed.suspend()
        let loading = Task { await model.loadMoreIfNeeded(visibleID: first.last!.id) }
        await feed.waitForRead()
        await model.loadMoreIfNeeded(visibleID: first.last!.id)
        check(await feed.requestCount() == 2, "same cursor not loaded concurrently")
        await feed.release(); await loading.value
        check(model.loadedCount == 205 && model.blocks.count == 2, "mixed offsets share one day plus unknown")
        check(model.blocks[0].items.count == 204 && model.blocks[0].id == first[0].id, "page boundary merges despite changed offset")
        check(model.heading(for: model.blocks[0]) == "2026年1月2日", "heading never includes offset")
        check(Set(model.blocks[0].items.map { $0.date.recordedOffset }) == Set<String?>([nil, "+09:00", "-05:00"]), "all offset values retained within one day")
        check(model.heading(for: model.blocks[1]) == "日時不明", "unknown heading")
        await model.loadMoreIfNeeded(visibleID: first.last!.id)
        check(await feed.requestCount() == 2, "old page trigger cannot request new cursor")
        await model.loadMoreIfNeeded(visibleID: second.last!.id)
        check(model.loadedCount == 206 && !model.hasMore, "final page")
        check(model.blocks.count == 2 && model.blocks.last!.items.count == 2, "unknown crosses page as one group")
        check(model.blocks.flatMap(\.items).map(\.id) == (first + second + third).map(\.id), "repository order unchanged")
        await model.loadMoreIfNeeded(visibleID: third[0].id)
        check(await feed.requestCount() == 3, "no load after final page")

        let differentDay = item(194, date: "2026-01-01T23:30:00", offset: "-05:00")
        let dayModel = TimelineController(source: PageFeed(pages: [page([first[0], differentDay], more: false)]).source())
        await dayModel.loadInitial()
        check(dayModel.blocks.count == 2 && dayModel.heading(for: dayModel.blocks[1]) == "2026年1月1日", "different calendar days separate")

        let resetFeed = PageFeed(pages: [page(first, more: true)])
        let resetting = TimelineController(source: resetFeed.source())
        await resetting.loadInitial()
        let oldDisplay = resetting.displayGeneration
        let replacement = item(999, date: "2027-01-01T00:00:00")
        await resetFeed.invalidate(with: page([replacement], more: false))
        await resetting.loadMoreIfNeeded(visibleID: first.last!.id)
        check(resetting.loadedCount == 1 && resetting.blocks[0].items[0].id == replacement.id, "cursor invalidation replaces old pages")
        check(resetting.displayGeneration != oldDisplay && resetting.errorMessage == nil, "reset scroll identity")
        check(await resetFeed.prepareCount() == 2, "one re-prepare")
        check(await resetFeed.requestCount() == 3, "one bounded restart")

        let failingFeed = PageFeed(pages: [page(first, more: true), page(third, more: false)])
        let failing = TimelineController(source: failingFeed.source())
        await failing.loadInitial(); await failingFeed.fail()
        await failing.loadMoreIfNeeded(visibleID: first.last!.id)
        check(failing.errorMessage != nil && failing.loadedCount == 200, "failed page retains existing data")
        await failing.loadMoreIfNeeded(visibleID: first.last!.id)
        check(await failingFeed.requestCount() == 2, "no automatic error retry loop")
        await failing.retry()
        check(failing.loadedCount == 201 && failing.errorMessage == nil, "explicit retry succeeds")

        let cancellationFeed = PageFeed(pages: [page(first, more: true), page(third, more: false)])
        let cancelledModel = TimelineController(source: cancellationFeed.source())
        await cancelledModel.loadInitial()
        await cancellationFeed.suspend()
        let cancelledRead = Task { await cancelledModel.loadMoreIfNeeded(visibleID: first.last!.id) }
        await cancellationFeed.waitForRead()
        cancelledRead.cancel()
        await cancellationFeed.release(); await cancelledRead.value
        check(cancelledModel.loadedCount == 200 && cancelledModel.hasMore && !cancelledModel.isLoading, "cancelled response never appended")
        check(cancelledModel.errorMessage == nil, "view cancellation not shown as an error")

        let empty = TimelineController(source: PageFeed(pages: [page([], more: false)]).source())
        await empty.loadInitial()
        check(empty.hasLoaded && empty.blocks.isEmpty && !empty.hasMore && empty.errorMessage == nil, "empty library")
        let absent = TimelineController(source: TimelinePageSource(prepare: { throw TimelineError.noLibrary }, page: { _, _ in fatalError("must not page") }))
        await absent.loadInitial()
        check(absent.hasLoaded && absent.blocks.isEmpty && absent.errorMessage == nil, "no saved library")

        let emptyFeed = PageFeed(pages: [page([], more: false), page([replacement], more: false)])
        let refreshEmpty = TimelineController(source: emptyFeed.source())
        await refreshEmpty.loadInitial()
        await refreshEmpty.retry()
        check(refreshEmpty.loadedCount == 1, "empty/no-next explicit retry rereads first page")
        let retainedGeneration = refreshEmpty.displayGeneration
        await refreshEmpty.reloadIfEmpty()
        check(await emptyFeed.requestCount() == 2 && refreshEmpty.displayGeneration == retainedGeneration,
              "update completion never resets populated timeline")

        let racingFeed = PageFeed(pages: [page([], more: false), page([replacement], more: false)])
        await racingFeed.suspend()
        let racing = TimelineController(source: racingFeed.source())
        let initialRead = Task { await racing.loadInitial() }
        await racingFeed.waitForRead()
        await racing.reloadIfEmpty() // 走査終了が初回の空page読み込みに重なる。
        await racingFeed.release()
        await initialRead.value
        check(racing.loadedCount == 1 && !racing.isLoading, "empty reload request survives in-flight read")

        // 実repositoryでprepared indexを起動。metadata/SMBモジュールのネットワーク実装はこのtest binaryへ含めない。
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = try MediaRepository(url: url)
        let settings = SMBConnectionSettings(host: "not-a-real-smb-host.invalid", username: "test", share: "fixture")
        let scan = try await repository.begin(settings: settings)
        let files = (0..<203).map { ScannedMedia(path: "\($0).\($0 % 2 == 0 ? "jpg" : "mov")", size: 100,
                                              creation: Date(timeIntervalSince1970: 1000), modified: Date(timeIntervalSince1970: 2000)) }
        try await repository.ingest(files, ticket: scan, progress: .init())
        _ = try await repository.finish(scan, progress: .init(), completed: true)
        let resolution = MetadataCore.outcome(format: .jpeg, evidence: .init(exif: .init(original: "2026:01:02 12:00:00", offset: nil, subsecond: nil)), creation: nil, modified: nil)
        while true {
            let targets = try await repository.metadataBatch(libraryID: scan.libraryID)
            if targets.isEmpty { break }
            try await repository.saveMetadata(targets.map { MetadataUpdate(target: $0, outcome: resolution) })
        }
        let removal = try await repository.begin(settings: settings)
        try await repository.ingest(Array(files.prefix(202)), ticket: removal, progress: .init())
        _ = try await repository.finish(removal, progress: .init(), completed: true)
        let timeline = TimelineRepository(store: repository)
        _ = try await timeline.prepare(settings: settings)
        let before = try await timeline.page(libraryID: scan.libraryID)
        let local = TimelineController(source: .local(repository: timeline, settings: settings))
        await local.loadInitial()
        check(local.loadedCount == 200 && local.hasMore, "real initial bounded page")
        await local.loadMoreIfNeeded(visibleID: local.blocks.last!.items.last!.id)
        check(local.loadedCount == 202 && !local.hasMore, "real final page excludes missing")
        check(!local.blocks.flatMap(\.items).contains { $0.relativePath == files.last!.path }, "missing entry absent")
        let after = try await timeline.page(libraryID: scan.libraryID)
        check(before.revision == after.revision, "opening prepared timeline does not rebuild keys")
        check(try await repository.selectMetadata(settings: settings).count == 0, "opening does not requeue metadata")
        let reopened = TimelineController(source: .local(repository: try TimelineRepository(url: url), settings: settings))
        await reopened.loadInitial()
        check(reopened.blocks.flatMap(\.items).map(\.id) == before.items.map(\.id), "offline reopen stable order")
        // 別Libraryで同じパスを使っても既存のscope識別で混ざらない。
        var otherSettings = settings; otherSettings.share = "other"
        let other = TimelineController(source: .local(repository: timeline, settings: otherSettings))
        await other.loadInitial()
        check(other.hasLoaded && other.blocks.isEmpty, "new library starts empty, never shows old library")
        let otherScan = try await repository.begin(settings: otherSettings)
        try await repository.ingest([files[0]], ticket: otherScan, progress: .init())
        // 更新の正常完了を待たずに保存済みバッチを読める。
        await other.reloadIfEmpty()
        check(other.loadedCount == 1 && other.blocks.flatMap(\.items).allSatisfy { $0.libraryID == otherScan.libraryID },
              "new library visible while scan running; old entries excluded")
        check(local.loadedCount == 202 && local.blocks.flatMap(\.items).allSatisfy { $0.libraryID == scan.libraryID },
              "old controller stays bound to original library")
        _ = try await repository.finish(otherScan, progress: .init(), completed: true)
        let switchBack = TimelineController(source: .local(repository: timeline, settings: settings))
        await switchBack.loadInitial()
        check(switchBack.loadedCount == 200 && switchBack.blocks.flatMap(\.items).allSatisfy { $0.libraryID == scan.libraryID },
              "switch back reads only original library")
        print("PASS: empty retry, no-library recovery, reload during initial read, populated display preserved, offline/index-first, library isolation and switch back")
        print("Timeline UI checks passed: first/next/final, duplicate suppression, incremental groups, mixed offsets, unknown, stable order, invalidation, retry, empty, local-only repository, missing exclusion, metadata preservation")
    }
}
