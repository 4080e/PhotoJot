import Foundation

nonisolated enum RangePlaybackPolicy {
    static let requestLimit = 32_768
    static let callLimit = 262_144
    static func byteLimit(size: UInt64) throws -> UInt64 {
        guard size > 0, size <= UInt64(Int64.max) else { throw RangeThumbnailError.invalid("再生サイズ不正") }
        let (fourPasses, overflow) = size.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw RangeThumbnailError.invalid("再生安全上限overflow") }
        return max(1_073_741_824, fourPasses)
    }
}
