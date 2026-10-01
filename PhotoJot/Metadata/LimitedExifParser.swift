// PhotoJotPoCで検証済みのcoreを本体用に移植。
import Foundation

nonisolated enum MetadataFailure: Error, CustomStringConvertible, Sendable {
    case missing(String), corrupt(String), unsupported(String), limit(String), smb(String)
    var category: String {
        switch self {
        case .missing: "タグ欠落"
        case .corrupt: "破損"
        case .unsupported: "非対応"
        case .limit: "制限超過"
        case .smb: "SMB読み込み失敗"
        }
    }
    var description: String {
        switch self {
        case .missing(let text), .corrupt(let text), .unsupported(let text), .limit(let text), .smb(let text): "\(category): \(text)"
        }
    }
}

// すべて相対位置。未整列load・未検証の添字・整数の切り詰めを使わない。
nonisolated struct MetadataBytes {
    let data: Data
    var position = 0
    var littleEndian = false
    init(_ data: Data, littleEndian: Bool = false) {
        self.data = data
        self.littleEndian = littleEndian
    }
    var remaining: Int { data.count - position }
    func range(_ offset: Int, _ length: Int) throws -> Range<Data.Index> {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw MetadataFailure.corrupt("Data範囲外 offset=\(offset) length=\(length)")
        }
        return (data.startIndex + offset)..<(data.startIndex + offset + length)
    }
    func uint(at offset: Int, width: Int) throws -> UInt64 {
        guard (0...8).contains(width) else { throw MetadataFailure.unsupported("整数幅 \(width)") }
        let bytes = data[try range(offset, width)]
        var value: UInt64 = 0
        if littleEndian {
            for byte in bytes.reversed() { value = (value << 8) | UInt64(byte) }
        } else {
            for byte in bytes { value = (value << 8) | UInt64(byte) }
        }
        return value
    }
    mutating func uint(_ width: Int) throws -> UInt64 {
        let value = try uint(at: position, width: width)
        position += width
        return value
    }
    mutating func fourCC() throws -> String {
        let bytes = data[try range(position, 4)]
        position += 4
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func fullBox(_ allowed: [UInt64], allowedFlags: UInt64 = 0) throws -> UInt64 {
        let version = try uint(1)
        let flags = try uint(3)
        guard allowed.contains(version), flags & ~allowedFlags == 0 else {
            throw MetadataFailure.unsupported("FullBox version=\(version) flags=\(flags)")
        }
        return version
    }
    func end() throws {
        guard remaining == 0 else { throw MetadataFailure.unsupported("未解釈の末尾データ \(remaining) bytes") }
    }
}

nonisolated struct ExifDateFields: Sendable {
    let original: String
    let offset: String?
    let subsecond: String?
}

nonisolated enum LimitedExifParser {
    private struct Entry {
        let type: UInt64
        let count: UInt64
        let valuePosition: Int
    }
    static func parse(item: Data) throws -> ExifDateFields {
        guard item.count <= 2 * 1024 * 1024 else { throw MetadataFailure.limit("Exif itemが2 MiB上限超過") }
        let container = MetadataBytes(item)
        let n = try container.uint(at: 0, width: 4) // HEIF prefixは常にBE
        guard n <= UInt64(max(0, item.count - 4)), item.count >= 4 else {
            throw MetadataFailure.corrupt("TIFF開始offsetがitem範囲外")
        }
        let start = 4 + Int(n)
        let tiff = Data(item[try container.range(start, item.count - start)])
        var bytes = MetadataBytes(tiff)
        let order = try bytes.uint(at: 0, width: 2)
        guard order == 0x4949 || order == 0x4D4D else { throw MetadataFailure.corrupt("TIFF byte order不正") }
        bytes.littleEndian = order == 0x4949
        let magic = try bytes.uint(at: 2, width: 2)
        guard magic == 42 else { throw MetadataFailure.unsupported("Classic TIFF以外 magic=\(magic)") }
        let first = try bytes.uint(at: 4, width: 4)
        guard first != 0 else { throw MetadataFailure.missing("IFD0なし") }
        let ifd0 = try entries(bytes, offset: first, wanted: [0x8769])
        guard let pointer = ifd0[0x8769] else { throw MetadataFailure.missing("ExifIFDPointerなし") }
        guard pointer.type == 4, pointer.count == 1 else { throw MetadataFailure.corrupt("ExifIFDPointerはLONG/count=1が必要") }
        let exifOffset = try bytes.uint(at: pointer.valuePosition, width: 4)
        guard exifOffset != first else { throw MetadataFailure.corrupt("IFDの自己参照") }
        guard exifOffset != 0 else { throw MetadataFailure.missing("Exif IFDなし") }
        let tags = try entries(bytes, offset: exifOffset, wanted: [0x9003, 0x9011, 0x9291])
        guard let original = try ascii(tags[0x9003], bytes: bytes, expectedCount: 20),
              !original.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MetadataFailure.missing("DateTimeOriginalなし／空白")
        }
        return ExifDateFields(original: original,
                              offset: try ascii(tags[0x9011], bytes: bytes, expectedCount: 7),
                              subsecond: try ascii(tags[0x9291], bytes: bytes, expectedCount: nil))
    }
    private static func entries(_ bytes: MetadataBytes, offset: UInt64, wanted: Set<UInt64>) throws -> [UInt64: Entry] {
        guard offset >= 8, offset <= UInt64(bytes.data.count) else { throw MetadataFailure.corrupt("IFD offset範囲外") }
        let pos = Int(offset)
        let count = try bytes.uint(at: pos, width: 2)
        guard count <= 4096 else { throw MetadataFailure.limit("IFD entry数上限4096超過") }
        // countに上限を適用後に乗算。次IFD pointerも構造として検証するが追跡しない。
        _ = try bytes.range(pos, 2 + Int(count) * 12 + 4)
        var found: [UInt64: Entry] = [:]
        for index in 0..<Int(count) {
            let p = pos + 2 + index * 12
            let tag = try bytes.uint(at: p, width: 2)
            guard wanted.contains(tag) else { continue }
            guard found[tag] == nil else { throw MetadataFailure.corrupt("対象タグ重複 0x\(String(tag, radix: 16))") }
            found[tag] = Entry(type: try bytes.uint(at: p + 2, width: 2),
                               count: try bytes.uint(at: p + 4, width: 4), valuePosition: p + 8)
        }
        return found
    }
    private static func ascii(_ entry: Entry?, bytes: MetadataBytes, expectedCount: UInt64?) throws -> String? {
        guard let entry else { return nil }
        guard entry.type == 2, entry.count > 0 else { throw MetadataFailure.corrupt("日時タグは非空ASCIIが必要") }
        guard entry.count <= 256 else { throw MetadataFailure.limit("日時文字列count上限256超過") }
        if let expectedCount, entry.count != expectedCount { throw MetadataFailure.corrupt("日時タグcount不正") }
        // 対象はASCII（要素サイズ1）だけ。未知typeのcountを乗算・参照しない。
        let offset = entry.count <= 4 ? UInt64(entry.valuePosition) : try bytes.uint(at: entry.valuePosition, width: 4)
        guard offset <= UInt64(bytes.data.count) else { throw MetadataFailure.corrupt("ASCII offset範囲外") }
        let value = bytes.data[try bytes.range(Int(offset), Int(entry.count))]
        guard value.last == 0, value.dropLast().allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            throw MetadataFailure.corrupt("ASCIIの終端NUL／文字コード不正")
        }
        return String(decoding: value.dropLast(), as: UTF8.self)
    }
}
