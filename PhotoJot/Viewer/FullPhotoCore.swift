import Foundation

nonisolated struct FullPhotoViewport: Equatable, Sendable {
    let width: Double
    let height: Double
    // 単位はpixels。ビューのpoints × 環境のdisplayScale。
    init(width: Double, height: Double, scale: Double) {
        self.width = width * scale; self.height = height * scale
    }
    var valid: Bool { width.isFinite && height.isFinite && width >= 1 && height >= 1 && width <= 16384 && height <= 16384 }
}
nonisolated enum FullPhotoSizing {
    static func longEdge(width: Int, height: Int, orientation: Int, viewport: FullPhotoViewport) throws -> Int {
        guard width > 0, height > 0, Double(width) * Double(height) <= 200_000_000,
              (1...8).contains(orientation), viewport.valid else { throw ThumbnailError.invalid("画像／表示領域の寸法不正（200MP上限）") }
        let w = Double(orientation >= 5 ? height : width)
        let h = Double(orientation >= 5 ? width : height)
        let ratio = min(1, viewport.width / w, viewport.height / h)
        return max(1, Int(ceil(max(w, h) * ratio)))
    }
}
// SMB実装に依存せず、read前後とwrite前のキャンセル境界をテストする。
nonisolated enum FullPhotoTransfer {
    static func copy(size: UInt64, chunk: Int = 1024 * 1024,
                     read: (UInt64, Int) async throws -> Data,
                     write: (Data) throws -> Void) async throws {
        guard size > 0, size <= PhotoThumbnailPolicy.maxOriginalBytes, chunk > 0, chunk <= 1024 * 1024 else {
            throw ThumbnailError.invalid("元画像サイズ／chunk不正（512MiB上限）")
        }
        var offset: UInt64 = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunk), size - offset))
            let data = try await read(offset, count)
            try Task.checkCancellation()
            guard data.count == count else { throw ThumbnailError.invalid("SMB short read") }
            try write(data)
            offset += UInt64(data.count)
        }
    }
}
