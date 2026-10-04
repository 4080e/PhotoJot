import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private actor DecodeGate {
    var edges: [Int] = []
    var continuation: CheckedContinuation<Void, Never>?
    func decode(_ url: URL, _ edge: Int) async throws -> CGImage {
        precondition(FileManager.default.fileExists(atPath: url.path))
        edges.append(edge)
        await withCheckedContinuation { continuation = $0 }
        // Deliberately ignore cancellation, like a synchronous ImageIO operation.
        return try FullPhotoImages.decode(url, maximumPixelSize: edge)
    }
    var waiting: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}
private actor Validity { var current = true; func invalidate() { current = false } }

@main struct PhotoResolutionChecks {
    @MainActor static func wait(_ condition: () async -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !(await condition()) && Date() < end { await Task.yield() }
        let success = await condition(); precondition(success, "timeout")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        func load() async throws -> LoadedPhoto {
            try await PhotoViewerImage.load(size: UInt64(data.count), viewport: .init(width: 100, height: 200, scale: 1), directory: root) { offset, length in
                data.subdata(in: Int(offset)..<(Int(offset) + length))
            }
        }
        precondition(PhotoResolution.requestedSize(displayEdge: 1680, originalEdge: 4032, scale: 3) == 4032)
        precondition(PhotoResolution.requestedSize(displayEdge: 1260, originalEdge: 3648, scale: 3) == 3648)
        precondition(PhotoResolution.requestedSize(displayEdge: 1477, originalEdge: 1477, scale: 3) == 1477)
        precondition(PhotoResolution.requestedSize(displayEdge: 100, originalEdge: 1000, scale: 9) == 300)
        let gate = DecodeGate(), photo = try await load()
        let resolution = PhotoResolution(decode: { try await gate.decode($0, $1) })
        resolution.install(photo, isCurrent: { true })
        resolution.request(scale: 2)
        await wait { await gate.waiting }
        resolution.request(scale: 2.5); resolution.request(scale: 3)
        await gate.release()
        await wait { let count = await gate.edges.count; let waiting = await gate.waiting; return count == 2 && waiting }
        precondition(resolution.image === photo.image, "superseded decode is not adopted")
        let firstEdges = await gate.edges; precondition(firstEdges == [300, 450], "latest request only")
        await gate.release(); await resolution.waitForDecode()
        precondition(resolution.image!.height == 450)
        resolution.request(scale: 2); await resolution.waitForDecode()
        let edgeCount = await gate.edges.count; precondition(edgeCount == 2, "already sufficient image does not decode again")
        await resolution.clear()
        precondition(!FileManager.default.fileExists(atPath: photo.original.url.path) && resolution.image == nil)

        let cleanupGate = DecodeGate(), cleanupPhoto = try await load()
        let cleanup = PhotoResolution(decode: { try await cleanupGate.decode($0, $1) })
        cleanup.install(cleanupPhoto, isCurrent: { true }); cleanup.request(scale: 3)
        await wait { await cleanupGate.waiting }
        cleanup.zoom.scale = 2
        let stop = Task { await cleanup.clear() }
        await wait { cleanup.zoom.scale == 1 }
        precondition(FileManager.default.fileExists(atPath: cleanupPhoto.original.url.path), "do not delete under running decoder")
        cleanup.request(scale: 2)
        await cleanupGate.release(); await stop.value
        precondition(cleanup.image == nil && !FileManager.default.fileExists(atPath: cleanupPhoto.original.url.path))
        let cleanupCount = await cleanupGate.edges.count; precondition(cleanupCount == 1)

        let failedPhoto = try await load()
        let failed = PhotoResolution(decode: { _, _ in throw CocoaError(.fileReadCorruptFile) })
        failed.install(failedPhoto, isCurrent: { true }); failed.request(scale: 3); await failed.waitForDecode()
        precondition(failed.image === failedPhoto.image, "failure keeps normal image")
        await failed.clear()

        let invalidPhoto = try await load(), validity = Validity(), invalidGate = DecodeGate()
        let invalid = PhotoResolution(decode: { try await invalidGate.decode($0, $1) })
        invalid.install(invalidPhoto, isCurrent: { await validity.current }); invalid.request(scale: 2)
        await wait { await invalidGate.waiting }
        await validity.invalidate(); await invalidGate.release(); await invalid.waitForDecode()
        precondition(invalid.image === invalidPhoto.image, "generation change rejects refined image")
        await invalid.clear()

        let orphan = root.appendingPathComponent("PhotoJotViewer-orphan.source")
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data().write(to: orphan); try Data().write(to: unrelated)
        PhotoOriginal.prepare(root)
        precondition(!FileManager.default.fileExists(atPath: orphan.path) && FileManager.default.fileExists(atPath: unrelated.path))
        print("PASS: local refinement, source cap, latest request coalescing, generation rejection, failure fallback, drain-before-delete, zoom reset, orphan cleanup")
    }
}
