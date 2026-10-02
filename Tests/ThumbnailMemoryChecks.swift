import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@main struct ThumbnailMemoryChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let disk = ThumbnailCache(directory: directory)
        let memory = ThumbnailMemoryCache()
        let key = ThumbnailKey(libraryID: UUID(), mediaEntryID: UUID(), generation: UUID(), specificationVersion: "photo-v1", pixelSize: 300)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination))
        let jpeg = data as Data
        try await disk.save(jpeg, for: key)
        check(memory.image(for: key) == nil)
        var diskReads = 0, generations = 0
        let first = try await memory.image(for: key) {
            diskReads += 1
            if let data = await disk.load(key) { return data }
            generations += 1
            return jpeg
        }
        check(diskReads == 1 && generations == 0)
        check(memory.image(for: key) === first)

        // SMB枠を占有し、diskを破損させてもmemory経路はどちらにも到達しない。
        let gate = SMBOperationGate()
        try await gate.acquire()
        try Data([1,2,3]).write(to: directory.appendingPathComponent(key.filename))
        let second = try await memory.image(for: key) {
            diskReads += 1
            try await gate.acquire()
            await gate.release()
            generations += 1
            throw CocoaError(.fileReadUnknown)
        }
        check(second === first && diskReads == 1 && generations == 0)
        check(await gate.waitingCount == 0)
        await gate.release()
        // memoryと独立して、従来どおり破損diskはmiss／安全に削除できる。
        check(await disk.load(key) == nil)
        try await disk.removeCorruptEntry(key)
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(key.filename).path))

        for other in [
            ThumbnailKey(libraryID: UUID(), mediaEntryID: key.mediaEntryID, generation: key.generation, specificationVersion: key.specificationVersion, pixelSize: key.pixelSize),
            ThumbnailKey(libraryID: key.libraryID, mediaEntryID: UUID(), generation: key.generation, specificationVersion: key.specificationVersion, pixelSize: key.pixelSize),
            ThumbnailKey(libraryID: key.libraryID, mediaEntryID: key.mediaEntryID, generation: UUID(), specificationVersion: key.specificationVersion, pixelSize: key.pixelSize),
            ThumbnailKey(libraryID: key.libraryID, mediaEntryID: key.mediaEntryID, generation: key.generation, specificationVersion: "photo-v2", pixelSize: key.pixelSize),
            ThumbnailKey(libraryID: key.libraryID, mediaEntryID: key.mediaEntryID, generation: key.generation, specificationVersion: key.specificationVersion, pixelSize: 600)
        ] { check(memory.image(for: other) == nil) }

        let pendingKey = ThumbnailKey(libraryID: key.libraryID, mediaEntryID: UUID(), generation: UUID(), specificationVersion: "photo-v1", pixelSize: 300)
        var continuation: CheckedContinuation<Void, Never>?
        let pending = Task {
            try await memory.image(for: pendingKey) {
                await withCheckedContinuation { continuation = $0 }
                return jpeg
            }
        }
        while continuation == nil { await Task.yield() }
        pending.cancel(); continuation?.resume()
        do { _ = try await pending.value; preconditionFailure("cancellation") } catch is CancellationError { }
        check(memory.image(for: pendingKey) == nil)
        do {
            _ = try await memory.image(for: pendingKey) { Data([0,1,2]) }
            preconditionFailure("decode failure")
        } catch ThumbnailCache.CacheError.invalidJPEG { }
        check(memory.image(for: pendingKey) == nil)
        print("PASS: disk-to-memory, synchronous image reuse, memory bypasses disk/decode/generator/occupied SMB gate, all key fields isolated, corrupt disk handling, cancellation and decode failure")
    }
}
