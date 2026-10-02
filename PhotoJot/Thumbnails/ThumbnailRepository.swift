import Foundation
import SwiftData

nonisolated struct PhotoThumbnailTarget: Sendable {
    let key: ThumbnailKey
    let path: String
    let fileSize: Int64
    let fileExtension: String
    let settings: SMBConnectionSettings
}

extension MediaRepository {
    // 安定UUIDによる単一行取得。timelineの並び順・revision・永続状態は変更しない。
    func photoThumbnailTarget(id: UUID, libraryID: UUID) throws -> PhotoThumbnailTarget? {
        let context = context()
        var query = FetchDescriptor<MediaEntry>(predicate: #Predicate { $0.id == id && $0.libraryID == libraryID })
        query.fetchLimit = 1
        guard let entry = try context.fetch(query).first,
              PhotoThumbnailPolicy.supports(entry.fileExtension),
              let library = try context.fetch(FetchDescriptor<Library>(predicate: #Predicate { $0.id == libraryID })).first,
              !entry.isMissing(completedScanSequence: library.completedScanSequence) else { return nil }
        return PhotoThumbnailTarget(key: ThumbnailKey(libraryID: libraryID, mediaEntryID: id,
            generation: entry.generation, specificationVersion: PhotoThumbnailPolicy.version, pixelSize: PhotoThumbnailPolicy.pixels),
            path: entry.relativePath, fileSize: entry.fileSize, fileExtension: entry.fileExtension,
            settings: try JSONDecoder().decode(SMBConnectionSettings.self, from: library.connectionData))
    }
}
