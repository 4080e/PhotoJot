import Foundation
import Observation

// Viewから保存先やSwiftDataを分離する。SMBやCredentialStoreへの依存は持たない。
nonisolated struct TimelinePageSource: Sendable {
    let prepare: @Sendable () async throws -> UUID
    let page: @Sendable (UUID, TimelineCursor?) async throws -> TimelinePage

    var months: @Sendable (UUID) async throws -> [TimelineMonth] = { _ in [] }
    var monthPage: @Sendable (UUID, TimelineMonth) async throws -> TimelinePage = { _, _ in throw TimelineError.needsPreparation }

    var newerPage: @Sendable (UUID, TimelineCursor) async throws -> TimelinePage = { _, _ in throw TimelineError.needsPreparation }

    var anchorPage: @Sendable (UUID, TimelineItem) async throws -> TimelinePage = { _, _ in throw TimelineError.needsPreparation }

    var dateTargets: @Sendable (UUID, String) async throws -> [TimelineDateMove: TimelineItem] = { _, _ in [:] }

    var rotations: @Sendable (UUID, [UUID]) async throws -> [UUID: Int] = { _, _ in [:] }

    static func local(repository: TimelineRepository, settings: SMBConnectionSettings) -> Self {
        Self(prepare: { try await repository.prepare(settings: settings) },
             page: { try await repository.page(libraryID: $0, after: $1) },
             months: { try await repository.months(libraryID: $0) },
             monthPage: { try await repository.page(libraryID: $0, startingAt: $1) },
             newerPage: { try await repository.newerPage(libraryID: $0, before: $1) },
             anchorPage: { try await repository.page(libraryID: $0, around: $1) },
             dateTargets: { try await repository.dateTargets(libraryID: $0, day: $1) },
             rotations: { try await repository.rotations(libraryID: $0, ids: $1) })
    }


}

// 同じ暦日をoffsetによらず結合する。IDは先頭entryの安定ID。
@MainActor @Observable final class TimelineBlock: Identifiable {
    let id: UUID
    let group: TimelineGroupKey?
    private(set) var items: [TimelineItem]
    init(first: TimelineItem) { id = first.id; group = first.date.groupKey; items = [first] }
    func append(_ item: TimelineItem) { items.append(item) }
    func applyRotations(_ values: [UUID: Int]) -> Bool {
        var changed = false
        for index in items.indices {
            guard let value = values[items[index].id], items[index].rotationQuarterTurns != value else { continue }
            items[index].rotationQuarterTurns = value
            changed = true
        }
        return changed
    }
    func prepend(_ values: [TimelineItem]) { items.insert(contentsOf: values, at: 0) }
}

struct TimelineScrollRequest: Equatable {
    let id = UUID()
    let mediaID: UUID
    var keepVisiblePosition = true
}

@MainActor @Observable final class TimelineController {
    private(set) var blocks: [TimelineBlock] = []
    private(set) var loadedCount = 0
    private(set) var isLoading = false {
        didSet {
            if !isLoading {
                let waiting = idleWaiters; idleWaiters = []
                waiting.forEach { $0.resume() }
            }
        }
    }
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var hasNewer = false
    private(set) var isLoadingNewer = false
    private(set) var newerErrorMessage: String?
    // Viewportの観測値だけ。プログラム上の位置指定には使用しない。
    @ObservationIgnored var visibleItemID: UUID?
    private(set) var contentVersion = 0
    private(set) var errorMessage: String?
    private(set) var emptyMessage = "保存済みの対象メディアがありません。"
    private(set) var displayGeneration = UUID()
    private(set) var initialJumpItemID: UUID?
    private(set) var selectedMonth: TimelineMonth?
    private(set) var displayedDay: String?
    private(set) var dateTargets: [TimelineDateMove: TimelineItem] = [:]
    private(set) var displayedMonth: TimelineMonth?
    private(set) var isViewerWindow = false
    private(set) var scrollRequest: TimelineScrollRequest?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func consumeScrollRequest(_ id: UUID) {
        if scrollRequest?.id == id { scrollRequest = nil }
    }

    func returnFromViewer(to item: TimelineItem) async {
        while isLoading { await withCheckedContinuation { idleWaiters.append($0) } }
        guard !Task.isCancelled, item.libraryID == libraryID else { return }
        isLoading = true
        defer { isLoading = false }
        if blocks.contains(where: { $0.items.contains(where: { $0.id == item.id }) }) {
            do {
                let values = try await source.rotations(item.libraryID, blocks.flatMap { $0.items.map(\.id) })
                try Task.checkCancellation()
                var changed = false
                for block in blocks {
                    if block.applyRotations(values) { changed = true }
                }
                if changed { contentVersion += 1 }
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
            // 可視範囲内なら位置を維持する。画像取得のrevisionは変更しない。
            scrollRequest = TimelineScrollRequest(mediaID: item.id)
            return
        }
        do {
            let page = try await source.anchorPage(item.libraryID, item)
            try Task.checkCancellation()
            guard page.items.contains(where: { $0.id == item.id }) else { return }
            reset(preservingViewport: true)
            isViewerWindow = true
            errorMessage = nil
            append(page)
            configureNewer(page, preservingViewport: true)
            scrollRequest = TimelineScrollRequest(mediaID: item.id, keepVisiblePosition: false)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func updateDisplayedDate(_ date: TimelineDate?) {
        let day = date?.groupKey?.day
        if displayedDay != day {
            dateTargets = [:]
            displayedDay = day
        }
        updateDisplayedMonth(date?.month)
    }

    func refreshDateTargets() async {
        guard let libraryID, let day = displayedDay else { return }
        do {
            let targets = try await source.dateTargets(libraryID, day)
            try Task.checkCancellation()
            guard displayedDay == day else { return }
            dateTargets = targets
        } catch is CancellationError { }
        catch { dateTargets = [:] }
    }

    func jump(_ move: TimelineDateMove) async {
        guard !isLoading, let item = dateTargets[move], let libraryID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await source.anchorPage(libraryID, item)
            try Task.checkCancellation()
            reset()
            selectedMonth = item.date.month
            errorMessage = nil
            append(page)
            configureNewer(page)
            initialJumpItemID = item.id
            updateDisplayedDate(item.date)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    // 閲覧位置からの表示専用通知。ジャンプ・ページングの状態には触れない。
    func updateDisplayedMonth(_ month: TimelineMonth?) {
        guard let month, displayedMonth != month else { return }
        displayedMonth = month
    }

    @ObservationIgnored private let source: TimelinePageSource
    @ObservationIgnored private var emptyReloadRequested = false
    @ObservationIgnored private var libraryID: UUID?
    @ObservationIgnored private var cursor: TimelineCursor?
    @ObservationIgnored private var newerCursor: TimelineCursor?
    @ObservationIgnored private var loadTriggerIDs: Set<UUID> = []
    // 次ページを促すのは取得済み末尾の少数件。page自体の件数はTimelinePolicyで管理。
    private static let nextPageThreshold = 20

    init(source: TimelinePageSource) { self.source = source }

    func availableMonths() async throws -> [TimelineMonth] {
        let id = try await source.prepare()
        return try await source.months(id)
    }

    // 取得成功時だけ表示を置換。失敗時は既存のtimelineと起点を維持する。
    func jump(to month: TimelineMonth?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let id = try await source.prepare()
            let page: TimelinePage
            if let month { page = try await source.monthPage(id, month) }
            else { page = try await source.page(id, nil) }
            try Task.checkCancellation()
            reset()
            selectedMonth = month
            errorMessage = nil
            libraryID = id
            append(page)
            configureNewer(page)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadInitial() async {
        guard !isLoading, !hasLoaded else { return }
        await reloadFromBeginning()
    }

    // 明示的な先頭再取得。取得成功までは現在の表示を保持する。
    func reloadFromBeginning() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        repeat {
            emptyReloadRequested = false
            errorMessage = nil
            do { try await startFromBeginning(replacing: true) }
            catch is CancellationError { return }
            catch TimelineError.noLibrary {
                hasLoaded = true
                emptyMessage = "保存済みの写真・動画はまだありません。ライブラリを更新してください。"
            }
            catch { errorMessage = error.localizedDescription }
        } while emptyReloadRequested && blocks.isEmpty && !Task.isCancelled
    }

    func reloadAfterUpdate() async {
        while isLoading { await withCheckedContinuation { idleWaiters.append($0) } }
        guard !Task.isCancelled else { return }
        await jump(to: nil)
    }

    func reloadIfEmpty() async {
        guard blocks.isEmpty else { return }
        if isLoading { emptyReloadRequested = true; return }
        await reloadFromBeginning()
    }

    func loadMoreIfNeeded(visibleID: UUID) async {
        guard loadTriggerIDs.contains(visibleID), errorMessage == nil else { return }
        await loadNext()
    }

    func retry() async {
        if blocks.isEmpty { await reloadFromBeginning() }
        else if hasLoaded { await loadNext() }
        else { await loadInitial() }
    }

    func loadNewerIfNeeded(visibleID: UUID) async {
        guard newerErrorMessage == nil,
              blocks.lazy.flatMap({ $0.items }).prefix(Self.nextPageThreshold).contains(where: { $0.id == visibleID }) else { return }
        await loadNewer()
    }

    func loadNewer() async {
        guard !isLoading, hasNewer, let libraryID, let newerCursor else { return }
        isLoading = true; isLoadingNewer = true; newerErrorMessage = nil
        defer { isLoading = false; isLoadingNewer = false }
        do {
            let page = try await source.newerPage(libraryID, newerCursor)
            try Task.checkCancellation()
            prepend(page)
        } catch is CancellationError { }
        catch TimelineError.changedDuringRead {
            do { try await refreshAtViewport() }
            catch is CancellationError { }
            catch { newerErrorMessage = error.localizedDescription }
        } catch { newerErrorMessage = error.localizedDescription }
    }

    private func configureNewer(_ page: TimelinePage, preservingViewport: Bool = false) {
        if let anchorID = page.initialAnchorID {
            initialJumpItemID = anchorID
            newerCursor = page.newerNext
            hasNewer = newerCursor != nil
            return
        }
        newerCursor = selectedMonth == nil && !preservingViewport ? nil : page.items.first.map {
            TimelineCursor(libraryID: $0.libraryID, revision: page.revision,
                           keyVersion: TimelinePolicy.version, lastKey: $0.sortKey)
        }
        hasNewer = newerCursor != nil
    }

    private func prepend(_ page: TimelinePage) {
        var added: [TimelineBlock] = []
        for item in page.items {
            if let last = added.last, last.group == item.date.groupKey { last.append(item) }
            else { added.append(TimelineBlock(first: item)) }
        }
        // 境界の日付が同じなら既存blockへ前置し、既存block/cellのidentityを保つ。
        if let last = added.last, let first = blocks.first, last.group == first.group {
            first.prepend(last.items)
            added.removeLast()
        }
        blocks.insert(contentsOf: added, at: 0)
        contentVersion += 1
        loadedCount += page.items.count
        newerCursor = page.next
        hasNewer = page.next != nil
        // 古い方向のcursor、displayGeneration、visibleItemIDはそのまま。
    }

    private func loadNext() async {
        guard !isLoading, hasMore, let libraryID, let cursor else { return }
        // awaitより前に排他。高速スクロールからの重複triggerも同じcursorを二重取得しない。
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await source.page(libraryID, cursor)
            try Task.checkCancellation()
            append(page)
        } catch is CancellationError { }
        catch TimelineError.changedDuringRead {
            // 古いページ群に新しいrevisionを混ぜず、閲覧中の位置から取り直す。
            do { try await refreshAtViewport() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshAtViewport() async throws {
        guard let id = libraryID else { return }
        while true {
            let observedID = visibleItemID
            guard let anchor = blocks.lazy.flatMap({ $0.items }).first(where: { $0.id == observedID }) ?? blocks.first?.items.first else { return }
            let page = try await source.anchorPage(id, anchor)
            try Task.checkCancellation()
            // 問い合わせ中にユーザーが移動した場合は、新しいviewportを優先する。
            guard visibleItemID == observedID else { continue }
            reset(preservingViewport: true)
            errorMessage = nil
            append(page)
            configureNewer(page, preservingViewport: true)
            return
        }
    }

    private func startFromBeginning(replacing: Bool = false) async throws {
        let id = try await source.prepare()
        let page: TimelinePage
        if let selectedMonth { page = try await source.monthPage(id, selectedMonth) }
        else { page = try await source.page(id, nil) }
        try Task.checkCancellation()
        if replacing { reset() }
        libraryID = id
        append(page)
        configureNewer(page)
    }

    private func reset(preservingViewport: Bool = false) {
        blocks = []; loadedCount = 0
        initialJumpItemID = nil
        hasLoaded = false; hasMore = false; cursor = nil; loadTriggerIDs = []
        newerCursor = nil; hasNewer = false; newerErrorMessage = nil
        if !preservingViewport {
            scrollRequest = nil
            isViewerWindow = false
            visibleItemID = nil
            // 初回／明示的な年月ジャンプ・最新操作だけの一回限りの位置指定。
            displayGeneration = UUID()
        }
    }

    private func append(_ page: TimelinePage) {
        // 追加pageだけを処理する。既存の全件再sort / regroupはしない。
        for item in page.items {
            if let last = blocks.last, last.group == item.date.groupKey {
                last.append(item)
            } else { blocks.append(TimelineBlock(first: item)) }
        }
        contentVersion += 1
        loadedCount += page.items.count
        cursor = page.next; hasMore = page.next != nil; hasLoaded = true
        loadTriggerIDs = hasMore ? Set(page.items.suffix(Self.nextPageThreshold).map(\.id)) : []
    }

    func heading(for block: TimelineBlock) -> String {
        TimelineDate.dayTitle(for: block.group)
    }
}
