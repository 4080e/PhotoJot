import Foundation
import CryptoKit

nonisolated struct ThumbnailKey: Hashable, Sendable {
    let libraryID: UUID
    let mediaEntryID: UUID
    let generation: UUID
    // 写真／動画の生成方式・向き・encoding等の仕様を含める。metadata版とは独立。
    let specificationVersion: String
    let pixelSize: Int

    var filename: String {
        let fields = [libraryID.uuidString.lowercased(), mediaEntryID.uuidString.lowercased(),
                      generation.uuidString.lowercased(), specificationVersion, String(pixelSize)]
        let canonical = fields.map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}
