import Foundation
import ImageIO
import CoreGraphics

nonisolated enum FullPhotoImages {
    static func decode(_ url: URL, viewport: FullPhotoViewport) throws -> (CGImage, Int, Int, Int) {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ThumbnailError.invalid("ImageIO source作成失敗")
            }
            let index = CGImageSourceGetPrimaryImageIndex(source)
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let h = props[kCGImagePropertyPixelHeight] as? NSNumber else { throw ThumbnailError.invalid("画像寸法なし") }
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let edge = try FullPhotoSizing.longEdge(width: w.intValue, height: h.intValue, orientation: orientation, viewport: viewport)
            return (try makeImage(source, index: index, edge: edge), w.intValue, h.intValue, orientation)
        }
    }

    static func decode(_ url: URL, maximumPixelSize: Int) throws -> CGImage {
        try autoreleasepool {
            guard maximumPixelSize > 0,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ThumbnailError.invalid("ImageIO source作成失敗")
            }
            return try makeImage(source, index: CGImageSourceGetPrimaryImageIndex(source), edge: maximumPixelSize)
        }
    }

    private static func makeImage(_ source: CGImageSource, index: Int, edge: Int) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ThumbnailError.invalid("ImageIO縮小失敗")
        }
        return image
    }
}

