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
        TimelinePageSource(prepare: { await self.prepare() }, page: { _, cursor in try await self.read(after: cursor) },
                           anchorPage: { _, _ in try await self.read(after: nil) })
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
        check(resetting.displayGeneration == oldDisplay && resetting.errorMessage == nil, "revision refresh does not issue another jump")
        check(await resetFeed.prepareCount() == 1, "viewport refresh does not re-prepare the month origin")
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
        // 年月ジャンプも実SwiftData indexを使う。選択月は200件を超え、同日時の境界を跨ぐ。
        var jumpSettings = settings; jumpSettings.share = "month-jump"
        let iso = ISO8601DateFormatter()
        func dated(_ path: String, _ date: String?) -> ScannedMedia {
            ScannedMedia(path: path, size: 100, creation: date.flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: -11644473600), modified: Date(timeIntervalSince1970: -11644473600))
        }
        let august = (0..<205).map { dated("aug/\($0).jpg", "2024-08-31T23:59:59Z") }
        let newerFiles = (0..<450).map { dated("newer/\($0).jpg", "2024-09-01T00:00:00Z") }
        let monthFiles = august + newerFiles + [
            dated("latest.mov", "2025-01-01T00:00:00Z"),
            dated("september.jpg", "2024-09-01T00:00:00Z"),
            dated("aug-start.jpg", "2024-08-01T00:00:00Z"),
            dated("july.jpg", "2024-07-31T23:59:59Z"),
            dated("january.jpg", "2024-01-01T00:00:00Z"),
            dated("december.jpg", "2023-12-31T23:59:59Z"),
            dated("unknown.jpg", nil)
        ]
        let monthScan = try await repository.begin(settings: jumpSettings)
        let initialMonthFiles = monthFiles + [dated("removed.jpg", "2030-06-01T00:00:00Z")]
        for offset in stride(from: 0, to: initialMonthFiles.count, by: 200) {
            try await repository.ingest(Array(initialMonthFiles.dropFirst(offset).prefix(200)), ticket: monthScan, progress: .init())
        }
        _ = try await repository.finish(monthScan, progress: .init(), completed: true)
        let monthRemoval = try await repository.begin(settings: jumpSettings)
        for offset in stride(from: 0, to: monthFiles.count, by: 200) {
            try await repository.ingest(Array(monthFiles.dropFirst(offset).prefix(200)), ticket: monthRemoval, progress: .init())
        }
        _ = try await repository.finish(monthRemoval, progress: .init(), completed: true)
        let jumping = TimelineController(source: .local(repository: timeline, settings: jumpSettings))
        await jumping.loadInitial()
        let candidates = try await jumping.availableMonths()
        check(candidates.map(\.id) == ["2025-01", "2024-09", "2024-08", "2024-07", "2024-01", "2023-12"], "only present months, no unknown/missing/other library")
        let aug = TimelineMonth(year: 2024, month: 8)
        let beforeJumpDisplay = jumping.displayGeneration
        await jumping.jump(to: aug)
        check(jumping.selectedMonth == aug && jumping.displayGeneration != beforeJumpDisplay, "jump replaces origin")
        let jumped = jumping.blocks.flatMap(\.items)
        check(jumped.count == 200 && jumped.allSatisfy { $0.relativePath.hasPrefix("aug/") }, "direct bounded page starts at newest in selected month")
        check(jumped.map(\.sortKey) == jumped.map(\.sortKey).sorted(by: >), "tie order stable")
        let jumpDisplay = jumping.displayGeneration
        await jumping.loadMoreIfNeeded(visibleID: jumped.last!.id)
        let entireJump = jumping.blocks.flatMap(\.items)
        check(entireJump.count == 210 && Set(entireJump.map(\.id)).count == 210 && !jumping.hasMore, "next page no gaps or duplicates")
        check(entireJump.map(\.sortKey) == entireJump.map(\.sortKey).sorted(by: >), "ties stable across pages")
        check(entireJump.last?.date.kind == .unknown, "unknown remains in normal paging")
        check(jumping.displayGeneration == jumpDisplay, "paging retains scroll identity")
        let anchor = entireJump[3].id
        jumping.visibleItemID = anchor
        let originalBlockID = jumping.blocks.first!.id
        await jumping.loadNewerIfNeeded(visibleID: anchor)
        check(jumping.loadedCount == 410 && jumping.hasNewer, "newer fetch bounded to 200")
        check(jumping.visibleItemID == anchor && jumping.displayGeneration == jumpDisplay, "prepend preserves current media anchor and scroll identity")
        check(jumping.blocks.contains { $0.id == originalBlockID }, "old block identity retained")
        await jumping.loadNewerIfNeeded(visibleID: jumping.blocks.first!.items.first!.id)
        check(jumping.loadedCount == 610 && jumping.hasNewer, "second newer page")
        await jumping.loadNewerIfNeeded(visibleID: jumping.blocks.first!.items.first!.id)
        let bidirectional = jumping.blocks.flatMap(\.items)
        check(bidirectional.count == monthFiles.count && !jumping.hasNewer && !jumping.hasMore, "latest and oldest reached independently")
        check(Set(bidirectional.map(\.id)).count == monthFiles.count, "no bidirectional duplicates")
        check(bidirectional.map(\.sortKey) == bidirectional.map(\.sortKey).sorted(by: >), "stable date/UUID order across newer pages")
        await jumping.loadNewer()
        check(jumping.loadedCount == monthFiles.count, "stop after latest")
        await jumping.jump(to: aug)
        await jumping.loadNewer()
        await jumping.loadMoreIfNeeded(visibleID: jumping.blocks.last!.items.last!.id)
        check(jumping.loadedCount == 410 && !jumping.hasMore && jumping.hasNewer, "older cursor still works after prepend")
        for (month, path) in [(TimelineMonth(year: 2025, month: 1), "latest.mov"),
                              (TimelineMonth(year: 2024, month: 1), "january.jpg"),
                              (TimelineMonth(year: 2023, month: 12), "december.jpg")] {
            await jumping.jump(to: month)
            check(jumping.blocks.first?.items.first?.relativePath == path, "month/year boundary starts inclusively at newest")
        }
        await jumping.jump(to: nil)
        check(!jumping.hasNewer && jumping.selectedMonth == nil && jumping.blocks.first?.items.first?.relativePath == "latest.mov", "return to latest")
        // 更新でcursorが失効しても、選択月の起点を維持して再取得する。
        await jumping.jump(to: aug)
        let revisionAnchor = jumping.blocks.first!.items[37]
        jumping.visibleItemID = revisionAnchor.id
        let revisionJumpID = jumping.displayGeneration
        let refreshScan = try await repository.begin(settings: jumpSettings)
        try await repository.ingest([dated("extra.jpg", "2024-07-01T00:00:00Z")], ticket: refreshScan, progress: .init())
        _ = try await repository.finish(refreshScan, progress: .init(), completed: false)
        await jumping.loadMoreIfNeeded(visibleID: jumping.blocks.last!.items.last!.id)
        check(jumping.selectedMonth == aug && jumping.blocks.first!.items.first!.id == revisionAnchor.id, "revision refresh uses current media, not month origin")
        check(jumping.displayGeneration == revisionJumpID && jumping.visibleItemID == revisionAnchor.id, "revision never reapplies initial jump")
        // 通信待ちに相当するpage待ち中の重複要求と、表示中IDの変更を検証。
        let preceding = (401...600).reversed().map { item($0) }
        let newerFeed = PageFeed(pages: [page(first, more: true), page(preceding, more: false)])
        var newerSource = newerFeed.source()
        newerSource.monthPage = { _, _ in try await newerFeed.read(after: nil) }
        newerSource.newerPage = { _, cursor in try await newerFeed.read(after: cursor) }
        let anchored = TimelineController(source: newerSource)
        await anchored.jump(to: aug)
        check(anchored.visibleItemID == nil && anchored.blocks.first!.items.first!.id == first.first!.id, "initial jump does not pin observation to an ID")
        let stableBlock = anchored.blocks.first!.id
        await newerFeed.suspend()
        let prependTask = Task { await anchored.loadNewer() }
        await newerFeed.waitForRead()
        anchored.visibleItemID = first[5].id
        await anchored.loadNewer()
        await anchored.loadMoreIfNeeded(visibleID: first.last!.id)
        check(await newerFeed.requestCount() == 2, "shared loading guard prevents both direction duplicates")
        await newerFeed.release(); await prependTask.value
        check(anchored.visibleItemID == first[5].id && anchored.blocks.first!.id == stableBlock, "in-flight scroll anchor and same-day block identity retained")
        check(anchored.blocks.count == 1 && anchored.loadedCount == 400, "same-day prepend merges without duplicates")
        let changingFeed = PageFeed(pages: [page(first, more: true)])
        let rebaseFeed = PageFeed(pages: [page(Array(first.dropFirst(3)), more: false), page(Array(first.dropFirst(5)), more: false)])
        var changingSource = changingFeed.source()
        changingSource.anchorPage = { _, _ in try await rebaseFeed.read(after: nil) }
        let changingViewport = TimelineController(source: changingSource)
        await changingViewport.loadInitial()
        let changingJumpID = changingViewport.displayGeneration
        changingViewport.visibleItemID = first[3].id
        await changingFeed.invalidate(with: page([], more: false))
        await rebaseFeed.suspend()
        let refresh = Task { await changingViewport.loadMoreIfNeeded(visibleID: first.last!.id) }
        await rebaseFeed.waitForRead()
        changingViewport.visibleItemID = first[5].id
        await rebaseFeed.release()
        await refresh.value
        check(await rebaseFeed.requestCount() == 2, "in-flight viewport change refreshes latest observed media")
        check(changingViewport.blocks.first?.items.first?.id == first[5].id && changingViewport.displayGeneration == changingJumpID, "user scrolling wins over stale rebase request")
        let viewport = TimelineViewportAnchor(id: first[5].id, distanceFromTop: -23)
        check(viewport.contentOffset(itemMinY: 1400, topInset: 64) == 1359, "partial visible cell retains actual position with inset")
        let offset = viewport.contentOffset(itemMinY: 2800, topInset: 64)
        check(2800 - offset - 64 == -23, "prepend retains exact viewport coordinate, not page top")
        let userMoved = TimelineViewportAnchor(id: first[9].id, distanceFromTop: 12)
        check(userMoved.contentOffset(itemMinY: 3000, topInset: 64) == 2924, "fresh anchor after scrolling supersedes initial jump")
        let titleJumpID = anchored.displayGeneration
        let titleVersion = anchored.contentVersion
        let titleAnchor = anchored.visibleItemID
        anchored.updateDisplayedMonth(first[0].date.month)
        check(anchored.displayedMonth == TimelineMonth(year: 2026, month: 1), "visible media month independent of selected month")
        anchored.updateDisplayedMonth(item(700, date: "2025-12-31T23:59:59").date.month)
        check(anchored.displayedMonth == TimelineMonth(year: 2025, month: 12), "month and year boundary updates title")
        anchored.updateDisplayedMonth(item(701, date: nil).date.month)
        check(anchored.displayedMonth == TimelineMonth(year: 2025, month: 12), "unknown date retains last month")
        check(anchored.displayGeneration == titleJumpID && anchored.contentVersion == titleVersion && anchored.visibleItemID == titleAnchor, "title update never changes viewport or paging")
        let returnFeed = PageFeed(pages: [page(first, more: true), page(second, more: true), page(third, more: false)])
        var returnSource = TimelinePageSource(prepare: { lib }, page: { _, cursor in try await returnFeed.read(after: cursor) },
                                              anchorPage: { _, _ in try await returnFeed.read(after: nil) })
        returnSource.newerPage = { _, cursor in try await returnFeed.read(after: cursor) }
        let returning = TimelineController(source: returnSource)
        await returning.loadInitial()
        await returning.returnFromViewer(to: first[80])
        check(await returnFeed.requestCount() == 1 && returning.scrollRequest?.mediaID == first[80].id, "loaded viewer destination requires no fetch")
        let consumed = returning.scrollRequest!.id
        returning.consumeScrollRequest(consumed)
        check(returning.scrollRequest == nil, "one-shot consumed")
        await returnFeed.suspend()
        let paging = Task { await returning.loadMoreIfNeeded(visibleID: first.last!.id) }
        await returnFeed.waitForRead()
        let restore = Task { await returning.returnFromViewer(to: second[0]) }
        await Task.yield()
        check(returning.scrollRequest == nil, "return waits for in-flight page")
        await returnFeed.release(); await paging.value; await restore.value
        check(await returnFeed.requestCount() == 2 && returning.scrollRequest?.mediaID == second[0].id, "completed page supplies destination without extra query")
        await returning.returnFromViewer(to: third[0])
        check(await returnFeed.requestCount() == 3 && returning.blocks.first?.items.first?.id == third[0].id, "unloaded viewer destination uses anchor page")
        check(returning.hasNewer && returning.isViewerWindow, "unknown-date return supports newer and latest action")
        returning.consumeScrollRequest(consumed)
        check(returning.scrollRequest?.mediaID == third[0].id, "old acknowledgement cannot consume newer request")

        let localReturn = TimelineController(source: .local(repository: timeline, settings: jumpSettings))
        await localReturn.loadInitial()
        let returnTarget = entireJump[3]
        await localReturn.returnFromViewer(to: returnTarget)
        check(localReturn.scrollRequest?.mediaID == returnTarget.id && localReturn.blocks.first?.items.first?.id == returnTarget.id, "real around query returns exact viewer item")
        localReturn.consumeScrollRequest(localReturn.scrollRequest!.id)
        await localReturn.loadMoreIfNeeded(visibleID: localReturn.blocks.last!.items.last!.id)
        await localReturn.loadNewer()
        let returnedItems = localReturn.blocks.flatMap(\.items)
        check(returnedItems.count > 200 && Set(returnedItems.map(\.id)).count == returnedItems.count, "return supports both directions without duplicates")
        check(returnedItems.map(\.sortKey) == returnedItems.map(\.sortKey).sorted(by: >) && localReturn.scrollRequest == nil, "paging preserves order without reissuing return")
        await localReturn.jump(to: nil)
        check(!localReturn.isViewerWindow && !localReturn.hasNewer && localReturn.scrollRequest == nil, "latest restores normal paging")
        print("PASS: viewer return loaded/unloaded, in-flight paging, one-shot consumption, bidirectional continuation")
        print("PASS: observed month title, month/year boundary, unknown date stability, observation-only update")
        print("PASS: bidirectional pages, bounds, stable ties, independent cursors, anchor retention, shared exclusion")
        print("PASS: month candidates, direct month start, month/year boundaries, stable ties, next page, unknown tail, latest return")
        print("PASS: empty retry, no-library recovery, reload during initial read, populated display preserved, offline/index-first, library isolation and switch back")
        print("Timeline UI checks passed: first/next/final, duplicate suppression, incremental groups, mixed offsets, unknown, stable order, invalidation, retry, empty, local-only repository, missing exclusion, metadata preservation")
    }
}
