import Foundation
import ImageIO

actor VideoSource {
    let data: Data
    var reads: [(UInt64, Int)] = []
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    init(_ data: Data, hold: Bool = false) { self.data = data; self.hold = hold }
    func read(_ offset: UInt64, _ length: Int) async throws -> Data {
        precondition(length <= 1_048_576 && offset + UInt64(length) <= data.count)
        reads.append((offset, length))
        if hold { await withCheckedContinuation { waiter = $0 } }
        return data.subdata(in: Int(offset)..<(Int(offset) + length))
    }
    var waiting: Bool { waiter != nil }
    func release() { hold = false; waiter?.resume(); waiter = nil }
}

@main struct VideoThumbnailChecks {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        for format in ["mov", "mp4"] {
            let data = try await VideoThumbnailFixture.make(format: format)
            let source = VideoSource(data)
            let key = ThumbnailKey(libraryID: UUID(), mediaEntryID: UUID(), generation: UUID(), specificationVersion: VideoThumbnailPolicy.version, pixelSize: 300)
            let disk = ThumbnailCache(directory: directory)
            let service = ThumbnailService(cache: disk) { _ in
                try await VideoThumbnailGenerator.generate(format: format, size: UInt64(data.count)) { try await source.read($0, $1) }
            }
            let jpeg = try await service.thumbnail(for: key)
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
            check(image.width > 0 && image.width <= 300 && image.height <= 300, "JPEG frame")
            let reads = await source.reads
            check(reads.count > 1, "multiple ranges")
            let bytes = reads.reduce(0) { $0 + $1.1 }
            check(bytes < data.count, "no full resource download")
            check(await disk.load(key) == jpeg, "service disk persistence")
            // 新serviceでもdisk hitはloader/generatorを起動しない。
            let offline = ThumbnailService(cache: disk) { _ in preconditionFailure("cache hit reached loader") }
            check(try await offline.thumbnail(for: key) == jpeg, "offline disk")
            let memory = ThumbnailMemoryCache()
            let first = try await memory.image(for: key) { try await offline.thumbnail(for: key) }
            let cached = try await memory.image(for: key) { preconditionFailure("memory hit reached disk") }
            check(first === cached, "decoded image reused")
            print("PASS: \(format) range frame, \(bytes)/\(data.count) bytes in \(reads.count) reads, disk/memory offline reuse")
        }
        let data = try await VideoThumbnailFixture.make()
        let source = VideoSource(data, hold: true)
        var ended = false
        let task = Task {
            defer { ended = true }
            return try await VideoThumbnailGenerator.generate(format: "mov", size: UInt64(data.count)) { try await source.read($0, $1) }
        }
        let deadline = Date().addingTimeInterval(10)
        while !(await source.waiting) { check(Date() < deadline, "start read"); await Task.yield() }
        task.cancel()
        // in-flight readを返すまでgeneratorはcleanupを完了できない。
        for _ in 0..<100 { await Task.yield() }
        check(!ended, "drain before return")
        await source.release()
        do { _ = try await task.value; preconditionFailure("cancel") } catch is CancellationError { }
        check(await source.reads.count == 1, "no new reads after cancellation")
        do {
            _ = try await VideoThumbnailGenerator.generate(format: "mov", size: 1000) { _,_ in Data() }
            preconditionFailure("short read accepted")
        } catch { check(!(error is CancellationError), "failure distinction") }
        check(try VideoThumbnailPolicy.time(0.4) == 0.2 && VideoThumbnailPolicy.time(10) == 0.5, "PoC time policy")
        print("PASS: video cancellation drains in-flight read, no later read, failure cleanup, representative time")
    }
}
