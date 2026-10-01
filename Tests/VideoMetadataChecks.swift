// PhotoJotPoCのfixtureを本体coreに対して実行。
import Foundation

nonisolated final class VideoMemorySource: MetadataRangeSource {
    let data: Data
    var size: UInt64 { UInt64(data.count) }
    var requests: [(UInt64, Int)] = []
    var shortReads = false
    var fails = false
    init(_ data: Data) { self.data = data }
    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String) async throws -> Data {
        if fails { throw VideoFailure.smb("synthetic") }
        guard offset <= size, length >= 0, UInt64(length) <= size - offset else { throw VideoFailure.smb("範囲外") }
        let count = shortReads ? min(3, length) : length
        requests.append((offset, count))
        return Data(data[Int(offset)..<(Int(offset) + count)])
    }
}
@main struct VideoMetadataChecks {
    static var checks = 0
    static func check(_ v: Bool, _ name: String) { precondition(v, name); checks += 1 }
    static func n(_ v: UInt64, _ width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) })
    }
    static func box(_ type: String, _ data: Data, extended: Bool = false, zero: Bool = false) -> Data {
        (extended ? n(1, 4) + Data(type.utf8) + n(UInt64(data.count + 16), 8) : n(zero ? 0 : UInt64(data.count + 8), 4) + Data(type.utf8)) + data
    }
    static func full(_ version: UInt64 = 0) -> Data { n(version, 1) + n(0, 3) }
    static func mvhd(_ version: UInt64 = 0, value: UInt64 = 3800000000) -> Data {
        box("mvhd", full(version) + n(value, version == 0 ? 4 : 8) + Data(repeating: 0, count: version == 0 ? 92 : 100))
    }
    static func meta(iso: Bool = false, keyIndex: Int = 2, raw: String = "2024-06-07T08:09:10+0900", duplicate: Bool = false,
                     missing: Bool = false, bad: String = "", extended: Bool = false) -> Data {
        let hdlr = box("hdlr", full() + n(0, 4) + Data("mdta".utf8) + Data(repeating: 0, count: 12))
        var keys = full() + n(bad == "count" ? UInt64(UInt32.max) : UInt64(keyIndex), 4)
        for i in 1...keyIndex {
            let name = Data((i == keyIndex && !missing ? "com.apple.quicktime.creationdate" : "unused.\(i)").utf8)
            keys += n(bad == "keysize" ? UInt64(UInt32.max) : UInt64(8 + name.count), 4) + Data("mdta".utf8) + name
        }
        func value(_ s: String) -> Data {
            box("data", bad == "data" ? Data([0]) : n(bad == "type" ? 2 : 1, 4) + n(99, 4) + Data(s.utf8))
        }
        let values = value(raw) + (duplicate ? value("2024-06-08T08:09:10+09:00") : Data())
        let item = n(UInt64(values.count + 8), 4) + n(bad == "index" ? UInt64(keyIndex + 1) : UInt64(keyIndex), 4) + values
        var content = (iso ? full() : Data()) + hdlr + box("keys", keys) + box("ilst", item)
        if bad == "child" { content.replaceSubrange((iso ? 4 : 0)..<(iso ? 8 : 4), with: n(UInt64(UInt32.max), 4)) }
        return box("meta", content, extended: extended)
    }
    static func file(meta: Data, version: UInt64 = 0, after: Bool = false, extended: Bool = false, zero: Bool = false, udta: Bool = false) -> Data {
        let ftyp = box("ftyp", Data("qt  ".utf8) + n(0, 4))
        let moov = box("moov", mvhd(version) + box("trak", Data(repeating: 0xCD, count: 4096)) + (udta ? box("udta", box("free", Data(repeating: 9, count: 31)) + meta) : meta), extended: extended)
        let mdat = box("mdat", Data(repeating: 0xCC, count: 10000), extended: extended, zero: zero)
        return ftyp + box("wide", Data()) + (after ? mdat + moov : moov + mdat)
    }
    static func parse(_ data: Data, short: Bool = false) async -> (VideoMetadata, VideoRangeReader, VideoMemorySource) {
        let source = VideoMemorySource(data); source.shortReads = short
        let reader = VideoRangeReader(source)
        // 使用したreaderを返し、転送量と全要求を検査する。
        let actual = LimitedVideoParser(reader)
        await actual.inspect()
        return (actual.metadata, reader, source)
    }
    static func main() async throws {
        for iso in [false, true] {
            for version: UInt64 in [0, 1] {
                for after in [false, true] {
                    for extended in [false, true] {
                        for index in [1, 4] {
                            let (m, r, s) = await parse(file(meta: meta(iso: iso, keyIndex: index, extended: extended), version: version, after: after, extended: extended, udta: iso))
                            check(m.completed && !m.failed && !m.unsupported, "正常32/64bit・QT/ISO・udta")
                            check(m.dates.count == 1 && m.dates[0].keyIndex == UInt64(index) && m.dates[0].locale == 99, "可変キー番号・locale")
                            check(m.dates[0].offset == "+0900" && m.dates[0].date != nil, "日時と元offset保持")
                            check(m.mvhdRaw == 3800000000 && m.mvhdDate != nil, "mvhd v0/v1")
                            check(s.requests.allSatisfy { req in
                                m.mdats.allSatisfy { req.0 + UInt64(req.1) <= $0.payload || req.0 >= $0.end }
                            }, "mdat payload転送0")
                            check(r.bytes < 2000, "trak・moov全体を取得しない")
                        }
                    }
                }
            }
        }
        let (zero, _, _) = await parse(file(meta: meta(), zero: true))
        check(zero.completed && zero.hasCreation, "top-level size0 mdat")
        let (short, _, _) = await parse(file(meta: meta()), short: true)
        check(short.hasCreation && !short.failed, "短いreadを不足分のみ追加")
        let (missing, _, _) = await parse(file(meta: meta(missing: true)))
        check(missing.completed && !missing.hasCreation && missing.mvhdDate != nil && !missing.failed, "creationdate欠落")
        let (dup, _, _) = await parse(file(meta: meta(duplicate: true)))
        check(dup.dates.count == 2 && dup.issues.contains { $0.contains("値が異なる") }, "複数値を保持")
        for bad in ["count", "keysize", "index", "data", "child", "type"] {
            let (m, _, _) = await parse(file(meta: meta(bad: bad)))
            check(m.failed || m.unsupported || m.limited, "不正keys/ilst/data/meta: \(bad)")
            check(m.mvhdDate != nil, "metadata不正でもmvhd観察")
        }
        for size: UInt64 in [2, 7, UInt64(UInt32.max)] {
            var d = file(meta: meta()); d.replaceSubrange(0..<4, with: n(size, 4))
            let (m, _, _) = await parse(d)
            check(m.failed, "不正box size")
        }
        let (overflow, _, _) = await parse(n(1, 4) + Data("moov".utf8) + n(UInt64.max, 8) + Data(repeating: 0, count: 30))
        check(overflow.failed, "64bit size overflow／範囲外")
        let huge = box("meta", Data(repeating: 0, count: 1024 * 1024 + 1))
        let (limit, limitReader, _) = await parse(file(meta: huge))
        check(limit.limited && limitReader.bytes < 1000, "meta上限：payload前に停止")
        let source = VideoMemorySource(Data(repeating: 0, count: 3 * 1024 * 1024))
        let budget = VideoRangeReader(source)
        _ = try await budget.read(0, VideoRangeReader.budget, "test")
        do { _ = try await budget.read(UInt64(VideoRangeReader.budget), 1, "test"); fatalError("上限なし") }
        catch VideoFailure.limit { check(true, "累計2MiB上限") }
        do { _ = try await budget.read(UInt64.max, 8, "test"); fatalError("overflow") }
        catch VideoFailure.corrupt { check(true, "read offset overflow") }
        let fullReader = VideoRangeReader(VideoMemorySource(Data(repeating: 0, count: 20)))
        do { _ = try await fullReader.read(0, 20, "test"); fatalError("全取得") }
        catch VideoFailure.limit { check(true, "全取得を拒否") }
        let guarded = VideoRangeReader(VideoMemorySource(Data(repeating: 0, count: 100)))
        try guarded.protectMdat([VideoBox(type: 0, start: 0, payload: 8, end: 100)])
        do { _ = try await guarded.read(8, 1, "test"); fatalError("mdat read") }
        catch VideoFailure.corrupt { check(true, "mdat実行前の防御") }
        for raw in ["2024-06-07T08:09:10", "2024-02-30T08:09:10Z", "2024-06-07T25:09:10Z", "2024-06-07T08:09:10+1460", "2024-06-07T08:09:10-00:00"] {
            check(VideoDates.parse(raw).0 == nil, "不正／offsetなしを補完しない")
        }
        check(VideoDates.parse("2024-06-07T08:09:10.123-05:30").0 != nil, "小数秒・負offset")
        check(VideoDates.parse("2024-06-07T08:09:10+0900").0 == VideoDates.parse("2024-06-06T23:09:10Z").0, "UTC変換一致")
        for value: UInt64 in [0, UInt64.max] {
            do { _ = try VideoDates.movie(value); fatalError("不正mvhd") }
            catch VideoFailure.corrupt { check(true, "mvhd無効値") }
        }
        let unknownVersion = box("moov", mvhd(2) + meta()) + box("mdat", Data(repeating: 0, count: 100))
        let (version, _, _) = await parse(unknownVersion)
        check(version.unsupported && version.hasCreation, "未知mvhdでもcreationdate観察")
        let sample = file(meta: meta())
        // 切断した管理情報の全境界でtrapを起こさない。
        for length in 0..<min(500, sample.count) {
            let (m, _, _) = await parse(Data(sample.prefix(length)))
            check(!m.completed, "切断入力")
        }
        print("PASS: \(checks) video checks")
    }
}
