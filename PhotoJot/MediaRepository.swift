import Foundation
import SwiftData

actor MediaRepository {
    // PoCで使用した単位。1バッチにつき照合fetchとsaveを各1回実行する。
    nonisolated static let batchSize = 500
    private let container: ModelContainer
    private var activeSettings: SMBConnectionSettings?

    func setActiveSettings(_ settings: SMBConnectionSettings) { activeSettings = settings }

    func connectionSettings(for library: Library) throws -> SMBConnectionSettings {
        if let activeSettings {
            guard activeSettings.libraryID == library.id else { throw LibraryBindingError.invalidProfile }
            return activeSettings
        }
        return try JSONDecoder().decode(SMBConnectionSettings.self, from: library.connectionData)
    }

    init(url: URL) throws {
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)
        ])
    }

    func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.undoManager = nil
        return context
    }

    func rotationQuarterTurns(id: UUID, libraryID: UUID) throws -> Int {
        let context = context()
        guard let entry = try context.fetch(FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.id == id && $0.libraryID == libraryID
        })).first else { throw IndexFailure.invalidState }
        return ((entry.rotationQuarterTurns ?? 0) % 4 + 4) % 4
    }

    func saveRotationQuarterTurns(_ value: Int, id: UUID, libraryID: UUID) throws {
        guard (0..<4).contains(value) else { throw IndexFailure.invalidState }
        let context = context()
        guard let entry = try context.fetch(FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.id == id && $0.libraryID == libraryID
        })).first else { throw IndexFailure.invalidState }
        entry.rotationQuarterTurns = value
        try context.save()
    }

    func library(settings: SMBConnectionSettings, in context: ModelContext) throws -> Library? {
        if let id = settings.libraryID {
            guard let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == id })).first else {
                throw LibraryBindingError.invalidProfile
            }
            return library
        }
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        return try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.scopeKey == scope })).first
    }

    // 認証・通信前に空Libraryを保存し、初回失敗・中断を次回起動で再試行しない。
    func prepareInitialUpdate(settings: SMBConnectionSettings) throws -> Bool {
        let context = context()
        guard try library(settings: settings, in: context) == nil else { return false }
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        context.insert(Library(scopeKey: scope, connectionData: try JSONEncoder().encode(settings),
                               displayName: settings.share + (settings.rootPath.isEmpty ? "" : "/" + settings.rootPath)))
        try context.save()
        return true
    }

    func saveSuccessfulUpdate(settings: SMBConnectionSettings) throws {
        let context = context()
        guard let library = try library(settings: settings, in: context) else { throw IndexFailure.invalidState }
        try Task.checkCancellation()
        library.lastSuccessfulUpdateAt = Date()
        try context.save()
    }

    func lastSuccessfulUpdate(settings: SMBConnectionSettings) throws -> Date? {
        try library(settings: settings, in: context())?.lastSuccessfulUpdateAt
    }

    func begin(settings: SMBConnectionSettings) throws -> ScanTicket {
        let context = context()
        let data = try JSONEncoder().encode(settings)
        let scope = [settings.host, String(settings.port), settings.domain, settings.username,
                     settings.share, settings.rootPath].map(ScannedMedia.exactKey).joined(separator: ":")
        let library = try library(settings: settings, in: context)
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

    func migrationProfile(legacy: SMBConnectionSettings) throws -> LibraryConnectionProfile {
        let libraries = try context().fetch(FetchDescriptor<Library>())
        let candidates = try libraries.compactMap { library -> (UUID, SMBConnectionSettings)? in
            let saved = try JSONDecoder().decode(SMBConnectionSettings.self, from: library.connectionData)
            guard LibraryConnectionProfile.isLANAddress(saved.host),
                  LibraryConnectionProfile.sameRoot(saved, legacy) else { return nil }
            return (library.id, saved)
        }
        guard candidates.count == 1, let (id, home) = candidates.first else { throw LibraryBindingError.ambiguous }
        return LibraryConnectionProfile(libraryID: id, homeHost: home.host,
            awayHost: LibraryConnectionProfile.isLANAddress(legacy.host) ? "100.92.22.5" : legacy.host,
            useAway: !LibraryConnectionProfile.isLANAddress(legacy.host), common: home)
    }

    func validateBinding(_ profile: LibraryConnectionProfile) throws {
        guard let library = try library(settings: profile.settings, in: context()) else { throw LibraryBindingError.invalidProfile }
        let original = try JSONDecoder().decode(SMBConnectionSettings.self, from: library.connectionData)
        guard LibraryConnectionProfile.sameRoot(original, profile.common) else { throw LibraryBindingError.changedRoot }
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
        guard let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == libraryID })).first else {
            throw IndexFailure.invalidState
        }
        var timelineChanged = false
        let keys = values.map(\.pathKey)
        let existing = try context.fetch(FetchDescriptor<MediaEntry>(predicate: #Predicate {
            $0.libraryID == libraryID && keys.contains($0.pathKey)
        }))
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.pathKey, $0) })
        for file in values {
            if let entry = byKey[file.pathKey] {
                let before = timelineItem(entry, completed: library.completedScanSequence)
                let changed = entry.fileSize != file.size || entry.smbCreationTime != file.creation || entry.smbLastWriteTime != file.modified
                if entry.lastSeenScanID == run.id && changed { throw IndexFailure.conflictingObservation }
                if changed {
                    entry.generation = UUID()
                    entry.clearMetadata()
                    entry.fileSize = file.size; entry.smbCreationTime = file.creation; entry.smbLastWriteTime = file.modified
                }
                entry.lastSeenScanID = run.id; entry.lastSeenSequence = run.sequence
                if changed || entry.timelineKeyVersion != TimelinePolicy.version || entry.timelineSortKey.isEmpty {
                    TimelineDates.apply(to: entry)
                }
                if before != timelineItem(entry, completed: library.completedScanSequence) { timelineChanged = true }
            } else {
                let entry = MediaEntry(libraryID: libraryID, run: run, file: file)
                TimelineDates.apply(to: entry)
                context.insert(entry); byKey[file.pathKey] = entry
                timelineChanged = true
            }
        }
        if timelineChanged { try advanceTimelineRevision(libraryID, context: context) }
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
            let previous = library.completedScanSequence
            if activeSettings?.libraryID == libraryID {
                let lost = try context.fetchCount(FetchDescriptor<MediaEntry>(predicate: #Predicate {
                    $0.libraryID == libraryID && $0.lastSeenSequence >= previous && $0.lastSeenSequence < sequence
                }))
                let present = try context.fetchCount(FetchDescriptor<MediaEntry>(predicate: #Predicate {
                    $0.libraryID == libraryID && $0.lastSeenSequence >= previous
                }))
                if lost > 0 && (lost == present || (lost >= 100 && lost * 2 >= present)) {
                    throw LibraryBindingError.excessiveMissing
                }
            }
            let version = TimelinePolicy.version
            let extensions = ["jpeg", "jpg", "heic", "mov", "mp4"]
            let newlyMissing = try context.fetchCount(FetchDescriptor<MediaEntry>(predicate: #Predicate {
                $0.libraryID == libraryID && $0.lastSeenSequence >= previous && $0.lastSeenSequence < sequence
                    && $0.timelineKeyVersion == version && $0.timelineSortKey != "" && extensions.contains($0.fileExtension)
            }))
            try Task.checkCancellation()
            // 完了runと公開sequenceを同じsaveで確定する。物理削除・全件更新は不要。
            library.completedScanSequence = sequence
            if newlyMissing > 0 { library.timelineRevision = (library.timelineRevision ?? 0) + 1 }
        }
        run.state = completed ? "completed" : (Task.isCancelled ? "cancelled" : "failed")
        run.endedAt = Date(); run.missingCount = missing
        run.files = progress.files; run.folders = progress.folders; run.media = progress.media
        library.updatedAt = Date()
        try context.save()
        return missing
    }
}
