import Foundation
import SwiftData

private func check(_ value: @autoclosure () throws -> Bool) throws { let result = try value(); precondition(result) }

@main struct MetadataStoreChecks {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let repository = try MediaRepository(url: url)
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        let reader = try ModelContainer(for: schema, configurations: [ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)])
        func rows() throws -> [MediaEntry] { try ModelContext(reader).fetch(FetchDescriptor<MediaEntry>()) }
        let oldID = try String(contentsOf: url.appendingPathExtension("uuid"), encoding: .utf8)
        let migrated = try rows()
        try check(migrated.count == 1 && migrated[0].id.uuidString == oldID && migrated[0].relativePath == "old.jpg")
        try check(migrated[0].metadataCompletedAt == nil && migrated[0].metadataState == nil)

        let migratedRotation = try await repository.rotationQuarterTurns(id: migrated[0].id, libraryID: migrated[0].libraryID)
        try check(migratedRotation == 0)
        print("PASS: migrated existing media defaults to zero rotation")

        let settings = SMBConnectionSettings(host: "nas", username: "user", share: "photos")
        func file(_ name: String, _ size: Int64 = 100) -> ScannedMedia {
            ScannedMedia(path: name, size: size, creation: Date(timeIntervalSince1970: 1000), modified: Date(timeIntervalSince1970: 2000))
        }
        let run = try await repository.begin(settings: settings)
        try await repository.ingest([file("a.jpg"), file("b.heic"), file("c.mov"), file("d.mp4")], ticket: run, progress: .init())
        _ = try await repository.finish(run, progress: .init(), completed: true)
        var selection = try await repository.selectMetadata(settings: settings)
        try check(selection.count == 4)
        let targets = try await repository.metadataBatch(libraryID: selection.libraryID)
        let missing = MetadataCore.outcome(format: .jpeg, evidence: .init(diagnostics: [.init(kind: .missing, message: "fixture")]), creation: nil, modified: nil)
        let retry = MetadataCore.outcome(format: .jpeg, evidence: .init(diagnostics: [.init(kind: .smb, message: "fixture")]), creation: nil, modified: nil)
        let complete = MetadataCore.outcome(format: .jpeg, evidence: .init(exif: .init(original: "2024:01:01 23:30:00", offset: nil, subsecond: "007")), creation: nil, modified: nil)
        let unsupported = MetadataCore.outcome(format: .heic, evidence: .init(diagnostics: [.init(kind: .unsupported, message: "fixture")]), creation: Date(), modified: nil)
        let outcomes = [missing, retry, complete, unsupported]
        try await repository.saveMetadata(zip(targets, outcomes).map { MetadataUpdate(target: $0.0, outcome: $0.1) })
        selection = try await repository.selectMetadata(settings: settings)
        try check(selection.count == 1)
        let retryRows = try await repository.metadataBatch(libraryID: selection.libraryID)
        try check(retryRows.count == 1 && retryRows[0].id == targets[1].id)
        let stored = try rows()
        try check(stored.first { $0.id == targets[0].id }!.metadataCompletedAt != nil)
        try check(stored.first { $0.id == targets[1].id }!.metadataCompletedAt == nil)
        let floating = stored.first { $0.id == targets[2].id }!
        try check(floating.resolvedInstant == nil && floating.resolvedFloatingDate == "2024:01:01 23:30:00.007" && floating.utcOffset == nil)
        let upgraded = try await repository.selectMetadata(settings: settings, version: MetadataPolicy.version + 1)
        try check(upgraded.count == 4)
        try await repository.saveMetadata([MetadataUpdate(target: retryRows[0], outcome: complete)])
        let allDone = try await repository.selectMetadata(settings: settings)
        try check(allDone.count == 0)

        let changedRun = try await repository.begin(settings: settings)
        let changedFiles = targets.map { file($0.file.path, $0.id == targets[0].id ? 200 : 100) }
        try await repository.ingest(changedFiles, ticket: changedRun, progress: .init())
        _ = try await repository.finish(changedRun, progress: .init(), completed: true)
        let changedSelection = try await repository.selectMetadata(settings: settings)
        try check(changedSelection.count == 1)
        let changedEntry = try rows().first { $0.id == targets[0].id }!
        try check(changedEntry.generation != targets[0].generation && changedEntry.metadataCompletedAt == nil && changedEntry.dateSource == nil)
        do {
            try await repository.saveMetadata([MetadataUpdate(target: targets[0], outcome: complete)])
            fatalError("stale generation accepted")
        } catch MetadataServiceError.staleIndex { }

        let missingRun = try await repository.begin(settings: settings)
        try await repository.ingest([file(targets[1].file.path)], ticket: missingRun, progress: .init())
        _ = try await repository.finish(missingRun, progress: .init(), completed: true)
        let onlyPresent = try await repository.selectMetadata(settings: settings)
        try check(onlyPresent.count == 0) // 未処理だがmissingのentryを処理しない。
        let context = ModelContext(reader)
        let pngRun = ScanRun(libraryID: selection.libraryID, sequence: 999)
        context.insert(pngRun)
        context.insert(MediaEntry(libraryID: selection.libraryID, run: pngRun, file: file("ignored.png")))
        try context.save()
        let withoutPNG = try await repository.selectMetadata(settings: settings)
        try check(withoutPNG.count == 0)

        let batchRun = try await repository.begin(settings: settings)
        try await repository.ingest((0..<201).map { file("batch/\($0).jpg") }, ticket: batchRun, progress: .init())
        _ = try await repository.finish(batchRun, progress: .init(), completed: true)
        let batchSelection = try await repository.selectMetadata(settings: settings)
        try check(batchSelection.count == 201)
        let firstBatch = try await repository.metadataBatch(libraryID: selection.libraryID)
        try check(firstBatch.count == 100)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await repository.saveMetadata(firstBatch.map { MetadataUpdate(target: $0, outcome: missing) })
                fatalError("cancelled save accepted")
            } catch is CancellationError { }
        }
        try await cancelled.value
        let afterCancel = try await repository.selectMetadata(settings: settings)
        try check(afterCancel.count == 201)
        for expected in [100, 100, 1] {
            let batch = try await repository.metadataBatch(libraryID: selection.libraryID)
            try check(batch.count == expected)
            try await repository.saveMetadata(batch.map { MetadataUpdate(target: $0, outcome: missing) })
        }
        let final = try await repository.selectMetadata(settings: settings)
        try check(final.count == 0)
        let resumeFiles = (0..<201).map { file("resume/\($0).jpg") }
        let resumeRun = try await repository.begin(settings: settings)
        try await repository.ingest(resumeFiles, ticket: resumeRun, progress: .init())
        _ = try await repository.finish(resumeRun, progress: .init(), completed: true)
        let savedBatch = try await repository.metadataBatch(libraryID: selection.libraryID)
        try await repository.saveMetadata(savedBatch.map { MetadataUpdate(target: $0, outcome: complete) })
        let unsavedBatch = try await repository.metadataBatch(libraryID: selection.libraryID)
        let stop = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await repository.saveMetadata(unsavedBatch.map { MetadataUpdate(target: $0, outcome: complete) })
                fatalError("cancelled metadata batch saved")
            } catch is CancellationError { }
        }
        try await stop.value
        let reopened = try MediaRepository(url: url)
        let pendingAfterStop = try await reopened.selectMetadata(settings: settings)
        try check(pendingAfterStop.count == 101)
        let savedIDs = Set(savedBatch.map(\.id))
        try check(try rows().filter { savedIDs.contains($0.id) && $0.metadataCompletedAt != nil }.count == 100)
        // 次回更新は全件再走査しても、保存済み結果を保持して未完了分だけ選択する。
        let rescan = try await reopened.begin(settings: settings)
        try await reopened.ingest(resumeFiles, ticket: rescan, progress: .init())
        _ = try await reopened.finish(rescan, progress: .init(), completed: true)
        for expected in [100, 1] {
            let batch = try await reopened.metadataBatch(libraryID: selection.libraryID)
            try check(batch.count == expected && batch.allSatisfy { !savedIDs.contains($0.id) })
            try await reopened.saveMetadata(batch.map { MetadataUpdate(target: $0, outcome: complete) })
        }
        let resumed = try await reopened.selectMetadata(settings: settings)
        try check(resumed.count == 0)
        print("PASS: metadata saved batch retained, 101 pending after cancellation/reopen, rescan resumes pending only")
        print("Metadata store checks passed (stage2 migration, pending predicate, terminal skip, retry, generation/version, stale rejection, floating persistence, present-only, PNG, batch100+tail, cancellation)")
    }
}
