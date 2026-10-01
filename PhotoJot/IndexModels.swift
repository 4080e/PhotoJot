import Foundation
import SwiftData

@Model nonisolated final class Library {
    #Unique<Library>([\.scopeKey])
    var id: UUID
    var scopeKey: String
    // 接続設定の確定済みスナップショット。パスワードを持たない既存DTOを使用する。
    var connectionData: Data
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var nextScanSequence: Int64
    var completedScanSequence: Int64
    // cursorの継続中にindexが更新されたことを検知する。
    var timelineRevision: Int64?
    var timelinePreparedVersion: Int?

    init(scopeKey: String, connectionData: Data, displayName: String) {
        id = UUID(); self.scopeKey = scopeKey; self.connectionData = connectionData
        self.displayName = displayName; createdAt = Date(); updatedAt = Date()
        nextScanSequence = 0; completedScanSequence = 0
    }
}

@Model nonisolated final class MediaEntry {
    #Unique<MediaEntry>([\.libraryID, \.pathKey])
    #Index<MediaEntry>([\.libraryID, \.lastSeenSequence],
                       [\.libraryID, \.timelineKeyVersion, \.timelineSortKey])
    var id: UUID
    // Library.idによる関連。モデルをactor間で渡さない。
    var libraryID: UUID
    var relativePath: String
    var pathKey: String
    var mediaType: String
    var fileExtension: String
    var fileSize: Int64
    var smbCreationTime: Date
    var smbLastWriteTime: Date
    var generation: UUID
    var lastSeenScanID: UUID
    var lastSeenSequence: Int64
    // Optional追加列により段階2の既存ストアを軽量migrationする。
    var resolvedInstant: Date?
    var resolvedFloatingDate: String?
    var dateSource: String?
    var dateQuality: String?
    var dateFallback: Bool?
    var originalDateValue: String?
    var utcOffset: String?
    var subsecond: String?
    var metadataState: String?
    var metadataGeneration: UUID?
    var metadataVersion: Int?
    var metadataCompletedAt: Date?
    var metadataDiagnostic: String?

    // 検索用の派生値だけを保存。source / quality / groupは既存metadataから算出する。
    var timelineSortKey: String = ""
    var timelineKeyVersion: Int?

    func clearMetadata() {
        timelineSortKey = ""; timelineKeyVersion = nil
        resolvedInstant = nil; resolvedFloatingDate = nil
        dateSource = nil; dateQuality = nil; dateFallback = nil
        originalDateValue = nil; utcOffset = nil; subsecond = nil
        metadataState = nil; metadataGeneration = nil; metadataVersion = nil
        metadataCompletedAt = nil; metadataDiagnostic = nil
    }

    init(libraryID: UUID, run: ScanRun, file: ScannedMedia) {
        id = UUID(); self.libraryID = libraryID
        relativePath = file.path; pathKey = file.pathKey
        mediaType = file.mediaType; fileExtension = file.fileExtension
        fileSize = file.size; smbCreationTime = file.creation; smbLastWriteTime = file.modified
        generation = UUID(); lastSeenScanID = run.id; lastSeenSequence = run.sequence
    }

    // completedScanSequenceは正常完了時だけ進める。途中失敗でmissingは増えない。
    func isMissing(completedScanSequence: Int64) -> Bool {
        lastSeenSequence < completedScanSequence
    }
}

@Model nonisolated final class ScanRun {
    #Unique<ScanRun>([\.id])
    var id: UUID
    var libraryID: UUID
    var sequence: Int64
    var startedAt: Date
    var endedAt: Date?
    var state: String
    var files: Int
    var folders: Int
    var media: Int
    var missingCount: Int?

    init(libraryID: UUID, sequence: Int64) {
        id = UUID(); self.libraryID = libraryID; self.sequence = sequence
        startedAt = Date(); state = "running"
        files = 0; folders = 0; media = 0
    }
}

nonisolated struct ScannedMedia: Sendable {
    let path: String
    let size: Int64
    let creation: Date
    let modified: Date
    var pathKey: String { Self.exactKey(path) }
    var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    var mediaType: String { ["mov", "mp4"].contains(fileExtension) ? "video" : "photo" }
    static func exactKey(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    static func isSupported(_ path: String) -> Bool {
        ["jpeg", "jpg", "heic", "mov", "mp4"].contains((path as NSString).pathExtension.lowercased())
    }
}

nonisolated struct ScanProgress: Sendable {
    var files = 0
    var folders = 0
    var media = 0
}

nonisolated struct ScanTicket: Sendable {
    let libraryID: UUID
    let runID: UUID
}

nonisolated enum IndexFailure: LocalizedError {
    case invalidState
    case conflictingObservation
    var errorDescription: String? {
        switch self {
        case .invalidState: "indexの走査状態が不正です。"
        case .conflictingObservation: "走査中に同じパスのファイル属性が変化しました。再走査してください。"
        }
    }
}
