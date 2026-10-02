import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

actor ThumbnailTestSource {
    var data: Data
    var reads: [(UInt64, Int)] = []
    var gate: CheckedContinuation<Void, Never>?
    var pause = false
    var fail = false
    init(_ data: Data) { self.data = data }
    func read(_ offset: UInt64, _ count: Int) async throws -> Data {
        reads.append((offset, count))
        if pause { await withCheckedContinuation { gate = $0 } }
        if fail { throw CocoaError(.fileReadUnknown) }
        return data.subdata(in: Int(offset)..<(Int(offset) + count))
    }
    func configure(pause: Bool = false, fail: Bool = false) { self.pause = pause; self.fail = fail }
    func release() { pause = false; gate?.resume(); gate = nil }
    var isWaiting: Bool { gate != nil }
    var usedOriginal: Bool { reads.contains { $0.0 == 0 && $0.1 == data.count } }
}

@main struct PhotoThumbnailChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    static func picture(type: UTType = .jpeg, width: Int = 600, height: Int = 400, orientation: Int = 1) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let output = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        check(CGImageDestinationFinalize(output)); return data as Data
    }
    static func embedded(original: Data, thumbnail: Data, orientation: UInt32) -> Data {
        func num(_ v: UInt32, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func entry(_ tag: UInt32, _ type: UInt32, _ value: UInt32) -> [UInt8] {
            num(tag, 2) + num(type, 2) + num(1, 4) + num(value, 4)
        }
        var tiff: [UInt8] = [73,73,42,0,8,0,0,0]
        tiff += num(1,2) + entry(0x112,3,orientation) + num(26,4)
        tiff += num(3,2) + entry(0x103,3,6) + entry(0x201,4,68) + entry(0x202,4,UInt32(thumbnail.count)) + num(0,4)
        tiff += thumbnail
        let payload = [UInt8]([69,120,105,102,0,0]) + tiff
        let length = payload.count + 2
        return Data([255,216,255,225,UInt8(length >> 8),UInt8(length & 255)] + payload) + original.dropFirst(2)
    }
    static func dimensions(_ data: Data) -> (Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return (image.width, image.height)
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = picture(orientation: 6)
        for orientation in 1...8 {
            let input = embedded(original: original, thumbnail: picture(), orientation: UInt32(orientation))
            let source = ThumbnailTestSource(input)
            let result = try await PhotoThumbnailGenerator.generate(format: "jpg", size: UInt64(input.count), temporaryDirectory: root) {
                try await source.read($0,$1)
            }
            check(!(await source.usedOriginal))
            let size = dimensions(result)
            check(size.0 == (orientation < 5 ? 300 : 200) && size.1 == (orientation < 5 ? 200 : 300))
        }
        for input in [original, embedded(original: original, thumbnail: picture(width: 160, height: 120), orientation: 6),
                      embedded(original: original, thumbnail: Data([1,2,3]), orientation: 6)] {
            let source = ThumbnailTestSource(input)
            let result = try await PhotoThumbnailGenerator.generate(format: "jpeg", size: UInt64(input.count), temporaryDirectory: root) {
                try await source.read($0,$1)
            }
            check(await source.usedOriginal)
            check(max(dimensions(result).0, dimensions(result).1) == 300)
            check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        let heic = picture(type: .heic, orientation: 6)
        let heicSource = ThumbnailTestSource(heic)
        let result = try await PhotoThumbnailGenerator.generate(format: "heic", size: UInt64(heic.count), temporaryDirectory: root) {
            try await heicSource.read($0,$1)
        }
        check(await heicSource.usedOriginal)
        check(dimensions(result).0 == 200 && dimensions(result).1 == 300)
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let cache = ThumbnailCache(directory: root.appendingPathComponent("cache"))
        let key = ThumbnailKey(libraryID: UUID(), mediaEntryID: UUID(), generation: UUID(), specificationVersion: PhotoThumbnailPolicy.version, pixelSize: 300)
        try await cache.save(result, for: key); check(await cache.load(key) == result)
        let temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let broken = ThumbnailTestSource(heic)
        await broken.configure(fail: true)
        do {
            _ = try await PhotoThumbnailGenerator.generate(format: "heic", size: UInt64(heic.count), temporaryDirectory: temporary) { try await broken.read($0,$1) }
            preconditionFailure("expected failure")
        } catch { check(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty) }
        await broken.configure(pause: true)
        let task = Task { try await PhotoThumbnailGenerator.generate(format: "heic", size: UInt64(heic.count), temporaryDirectory: temporary) { try await broken.read($0,$1) } }
        while !(await broken.isWaiting) { await Task.yield() }
        task.cancel(); await broken.release()
        do { _ = try await task.value; preconditionFailure("expected cancel") } catch is CancellationError { }
        check(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        print("PASS: embedded adoption/fallback/corruption, orientations 1...8, real HEIC encode/decode, cache save, failure/cancel cleanup")
    }
}
