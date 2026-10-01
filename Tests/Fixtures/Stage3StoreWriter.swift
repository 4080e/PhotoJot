import Foundation
import SwiftData

// 段階3のschemaでストアを実際に作成する。巨大なbinary fixtureは保存しない。
@main struct Stage3StoreWriter {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let settings = SMBConnectionSettings(host: "nas", username: "user", share: "photos")
        let scope = [settings.host, String(settings.port), settings.domain, settings.username, settings.share, settings.rootPath]
            .map(ScannedMedia.exactKey).joined(separator: ":")
        let library = Library(scopeKey: scope, connectionData: try JSONEncoder().encode(settings), displayName: "fixture")
        let run = ScanRun(libraryID: library.id, sequence: 2)
        library.completedScanSequence = 2; library.nextScanSequence = 2; run.state = "completed"
        context.insert(library); context.insert(run)
        var manifest: [String: [String: String]] = [:]
        func add(_ name: String, raw: String? = "2025:01:01 12:00:00", offset: String? = nil,
                 source: String? = "jpegExifDateTimeOriginal", quality: String? = "captureMetadata",
                 pending: Bool = false, invalidCreation: Bool = false, invalidWrite: Bool = false,
                 stale: Bool = false, missing: Bool = false) {
            let file = ScannedMedia(path: name, size: 100,
                                    creation: Date(timeIntervalSince1970: invalidCreation ? -11644473600 : 1000),
                                    modified: Date(timeIntervalSince1970: invalidWrite ? -11644473600 : 2000))
            let entry = MediaEntry(libraryID: library.id, run: run, file: file)
            if !pending {
                entry.metadataGeneration = stale ? UUID() : entry.generation
                entry.metadataVersion = 1; entry.metadataCompletedAt = Date(timeIntervalSince1970: 3000)
                entry.metadataState = source == nil ? "missing" : "complete"
                entry.dateSource = source; entry.dateQuality = quality
                entry.dateFallback = source == "smbCreationTime" || source == "movieHeaderCreationTime"
                entry.originalDateValue = raw; entry.utcOffset = offset
                if source == "smbCreationTime" || source == "movieHeaderCreationTime" {
                    entry.resolvedInstant = Date(timeIntervalSince1970: 1000)
                } else if source != nil {
                    if offset == nil { entry.resolvedFloatingDate = raw }
                    else { entry.resolvedInstant = Date(timeIntervalSince1970: 1760000000) }
                }
            }
            if missing { entry.lastSeenSequence = 1 }
            context.insert(entry)
            manifest[name] = ["id": entry.id.uuidString, "generation": entry.generation.uuidString,
                              "metadataGeneration": entry.metadataGeneration?.uuidString ?? "nil",
                              "metadataVersion": entry.metadataVersion.map(String.init) ?? "nil",
                              "metadataState": entry.metadataState ?? "nil", "source": entry.dateSource ?? "nil",
                              "original": entry.originalDateValue ?? "nil", "offset": entry.utcOffset ?? "nil",
                              "instant": entry.resolvedInstant.map { String($0.timeIntervalSince1970) } ?? "nil",
                              "floating": entry.resolvedFloatingDate ?? "nil", "quality": entry.dateQuality ?? "nil",
                              "fallback": entry.dateFallback.map(String.init) ?? "nil",
                              "completion": entry.metadataCompletedAt.map { String($0.timeIntervalSince1970) } ?? "nil"]
        }
        add("floating.jpg", raw: "2026:01:01 23:30:00")
        add("positive.heic", raw: "2026:01:01 23:30:00", offset: "+09:00", source: "heicExifDateTimeOriginal")
        add("negative.jpg", raw: "2026:01:01 23:30:00", offset: "-05:00")
        add("quicktime.mov", raw: "2026-01-01T23:30:00-05:00", offset: "-05:00", source: "quickTimeCreationDate")
        add("fallback.jpg", raw: "1970-01-01T00:16:40Z", source: "smbCreationTime", quality: "fileSystemCreationTime")
        add("container.mp4", raw: "2082845800", offset: "+00:00", source: "movieHeaderCreationTime", quality: "containerCreationTime")
        add("creation.jpg", pending: true)
        add("write.jpg", pending: true, invalidCreation: true)
        add("unknown.jpg", raw: nil, source: nil, quality: nil, invalidCreation: true, invalidWrite: true)
        add("unknown-pending.jpg", pending: true, invalidCreation: true, invalidWrite: true)
        add("stale.jpg", stale: true)
        for i in 0..<605 {
            let fractions = [".1", ".100", ".1001", ".0001"]
            add("bulk/\(i).jpg", raw: "2025:01:01 12:00:00" + (i < fractions.count ? fractions[i] : ""))
        }
        add("missing.jpg", missing: true)
        add("ignored.png")
        try context.save()
        try JSONEncoder().encode(manifest).write(to: url.appendingPathExtension("json"))
        print("Stage3 fixture saved: \(manifest.count) entries")
    }
}
