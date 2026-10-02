import Foundation
import Observation

// Viewから保存先やSwiftDataを分離する。SMBやCredentialStoreへの依存は持たない。
nonisolated struct TimelinePageSource: Sendable {
    let prepare: @Sendable () async throws -> UUID
    let page: @Sendable (UUID, TimelineCursor?) async throws -> TimelinePage

    static func local(repository: TimelineRepository, settings: SMBConnectionSettings) -> Self {
        Self(prepare: { try await repository.prepare(settings: settings) },
             page: { try await repository.page(libraryID: $0, after: $1) })
    }

    static func savedIndex(repository: TimelineRepository) -> Self {
        Self(prepare: {
            guard let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey) else {
                throw TimelineError.noLibrary
            }
            let settings = try JSONDecoder().decode(SMBConnectionSettings.self, from: data).validated()
            return try await repository.prepare(settings: settings)
        }, page: { try await repository.page(libraryID: $0, after: $1) })
    }

}

// 同じ暦日をoffsetによらず結合する。IDは先頭entryの安定ID。
@MainActor @Observable final class TimelineBlock: Identifiable {
    let id: UUID
    let group: TimelineGroupKey?
    private(set) var items: [TimelineItem]
    init(first: TimelineItem) { id = first.id; group = first.date.groupKey; items = [first] }
    func append(_ item: TimelineItem) { items.append(item) }
}

@MainActor @Observable final class TimelineController {
    private(set) var blocks: [TimelineBlock] = []
    private(set) var loadedCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var emptyMessage = "保存済みの対象メディアがありません。"
    private(set) var displayGeneration = UUID()
    @ObservationIgnored private let source: TimelinePageSource
    @ObservationIgnored private var libraryID: UUID?
    @ObservationIgnored private var cursor: TimelineCursor?
    @ObservationIgnored private var loadTriggerIDs: Set<UUID> = []
    // 次ページを促すのは取得済み末尾の少数件。page自体の件数はTimelinePolicyで管理。
    private static let nextPageThreshold = 20

    init(source: TimelinePageSource) { self.source = source }

    func loadInitial() async {
        guard !isLoading, !hasLoaded else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { try await startFromBeginning() }
        catch is CancellationError { }
        catch TimelineError.noLibrary {
            hasLoaded = true
            emptyMessage = "保存済みindexがありません。開発用画面で接続先とindexを準備してください。"
        }
        catch { errorMessage = error.localizedDescription }
    }

    func loadMoreIfNeeded(visibleID: UUID) async {
        guard loadTriggerIDs.contains(visibleID), errorMessage == nil else { return }
        await loadNext()
    }

    func retry() async {
        if hasLoaded { await loadNext() }
        else { await loadInitial() }
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
            // 古いページ群に新しいrevisionを混ぜない。自動再取得は1回だけ。
            do { try await startFromBeginning(replacing: true) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startFromBeginning(replacing: Bool = false) async throws {
        let id = try await source.prepare()
        let page = try await source.page(id, nil)
        try Task.checkCancellation()
        if replacing { reset() }
        libraryID = id
        append(page)
    }

    private func reset() {
        blocks = []; loadedCount = 0
        hasLoaded = false; hasMore = false; cursor = nil; loadTriggerIDs = []
        displayGeneration = UUID()
    }

    private func append(_ page: TimelinePage) {
        // 追加pageだけを処理する。既存の全件再sort / regroupはしない。
        for item in page.items {
            if let last = blocks.last, last.group == item.date.groupKey {
                last.append(item)
            } else { blocks.append(TimelineBlock(first: item)) }
        }
        loadedCount += page.items.count
        cursor = page.next; hasMore = page.next != nil; hasLoaded = true
        loadTriggerIDs = hasMore ? Set(page.items.suffix(Self.nextPageThreshold).map(\.id)) : []
    }

    func heading(for block: TimelineBlock) -> String {
        guard let group = block.group else { return "日時不明" }
        let components = group.day.split(separator: "-").compactMap { Int($0) }
        let day = components.count == 3
            ? "\(components[0])年\(components[1])月\(components[2])日" : group.day
        return day
    }
}
