import Foundation

nonisolated enum ThumbnailError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}

nonisolated struct JPEGThumbnailPlan: Sendable {
    let offset: UInt64
    let length: Int
    let orientation: Int
}

// JPEG markerとExif IFD0/IFD1だけ。日時parser、MakerNote等は変更しない。
nonisolated enum JPEGThumbnailLocator {
    static func locate(size: UInt64, read: (UInt64, Int) async throws -> Data) async throws -> JPEGThumbnailPlan? {
        func fetch(_ offset: UInt64, _ count: Int) async throws -> [UInt8] {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ThumbnailError.invalid("JPEG範囲外") }
            let data = try await read(offset, count)
            guard data.count == count else { throw ThumbnailError.invalid("JPEG short read") }
            return Array(data)
        }
        guard try await fetch(0, 2) == [0xff, 0xd8] else { throw ThumbnailError.invalid("JPEG SOIなし") }
        var offset: UInt64 = 2
        for _ in 0..<512 {
            let marker = try await fetch(offset, 2)
            guard marker[0] == 0xff else { throw ThumbnailError.invalid("JPEG marker不正") }
            if marker[1] == 0xff { offset += 1; continue }
            if marker[1] == 0xda || marker[1] == 0xd9 { return nil }
            guard marker[1] != 0, marker[1] != 0xd8 else { throw ThumbnailError.invalid("JPEG marker不正") }
            if marker[1] == 0x01 || (0xd0...0xd7).contains(marker[1]) { offset += 2; continue }
            let lengthBytes = try await fetch(offset + 2, 2)
            let length = Int(lengthBytes[0]) * 256 + Int(lengthBytes[1])
            guard length >= 2, UInt64(length) <= size - offset - 2 else { throw ThumbnailError.invalid("JPEG segment長不正") }
            if marker[1] == 0xe1, length >= 8,
               try await fetch(offset + 4, 6) == [69, 120, 105, 102, 0, 0] {
                return try await tiff(base: offset + 10, length: length - 8, read: read)
            }
            offset += UInt64(length) + 2
        }
        throw ThumbnailError.invalid("JPEG marker探索上限512")
    }
    private static func tiff(base: UInt64, length: Int, read: (UInt64, Int) async throws -> Data) async throws -> JPEGThumbnailPlan? {
        func fetch(_ offset: Int, _ count: Int) async throws -> [UInt8] {
            guard offset >= 0, count >= 0, offset <= length, count <= length - offset,
                  UInt64(offset) <= UInt64.max - base else { throw ThumbnailError.invalid("Exif範囲外") }
            let data = try await read(base + UInt64(offset), count)
            guard data.count == count else { throw ThumbnailError.invalid("Exif short read") }
            return Array(data)
        }
        let header = try await fetch(0, 8)
        let little: Bool
        if header[0...1] == [73, 73] { little = true }
        else if header[0...1] == [77, 77] { little = false }
        else { throw ThumbnailError.invalid("TIFF byte order不正") }
        func number(_ bytes: [UInt8], _ position: Int, _ count: Int) -> UInt32 {
            // 呼出元で固定長header/tableを検証済み。未整列loadを使わない。
            var value: UInt32 = 0
            for i in 0..<count { value = (value << 8) | UInt32(bytes[position + (little ? count - 1 - i : i)]) }
            return value
        }
        guard number(header, 2, 2) == 42 else { throw ThumbnailError.invalid("TIFF magic不正") }
        func ifd(_ offset: Int) async throws -> (entries: [UInt8], next: Int, end: Int) {
            guard offset >= 8 else { throw ThumbnailError.invalid("IFD offset不正") }
            let countData = try await fetch(offset, 2)
            let count = Int(number(countData, 0, 2))
            guard count <= 256 else { throw ThumbnailError.invalid("IFD entry上限256") }
            let table = try await fetch(offset + 2, count * 12 + 4)
            return (Array(table.prefix(count * 12)), Int(number(table, count * 12, 4)), offset + 2 + count * 12 + 4)
        }
        func scalar(_ entry: [UInt8], type: UInt32) throws -> Int {
            guard number(entry, 2, 2) == type, number(entry, 4, 4) == 1 else { throw ThumbnailError.invalid("thumbnail tag型/count不正") }
            return Int(number(entry, 8, type == 3 ? 2 : 4))
        }
        let firstOffset = Int(number(header, 4, 4))
        let first = try await ifd(firstOffset)
        var orientation = 1, seenOrientation = false
        for p in stride(from: 0, to: first.entries.count, by: 12) {
            let entry = Array(first.entries[p..<p + 12])
            if number(entry, 0, 2) == 0x0112 {
                guard !seenOrientation else { throw ThumbnailError.invalid("重複orientation") }
                seenOrientation = true; orientation = try scalar(entry, type: 3)
                guard (1...8).contains(orientation) else { throw ThumbnailError.invalid("orientation範囲外") }
            }
        }
        guard first.next != 0 else { return nil }
        guard first.next < firstOffset || first.next >= first.end else { throw ThumbnailError.invalid("IFD重複/循環") }
        let second = try await ifd(first.next)
        guard second.end <= firstOffset || first.next >= first.end else { throw ThumbnailError.invalid("IFD領域重複") }
        var values: [UInt32: Int] = [:]
        for p in stride(from: 0, to: second.entries.count, by: 12) {
            let entry = Array(second.entries[p..<p + 12]), tag = number(second.entries, p, 2)
            guard [UInt32(0x0103), 0x0201, 0x0202, 0x0112].contains(tag) else { continue }
            guard values[tag] == nil else { throw ThumbnailError.invalid("重複thumbnail tag") }
            values[tag] = try scalar(entry, type: (tag == 0x0103 || tag == 0x0112) ? 3 : 4)
        }
        guard values[0x0103] == 6, let position = values[0x0201], let count = values[0x0202] else { return nil }
        if let thumbOrientation = values[0x0112] { orientation = thumbOrientation }
        guard (1...8).contains(orientation), position >= 8, count > 0, position <= length, count <= length - position else {
            throw ThumbnailError.invalid("thumbnail extent/orientation範囲外")
        }
        for (a, b) in [(firstOffset, first.end), (first.next, second.end)] {
            guard position + count <= a || position >= b else { throw ThumbnailError.invalid("thumbnailとIFDが重複") }
        }
        return JPEGThumbnailPlan(offset: base + UInt64(position), length: count, orientation: orientation)
    }
}
