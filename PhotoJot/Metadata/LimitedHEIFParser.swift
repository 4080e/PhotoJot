// PhotoJotPoCで検証済みのcoreを本体用に移植。
import Foundation

nonisolated enum MetadataReadKind { case management, exif }
nonisolated protocol MetadataRangeSource: AnyObject {
    var size: UInt64 { get }
    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String) async throws -> Data
}
nonisolated struct ExifExtent: Sendable {
    let offset: UInt64
    let length: Int
}
nonisolated struct HEIFExifPlan: Sendable {
    let itemID: UInt64
    let method: UInt64
    let extents: [ExifExtent]
    let embeddedExif: Data?

    func readExif(from source: any MetadataRangeSource) async throws -> Data {
        if let embeddedExif { return embeddedExif }
        var item = Data()
        // iloc記載順を維持する。物理offset順には並べ替えない。
        for (index, extent) in extents.enumerated() {
            item.append(try await source.read(offset: extent.offset, length: extent.length,
                                             kind: .exif, purpose: "Exif extent \(index + 1)"))
        }
        return item
    }
}

// ファイル絶対offsetを保ったまま、取得済みmetaだけを参照する。
// SMBへフォールバックしないため、子box解析で追加通信は発生しない。
nonisolated private final class MetaMemorySource: MetadataRangeSource {
    let size: UInt64
    let base: UInt64
    let data: Data
    init(size: UInt64, base: UInt64, data: Data) {
        self.size = size
        self.base = base
        self.data = data
    }
    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String) async throws -> Data {
        guard offset >= base, length >= 0, offset - base <= UInt64(data.count),
              UInt64(length) <= UInt64(data.count) - (offset - base) else {
            throw MetadataFailure.corrupt("取得済みmeta範囲外")
        }
        let start = Int(offset - base)
        return Data(data[start..<(start + length)])
    }
}

nonisolated enum LimitedHEIFParser {
    private struct Box {
        let type: String
        let payload: UInt64
        let end: UInt64
    }
    private struct Location {
        let method: UInt64
        let reference: UInt64
        let base: UInt64
        let extents: [(index: UInt64, offset: UInt64, length: UInt64)]
    }
    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw MetadataFailure.corrupt("offset加算overflow") }
        return value
    }
    private static func header(_ source: any MetadataRangeSource, at start: UInt64, end: UInt64) async throws -> Box {
        guard start <= end, end - start >= 8 else { throw MetadataFailure.corrupt("box header不足") }
        var h = MetadataBytes(try await source.read(offset: start, length: 8, kind: .management, purpose: "box header"))
        var length = try h.uint(4)
        let type = try h.fourCC()
        var headerSize: UInt64 = 8
        if length == 1 {
            guard end - start >= 16 else { throw MetadataFailure.corrupt("extended size不足") }
            length = try MetadataBytes(await source.read(offset: start + 8, length: 8, kind: .management, purpose: "box extended header (\(type))")).uint(at: 0, width: 8)
            headerSize = 16
        } else if length == 0 {
            // size=0はファイル終端まで。親boxをはみ出す場合は解釈を広げない。
            guard end == source.size else { throw MetadataFailure.unsupported("ファイル終端と一致しない親内のsize=0") }
            length = end - start
        }
        if type == "uuid" { headerSize += 16 }
        guard length >= headerSize, length <= end - start else { throw MetadataFailure.corrupt("不正box size: \(type)") }
        return Box(type: type, payload: start + headerSize, end: start + length)
    }
    private static func children(_ source: any MetadataRangeSource, start: UInt64, end: UInt64) async throws -> [Box] {
        var boxes: [Box] = []
        var position = start
        while position < end {
            guard boxes.count < 4096 else { throw MetadataFailure.limit("box数上限4096超過") }
            let box = try await header(source, at: position, end: end)
            boxes.append(box)
            position = box.end
        }
        return boxes
    }
    private static func payload(_ source: any MetadataRangeSource, _ box: Box) async throws -> Data {
        guard box.end - box.payload <= 1024 * 1024 else { throw MetadataFailure.limit("管理boxの1 MiB上限超過: \(box.type)") }
        return try await source.read(offset: box.payload, length: Int(box.end - box.payload), kind: .management, purpose: box.type == "meta" ? "meta（一括取得）" : box.type)
    }
    private static func one(_ boxes: [Box], _ type: String) throws -> Box? {
        let matches = boxes.filter { $0.type == type }
        guard matches.count <= 1 else { throw MetadataFailure.corrupt("\(type) box重複") }
        return matches.first
    }
    static func locate(_ source: any MetadataRangeSource) async throws -> HEIFExifPlan {
        let root = try await children(source, start: 0, end: source.size)
        guard let ftyp = try one(root, "ftyp") else { throw MetadataFailure.corrupt("ftypなし") }
        var brands = MetadataBytes(try await payload(source, ftyp))
        let major = try brands.fourCC()
        _ = try brands.uint(4)
        var compatible = [major]
        while brands.remaining > 0 { compatible.append(try brands.fourCC()) }
        guard compatible.contains("heic") || compatible.contains("heix") else {
            throw MetadataFailure.unsupported("HEIC/HEIX brandなし")
        }
        guard let meta = try one(root, "meta"), meta.end - meta.payload >= 4 else { throw MetadataFailure.corrupt("meta不足") }
        let metaData = try await payload(source, meta)
        let memory = MetaMemorySource(size: source.size, base: meta.payload, data: metaData)
        var full = MetadataBytes(metaData)
        _ = try full.fullBox([0])
        let boxes = try await children(memory, start: meta.payload + 4, end: meta.end)
        guard let pitm = try one(boxes, "pitm"), let iinf = try one(boxes, "iinf"),
              let iloc = try one(boxes, "iloc") else { throw MetadataFailure.corrupt("pitm/iinf/iloc不足") }
        guard let iref = try one(boxes, "iref") else { throw MetadataFailure.missing("cdsc参照なし") }
        var primaryData = MetadataBytes(try await payload(memory, pitm))
        let primaryVersion = try primaryData.fullBox([0, 1])
        let primary = try primaryData.uint(primaryVersion == 0 ? 2 : 4)
        try primaryData.end()
        let items = try itemInfo(await payload(memory, iinf))
        guard let primaryInfo = items[primary] else { throw MetadataFailure.corrupt("主画像IDがiinfにない") }
        guard primaryInfo.protection == 0 else { throw MetadataFailure.unsupported("保護された主画像") }
        let refs = try descriptions(await payload(memory, iref))
        let ids = items.filter { $0.value.type == "Exif" && refs[$0.key, default: []].contains(primary) }.map(\.key)
        guard !ids.isEmpty else { throw MetadataFailure.missing("主画像にcdscで対応するExif itemなし") }
        guard ids.count == 1, let id = ids.first else { throw MetadataFailure.unsupported("主画像に複数のExif item") }
        guard items[id]?.protection == 0 else { throw MetadataFailure.unsupported("保護されたExif item") }
        let locations = try itemLocations(await payload(memory, iloc))
        guard let loc = locations[id] else { throw MetadataFailure.corrupt("Exif itemのilocなし") }
        guard loc.reference == 0 else { throw MetadataFailure.unsupported("外部data reference") }
        guard loc.method == 0 || loc.method == 1 else { throw MetadataFailure.unsupported("construction_method=\(loc.method)") }
        let idat = try one(boxes, "idat")
        if loc.method == 1 && idat == nil { throw MetadataFailure.corrupt("method 1なのにidatなし") }
        guard !loc.extents.isEmpty else { throw MetadataFailure.corrupt("Exif extentなし") }
        var extents: [ExifExtent] = []
        var total: UInt64 = 0
        for extent in loc.extents {
            guard extent.index == 0 else { throw MetadataFailure.unsupported("method 0/1で非ゼロextent_index") }
            guard extent.length > 0 else { throw MetadataFailure.unsupported("長さ省略／ゼロのextent") }
            total = try add(total, extent.length)
            guard total <= 2 * 1024 * 1024 else { throw MetadataFailure.limit("Exif itemの2 MiB上限超過") }
            let relative = try add(loc.base, extent.offset)
            let offset: UInt64
            if loc.method == 1, let idat {
                guard relative <= idat.end - idat.payload, extent.length <= idat.end - idat.payload - relative else {
                    throw MetadataFailure.corrupt("idat extent範囲外")
                }
                offset = try add(idat.payload, relative)
            } else {
                offset = relative
                guard offset <= source.size, extent.length <= source.size - offset else { throw MetadataFailure.corrupt("file extent範囲外") }
                // この限定実装は同一ファイルのmdat payload内のみ対応する。
                guard root.contains(where: { $0.type == "mdat" && offset >= $0.payload && offset <= $0.end && extent.length <= $0.end - offset }) else {
                    throw MetadataFailure.unsupported("mdat payload外のfile extent")
                }
            }
            extents.append(ExifExtent(offset: offset, length: Int(extent.length)))
        }
        var embeddedExif: Data?
        if loc.method == 1 {
            var item = Data()
            for extent in extents {
                item.append(try await memory.read(offset: extent.offset, length: extent.length,
                                                  kind: .exif, purpose: "idat内Exif"))
            }
            embeddedExif = item
        }
        return HEIFExifPlan(itemID: id, method: loc.method, extents: extents, embeddedExif: embeddedExif)
    }
    // iinf/irefは既に小さな管理boxとして一括取得済み。子box毎のSMB通信は不要。
    private static func localBox(_ bytes: inout MetadataBytes) throws -> (String, Data) {
        let start = bytes.position
        var size = try bytes.uint(4)
        let type = try bytes.fourCC()
        var header = 8
        if size == 1 { size = try bytes.uint(8); header = 16 }
        guard size != 0 else { throw MetadataFailure.unsupported("管理テーブル内のsize=0子box") }
        guard size >= UInt64(header), size <= UInt64(bytes.data.count - start) else { throw MetadataFailure.corrupt("管理テーブル内box size不正") }
        let data = Data(bytes.data[try bytes.range(start + header, Int(size) - header)])
        bytes.position = start + Int(size)
        return (type, data)
    }
    private static func itemInfo(_ data: Data) throws -> [UInt64: (type: String, protection: UInt64)] {
        var b = MetadataBytes(data)
        let v = try b.fullBox([0, 1])
        let count = try b.uint(v == 0 ? 2 : 4)
        guard count <= 4096 else { throw MetadataFailure.limit("item数上限4096超過") }
        var items: [UInt64: (type: String, protection: UInt64)] = [:]
        for _ in 0..<Int(count) {
            let (type, data) = try localBox(&b)
            guard type == "infe" else { throw MetadataFailure.unsupported("iinf内のinfe以外の構造") }
            var info = MetadataBytes(data)
            let version = try info.fullBox([2, 3], allowedFlags: 1) // hidden flagは位置特定に影響しない
            let id = try info.uint(version == 2 ? 2 : 4)
            let protection = try info.uint(2)
            let itemType = try info.fourCC()
            var terminated = false
            while info.remaining > 0 {
                if try info.uint(1) == 0 { terminated = true; break }
            }
            guard terminated else { throw MetadataFailure.corrupt("infe item_name未終端") }
            if itemType == "Exif" { try info.end() }
            guard items[id] == nil else { throw MetadataFailure.corrupt("item ID重複") }
            items[id] = (itemType, protection)
        }
        try b.end()
        return items
    }
    private static func descriptions(_ data: Data) throws -> [UInt64: Set<UInt64>] {
        var b = MetadataBytes(data)
        let version = try b.fullBox([0, 1])
        var refs: [UInt64: Set<UInt64>] = [:]
        var boxes = 0
        while b.remaining > 0 {
            boxes += 1
            guard boxes <= 4096 else { throw MetadataFailure.limit("iref box数上限") }
            let (type, payload) = try localBox(&b)
            guard type == "cdsc" else { continue }
            var r = MetadataBytes(payload)
            let id = try r.uint(version == 0 ? 2 : 4)
            let count = try r.uint(2)
            guard count <= 4096 else { throw MetadataFailure.limit("参照数上限") }
            guard refs[id] == nil else { throw MetadataFailure.corrupt("cdsc from ID重複") }
            var targets: Set<UInt64> = []
            for _ in 0..<Int(count) { targets.insert(try r.uint(version == 0 ? 2 : 4)) }
            try r.end()
            refs[id] = targets
        }
        return refs
    }
    private static func itemLocations(_ data: Data) throws -> [UInt64: Location] {
        var b = MetadataBytes(data)
        let version = try b.fullBox([0, 1, 2])
        let widths = try b.uint(1)
        let more = try b.uint(1)
        let offsetSize = Int(widths >> 4), lengthSize = Int(widths & 15)
        let baseSize = Int(more >> 4), indexSize = version == 0 ? 0 : Int(more & 15)
        guard [offsetSize, lengthSize, baseSize, indexSize].allSatisfy({ [0, 4, 8].contains($0) }),
              version != 0 || more & 15 == 0 else { throw MetadataFailure.unsupported("iloc field幅／予約ビット") }
        let count = try b.uint(version < 2 ? 2 : 4)
        guard count <= 4096 else { throw MetadataFailure.limit("iloc item数上限") }
        var locations: [UInt64: Location] = [:]
        var totalExtents = 0
        for _ in 0..<Int(count) {
            let id = try b.uint(version < 2 ? 2 : 4)
            let construction = version == 0 ? 0 : try b.uint(2)
            guard construction & 0xFFF0 == 0 else { throw MetadataFailure.unsupported("iloc construction予約ビット") }
            let reference = try b.uint(2)
            let base = try b.uint(baseSize)
            let extentCount = try b.uint(2)
            totalExtents += Int(extentCount)
            guard extentCount <= 128, totalExtents <= 8192 else { throw MetadataFailure.limit("extent数上限（item毎128/全体8192）") }
            var extents: [(UInt64, UInt64, UInt64)] = []
            for _ in 0..<Int(extentCount) { extents.append((try b.uint(indexSize), try b.uint(offsetSize), try b.uint(lengthSize))) }
            guard locations[id] == nil else { throw MetadataFailure.corrupt("iloc item ID重複") }
            locations[id] = Location(method: construction, reference: reference, base: base, extents: extents)
        }
        try b.end()
        return locations
    }
}
