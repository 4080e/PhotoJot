import Foundation
import ImageIO

// UIで採用するdecode済み画像だけを共有。元画像やJPEGデータは保持しない。
@MainActor final class ThumbnailMemoryCache {
    private nonisolated final class Key: NSObject {
        let value: ThumbnailKey
        init(_ value: ThumbnailKey) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.value == value }
    }
    private let images = NSCache<Key, CGImage>()

    init() {
        // 300pxのグリッド画像を近傍の再表示用に保持。全timelineを保持しない。
        // countLimitはNSCacheの目安であり、厳密な容量保証ではない。
        images.countLimit = 200
    }
    func image(for key: ThumbnailKey) -> CGImage? { images.object(forKey: Key(key)) }

    func image(for key: ThumbnailKey, load: () async throws -> Data) async throws -> CGImage {
        try Task.checkCancellation()
        if let image = image(for: key) { return image }
        let data = try await load()
        try Task.checkCancellation()
        // await中に同じ画像が登録された場合はdecodeも省く。
        if let image = image(for: key) { return image }
        let decoded = await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
            return CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        try Task.checkCancellation()
        guard let decoded else { throw ThumbnailCache.CacheError.invalidJPEG }
        images.setObject(decoded, forKey: Key(key))
        return decoded
    }
}
