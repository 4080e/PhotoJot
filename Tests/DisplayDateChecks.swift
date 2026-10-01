// PhotoJotPoCのfixtureを本体coreに対して実行。
import Foundation

@main struct DisplayDateChecks {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { fatalError("FAILED: \(name)") }
        }
        let created = Date(timeIntervalSince1970: 1700000000)
        let modified = created.addingTimeInterval(100)
        func resolve(_ format: MediaDateFormat, _ evidence: InternalDateEvidence = .init(),
                     _ creation: Date? = created, _ write: Date? = modified) -> DisplayDateResolution {
            DisplayDateResolver.resolve(format: format, evidence: evidence, creationTime: creation, lastWriteTime: write)
        }
        let fields = ExifDateFields(original: "2024:02:29 12:34:56", offset: "+09:00", subsecond: "123456")
        for format in [MediaDateFormat.jpeg, .heic] {
            let r = resolve(format, .init(exif: fields))
            check(r.source == (format == .jpeg ? .jpegExifDateTimeOriginal : .heicExifDateTimeOriginal), "Exif優先")
            check(r.utcOffset == "+09:00" && r.subsecond == "123456", "offset/subsecond保存")
            check(r.originalValue == fields.original && r.quality == .captureMetadata, "原値/quality")
            check(!r.fallback && r.internalSuccess, "内部成功")
            if case .absolute(let d) = r.displayDate {
                let expected = VideoDates.parse("2024-02-29T03:34:56.123456Z").0!
                check(abs(d.timeIntervalSince(expected)) < 0.00001, "絶対時刻")
            } else { check(false, "絶対時刻型") }
            let missing = resolve(format)
            check(missing.source == .smbCreationTime && missing.fallback, "Exifなし正常fallback")
            check(missing.diagnostics.contains { $0.kind == .missing }, "欠落")
        }
        let floating = resolve(.jpeg, .init(exif: .init(original: fields.original, offset: nil, subsecond: "007")))
        check(floating.displayDate == .floating("2024:02:29 12:34:56.007"), "offsetなしは暦日時")
        check(floating.utcOffset == nil && floating.source == .jpegExifDateTimeOriginal, "offset補完なし")
        for zone in ["Asia/Tokyo", "America/Los_Angeles"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            check(resolve(.jpeg, .init(exif: .init(original: fields.original, offset: nil, subsecond: "007"))).displayDate == floating.displayDate, "端末TZ非依存")
        }
        for invalid in ["2023:02:29 12:34:56", "2024:13:01 00:00:00", "0000:01:01 00:00:00", "garbage", "2024:01:01 25:00:00"] {
            let r = resolve(.jpeg, .init(exif: .init(original: invalid, offset: nil, subsecond: nil)))
            check(r.source == .smbCreationTime && r.diagnostics.contains { $0.kind == .invalid }, "無効Exif")
        }
        for offset in ["+15:00", "+09:99", "-00:00", "", "JST"] {
            check(resolve(.heic, .init(exif: .init(original: fields.original, offset: offset, subsecond: nil))).source == .smbCreationTime, "無効offset")
        }
        check(resolve(.heic, .init(exif: .init(original: fields.original, offset: nil, subsecond: "abc"))).source == .smbCreationTime, "無効subsecond")
        check(resolve(.jpeg, .init(), nil).source == .smbLastWriteTime, "更新日時fallback")
        check(resolve(.jpeg, .init(), nil).displayDate == .absolute(modified), "SMB Dateそのまま")
        check(resolve(.jpeg, .init(), nil, nil).displayDate == nil, "unknown")
        check(resolve(.jpeg, .init(), Date(timeIntervalSince1970: -11644473600)).source == .smbLastWriteTime, "FILETIME0")
        check(resolve(.jpeg, .init(), Date(timeIntervalSince1970: .infinity)).source == .smbLastWriteTime, "無限日時")
        func video(_ raw: String?) -> VideoMetadata {
            var v = VideoMetadata()
            v.completed = true
            v.mvhdRaw = 3800000000
            v.mvhdDate = try! VideoDates.movie(3800000000)
            if let raw { v.dates = [.init(location: "movie", keyIndex: 3, type: 1, locale: 0, raw: raw, date: nil, offset: nil, diagnostic: "")] }
            return v
        }
        for format in [MediaDateFormat.mov, .mp4] {
            let r = resolve(format, .init(video: video("2024-02-29T12:34:56+0900")))
            check(r.source == .quickTimeCreationDate && !r.fallback, "QT優先")
            check(r.utcOffset == "+0900", "QT offset保持")
            let fallback = resolve(format, .init(video: video(nil)))
            check(fallback.source == .movieHeaderCreationTime && fallback.fallback, "mvhd fallback")
            check(fallback.quality == .containerCreationTime && fallback.utcOffset == "+00:00", "mvhd意味")
            var empty = VideoMetadata(); empty.completed = true
            check(resolve(format, .init(video: empty)).source == .smbCreationTime, "動画両方なし")
            check(resolve(format, .init(video: empty), nil, nil).source == nil, "動画日時不明")
            var invalid = video(nil); invalid.mvhdRaw = 0; invalid.mvhdDate = nil
            let invalidResult = resolve(format, .init(video: invalid))
            check(invalidResult.source == .smbCreationTime && invalidResult.diagnostics.contains { $0.kind == .invalid }, "mvhd0無効")
            check(resolve(format, .init(video: video("invalid"))).source == .movieHeaderCreationTime, "QT無効からmvhd")
        }
        var conflict = video("2024-01-01T00:00:00Z")
        conflict.dates += video("2025-01-01T00:00:00Z").dates
        check(resolve(.mov, .init(video: conflict)).source == .movieHeaderCreationTime, "競合QTを選ばない")
        var duplicate = video("2024-01-01T00:00:00Z"); duplicate.dates += duplicate.dates
        check(resolve(.mov, .init(video: duplicate)).source == .quickTimeCreationDate, "同値重複")
        for kind in [DateDiagnosticKind.missing, .unsupported, .corrupt, .smb, .unconfirmed] {
            let r = resolve(.heic, .init(diagnostics: [.init(kind: kind, message: "diagnostic")]))
            check(r.fallback && r.source == .smbCreationTime, "診断後もfallback")
            check(r.diagnostics.first?.kind == kind && r.diagnostics.count == 1, "診断種別維持")
        }
        for (name, expected) in [("a.JPG", MediaDateFormat.jpeg), ("b.JpEg", .jpeg), ("c.HEIC", .heic), ("e.MOV", .mov), ("f.Mp4", .mp4)] {
            check(MediaDateFormat(name: name) == expected, "大文字小文字")
        }
        check(MediaDateFormat(name: "a.png") == nil, "PNG対象外")
        check(MediaDateFormat(name: "a.raw") == nil, "対象外")
        print("Display date checks: \(checks) passed")
    }
}
