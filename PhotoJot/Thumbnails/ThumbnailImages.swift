import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ThumbnailImages {
    static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    static func downsample(_ source: CGImageSource) throws -> CGImage {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 200_000_000 else {
            throw ThumbnailError.invalid("画像寸法不正／200MP上限")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoThumbnailPolicy.pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ThumbnailError.invalid("ImageIO thumbnail生成失敗")
        }
        return image
    }
    static func embedded(_ data: Data, orientation: Int) throws -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? NSNumber, let h = p[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ThumbnailError.invalid("埋め込みJPEGが破損／非対応")
        }
        guard w.doubleValue > 0, h.doubleValue > 0, w.doubleValue * h.doubleValue <= 200_000_000 else {
            throw ThumbnailError.invalid("埋め込み画像寸法不正／200MP上限")
        }
        // 300pxグリッドのPoC基準。低解像度の埋め込み画像を引き伸ばさない。
        guard max(w.intValue, h.intValue) >= 300, min(w.intValue, h.intValue) >= 150 else { return nil }
        // 抽出JPEGへIFDのorientationを付与してImageIOに標準変換を任せる。
        let oriented = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(oriented, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.invalid("orientation設定失敗")
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let transformed = CGImageSourceCreateWithData(oriented, nil) else {
            throw ThumbnailError.invalid("orientation設定失敗")
        }
        return try downsample(transformed)
    }
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.invalid("cache encode失敗")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.invalid("cache encode失敗") }
        return data as Data
    }
}

