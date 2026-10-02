import Foundation
import ImageIO
import UniformTypeIdentifiers

// immutableな保存先とqueueだけを共有。readは並行、save/removeはbarrierで排他。
nonisolated final class ThumbnailCache: Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "PhotoJot.thumbnail-cache", qos: .utility, attributes: .concurrent)

    init(directory: URL) { self.directory = directory }

    static func applicationCache() -> ThumbnailCache {
        let root = URL.cachesDirectory.appendingPathComponent("PhotoJot/Thumbnails", isDirectory: true)
        return ThumbnailCache(directory: root)
    }

    func load(_ key: ThumbnailKey) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let value: Data? = autoreleasepool {
                    guard let data = try? Data(contentsOf: self.directory.appendingPathComponent(key.filename)),
                          Self.isJPEG(data) else { return nil }
                    return data
                }
                continuation.resume(returning: value)
            }
        }
    }

    func save(_ data: Data, for key: ThumbnailKey) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async(flags: .barrier) {
                do {
                    try autoreleasepool {
                        guard Self.isJPEG(data) else { throw CacheError.invalidJPEG }
                        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                        try data.write(to: self.directory.appendingPathComponent(key.filename), options: .atomic)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // read後に遅れて有効cacheを消さないよう、削除時にもbarrier内で再検証する。
    func removeCorruptEntry(_ key: ThumbnailKey) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async(flags: .barrier) {
                do {
                    let url = self.directory.appendingPathComponent(key.filename)
                    if FileManager.default.fileExists(atPath: url.path) {
                        let data = try Data(contentsOf: url)
                        if !Self.isJPEG(data) { try FileManager.default.removeItem(at: url) }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    enum CacheError: Error { case invalidJPEG }
}
