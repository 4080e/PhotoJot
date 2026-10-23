import Foundation
import SwiftData

nonisolated struct MediaThumbnailTarget: Sendable {
    let key: ThumbnailKey
    let path: String
    let fileSize: Int64
    let fileExtension: String
    let settings: SMBConnectionSettings
}

extension MediaRepository {
    // 安定UUIDによる単一行取得。timelineの並び順・revision・永続状態は変更しない。
    func thumbnailTarget(id: UUID, libraryID: UUID) throws -> MediaThumbnailTarget? {
        let context = context()
        var query = FetchDescriptor<MediaEntry>(predicate: #Predicate { $0.id == id && $0.libraryID == libraryID })
        query.fetchLimit = 1
        guard let entry = try context.fetch(query).first,
              (PhotoThumbnailPolicy.supports(entry.fileExtension) || VideoThumbnailPolicy.supports(entry.fileExtension)),
              let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == libraryID })).first,
              !entry.isMissing(completedScanSequence: library.completedScanSequence) else { return nil }
        return MediaThumbnailTarget(key: ThumbnailKey(libraryID: libraryID, mediaEntryID: id,
            generation: entry.generation, specificationVersion: VideoThumbnailPolicy.supports(entry.fileExtension) ? VideoThumbnailPolicy.version : PhotoThumbnailPolicy.version, pixelSize: PhotoThumbnailPolicy.pixels),
            path: entry.relativePath, fileSize: entry.fileSize, fileExtension: entry.fileExtension,
            settings: try connectionSettings(for: library))
    }
}
