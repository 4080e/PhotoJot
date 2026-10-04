import Foundation
import Observation

// メディア本体は保持しない。timelineと同じRepositoryを、独立した有限windowから利用する。
@MainActor @Observable final class ViewerSession {
    static let maximumItems = TimelinePolicy.pageSize * 3
    private(set) var currentItem: TimelineItem
    private(set) var items: [TimelineItem]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasOlder = true
    private(set) var hasNewer = true
    @ObservationIgnored private let source: TimelinePageSource
    @ObservationIgnored private var revision: Int64?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    private(set) var isClosed = false
    private static let threshold = 20

    init(item: TimelineItem, source: TimelinePageSource) {
        currentItem = item; items = [item]; self.source = source
    }

    func begin() { requestSupply() }

    func commit(_ item: TimelineItem) {
        guard !isClosed, item.libraryID == currentItem.libraryID else { return }
        if let retained = items.first(where: { $0.id == item.id }) {
            currentItem = retained
        } else {
            // スクロール中にwindowが入れ替わっても、確定したIDを起点に再供給する。
            epoch += 1; revision = nil
            currentItem = item; items = [item]; hasOlder = true; hasNewer = true
        }
        trim()
        errorMessage = nil
        requestSupply()
    }

    func retry() { errorMessage = nil; requestSupply() }
    @discardableResult func close() -> TimelineItem {
        isClosed = true; epoch += 1; work?.cancel()
        return currentItem
    }
    func waitForSupply() async { await work?.value }

    private func requestSupply() {
        guard !isClosed, work == nil, errorMessage == nil else { return }
        isLoading = true
        work = Task {
            defer { isLoading = false; work = nil }
            var recoveredRevision = false
            while !isClosed && !Task.isCancelled {
                do {
                    if revision == nil { try await rebase(); continue }
                    guard let index = items.firstIndex(where: { $0.id == currentItem.id }), let revision else { return }
                    let older = hasOlder && index >= items.count - Self.threshold
                    let newer = hasNewer && index < Self.threshold
                    guard older || newer, let boundary = older ? items.last : items.first else { return }
                    let requestEpoch = epoch
                    let cursor = TimelineCursor(libraryID: currentItem.libraryID, revision: revision,
                                                keyVersion: TimelinePolicy.version, lastKey: boundary.sortKey)
                    let page = older ? try await source.page(currentItem.libraryID, cursor)
                                     : try await source.newerPage(currentItem.libraryID, cursor)
                    try Task.checkCancellation()
                    guard !isClosed, requestEpoch == epoch else { continue }
                    guard page.items.count <= TimelinePolicy.pageSize,
                          !page.items.isEmpty || page.next == nil,
                          page.revision == revision,
                          page.items.allSatisfy({ $0.libraryID == currentItem.libraryID }) else { throw TimelineError.changedDuringRead }
                    // 排他的なkeyset境界を保つ。異なるgenerationを同一IDへ混ぜない。
                    let existing = Set(items.map(\.id))
                    guard page.items.allSatisfy({ !existing.contains($0.id) && (older ? $0.sortKey < boundary.sortKey : $0.sortKey > boundary.sortKey) }),
                          page.items.map(\.sortKey) == page.items.map(\.sortKey).sorted(by: >),
                          Set(page.items.map(\.id)).count == page.items.count else { throw TimelineError.changedDuringRead }
                    if older { items += page.items; hasOlder = page.next != nil }
                    else { items.insert(contentsOf: page.items, at: 0); hasNewer = page.next != nil }
                    trim()
                } catch is CancellationError { return }
                catch TimelineError.changedDuringRead {
                    guard !recoveredRevision else {
                        errorMessage = "ライブラリが更新されています。再試行してください。"; return
                    }
                    recoveredRevision = true
                    revision = nil
                } catch {
                    errorMessage = "前後のメディアを取得できませんでした。再試行してください。"
                    return
                }
            }
        }
    }

    private func rebase() async throws {
        let anchor = currentItem
        let requestEpoch = epoch
        let page = try await source.anchorPage(anchor.libraryID, anchor)
        try Task.checkCancellation()
        guard !isClosed, epoch == requestEpoch, currentItem.id == anchor.id else { return }
        guard page.items.count <= TimelinePolicy.pageSize,
              page.items.allSatisfy({ $0.libraryID == anchor.libraryID }),
              let fresh = page.items.first, fresh.id == anchor.id else { throw ViewerSessionFailure.missing }
        // 同じIDの更新済みgenerationへ揃える。本体側も既存generation検証を行う。
        currentItem = fresh
        items = page.items
        revision = page.revision
        hasOlder = page.next != nil; hasNewer = true
        trim()
    }

    private func trim() {
        guard items.count > Self.maximumItems,
              let index = items.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let lower = min(max(0, index - TimelinePolicy.pageSize), items.count - Self.maximumItems)
        let upper = lower + Self.maximumItems
        if lower > 0 { hasNewer = true }
        if upper < items.count { hasOlder = true }
        items = Array(items[lower..<upper])
    }
}

private enum ViewerSessionFailure: Error { case missing }
