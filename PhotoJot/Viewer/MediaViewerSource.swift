import Foundation
import CoreGraphics

nonisolated struct MediaViewerStream: Sendable {
    let read: @Sendable (UInt64, Int) async throws -> Data
    let close: @Sendable () async -> Void
}

nonisolated enum ViewerFailure: Error { case changed, unavailable }

nonisolated enum PhotoViewerImage {
    // 1件表示なのでPoCの3件LRUは不要。decode済み画像だけ返し、原本は直ちに削除。
    static func load(size: UInt64, viewport: FullPhotoViewport,
                     directory: URL = FileManager.default.temporaryDirectory,
                     read: @Sendable (UInt64, Int) async throws -> Data) async throws -> CGImage {
        let url = directory.appendingPathComponent("PhotoJotViewer-\(UUID()).source")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ViewerFailure.unavailable }
        do {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try await FullPhotoTransfer.copy(size: size, read: read, write: { try handle.write(contentsOf: $0) })
                try handle.close()
            } catch { try? handle.close(); throw error }
            try Task.checkCancellation()
            let image = try FullPhotoImages.decode(url, viewport: viewport).0
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: url)
            return image
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
