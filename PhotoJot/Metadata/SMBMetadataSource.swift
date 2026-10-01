import Foundation
import SMBClient

// PoCのrange read上限・全体取得抑止を維持し、計測ログだけを除いたアダプタ。
nonisolated final class SMBMetadataSource: MetadataRangeSource {
    let reader: FileReader
    let size: UInt64
    private let isJPEG: Bool
    private var managementBytes = 0
    private var exifBytes = 0
    private var reads = 0
    private var received: [Range<UInt64>] = []

    init(reader: FileReader, size: UInt64, isJPEG: Bool) {
        self.reader = reader; self.size = size; self.isJPEG = isJPEG
    }

    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String) async throws -> Data {
        try Task.checkCancellation()
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else { throw MetadataFailure.corrupt("要求範囲外") }
        let used = kind == .management ? managementBytes : exifBytes
        guard length <= 2 * 1024 * 1024 - used else { throw MetadataFailure.limit("管理情報／Exifの各2 MiB上限") }
        if isJPEG && (offset > 128 * 1024 || UInt64(length) > 128 * 1024 - offset) {
            throw MetadataFailure.limit("JPEG prefix 128 KiB上限")
        }
        if length == 0 { return Data() }
        var ranges: [Range<UInt64>] = []
        for range in (received + [offset..<(offset + UInt64(length))]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        if !isJPEG && ranges.count == 1 && ranges[0].lowerBound == 0 && ranges[0].upperBound == size {
            throw MetadataFailure.limit("全ファイル範囲取得を拒否")
        }
        var data = Data()
        while data.count < length {
            try Task.checkCancellation()
            reads += 1
            guard reads <= 4096 else { throw MetadataFailure.limit("read回数4096上限") }
            let count = min(64 * 1024, length - data.count)
            let chunk: Data
            do { chunk = try await reader.read(offset: offset + UInt64(data.count), length: UInt32(count)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw MetadataFailure.smb("SMB range read失敗") }
            guard !chunk.isEmpty, chunk.count <= count else { throw MetadataFailure.smb("短いEOF／応答長不正") }
            if kind == .management { managementBytes += chunk.count } else { exifBytes += chunk.count }
            data.append(chunk)
        }
        received = ranges
        return data
    }
}
