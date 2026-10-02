// PhotoJotPoCで検証済みのcoreを本体用に移植。
import Foundation

nonisolated enum VideoFailure: Error, CustomStringConvertible {
    case corrupt(String), unsupported(String), limit(String), smb(String)
    var category: String {
        switch self {
        case .corrupt: "破損"
        case .unsupported: "非対応"
        case .limit: "制限超過"
        case .smb: "SMB読み込み失敗"
        }
    }
    var description: String {
        switch self {
        case .corrupt(let s), .unsupported(let s), .limit(let s), .smb(let s): "\(category): \(s)"
        }
    }
}
nonisolated struct VideoBox: Sendable {
    let type: UInt64
    let start: UInt64
    let payload: UInt64
    let end: UInt64
    var size: UInt64 { end - start }
    var label: String {
        String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: type >> ((3 - $0) * 8)) }, encoding: .ascii) ?? "数値type=\(type)"
    }
}
// SMBアダプタとテスト入力に同一の取得制限を適用する。1ファイルを逐次処理する所有者のみが使用。
nonisolated final class VideoRangeReader {
    let source: any MetadataRangeSource
    var size: UInt64 { source.size }
    private var readCount = 0
    private(set) var bytes = 0
    private var received: [Range<UInt64>] = []
    private var forbidden: [Range<UInt64>] = []
    static let budget = 2 * 1024 * 1024
    init(_ source: any MetadataRangeSource) { self.source = source }
    func protectMdat(_ boxes: [VideoBox]) throws {
        forbidden = boxes.map { $0.payload..<$0.end }
        guard !received.contains(where: { read in
            forbidden.contains { read.lowerBound < $0.upperBound && read.upperBound > $0.lowerBound }
        }) else { throw VideoFailure.corrupt("探索中にmdat payload取得を検出") }
    }
    func read(_ offset: UInt64, _ length: Int, _ purpose: String) async throws -> Data {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { throw VideoFailure.corrupt("read範囲外") }
        guard length <= Self.budget - bytes else { throw VideoFailure.limit("管理情報2 MiB上限") }
        if length == 0 { return Data() }
        let end = offset + UInt64(length)
        guard !forbidden.contains(where: { offset < $0.upperBound && end > $0.lowerBound }) else {
            throw VideoFailure.corrupt("mdat payloadへのreadを拒否")
        }
        var union: [Range<UInt64>] = []
        for r in (received + [offset..<end]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = union.last, r.lowerBound <= last.upperBound {
                union[union.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { union.append(r) }
        }
        guard !(union.count == 1 && union[0].lowerBound == 0 && union[0].upperBound == size) else {
            throw VideoFailure.limit("全ファイル範囲取得を拒否")
        }
        var data = Data()
        while data.count < length {
            guard readCount < 4096 else { throw VideoFailure.limit("read回数4096上限") }
            let position = offset + UInt64(data.count), count = min(64 * 1024, length - data.count)
            try Task.checkCancellation()
            readCount += 1
            let chunk: Data
            do { chunk = try await source.read(offset: position, length: count, kind: .management, purpose: purpose) }
            catch let error as MetadataFailure {
                switch error {
                case .limit(let text): throw VideoFailure.limit(text)
                case .unsupported(let text): throw VideoFailure.unsupported(text)
                case .corrupt(let text): throw VideoFailure.corrupt(text)
                case .missing(let text): throw VideoFailure.corrupt(text)
                case .smb(let text): throw VideoFailure.smb(text)
                }
            }
            bytes += chunk.count
            guard !chunk.isEmpty, chunk.count <= count else { throw VideoFailure.smb("短いEOF／要求長を超える応答") }
            data.append(chunk)
        }
        received = union
        return data
    }
}

nonisolated struct VideoCreationDate: Sendable {
    let location: String
    let keyIndex: UInt64
    let type: UInt64
    let locale: UInt64
    let raw: String?
    let date: Date?
    let offset: String?
    let diagnostic: String
}
nonisolated struct VideoMetadata: Sendable {
    var brands: [String] = []
    var moov: VideoBox?
    var mdats: [VideoBox] = []
    var dates: [VideoCreationDate] = []
    var mvhdRaw: UInt64?
    var mvhdDate: Date?
    var completed = false
    var issues: [String] = []
    var unsupported = false
    var failed = false
    var limited = false
    var transportFailure = false
    var unclassifiedFailure = false
    var hasCreation: Bool { dates.contains { $0.raw?.isEmpty == false } }

}

nonisolated enum VideoDates {
    static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    // 明示offsetを持つ完全なISO形式だけをDateに変換。日付だけ／offsetなしは原文で保持。
    static func parse(_ raw: String) -> (Date?, String?, String) {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else {
            return (nil, nil, "日時変換なし（対応する完全ISO日時・明示UTC offsetが必要）")
        }
        func part(_ i: Int) -> String {
            guard let r = Range(match.range(at: i), in: raw) else { return "" }
            return String(raw[r])
        }
        let zone = part(8)
        let digits = zone.replacingOccurrences(of: ":", with: "")
        var offsetSeconds = 0
        if zone != "Z" {
            let chars = Array(digits)
            guard chars.count == 5, let h = Int(String(chars[1...2])), let m = Int(String(chars[3...4])),
                  h <= 14, m < 60, h < 14 || m == 0 else { return (nil, zone, "不正UTC offset") }
            // RFC 3339の-00:00はoffset不明。UTCに補完しない。
            if chars[0] == "-", h == 0, m == 0 { return (nil, zone, "UTC offset不明（-00:00）") }
            offsetSeconds = (h * 3600 + m * 60) * (chars[0] == "-" ? -1 : 1)
        }
        guard let tz = TimeZone(secondsFromGMT: offsetSeconds) else { return (nil, zone, "不正UTC offset") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let values = (1...6).map { Int(part($0)) ?? -1 }
        guard values[0] >= 1, (1...12).contains(values[1]), (1...31).contains(values[2]),
              (0...23).contains(values[3]), (0...59).contains(values[4]), (0...59).contains(values[5]) else {
            return (nil, zone, "不正な日時フィールド")
        }
        let components = DateComponents(year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4], second: values[5])
        guard let date = calendar.date(from: components) else { return (nil, zone, "日時変換不能") }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == values[0], back.month == values[1], back.day == values[2], back.hour == values[3],
              back.minute == values[4], back.second == values[5] else { return (nil, zone, "存在しない日付") }
        let fraction = Double("0." + part(7)) ?? 0
        return (date.addingTimeInterval(fraction), zone, "明示offsetでUTC変換（原文も保持）")
    }
    static func movie(_ value: UInt64) throws -> Date {
        // Foundationで表現・表示する対象を西暦9999年までに限定。0は未設定。
        guard value > 0, value <= 255485145599 else { throw VideoFailure.corrupt("mvhd creation_timeが0または対応日時範囲外") }
        return Date(timeIntervalSince1970: Double(value) - 2082844800)
    }
}

nonisolated final class LimitedVideoParser {
    let reader: VideoRangeReader
    private(set) var metadata = VideoMetadata()
    private var boxCount = 0
    static let boxLimit = 1024 * 1024
    init(_ reader: VideoRangeReader) { self.reader = reader }
    static func code(_ s: String) -> UInt64 { s.utf8.reduce(0) { ($0 << 8) | UInt64($1) } }
    private func registerBox() throws {
        boxCount += 1
        guard boxCount <= 4096 else { throw VideoFailure.limit("box数4096上限") }
    }
    private func box(_ data: Data, start: UInt64, end: UInt64, top: Bool) throws -> VideoBox {
        var b = MetadataBytes(data)
        var size = try b.uint(4)
        let type = try b.uint(4)
        var header: UInt64 = 8
        if size == 1 { size = try b.uint(8); header = 16 }
        else if size == 0 {
            guard top else { throw VideoFailure.unsupported("子boxのsize 0") }
            guard start <= end else { throw VideoFailure.corrupt("box開始範囲外") }
            size = end - start
        }
        if type == Self.code("uuid") { header += 16 }
        guard start <= end, size >= header, size <= end - start else { throw VideoFailure.corrupt("不正box size／親範囲外") }
        return VideoBox(type: type, start: start, payload: start + header, end: start + size)
    }
    private func remoteChildren(_ start: UInt64, _ end: UInt64, _ purpose: String, top: Bool = false) async throws -> [VideoBox] {
        var p = start, output: [VideoBox] = []
        while p < end {
            try registerBox()
            guard end - p >= 8 else { throw VideoFailure.corrupt("box header不足") }
            var data = try await reader.read(p, 8, purpose)
            if try MetadataBytes(data).uint(at: 0, width: 4) == 1 {
                guard end - p >= 16 else { throw VideoFailure.corrupt("extended header不足") }
                data.append(try await reader.read(p + 8, 8, "extended header"))
            }
            let child = try box(data, start: p, end: end, top: top)
            output.append(child)
            p = child.end
        }
        return output
    }
    private func localChildren(_ data: Data, start: Int, end: Int, depth: Int) throws -> [VideoBox] {
        guard depth <= 4, start >= 0, end <= data.count, start <= end else { throw VideoFailure.corrupt("meta境界／階層範囲外") }
        var p = start, output: [VideoBox] = []
        while p < end {
            try registerBox()
            guard end - p >= 8 else { throw VideoFailure.corrupt("meta子header不足") }
            let prefix = Data(data[p..<min(end, p + 16)])
            let child = try box(prefix, start: UInt64(p), end: UInt64(end), top: false)
            output.append(child); p = Int(child.end)
        }
        return output
    }
    private func payload(_ box: VideoBox, _ purpose: String) async throws -> Data {
        guard box.end - box.payload <= UInt64(Self.boxLimit) else { throw VideoFailure.limit("\(purpose)の1 MiB上限") }
        return try await reader.read(box.payload, Int(box.end - box.payload), purpose)
    }
    private func record(_ error: Error) {
        if let e = error as? VideoFailure {
            switch e {
            case .unsupported: metadata.unsupported = true
            case .limit: metadata.limited = true
            case .smb: metadata.transportFailure = true; metadata.failed = true
            default: metadata.failed = true
            }
            metadata.issues.append(e.description)
        } else if let e = error as? MetadataFailure {
            switch e {
            case .unsupported: metadata.unsupported = true
            case .limit: metadata.limited = true
            case .smb: metadata.transportFailure = true; metadata.failed = true
            default: metadata.failed = true
            }
            metadata.issues.append(e.description)
        } else {
            metadata.unclassifiedFailure = true; metadata.issues.append("未分類の解析エラー")
        }
    }
    // 非対応／不正な個別metadataでも他方の日時を観察。通信・資源上限エラーは直ちに終了。
    private func componentError(_ error: Error) throws {
        if error is CancellationError { throw CancellationError() }
        if let e = error as? VideoFailure {
            switch e { case .limit, .smb: throw e; default: break }
        }
        record(error)
    }
    func inspect() async throws {
        do {
            let root = try await remoteChildren(0, reader.size, "top-level header", top: true)
            metadata.mdats = root.filter { $0.type == Self.code("mdat") }
            try reader.protectMdat(metadata.mdats)
            let movies = root.filter { $0.type == Self.code("moov") }
            guard movies.count == 1, let movie = movies.first else { throw VideoFailure.unsupported("moovがない／複数moov") }
            metadata.moov = movie
            let ftyps = root.filter { $0.type == Self.code("ftyp") }
            guard ftyps.count <= 1 else { throw VideoFailure.corrupt("ftyp重複") }
            if let ftyp = ftyps.first {
                var b = MetadataBytes(try await payload(ftyp, "ftyp"))
                metadata.brands.append(try b.fourCC()); _ = try b.uint(4)
                while b.remaining > 0 {
                    guard metadata.brands.count < 256 else { throw VideoFailure.limit("brand数上限") }
                    metadata.brands.append(try b.fourCC())
                }
            }
            let children = try await remoteChildren(movie.payload, movie.end, "moov child header")
            let headers = children.filter { $0.type == Self.code("mvhd") }
            if headers.count > 1 { record(VideoFailure.corrupt("mvhd重複")) }
            else if let header = headers.first {
                do { try await movieHeader(header) } catch { try componentError(error) }
            } else { metadata.issues.append("mvhd欠落") }
            var metas = children.filter { $0.type == Self.code("meta") }.map { ($0, "moov/meta") }
            for udta in children.filter({ $0.type == Self.code("udta") }) {
                let nested = try await remoteChildren(udta.payload, udta.end, "udta child header")
                metas += nested.filter { $0.type == Self.code("meta") }.map { ($0, "moov/udta/meta") }
            }
            for (meta, path) in metas {
                do { try parseMeta(await payload(meta, "meta（一括取得）"), location: "\(path) @\(meta.start)") }
                catch { try componentError(error) }
            }
            if !metadata.hasCreation { metadata.issues.append("対応範囲でcreationdate未取得") }
            let values = Set(metadata.dates.compactMap(\.raw))
            if metadata.dates.count > 1 { metadata.issues.append(values.count > 1 ? "複数creationdate：値が異なる（自動採用なし）" : "複数creationdate：同じ値（全候補を表示）") }
            metadata.completed = true
        } catch is CancellationError { throw CancellationError() }
        catch { record(error) }
    }
    private func movieHeader(_ box: VideoBox) async throws {
        guard box.end - box.payload >= 4 else { throw VideoFailure.corrupt("mvhd FullBox不足") }
        // version判別後も必要部分だけ読む。通常mvhdは小さいため全payloadを一括取得。
        guard box.end - box.payload <= 112 else { throw VideoFailure.unsupported("未知のmvhdサイズ") }
        var b = MetadataBytes(try await payload(box, "mvhd"))
        let v = try b.uint(1), flags = try b.uint(3)
        guard v <= 1, flags == 0 else { throw VideoFailure.unsupported("mvhd version/flags") }
        guard b.data.count == (v == 0 ? 100 : 112) else { throw VideoFailure.corrupt("mvhdサイズ不正") }
        let value = try b.uint(v == 0 ? 4 : 8)
        metadata.mvhdRaw = value
        metadata.mvhdDate = try VideoDates.movie(value)
    }
    private func parseMeta(_ data: Data, location: String) throws {
        // QT: 子boxが直ちに始まる。ISO: version=0/flags=0の4 bytesが先行。
        // 子size=0を許可しないため、先頭0との判別は曖昧にならない。
        let first = try MetadataBytes(data).uint(at: 0, width: 4)
        let start: Int
        if first == 0 { start = 4 }
        else {
            guard data.count >= 8 else { throw VideoFailure.corrupt("meta header不足") }
            let type = try MetadataBytes(data).uint(at: 4, width: 4)
            guard type == Self.code("hdlr") else { throw VideoFailure.unsupported("QT/ISO metaの構造を判別不能") }
            start = 0
        }
        let children = try localChildren(data, start: start, end: data.count, depth: 1)
        func unique(_ name: String) throws -> VideoBox {
            let matches = children.filter { $0.type == Self.code(name) }
            guard matches.count == 1, let value = matches.first else { throw VideoFailure.corrupt("metaの\(name)欠落／重複") }
            return value
        }
        let handler = try unique("hdlr")
        var h = MetadataBytes(Data(data[Int(handler.payload)..<Int(handler.end)]))
        _ = try h.fullBox([0]); _ = try h.uint(4)
        guard try h.uint(4) == Self.code("mdta") else { throw VideoFailure.unsupported("mdta以外のmetadata handler") }
        _ = try h.uint(4); _ = try h.uint(4); _ = try h.uint(4) // reserved構造の存在確認
        let keys = try unique("keys"), ilst = try unique("ilst")
        var k = MetadataBytes(Data(data[Int(keys.payload)..<Int(keys.end)]))
        _ = try k.fullBox([0])
        let count = try k.uint(4)
        guard count <= 4096 else { throw VideoFailure.limit("keys数4096上限") }
        guard count <= UInt64(k.remaining / 8) else { throw VideoFailure.corrupt("keys count範囲外") }
        var selected: Set<UInt64> = []
        for i in 0..<Int(count) {
            let size = try k.uint(4), namespace = try k.uint(4)
            guard size >= 8, size - 8 <= UInt64(k.remaining) else { throw VideoFailure.corrupt("key size範囲外") }
            guard size - 8 <= 4096 else { throw VideoFailure.limit("key文字列4 KiB上限") }
            let range = try k.range(k.position, Int(size) - 8)
            let name = String(data: k.data[range], encoding: .utf8)
            k.position += Int(size) - 8
            if namespace == Self.code("mdta"), name == "com.apple.quicktime.creationdate" { selected.insert(UInt64(i + 1)) }
        }
        try k.end()
        for item in try localChildren(data, start: Int(ilst.payload), end: Int(ilst.end), depth: 2) {
            guard item.type > 0, item.type <= count else { throw VideoFailure.corrupt("ilstキー番号範囲外") }
            guard selected.contains(item.type) else { continue }
            let values = try localChildren(data, start: Int(item.payload), end: Int(item.end), depth: 3).filter { $0.type == Self.code("data") }
            guard !values.isEmpty else { throw VideoFailure.corrupt("creationdateのdata欠落") }
            for value in values {
                guard metadata.dates.count < 64 else { throw VideoFailure.limit("日時候補64件上限") }
                var d = MetadataBytes(Data(data[Int(value.payload)..<Int(value.end)]))
                let type = try d.uint(4), locale = try d.uint(4)
                guard d.remaining <= 4096 else { throw VideoFailure.limit("日時文字列4 KiB上限") }
                guard type == 1 else {
                    metadata.dates.append(VideoCreationDate(location: location, keyIndex: item.type, type: type, locale: locale, raw: nil, date: nil, offset: nil, diagnostic: "非対応data型（UTF-8のみ対応）"))
                    metadata.unsupported = true
                    continue
                }
                guard let raw = String(data: d.data[try d.range(d.position, d.remaining)], encoding: .utf8) else { throw VideoFailure.corrupt("creationdate UTF-8不正") }
                let (date, offset, note) = VideoDates.parse(raw)
                metadata.dates.append(VideoCreationDate(location: location, keyIndex: item.type, type: type, locale: locale, raw: raw, date: date, offset: offset, diagnostic: note))
            }
        }
    }
}
