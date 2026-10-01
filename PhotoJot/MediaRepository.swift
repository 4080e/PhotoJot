import Foundation
import SwiftData

actor MediaRepository {
    // PoCで使用した単位。1バッチにつき照合fetchとsaveを各1回実行する。
    nonisolated static let batchSize = 500
    private let container: ModelContainer

    init(url: URL) throws {
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)
        ])
    }

    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.undoManager = nil
        return context
    }

    func begin(settings: SMBConnectionSettings) throws -> ScanTicket {
        let context = context()
        let data = try JSONEncoder().encode(settings)
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.scopeKey == scope })).first
            ?? Library(scopeKey: scope, connectionData: data, displayName: settings.share + (settings.rootPath.isEmpty ? "" : "/" + settings.rootPath))
        if library.modelContext == nil { context.insert(library) }
        let libraryID = library.id
        // 強制終了などで残ったrunを終了扱いにする。完了sequenceは変更しない。
        for run in try context.fetch(FetchDescriptor<ScanRun>(predicate: #Predicate { $0.state == "running" })) {
            run.state = "interrupted"; run.endedAt = Date()
        }
        library.nextScanSequence += 1
        library.updatedAt = Date()
        let run = ScanRun(libraryID: libraryID, sequence: library.nextScanSequence)
        context.insert(run)
        try context.save()
        return ScanTicket(libraryID: libraryID, runID: run.id)
    }

    private func run(_ ticket: ScanTicket, in context: ModelContext) throws -> ScanRun {
        let id = ticket.runID
        guard let run = try context.fetch(FetchDescriptor<ScanRun>(predicate: #Predicate { $0.id == id })).first,
              run.libraryID == ticket.libraryID, run.state == "running" else { throw IndexFailure.invalidState }
        return run
    }

    func ingest(_ values: [ScannedMedia], ticket: ScanTicket, progress: ScanProgress) throws {
        guard values.count <= Self.batchSize, values.allSatisfy({ ScannedMedia.isSupported($0.path) }) else {
            throw IndexFailure.invalidState
        }
        let context = context(), libraryID = ticket.libraryID
        let run = try run(ticket, in: context)
        let keys = values.map(\.pathKey)
        let existing = try context.fetch(FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.libraryID == libraryID && keys.contains($0.pathKey)
        }))
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.pathKey, $0) })
        for file in values {
            if let entry = byKey[file.pathKey] {
                let changed = entry.fileSize != file.size || entry.smbCreationTime != file.creation || entry.smbLastWriteTime != file.modified
                if entry.lastSeenScanID == run.id && changed { throw IndexFailure.conflictingObservation }
                if changed {
                    entry.generation = UUID()
                    entry.fileSize = file.size; entry.smbCreationTime = file.creation; entry.smbLastWriteTime = file.modified
                }
                entry.lastSeenScanID = run.id; entry.lastSeenSequence = run.sequence
            } else {
                let entry = MediaEntry(libraryID: libraryID, run: run, file: file)
                context.insert(entry); byKey[file.pathKey] = entry
            }
        }
        run.files = progress.files; run.folders = progress.folders; run.media = progress.media
        try Task.checkCancellation()
        try context.save()
        // contextをバッチごとに解放し、全件をメモリに保持しない。
    }

    func finish(_ ticket: ScanTicket, progress: ScanProgress, completed: Bool) throws -> Int? {
        let context = context()
        let run = try run(ticket, in: context)
        let libraryID = ticket.libraryID
        guard let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == libraryID })).first else {
            throw IndexFailure.invalidState
        }
        var missing: Int?
        if completed {
            try Task.checkCancellation()
            let sequence = run.sequence
            missing = try context.fetchCount(FetchDescriptor<MediaEntry>(predicate: #Predicate {
                $0.libraryID == libraryID && $0.lastSeenSequence < sequence
            }))
            try Task.checkCancellation()
            // 完了runと公開sequenceを同じsaveで確定する。物理削除・全件更新は不要。
            library.completedScanSequence = sequence
        }
        run.state = completed ? "completed" : (Task.isCancelled ? "cancelled" : "failed")
        run.endedAt = Date(); run.missingCount = missing
        run.files = progress.files; run.folders = progress.folders; run.media = progress.media
        library.updatedAt = Date()
        try context.save()
        return missing
    }
}
