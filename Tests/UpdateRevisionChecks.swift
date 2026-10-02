import Foundation

@main struct UpdateRevisionChecks {
    static func main() async throws {
        let store = try MediaRepository(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let timeline = TimelineRepository(store: store)
        let settings = SMBConnectionSettings(host: "nas", share: "photos")
        func file(_ name: String, size: Int64 = 100) -> ScannedMedia {
            ScannedMedia(path: name, size: size, creation: Date(timeIntervalSince1970: 1000), modified: Date(timeIntervalSince1970: 2000))
        }
        let files = (0..<201).map { file("\($0).jpg") }
        let first = try await store.begin(settings: settings)
        try await store.ingest(files, ticket: first, progress: .init())
        _ = try await store.finish(first, progress: .init(), completed: true)
        let id = try await timeline.prepare(settings: settings)
        func page() async throws -> TimelinePage { try await timeline.page(libraryID: id) }
        let initial = try await page()
        precondition(initial.items.count == 200 && initial.next != nil)
        let same = try await store.begin(settings: settings)
        let duringBegin = try await page()
        precondition(duringBegin.revision == initial.revision)
        try await store.ingest(files, ticket: same, progress: .init())
        let duringScan = try await page() // 更新完了前にも同じRepositoryで閲覧できる。
        precondition(duringScan.items == initial.items && duringScan.revision == initial.revision)
        _ = try await store.finish(same, progress: .init(), completed: true)
        let samePage = try await page()
        precondition(samePage.revision == initial.revision)
        let tail = try await timeline.page(libraryID: id, after: initial.next)
        precondition(tail.items.count == 1) // 無変更走査で既存cursorを失効させない。

        let target = try await store.metadataBatch(libraryID: id)[0]
        let outcome = MetadataCore.outcome(format: .jpeg,
            evidence: .init(exif: .init(original: "2024:01:01 12:00:00", offset: nil, subsecond: nil)), creation: nil, modified: nil)
        try await store.saveMetadata([MetadataUpdate(target: target, outcome: outcome)])
        let parsed = try await page()
        precondition(parsed.revision > samePage.revision)
        do {
            _ = try await timeline.page(libraryID: id, after: initial.next)
            fatalError("changed metadata did not invalidate cursor")
        } catch TimelineError.changedDuringRead { }
        try await store.saveMetadata([MetadataUpdate(target: target, outcome: outcome)])
        let repeated = try await page()
        precondition(repeated.revision == parsed.revision) // completedAtだけの変更。
        let retryTarget = try await store.metadataBatch(libraryID: id)[0]
        for message in ["first failure", "different diagnostic"] {
            let retry = MetadataCore.outcome(format: .jpeg,
                evidence: .init(diagnostics: [.init(kind: .smb, message: message)]), creation: nil, modified: nil)
            let before = try await page()
            try await store.saveMetadata([MetadataUpdate(target: retryTarget, outcome: retry)])
            let after = try await page()
            if message == "different diagnostic" { precondition(after.revision == before.revision) }
            else { precondition(after.revision > before.revision) } // UIで参照するmetadataStateの変化。
        }

        let beforeMissing = try await page()
        let deletion = try await store.begin(settings: settings)
        try await store.ingest([files[0]], ticket: deletion, progress: .init())
        let notYetMissing = try await page()
        precondition(notYetMissing.revision == beforeMissing.revision)
        _ = try await store.finish(deletion, progress: .init(), completed: true)
        let missing = try await page()
        precondition(missing.items.count == 1 && missing.revision > beforeMissing.revision)
        let repeatDeletion = try await store.begin(settings: settings)
        try await store.ingest([files[0]], ticket: repeatDeletion, progress: .init())
        _ = try await store.finish(repeatDeletion, progress: .init(), completed: true)
        let stillMissing = try await page()
        precondition(stillMissing.revision == missing.revision) // 既にmissingの件数だけでは進めない。

        let interrupted = try await store.begin(settings: settings)
        _ = try await store.finish(interrupted, progress: .init(), completed: false)
        let interruptedPage = try await page()
        precondition(interruptedPage.revision == stillMissing.revision)
        let reappear = try await store.begin(settings: settings)
        try await store.ingest(files, ticket: reappear, progress: .init())
        let reappeared = try await page()
        precondition(reappeared.revision > stillMissing.revision && reappeared.items.count == 200)
        _ = try await store.finish(reappear, progress: .init(), completed: true)
        let finished = try await page()
        precondition(finished.revision == reappeared.revision)
        let changed = try await store.begin(settings: settings)
        try await store.ingest([file(files[0].path, size: 200)], ticket: changed, progress: .init())
        let changedPage = try await page()
        precondition(changedPage.revision > finished.revision)
        _ = try await store.finish(changed, progress: .init(), completed: false)
        let added = try await store.begin(settings: settings)
        try await store.ingest([file("new.jpg")], ticket: added, progress: .init())
        let addedPage = try await page()
        precondition(addedPage.revision > changedPage.revision)
        _ = try await store.finish(added, progress: .init(), completed: false)
        print("PASS: shared store reads during scan, unchanged scan cursor, metadata changes/no-op/diagnostic, missing/repeated missing, interrupted scan, reappearance, changes, additions")
    }
}
