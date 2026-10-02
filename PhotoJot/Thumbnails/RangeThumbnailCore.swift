import Foundation

nonisolated enum RangeThumbnailError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let text): return text } }
}
nonisolated struct RangeThumbnailCursor: Sendable {
    var position: UInt64
    let end: UInt64
    var cancelled = false
    init(size: UInt64, requested: Int64, current: Int64, length: Int, allToEnd: Bool) throws {
        guard size <= UInt64(Int64.max), requested >= 0, current >= 0, length >= 0 else {
            throw RangeThumbnailError.invalid("負値／サイズ不正")
        }
        let start = UInt64(requested)
        // currentOffsetは次に供給すべき位置。未供給時の0はrequestedOffsetを使用する。
        let next = current == 0 ? start : UInt64(current)
        guard start <= size, next >= start, next <= size else { throw RangeThumbnailError.invalid("EOF範囲外／currentOffset不正") }
        if allToEnd { end = size }
        else {
            let (sum, overflow) = requested.addingReportingOverflow(Int64(length))
            guard !overflow else { throw RangeThumbnailError.invalid("offset + length overflow") }
            end = min(size, UInt64(sum))
        }
        guard next <= end else { throw RangeThumbnailError.invalid("currentOffsetが要求終端を超過") }
        position = next
    }
    func next() -> (UInt64, Int)? {
        guard !cancelled, position < end else { return nil }
        return (position, Int(min(1_048_576, end - position)))
    }
    mutating func accept(_ count: Int) throws -> Bool {
        guard !cancelled else { return false }
        guard count > 0, UInt64(count) <= end - position else { throw RangeThumbnailError.invalid("返却bytes不正") }
        position += UInt64(count)
        return true
    }
}
nonisolated struct RangeThumbnailLedger: Sendable {
    let limit: UInt64
    let callLimit: Int
    var bytes: UInt64 = 0
    var calls = 0
    var wait = 0.0
    var intervals: [Range<UInt64>] = []
    init(limit: UInt64 = 256 * 1_048_576, callLimit: Int = 65_536) { self.limit = limit; self.callLimit = callLimit }
    mutating func begin(_ count: Int) throws {
        guard count > 0, count <= 1_048_576, bytes < limit, UInt64(count) <= limit - bytes else {
            throw RangeThumbnailError.invalid("取得上限超過（\(limit) bytes）")
        }
        guard calls < callLimit else { throw RangeThumbnailError.invalid("read回数制限超過") }
        calls += 1
    }
    mutating func record(offset: UInt64, count: Int) throws {
        guard count >= 0, UInt64(count) <= limit - bytes, offset <= UInt64.max - UInt64(count) else {
            throw RangeThumbnailError.invalid("取得集計範囲外")
        }
        bytes += UInt64(count)
        guard count > 0 else { return }
        var low = offset, high = offset + UInt64(count)
        var merged: [Range<UInt64>] = []
        for range in intervals {
            if range.upperBound < low { merged.append(range) }
            else if high < range.lowerBound { merged.append(low..<high); low = range.lowerBound; high = range.upperBound }
            else { low = min(low, range.lowerBound); high = max(high, range.upperBound) }
        }
        merged.append(low..<high); intervals = merged
    }
    var isLimitReached: Bool { bytes >= limit }
    var uniqueBytes: UInt64 { intervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    var duplicateBytes: UInt64 { bytes - uniqueBytes }
}
nonisolated struct RangeThumbnailRequestLog: Sendable, Identifiable {
    let id: Int
    let requested: Int64
    let current: Int64
    let length: Int
    let allToEnd: Bool
    var bytes: UInt64 = 0
    var status = "待機"
}
nonisolated struct RangeTransferRecord: Sendable {
    let offset: UInt64
    let bytes: Int
}
nonisolated struct RangeThumbnailSnapshot: Sendable {
    var capturedAt = ProcessInfo.processInfo.systemUptime
    var transfers: [RangeTransferRecord] = []
    var ledger = RangeThumbnailLedger()
    var loading = 0, content = 0, data = 0, cancellations = 0, cancelCallbacks = 0, allToEnd = 0
    var logs: [RangeThumbnailRequestLog] = []
    var error: String?
}
