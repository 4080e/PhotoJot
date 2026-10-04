import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

private actor PlaceholderProbe {
    var targets: [UUID: MediaThumbnailTarget] = [:]
    var generated = 0
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    func put(_ target: MediaThumbnailTarget) { targets[target.key.mediaEntryID] = target }
    func resolve(_ id: UUID, _ library: UUID) async -> MediaThumbnailTarget? {
        if hold { await withCheckedContinuation { waiter = $0 } }
        return targets[id].flatMap { $0.key.libraryID == library ? $0 : nil }
    }
    func generate() throws -> Data { generated += 1; throw CocoaError(.fileReadUnknown) }
    func suspend() { hold = true }
    func release() { hold = false; waiter?.resume(); waiter = nil }
    var waiting: Bool { waiter != nil }
}
@main struct ViewerPlaceholderChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    @MainActor static func main() async throws {
        let cache = ThumbnailCache(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        let probe = PlaceholderProbe()
        let session = ThumbnailSession(cache: cache, resolve: { await probe.resolve($0, $1) },
            generate: { _ in try await probe.generate() }, disconnect: {})
        let library = UUID()
        func item(_ ext: String, id: UUID = UUID(), generation: UUID = UUID()) -> TimelineItem {
            let date = TimelineDate(calendarDateTime: nil, recordedOffset: nil, kind: .unknown, source: nil, quality: nil)
            return TimelineItem(id: id, libraryID: library, relativePath: "\(id).\(ext)", mediaType: ext == "mp4" ? "video" : "photo",
                                fileExtension: ext, generation: generation, date: date, sortKey: date.sortKey(id: id), metadataState: nil, metadataIsCurrent: false)
        }
        func target(_ item: TimelineItem) -> MediaThumbnailTarget {
            MediaThumbnailTarget(key: ThumbnailSession.placeholderKey(for: item), path: item.relativePath, fileSize: 1,
                                 fileExtension: item.fileExtension, settings: SMBConnectionSettings())
        }
        func jpeg(_ width: Int) -> Data {
            let context = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let buffer = NSMutableData()
            let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            check(CGImageDestinationFinalize(destination))
            return buffer as Data
        }
        let photo = item("jpg"), video = item("mp4"), missing = item("heic")
        for value in [photo, video, missing] { await probe.put(target(value)) }
        let photoKey = target(photo).key, videoKey = target(video).key
        check(photoKey.specificationVersion == PhotoThumbnailPolicy.version && videoKey.specificationVersion == VideoThumbnailPolicy.version)
        try await cache.save(jpeg(8), for: photoKey)
        try await cache.save(jpeg(16), for: videoKey)
        check(session.cachedImage(for: photoKey) == nil)
        let photoImage = try await session.cachedImageOnly(for: photoKey)
        let videoImage = try await session.cachedImageOnly(for: videoKey)
        check(photoImage?.width == 8 && videoImage?.width == 16)
        check(session.cachedImage(for: photoKey) === photoImage && session.cachedImage(for: videoKey) === videoImage)
        // Disk is now corrupt: the shared decoded memory image still returns synchronously.
        try Data([1,2,3]).write(to: cache.directory.appendingPathComponent(photoKey.filename))
        check(try await session.cachedImageOnly(for: photoKey) === photoImage)
        do { _ = try await session.cachedImageOnly(for: target(missing).key); preconditionFailure("miss") }
        catch is CancellationError { }
        try Data([1,2,3]).write(to: cache.directory.appendingPathComponent(target(missing).key.filename))
        do { _ = try await session.cachedImageOnly(for: target(missing).key); preconditionFailure("corrupt miss") }
        catch is CancellationError { }
        check(await probe.generated == 0)
        let changed = item("jpg", id: photo.id)
        await probe.put(target(changed))
        check(try await session.cachedImageOnly(for: photoKey) == nil)
        check(session.cachedImage(for: target(changed).key) == nil)
        // A cancelled old cell cannot deliver a late result to its caller.
        await probe.suspend()
        let oldTask = Task { try await session.cachedImageOnly(for: videoKey) }
        while !(await probe.waiting) { await Task.yield() }
        oldTask.cancel(); await probe.release()
        do { _ = try await oldTask.value; preconditionFailure("late result adopted") } catch is CancellationError { }
        check(try await session.cachedImageOnly(for: videoKey) === videoImage)
        check(await probe.generated == 0)
        print("PASS: photo/video cache-only placeholders, shared memory, disk hits, miss/corruption never generate, key isolation, stale generation and cancelled late result")
    }
}
