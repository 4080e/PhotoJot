import Foundation
import SwiftData

private func check(_ value: Bool, _ label: String) { precondition(value, label) }

@main struct TimelineChecks {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let settings = SMBConnectionSettings(host: "nas", username: "user", share: "photos")
        let store = try MediaRepository(url: url)
        let timeline = TimelineRepository(store: store)
        let manifest = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url.appendingPathExtension("json")))
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        let reader = try ModelContainer(for: schema, configurations: [ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)])
        func rows() throws -> [MediaEntry] { try ModelContext(reader).fetch(FetchDescriptor<MediaEntry>()) }
        let selection = try await store.selectMetadata(settings: settings)
        check(selection.count == 4, "only preexisting pending/stale")
        let initialTargets = try await store.metadataBatch(libraryID: selection.libraryID)
        check(Set(initialTargets.map { $0.file.path }) == ["creation.jpg", "write.jpg", "unknown-pending.jpg", "stale.jpg"], "completed Stage3 entries not selected")
        do { _ = try await timeline.page(libraryID: selection.libraryID); fatalError("unprepared accepted") }
        catch TimelineError.needsPreparation { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await timeline.prepare(settings: settings); fatalError("cancelled build accepted") }
            catch is CancellationError { }
        }
        try await cancelled.value
        check(try rows().allSatisfy { $0.timelineKeyVersion == nil }, "cancelled build did not write")
        check(try await store.buildTimelineBatch(libraryID: selection.libraryID) == 500, "bounded backfill batch")
        do { _ = try await timeline.page(libraryID: selection.libraryID); fatalError("partial preparation accepted") }
        catch TimelineError.needsPreparation { }
        let libraryID = try await timeline.prepare(settings: settings)
        check(try await store.buildTimelineBatch(libraryID: libraryID) == 0, "idempotent build")
        for entry in try rows() {
            let saved = manifest[entry.relativePath]!
            check(entry.id.uuidString == saved["id"] && entry.generation.uuidString == saved["generation"], "identity migration")
            check(entry.metadataGeneration?.uuidString ?? "nil" == saved["metadataGeneration"], "metadata generation unchanged")
            check(entry.metadataVersion.map(String.init) ?? "nil" == saved["metadataVersion"], "parser version unchanged")
            check(entry.metadataState ?? "nil" == saved["metadataState"], "state unchanged")
            check(entry.dateSource ?? "nil" == saved["source"], "source unchanged")
            check(entry.resolvedInstant.map { String($0.timeIntervalSince1970) } ?? "nil" == saved["instant"], "instant unchanged")
            check(entry.resolvedFloatingDate ?? "nil" == saved["floating"], "floating unchanged")
            check(entry.dateQuality ?? "nil" == saved["quality"], "quality unchanged")
            check(entry.dateFallback.map(String.init) ?? "nil" == saved["fallback"], "fallback unchanged")
            check(entry.metadataCompletedAt.map { String($0.timeIntervalSince1970) } ?? "nil" == saved["completion"], "completion unchanged")
            check(entry.originalDateValue ?? "nil" == saved["original"] && entry.utcOffset ?? "nil" == saved["offset"], "original fields unchanged")
        }
        let diagnostics = try await timeline.diagnostics(settings: settings)
        check(diagnostics.total == 616, "present supported only: \(diagnostics.total), kinds=\(diagnostics.kinds)")
        check(diagnostics.kinds[.internalMetadata] == 609 && diagnostics.kinds[.containerDate] == 1, "internal/container")
        check(diagnostics.kinds[.confirmedFallback] == 1 && diagnostics.kinds[.provisional] == 3 && diagnostics.kinds[.unknown] == 2, "fallback/provisional/unknown")
        check(diagnostics.withOffset == 3 && diagnostics.withoutOffset == 613, "recorded offset only")
        check(diagnostics.offsets == ["+09:00": 1, "-05:00": 2], "offset counts exclude container UTC")
        check(diagnostics.pendingMetadataBefore == 4 && diagnostics.pendingMetadataAfter == 4, "build never requeues metadata")

        func allPages(_ repo: TimelineRepository) async throws -> [TimelineItem] {
            var items: [TimelineItem] = [], cursor: TimelineCursor?
            repeat {
                let page = try await repo.page(libraryID: libraryID, after: cursor)
                check(page.items.count <= TimelinePolicy.pageSize, "bounded page")
                items += page.items; cursor = page.next
            } while cursor != nil
            return items
        }
        let items = try await allPages(timeline)
        check(items.count == 616 && Set(items.map(\.id)).count == 616, "pagination no omissions/duplicates")
        check(items.map(\.sortKey) == items.map(\.sortKey).sorted(by: >), "newest first and tie break descending")
        check(items.suffix(2).allSatisfy { $0.date.kind == .unknown }, "unknown tail")
        check(Set(items.map(\.mediaType)) == ["photo", "video"], "mixed media")
        func item(_ path: String) -> TimelineItem { items.first { $0.relativePath == path }! }
        for path in ["floating.jpg", "positive.heic", "negative.jpg", "quicktime.mov"] {
            check(item(path).date.calendarDateTime == "2026-01-01T23:30:00", "original wall clock \(path)")
        }
        check(Set([item("floating.jpg"), item("positive.heic"), item("negative.jpg")].compactMap { $0.date.groupKey }).count == 3, "offset/absent groups separate")
        check(item("creation.jpg").date.source == "smbCreationTime" && item("write.jpg").date.source == "smbLastWriteTime", "provisional precedence")
        check(item("container.mp4").date.quality == "containerCreationTime" && item("container.mp4").date.recordedOffset == nil, "container not capture offset")
        let originalZone = NSTimeZone.default
        for zone in ["Asia/Tokyo", "America/New_York", "Pacific/Honolulu"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let read = try await allPages(timeline)
            check(read.map(\.date) == items.map(\.date), "timezone independent \(zone)")
        }
        NSTimeZone.default = originalZone
        let reopened = try TimelineRepository(url: url)
        check(try await allPages(reopened).map(\.id) == items.map(\.id), "stable after reopening")
        let parsed = TimelineDates.localCalendar("2026:01:01 23:30:00", separateOffset: nil, subsecond: "1000")!
        let parsed2 = TimelineDates.localCalendar("2026-01-01T23:30:00.1001Z", separateOffset: nil, subsecond: nil)!
        check(parsed.date < parsed2.date && parsed2.offset == "+00:00", "fraction precision and Z")
        check(TimelineDates.localCalendar("2026:02:30 12:00:00", separateOffset: nil, subsecond: nil) == nil, "invalid date")

        // 通常scanの保存経路からgeneration変更→provisional。failed scanでは既存entryが消えない。
        let firstPage = try await timeline.page(libraryID: libraryID)
        let file = ScannedMedia(path: "positive.heic", size: 200, creation: Date(timeIntervalSince1970: 1000), modified: Date(timeIntervalSince1970: 2000))
        let run = try await store.begin(settings: settings)
        try await store.ingest([file], ticket: run, progress: .init())
        _ = try await store.finish(run, progress: .init(), completed: false)
        do { _ = try await timeline.page(libraryID: libraryID, after: firstPage.next); fatalError("stale cursor accepted") }
        catch TimelineError.changedDuringRead { }
        let changed = try await allPages(timeline)
        check(changed.count == 616, "failed scan does not hide existing")
        check(changed.first { $0.relativePath == file.path }!.date.kind == .provisional, "changed generation becomes provisional")
        let currentSelection = try await store.selectMetadata(settings: settings)
        check(currentSelection.count == 5, "only changed file additionally pending")
        let target = try await store.metadataBatch(libraryID: libraryID).first { $0.file.path == file.path }!
        let outcome = MetadataCore.outcome(format: .heic, evidence: .init(exif: .init(original: "2027:01:01 00:00:00", offset: "-05:00", subsecond: nil)), creation: nil, modified: nil)
        try await store.saveMetadata([MetadataUpdate(target: target, outcome: outcome)])
        let updated = try await timeline.page(libraryID: libraryID)
        check(updated.items.first?.id == target.id && updated.items.first?.date.kind == .internalMetadata, "metadata save updates sort key atomically")
        let successful = try await store.begin(settings: settings)
        try await store.ingest([file], ticket: successful, progress: .init())
        _ = try await store.finish(successful, progress: .init(), completed: true)
        let remaining = try await allPages(timeline)
        check(remaining.count == 1 && remaining[0].id == target.id, "successful scan excludes missing")
        check(try rows().count == manifest.count, "missing not deleted")
        let finalPending = try await store.selectMetadata(settings: settings)
        check(finalPending.count == 0, "completed present metadata remains skipped")
        // unknownだけでもcursorを使って安定して次ページへ進める。
        let unknownSettings = SMBConnectionSettings(host: "nas", username: "user", share: "unknown")
        let unknownRun = try await store.begin(settings: unknownSettings)
        let invalid = Date(timeIntervalSince1970: -11644473600)
        try await store.ingest((0..<201).map { ScannedMedia(path: "unknown/\($0).jpg", size: 1, creation: invalid, modified: invalid) }, ticket: unknownRun, progress: .init())
        _ = try await store.finish(unknownRun, progress: .init(), completed: true)
        let unknownLibrary = try await timeline.prepare(settings: unknownSettings)
        let unknownFirst = try await timeline.page(libraryID: unknownLibrary)
        let unknownLast = try await timeline.page(libraryID: unknownLibrary, after: unknownFirst.next)
        check(unknownFirst.items.count == 200 && unknownLast.items.count == 1 && unknownLast.next == nil, "unknown page boundary")
        check(Set((unknownFirst.items + unknownLast.items).map(\.id)).count == 201, "unknown page no duplicates")
        check((unknownFirst.items + unknownLast.items).allSatisfy { $0.date.kind == .unknown }, "unknown status")
        do { _ = try await timeline.page(libraryID: unknownLibrary, after: firstPage.next); fatalError("wrong library cursor accepted") }
        catch TimelineError.changedDuringRead { }
        print("Timeline checks passed: Stage3 migration, preserved metadata, offset groups, UTC fallback, kinds, timezone independence, keyset pages, unknown tail, stable IDs, generation, save integration, missing and stale cursor")
    }
}
