import Foundation
import SwiftData

private func check(_ condition: @autoclosure () throws -> Bool) throws {
    let result = try condition()
    precondition(result)
}

@main struct IndexChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = directory.appendingPathComponent("index.store")
        let repository = try MediaRepository(url: url)
        let settings = SMBConnectionSettings(host: "nas", username: "user", share: "photos", rootPath: "root")
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        let reader = try ModelContainer(for: schema, configurations: [ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)])
        func rows() throws -> [MediaEntry] { try ModelContext(reader).fetch(FetchDescriptor<MediaEntry>()) }
        func libraries() throws -> [Library] { try ModelContext(reader).fetch(FetchDescriptor<Library>()) }
        func runs() throws -> [ScanRun] { try ModelContext(reader).fetch(FetchDescriptor<ScanRun>()) }
        func file(_ path: String, size: Int64 = 100) -> ScannedMedia {
            ScannedMedia(path: path, size: size, creation: Date(timeIntervalSince1970: 1000), modified: Date(timeIntervalSince1970: 2000))
        }
        for ext in ["JPEG", "jpg", "HeIc", "MOV", "mp4"] { try check(ScannedMedia.isSupported("a." + ext)) }
        for name in ["a.PNG", "a.txt", "a.gif", "noExtension"] { try check(!ScannedMedia.isSupported(name)) }
        let first = try await repository.begin(settings: settings)
        let paths = ["root/a.JPG", "root/A.JPG", "root/sub/a.JPG", "root/é.jpg", "root/e\u{301}.jpg"]
        let initial = paths.map { file($0) }
        try check(Set(initial.map(\.pathKey)).count == 5)
        try await repository.ingest(initial, ticket: first, progress: ScanProgress(files: 5, folders: 2, media: 5))
        let firstMissing = try await repository.finish(first, progress: ScanProgress(), completed: true)
        try check(firstMissing == 0)
        let baseline = try rows()
        try check(baseline.count == 5)
        let original = baseline.first { $0.pathKey == initial[0].pathKey }!
        let originalID = original.id, originalGeneration = original.generation

        let second = try await repository.begin(settings: settings)
        try await repository.ingest([initial[0], initial[1]], ticket: second, progress: ScanProgress())
        _ = try await repository.finish(second, progress: ScanProgress(), completed: false)
        var completed = try libraries().first!.completedScanSequence
        try check(try rows().allSatisfy { !$0.isMissing(completedScanSequence: completed) })

        let third = try await repository.begin(settings: settings)
        try await repository.ingest([file(paths[0], size: 200), initial[1]], ticket: third, progress: ScanProgress())
        let missing = try await repository.finish(third, progress: ScanProgress(), completed: true)
        try check(missing == 3)
        completed = try libraries().first!.completedScanSequence
        let after = try rows()
        try check(after.count == 5 && after.filter { $0.isMissing(completedScanSequence: completed) }.count == 3)
        let changed = after.first { $0.pathKey == initial[0].pathKey }!
        try check(changed.id == originalID && changed.generation != originalGeneration)
        let unchanged = after.first { $0.pathKey == initial[1].pathKey }!
        try check(unchanged.generation == baseline.first { $0.pathKey == initial[1].pathKey }!.generation)

        let cancelled = try await repository.begin(settings: settings)
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await repository.finish(cancelled, progress: ScanProgress(), completed: true)
                fatalError("Cancelled scan completed")
            } catch is CancellationError { }
            _ = try await repository.finish(cancelled, progress: ScanProgress(), completed: false)
        }
        try await cancelledTask.value
        try check(try libraries().first!.completedScanSequence == completed)
        try check(try runs().first { $0.id == cancelled.runID }!.state == "cancelled")

        let interrupted = try await repository.begin(settings: settings)
        let retry = try await repository.begin(settings: settings)
        try check(try runs().first { $0.id == interrupted.runID }!.state == "interrupted")
        do {
            try await repository.ingest([file("root/a.png")], ticket: retry, progress: ScanProgress())
            fatalError("PNG accepted")
        } catch IndexFailure.invalidState { }
        try await repository.ingest(initial, ticket: retry, progress: ScanProgress())
        _ = try await repository.finish(retry, progress: ScanProgress(), completed: true)
        completed = try libraries().first!.completedScanSequence
        try check(try rows().allSatisfy { !$0.isMissing(completedScanSequence: completed) })
        try check(try rows().count == 5)

        var other = settings; other.rootPath = "other"
        let otherRun = try await repository.begin(settings: other)
        try await repository.ingest([initial[0]], ticket: otherRun, progress: ScanProgress())
        _ = try await repository.finish(otherRun, progress: ScanProgress(), completed: true)
        try check(try rows().count == 6)
        try check(try libraries().count == 2)
        let object = try JSONSerialization.jsonObject(with: libraries().first!.connectionData) as! [String: Any]
        try check(Set(object.keys) == Set(["host", "port", "username", "domain", "share", "rootPath"]))

        let batchRun = try await repository.begin(settings: settings)
        let batch = (0..<500).map { file("root/batch/\($0).jpg") }
        try await repository.ingest(batch, ticket: batchRun, progress: ScanProgress())
        do {
            try await repository.ingest(batch + [file("root/overflow.jpg")], ticket: batchRun, progress: ScanProgress())
            fatalError("Oversized batch accepted")
        } catch IndexFailure.invalidState { }
        do {
            try await repository.ingest([file("root/batch/0.jpg", size: 999)], ticket: batchRun, progress: ScanProgress())
            fatalError("Conflicting observation accepted")
        } catch IndexFailure.conflictingObservation { }
        _ = try await repository.finish(batchRun, progress: ScanProgress(), completed: false)
        try check(try libraries().first { $0.id == first.libraryID }!.completedScanSequence == completed)
        // 同じ500件を再走査してもUUID・件数が増えない。500件+端数の保存も確認。
        let savedBatch = try rows().filter { $0.relativePath.hasPrefix("root/batch/") }
        let batchIDs = Set(savedBatch.map(\.id))
        let finalRun = try await repository.begin(settings: settings)
        try await repository.ingest(batch, ticket: finalRun, progress: ScanProgress())
        try await repository.ingest([file("root/tail.HEIC")], ticket: finalRun, progress: ScanProgress())
        let finalMissing = try await repository.finish(finalRun, progress: ScanProgress(), completed: true)
        try check(finalMissing == 5)
        let finalRows = try rows()
        try check(finalRows.count == 507)
        try check(Set(finalRows.filter { $0.relativePath.hasPrefix("root/batch/") }.map(\.id)) == batchIDs)
        print("PASS: formats, byte-exact paths, library isolation, stable IDs, generation, failed/cancelled/interrupted scans, successful missing, reappearance, batch limits, password-free settings")
    }
}
