// PhotoJotPoCのfixtureを本体coreに対して実行。
import Foundation

// 実ファイル・SMB・ImageIOを使用しない、実装本体に対する検証。
nonisolated final class MemoryMetadataSource: MetadataRangeSource {
    let data: Data
    var requests: [(UInt64, Int, MetadataReadKind)] = []
    var size: UInt64 { UInt64(data.count) }
    init(_ data: Data) { self.data = data }
    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String = "その他") async throws -> Data {
        guard offset <= size, length >= 0, UInt64(length) <= size - offset else { throw MetadataFailure.smb("test範囲外") }
        requests.append((offset, length, kind))
        return Data(data[Int(offset)..<(Int(offset) + length)])
    }
}

@main struct LimitedMetadataChecks {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks += 1
    }
    static func reject(_ category: String, _ name: String, _ work: () throws -> Void) {
        do { try work(); fatalError("期待したエラーなし: \(name)") }
        catch let error as MetadataFailure { check(error.category == category, "\(name): \(error)") }
        catch { fatalError("想定外エラー: \(error)") }
    }
    static func rejectAsync(_ category: String, _ name: String, _ work: () async throws -> Void) async {
        do { try await work(); fatalError("期待したエラーなし: \(name)") }
        catch let error as MetadataFailure { check(error.category == category, "\(name): \(error)") }
        catch { fatalError("想定外エラー: \(error)") }
    }
    static func number(_ value: UInt64, _ width: Int, little: Bool = false) -> Data {
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Data(little ? bytes : bytes.reversed())
    }
    static func patch(_ data: inout Data, _ pos: Int, _ value: UInt64, _ width: Int, little: Bool = false) {
        data.replaceSubrange(pos..<(pos + width), with: number(value, width, little: little))
    }
    static func tiff(little: Bool = true, prefix: Int = 0, subsecond: String = "007") -> Data {
        func n(_ v: UInt64, _ w: Int) -> Data { number(v, w, little: little) }
        func entry(_ tag: UInt64, _ type: UInt64, _ count: UInt64, _ value: Data) -> Data {
            n(tag, 2) + n(type, 2) + n(count, 4) + value
        }
        let date = Data("2024:06:07 08:09:10\0".utf8)
        let offset = Data("+09:00\0".utf8)
        let sub = Data((subsecond + "\0").utf8)
        var raw = Data((little ? "II" : "MM").utf8) + n(42, 2) + n(8, 4)
        raw += n(1, 2) + entry(0x8769, 4, 1, n(26, 4)) + n(0, 4)
        raw += n(3, 2)
        raw += entry(0x9003, 2, 20, n(68, 4))
        raw += entry(0x9011, 2, 7, n(88, 4))
        raw += entry(0x9291, 2, UInt64(sub.count), sub.count <= 4 ? sub + Data(repeating: 0, count: 4 - sub.count) : n(95, 4))
        raw += n(0, 4) + date + offset
        if sub.count > 4 { raw += sub }
        return number(UInt64(prefix), 4) + Data(repeating: 0x58, count: prefix) + raw
    }
    static func box(_ type: String, _ payload: Data, extended: Bool = false, zero: Bool = false) -> Data {
        if extended { return number(1, 4) + Data(type.utf8) + number(UInt64(payload.count + 16), 8) + payload }
        return number(zero ? 0 : UInt64(payload.count + 8), 4) + Data(type.utf8) + payload
    }
    static func full(_ version: UInt64 = 0) -> Data { number(version, 1) + number(0, 3) }
    struct Fixture {
        var data: Data
        var first: UInt64
        var second: UInt64
        var mdat: Range<UInt64>
    }
    static func heif(method: UInt64 = 0, width: Int = 4, extended: Bool = false, zeroMdat: Bool = false,
                     modernIDs: Bool = false, protection: UInt64 = 0, reference: UInt64 = 0,
                     baseShift: UInt64 = 0, extentOffset: UInt64 = 100, primaryReference: UInt64? = nil, leadingBytes: Int = 0, metaPadding: Int = 0) -> Fixture {
        let primary: UInt64 = modernIDs ? 70001 : 1
        let exif: UInt64 = modernIDs ? 70002 : 2
        let decoy: UInt64 = modernIDs ? 70003 : 3
        let idWidth = modernIDs ? 4 : 2
        let item = tiff(prefix: 6)
        let cut = item.count / 2
        var storage = Data(repeating: 0xCD, count: 300)
        storage.replaceSubrange((100 + Int(baseShift))..<(100 + Int(baseShift) + cut), with: item.prefix(cut))
        storage.replaceSubrange(Int(baseShift)..<(Int(baseShift) + item.count - cut), with: item.dropFirst(cut))
        let leading = leadingBytes == 0 ? Data() : box("free", Data(repeating: 0, count: leadingBytes))
        let ftyp = box("ftyp", Data("heic".utf8) + number(0, 4) + Data("mif1".utf8))
        func infe(_ id: UInt64, _ type: String) -> Data {
            box("infe", full(modernIDs ? 3 : 2) + number(id, idWidth) + number(id == exif ? protection : 0, 2) + Data(type.utf8) + Data([0]))
        }
        let iinf = box("iinf", full() + number(3, 2) + infe(decoy, "Exif") + infe(primary, "grid") + infe(exif, "Exif"))
        let pitm = box("pitm", full(modernIDs ? 1 : 0) + number(primary, idWidth))
        let cdsc = box("cdsc", number(exif, idWidth) + number(1, 2) + number(primaryReference ?? primary, idWidth))
        let iref = box("iref", full(modernIDs ? 1 : 0) + cdsc)
        func meta(_ base: UInt64) -> Data {
            var location = full(modernIDs ? 2 : 1)
            location += Data([UInt8(width * 16 + width), UInt8(width * 16)])
            location += number(1, modernIDs ? 4 : 2) + number(exif, idWidth)
            location += number(method, 2) + number(reference, 2) + number(base, width) + number(2, 2)
            location += number(extentOffset, width) + number(UInt64(cut), width)
            location += number(0, width) + number(UInt64(item.count - cut), width)
            return box("meta", full() + pitm + iinf + iref + (metaPadding == 0 ? Data() : box("free", Data(repeating: 0, count: metaPadding))) + box("iloc", location) + (method == 1 ? box("idat", storage) : Data()), extended: extended)
        }
        let placeholder = meta(0)
        let mdatHeader = extended ? 16 : 8
        let mdatStart = leading.count + ftyp.count + placeholder.count + mdatHeader
        let actualMeta = meta(method == 1 ? baseShift : UInt64(mdatStart) + baseShift)
        let file = leading + ftyp + actualMeta + box("mdat", method == 1 ? Data(repeating: 0xCC, count: 400) : storage, extended: extended, zero: zeroMdat)
        let storeStart = method == 1 ? leading.count + ftyp.count + actualMeta.count - storage.count : mdatStart
        return Fixture(data: file, first: UInt64(storeStart + 100) + baseShift, second: UInt64(storeStart) + baseShift, mdat: UInt64(mdatStart)..<UInt64(file.count))
    }
    static func main() async throws {
        for little in [true, false] {
            for prefix in [0, 6, 19] {
                for sub in ["7", "007", "001234"] {
                    let result = try LimitedExifParser.parse(item: tiff(little: little, prefix: prefix, subsecond: sub))
                    check(result.original == "2024:06:07 08:09:10" && result.offset == "+09:00" && result.subsecond == sub, "II/MM、非ゼロprefix、inline/offset")
                }
            }
        }
        let baseline = tiff()
        var d = baseline
        patch(&d, 4 + 28, 0x7777, 2, little: true)
        reject("タグ欠落", "DateTimeOriginal欠落") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 40, 0x7777, 2, little: true)
        check(try LimitedExifParser.parse(item: d).offset == nil, "未知タグを無視")
        d = baseline; patch(&d, 4 + 40, 0x9003, 2, little: true)
        reject("破損", "重複対象タグ") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 36, UInt64(UInt32.max), 4, little: true)
        reject("破損", "範囲外値offset") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 32, UInt64(UInt32.max), 4, little: true)
        reject("制限超過", "巨大count") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 18, 4, 4, little: true)
        reject("破損", "不正ExifIFD") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 26, 65535, 2, little: true)
        reject("制限超過", "巨大IFD entry数") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 0, UInt64(UInt32.max), 4)
        reject("破損", "TIFF開始範囲外") { _ = try LimitedExifParser.parse(item: d) }
        d = baseline; patch(&d, 4 + 32, 19, 4, little: true)
        reject("破損", "日時count不正") { _ = try LimitedExifParser.parse(item: d) }
        for count in 0..<baseline.count {
            do { _ = try LimitedExifParser.parse(item: Data(baseline.prefix(count))) }
            catch is MetadataFailure { checks += 1 }
        }
        reject("破損", "UInt64 overflow") { _ = try LimitedHEIFParser.add(UInt64.max, 1) }
        for method: UInt64 in [0, 1] {
            for width in [4, 8] {
                for extended in [false, true] {
                    let f = heif(method: method, width: width, extended: extended, modernIDs: true, baseShift: 7)
                    let source = MemoryMetadataSource(f.data)
                    let plan = try await LimitedHEIFParser.locate(source)
                    check(plan.itemID == 70002 && plan.method == method && plan.extents.count == 2, "Exif選択とmodern ID")
                    check(plan.extents[0].offset == f.first && plan.extents[1].offset == f.second, "extentは物理順に並べない")
                    check(source.requests.allSatisfy { !f.mdat.contains($0.0) }, "管理情報読み取りでmdat payloadを転送しない")
                    let item = try await plan.readExif(from: source)
                    check(try LimitedExifParser.parse(item: item).subsecond == "007", "HEIF→TIFF統合")
                }
            }
        }
        _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(heif(zeroMdat: true).data))
        checks += 1
        for (name, fixture, category) in [
            ("method2", heif(method: 2), "非対応"),
            ("external reference", heif(reference: 1), "非対応"),
            ("protected item", heif(protection: 1), "非対応"),
            ("extent outside", heif(extentOffset: UInt64(UInt32.max)), "破損"),
            ("offset overflow", heif(width: 8, extentOffset: UInt64.max), "破損"),
            ("cdsc mismatch", heif(primaryReference: 99), "タグ欠落")
        ] {
            await rejectAsync(category, name) { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(fixture.data)) }
        }
        for size: UInt64 in [2, 7, UInt64(UInt32.max)] {
            var file = heif().data; patch(&file, 0, size, 4)
            await rejectAsync("破損", "box size不正") { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(file)) }
        }
        var extended = number(1, 4) + Data("meta".utf8) + number(UInt64.max, 8)
        await rejectAsync("破損", "extended size範囲外") { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(extended)) }
        extended = Data(extended.prefix(12))
        await rejectAsync("破損", "extended size途中切断") { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(extended)) }
        let valid = heif().data
        for count in 0..<valid.count {
            do { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(Data(valid.prefix(count)))) }
            catch is MetadataFailure { checks += 1 }
        }
        // metaの位置・サイズ・header幅が変わっても、一括取得はbox sizeで決まる。
        for method: UInt64 in [0, 1] {
            for padding in [0, 173, 8193] {
                for extended in [false, true] {
                    let f = heif(method: method, extended: extended, leadingBytes: 137, metaPadding: padding)
                    let source = MemoryMetadataSource(f.data)
                    let plan = try await LimitedHEIFParser.locate(source)
                    let beforeExif = source.requests.count
                    let item = try await plan.readExif(from: source)
                    check(try LimitedExifParser.parse(item: item).original == "2024:06:07 08:09:10", "可変位置・サイズのmeta")
                    let metaStart = 145 + 20
                    let metaHeader = extended ? 16 : 8
                    let metaSize = try MetadataBytes(f.data).uint(at: metaStart + (extended ? 8 : 0), width: extended ? 8 : 4)
                    let payloadStart = UInt64(metaStart + metaHeader)
                    let payloadEnd = UInt64(metaStart) + metaSize
                    let inside = source.requests.filter { $0.0 >= payloadStart && $0.0 < payloadEnd }
                    check(inside.count == 1 && inside[0].0 == payloadStart && inside[0].1 == Int(metaSize) - metaHeader, "meta payloadは一括取得のみ")
                    check(source.requests.count - beforeExif == (method == 1 ? 0 : 2), "method1再利用／method0記載順の複数extent")
                    let mdatReads = source.requests.filter { $0.0 < f.mdat.upperBound && $0.0 + UInt64($0.1) > f.mdat.lowerBound }
                    check(mdatReads.count == (method == 1 ? 0 : 2), "mdat payloadは必要なExif extentのみ")
                    check(mdatReads.allSatisfy { $0.0 == f.first || $0.0 == f.second }, "余分なmdat範囲を読まない")
                }
            }
        }
        // metaがmdatの後ろにあるmethod1も、top-level sizeに従って探索する。
        let original = heif(method: 1).data
        let metaLength = Int(try MetadataBytes(original).uint(at: 20, width: 4))
        let reordered = Data(original.prefix(20)) + Data(original.dropFirst(20 + metaLength)) + Data(original[20..<(20 + metaLength)])
        for zeroMeta in [false, true] {
            var file = reordered
            if zeroMeta { patch(&file, file.count - metaLength, 0, 4) }
            let source = MemoryMetadataSource(file)
            let plan = try await LimitedHEIFParser.locate(source)
            let count = source.requests.count
            let item = try await plan.readExif(from: source)
            check(try LimitedExifParser.parse(item: item).offset == "+09:00", "末尾meta／size0")
            check(source.requests.count == count, "末尾idat再利用")
        }
        for size: UInt64 in [7, UInt64(UInt32.max)] {
            var file = heif().data
            patch(&file, 20, size, 4)
            await rejectAsync("破損", "不正meta size") { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(file)) }
        }
        var badChild = heif().data
        patch(&badChild, 20 + 8 + 4, UInt64(UInt32.max), 4)
        await rejectAsync("破損", "meta子box範囲外") { _ = try await LimitedHEIFParser.locate(MemoryMetadataSource(badChild)) }
        let oversized = Data(heif().data.prefix(20)) + box("meta", Data(repeating: 0, count: 1024 * 1024 + 1)) + box("mdat", Data(repeating: 0, count: 100))
        let oversizedSource = MemoryMetadataSource(oversized)
        await rejectAsync("制限超過", "meta管理box上限") { _ = try await LimitedHEIFParser.locate(oversizedSource) }
        check(oversizedSource.requests.allSatisfy { $0.1 <= 12 }, "巨大meta payloadを読み込む前に拒否")
        print("PASS: \(checks) checks (TIFF, HEIF, truncation, bounds, selection, extent order, transfer ranges)")
    }
}
