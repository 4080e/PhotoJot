import Foundation
import CoreGraphics

nonisolated struct MediaViewerStream: Sendable {
    let read: @Sendable (UInt64, Int) async throws -> Data
    let close: @Sendable () async -> Void
}

nonisolated enum ViewerFailure: Error { case changed, unavailable }

nonisolated enum PhotoViewerImage {
    // 原本の所有権をcurrent photoへ渡す。取得失敗・採用されなかった結果は削除する。
    static func load(size: UInt64, viewport: FullPhotoViewport,
                     directory: URL = PhotoOriginal.directory,
                     read: @Sendable (UInt64, Int) async throws -> Data) async throws -> LoadedPhoto {
        let url = directory.appendingPathComponent("PhotoJotViewer-\(UUID()).source")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ViewerFailure.unavailable }
        do {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try await FullPhotoTransfer.copy(size: size, read: read, write: { try handle.write(contentsOf: $0) })
                try handle.close()
            } catch { try? handle.close(); throw error }
            try Task.checkCancellation()
            let decoded = try FullPhotoImages.decode(url, viewport: viewport)
            try Task.checkCancellation()
            return LoadedPhoto(image: decoded.0, original: PhotoOriginal(url: url,
                originalEdge: max(decoded.1, decoded.2),
                displayEdge: try FullPhotoSizing.longEdge(width: decoded.1, height: decoded.2, orientation: decoded.3, viewport: viewport)))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

nonisolated struct LoadedPhoto: @unchecked Sendable {
    let image: CGImage
    let original: PhotoOriginal
}

nonisolated final class PhotoOriginal: @unchecked Sendable {
    let url: URL
    let originalEdge: Int
    let displayEdge: Int
    init(url: URL, originalEdge: Int, displayEdge: Int) {
        self.url = url; self.originalEdge = originalEdge; self.displayEdge = displayEdge
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    deinit { remove() }

    // 初回取得前に一度だけ、前プロセスが残した専用領域を掃除する。
    // 現在プロセスの原本を取得のたびに消すことはない。
    static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoJotViewerOriginals", isDirectory: true)
        prepare(directory)
        return directory
    }()
    static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("PhotoJotViewer-") && file.pathExtension == "source" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
