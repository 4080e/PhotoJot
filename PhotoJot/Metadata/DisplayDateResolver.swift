// PhotoJotPoCで検証済みのcoreを本体用に移植。
import Foundation

nonisolated enum MediaDateFormat: String, CaseIterable, Sendable {
    case jpeg = "JPEG/JPG", heic = "HEIC", mov = "MOV", mp4 = "MP4"
    init?(name: String) {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "heic": self = .heic
        case "mov": self = .mov
        case "mp4": self = .mp4
        default: return nil
        }
    }
}
nonisolated enum DisplayDateSource: String, CaseIterable, Sendable {
    case jpegExifDateTimeOriginal, heicExifDateTimeOriginal, quickTimeCreationDate
    case movieHeaderCreationTime, smbCreationTime, smbLastWriteTime
}
nonisolated enum DisplayDateQuality: String, Sendable {
    case captureMetadata, containerCreationTime, fileSystemCreationTime, fileSystemModificationTime
}
// Floatingは「日時不明」ではない。時差未確定の暦日時をDate(絶対時刻)に偽装しない。
nonisolated enum DisplayDateValue: Sendable, Equatable {
    case absolute(Date)
    case floating(String)
    var text: String {
        switch self {
        case .absolute(let date): VideoDates.utc(date)
        case .floating(let text): text + "（UTC offset不明）"
        }
    }
}
nonisolated enum DateDiagnosticKind: String, CaseIterable, Sendable {
    case missing = "metadataなし", unconfirmed = "部分取得では未確認", skipped = "内部解析対象外"
    case invalid = "日時無効", unsupported = "parser非対応", limit = "parser制限超過", corrupt = "解析失敗／破損"
    case temporary = "一時的失敗", smb = "SMB read／open失敗", cleanup = "SMB close失敗", note = "情報"
}
nonisolated struct DateDiagnostic: Sendable {
    let kind: DateDiagnosticKind
    var message: String
}
nonisolated struct InternalDateEvidence: Sendable {
    var exif: ExifDateFields?
    var video: VideoMetadata?
    var diagnostics: [DateDiagnostic] = []
}
nonisolated struct DisplayDateResolution: Sendable {
    var displayDate: DisplayDateValue?
    var source: DisplayDateSource?
    var originalValue: String?
    var utcOffset: String?
    var subsecond: String?
    var quality: DisplayDateQuality?
    var fallback = false
    var internalSuccess = false
    var diagnostics: [DateDiagnostic] = []
}
nonisolated enum DisplayDateResolver {
    private struct Candidate {
        let value: DisplayDateValue
        let raw: String
        let offset: String?
        let subsecond: String?
    }
    // 厳格な完全日時だけを受理。offsetなしはUTCを検証用にだけ使い、絶対時刻は返さない。
    private static func iso(_ raw: String) -> Candidate? {
        guard raw.utf8.count <= 128 else { return nil }
        let floatingPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?$"#
        let floating = raw.range(of: floatingPattern, options: .regularExpression) != nil
        let (date, offset, _) = VideoDates.parse(floating ? raw + "Z" : raw)
        guard let date else { return nil }
        let fraction = raw.range(of: #"(?<=\.)\d+"#, options: .regularExpression).map { String(raw[$0]) }
        return Candidate(value: floating ? .floating(raw) : .absolute(date), raw: raw,
                         offset: floating ? nil : offset, subsecond: fraction)
    }
    private static func exif(_ fields: ExifDateFields) -> Candidate? {
        guard fields.original.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = fields.original.split(separator: " ")
        var raw = parts[0].replacingOccurrences(of: ":", with: "-") + "T" + parts[1]
        if let sub = fields.subsecond {
            guard !sub.isEmpty, sub.utf8.count <= 256, sub.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            // Dateの精度を超える桁は変換用のみ制限。元の全桁は保持。
            raw += "." + sub.prefix(9)
        }
        if let offset = fields.offset {
            guard offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
            raw += offset
        }
        guard let parsed = iso(raw) else { return nil }
        let value: DisplayDateValue
        if fields.offset == nil {
            value = .floating(fields.original + (fields.subsecond.map { "." + $0 } ?? ""))
        } else { value = parsed.value }
        return Candidate(value: value, raw: fields.original, offset: fields.offset, subsecond: fields.subsecond)
    }
    static func validSMBDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 > -11644473600, // FILETIME 0 (1601-01-01) は未設定として扱う
              date.timeIntervalSince1970 <= 253402300799 else { return nil }
        return date
    }
    static func resolve(format: MediaDateFormat, evidence: InternalDateEvidence,
                        creationTime: Date?, lastWriteTime: Date?) -> DisplayDateResolution {
        var result = DisplayDateResolution(diagnostics: evidence.diagnostics)
        func choose(_ candidate: Candidate, _ source: DisplayDateSource, _ quality: DisplayDateQuality, fallback: Bool) {
            result.displayDate = candidate.value; result.originalValue = candidate.raw
            result.utcOffset = candidate.offset; result.subsecond = candidate.subsecond
            result.source = source; result.quality = quality; result.fallback = fallback
            result.internalSuccess = true
        }
        switch format {
        case .jpeg, .heic:
            if let fields = evidence.exif {
                if let candidate = exif(fields) {
                    choose(candidate, format == .jpeg ? .jpegExifDateTimeOriginal : .heicExifDateTimeOriginal, .captureMetadata, fallback: false)
                } else { result.diagnostics.append(.init(kind: .invalid, message: "Exif日時無効: \(fields.original), offset=\(fields.offset ?? "なし"), subsecond=\(fields.subsecond ?? "なし")")) }
            } else if evidence.diagnostics.isEmpty {
                result.diagnostics.append(.init(kind: .missing, message: "DateTimeOriginalなし"))
            }
        case .mov, .mp4:
            if let video = evidence.video {
                let raws = Set(video.dates.compactMap(\.raw))
                if raws.count == 1, let raw = raws.first, video.dates.allSatisfy({ $0.raw != nil }) {
                    if let candidate = iso(raw) { choose(candidate, .quickTimeCreationDate, .captureMetadata, fallback: false) }
                    else { result.diagnostics.append(.init(kind: .invalid, message: "creationdate日時無効／変換非対応: \(raw)")) }
                } else if raws.count > 1 {
                    result.diagnostics.append(.init(kind: .invalid, message: "creationdate候補が競合: " + raws.sorted().joined(separator: " / ")))
                } else if video.dates.isEmpty && video.completed && !video.unsupported && !video.failed && !video.limited {
                    result.diagnostics.append(.init(kind: .missing, message: "creationdateなし"))
                }
                if result.displayDate == nil, let raw = video.mvhdRaw {
                    if let date = try? VideoDates.movie(raw) {
                        choose(Candidate(value: .absolute(date), raw: String(raw), offset: "+00:00", subsecond: nil),
                               .movieHeaderCreationTime, .containerCreationTime, fallback: true)
                    } else { result.diagnostics.append(.init(kind: .invalid, message: "mvhd creation_time無効: \(raw)")) }
                }
                if result.displayDate == nil && video.mvhdRaw == nil && video.completed {
                    result.diagnostics.append(.init(kind: .missing, message: "mvhd日時未取得"))
                }
            } else if evidence.diagnostics.isEmpty {
                result.diagnostics.append(.init(kind: .missing, message: "動画日時なし"))
            }
        }
        if result.displayDate != nil { return result }
        for (input, source, quality) in [(creationTime, DisplayDateSource.smbCreationTime, DisplayDateQuality.fileSystemCreationTime),
                                         (lastWriteTime, .smbLastWriteTime, .fileSystemModificationTime)] {
            if let date = validSMBDate(input) {
                result.displayDate = .absolute(date); result.source = source; result.quality = quality
                result.originalValue = VideoDates.utc(date) // SMBは元文字列を提供しない。受領DateをUTC表記。
                result.fallback = true
                return result
            }
            if input != nil { result.diagnostics.append(.init(kind: .invalid, message: "\(source.rawValue)が未設定／範囲外")) }
        }
        result.diagnostics.append(.init(kind: .note, message: "すべての候補がなく日時不明"))
        return result
    }
}
