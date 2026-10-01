import Foundation
import SwiftData

@main struct Stage2StoreWriter {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema([Library.self, MediaEntry.self, ScanRun.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("PhotoJotIndex", schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let library = Library(scopeKey: "stage2", connectionData: Data(), displayName: "stage2")
        let run = ScanRun(libraryID: library.id, sequence: 1)
        library.completedScanSequence = 1; library.nextScanSequence = 1
        run.state = "completed"
        let file = ScannedMedia(path: "old.jpg", size: 100, creation: Date(), modified: Date())
        let entry = MediaEntry(libraryID: library.id, run: run, file: file)
        context.insert(library); context.insert(run); context.insert(entry)
        try context.save()
        try Data(entry.id.uuidString.utf8).write(to: url.appendingPathExtension("uuid"))
        print("Stage 2 store fixture saved")
    }
}
