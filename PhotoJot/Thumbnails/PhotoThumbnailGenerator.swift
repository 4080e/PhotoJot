import Foundation
import CoreGraphics
#if DEBUG
import os
#endif

nonisolated enum PhotoThumbnailPolicy {
    static let pixels = 300
    static let version = "photo-v1-300-oriented-sdr-jpeg85"
    // PoCの原本取得／decode安全弁を維持。快適な生成時間を保証する閾値ではない。
    static let maxOriginalBytes: UInt64 = 512 * 1024 * 1024
    static func supports(_ ext: String) -> Bool { ["jpg", "jpeg", "heic"].contains(ext) }
}

nonisolated enum PhotoThumbnailGenerator {
    // readは呼び出し元が所有するreader一つから逐次供給。cache保存はServiceだけが行う。
    static func generate(format: String, size: UInt64,
                         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                         read: @Sendable (UInt64, Int) async throws -> Data) async throws -> Data {
        guard PhotoThumbnailPolicy.supports(format), size > 0 else { throw ThumbnailError.invalid("写真形式／サイズ不正") }
        let temporary = temporaryDirectory.appendingPathComponent("PhotoJotThumbnail-\(UUID()).source")
        defer { try? FileManager.default.removeItem(at: temporary) }
        @Sendable func fetch(_ offset: UInt64, _ count: Int) async throws -> Data {
            try Task.checkCancellation()
            guard count > 0, count <= 1_048_576, offset <= size, UInt64(count) <= size - offset else {
                throw ThumbnailError.invalid("写真range不正")
            }
            let data: Data
            do { data = try await read(offset, count) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            guard data.count == count else { throw ThumbnailError.invalid("写真short read") }
            return data
        }
        var image: CGImage?
        if format != "heic" {
            do {
                if let plan = try await JPEGThumbnailLocator.locate(size: size, read: fetch) {
                    let bytes = try await fetch(plan.offset, plan.length)
                    image = try autoreleasepool { try ThumbnailImages.embedded(bytes, orientation: plan.orientation) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* PoCと同じく、不足・破損・非対応は原本へfallback。 */ }
        }
        #if DEBUG
        Logger(subsystem: "PhotoJot", category: "Thumbnail").debug("photo format=\(format, privacy: .public), embedded=\(image != nil)")
        #endif
        if image == nil {
            guard size <= PhotoThumbnailPolicy.maxOriginalBytes else { throw ThumbnailError.invalid("原本512MiB上限") }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ThumbnailError.invalid("一時ファイル作成失敗") }
            let file = try FileHandle(forWritingTo: temporary)
            do {
                var offset: UInt64 = 0
                while offset < size {
                    let data = try await fetch(offset, Int(min(1_048_576, size - offset)))
                    try file.write(contentsOf: data); offset += UInt64(data.count)
                    await Task.yield()
                }
                try file.close()
            } catch { try? file.close(); throw error }
            try Task.checkCancellation()
            image = try autoreleasepool {
                guard let source = ThumbnailImages.source(temporary) else { throw ThumbnailError.invalid("ImageIO source失敗") }
                return try ThumbnailImages.downsample(source)
            }
        }
        try Task.checkCancellation()
        guard let image else { throw ThumbnailError.invalid("生成画像なし") }
        let result = try autoreleasepool { try ThumbnailImages.encode(image) }
        try Task.checkCancellation()
        return result
    }
}
