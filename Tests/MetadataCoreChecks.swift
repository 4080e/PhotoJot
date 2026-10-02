import Foundation
import ImageIO
import CoreGraphics

nonisolated final class MetadataTestSource: MetadataRangeSource {
    let data: Data
    var size: UInt64 { UInt64(data.count) }
    var requests: [(UInt64, Int)] = []
    var cancelRead = false
    var fail = false
    var parserLimit = false
    init(_ data: Data) { self.data = data }
    func read(offset: UInt64, length: Int, kind: MetadataReadKind, purpose: String) async throws -> Data {
        if cancelRead { throw CancellationError() }
        if parserLimit { throw MetadataFailure.limit("fixture limit") }
        if fail { throw MetadataFailure.smb("fixture failure") }
        requests.append((offset, length))
        return data.subdata(in: Int(offset)..<(Int(offset) + length))
    }
}

@main struct MetadataCoreChecks {
    static func main() async throws {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        func jpeg(withExif: Bool) -> Data {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            let properties: [CFString: Any] = withExif ? [kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:01 23:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "-08:00",
                kCGImagePropertyExifSubsecTimeOriginal: "123"
            ]] : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let source = MetadataTestSource(jpeg(withExif: true))
        let result = try await MetadataCore.parse(format: .jpeg, source: source, creation: nil, modified: nil)
        precondition(result.resolution.source == .jpegExifDateTimeOriginal)
        precondition(result.resolution.originalValue == "2024:01:01 23:30:00")
        precondition(result.resolution.utcOffset == "-08:00" && result.resolution.subsecond == "123")
        precondition(result.state == "complete")

        // Exifより前のAPP2を追加し、32 KiBへの段階読みを必要にする。
        let raw = jpeg(withExif: true)
        let padded = raw.prefix(2) + Data([0xFF, 0xE2, 0x50, 0x02]) + Data(repeating: 0, count: 0x5000) + raw.dropFirst(2)
        let staged = MetadataTestSource(padded)
        let stagedResult = try await MetadataCore.parse(format: .jpeg, source: staged, creation: nil, modified: nil)
        precondition(stagedResult.resolution.source == .jpegExifDateTimeOriginal)
        precondition(staged.requests.count >= 2 && staged.requests[0].1 == 16 * 1024)
        precondition(staged.requests[1].0 == 16 * 1024)

        var late = Data(raw.prefix(2))
        for _ in 0..<3 { late.append(Data([0xFF, 0xE2, 0xEA, 0x62]) + Data(repeating: 0, count: 60000)) }
        late.append(raw.dropFirst(2))
        let limitedPrefix = MetadataTestSource(late)
        let unconfirmed = try await MetadataCore.parse(format: .jpeg, source: limitedPrefix, creation: Date(), modified: nil)
        precondition(unconfirmed.state == "unconfirmed")
        precondition(limitedPrefix.requests.map { $0.1 } == [16384, 16384, 32768, 65536])
        precondition(limitedPrefix.requests.reduce(0) { $0 + $1.1 } == 128 * 1024)
        for format in [MediaDateFormat.heic, .mov, .mp4] {
            let failedSource = MetadataTestSource(late); failedSource.fail = true
            let failed = try await MetadataCore.parse(format: format, source: failedSource, creation: Date(), modified: nil)
            precondition(failed.requiresRetry)
            let limitedSource = MetadataTestSource(late); limitedSource.parserLimit = true
            let limited = try await MetadataCore.parse(format: format, source: limitedSource, creation: Date(), modified: nil)
            precondition(limited.state == "limit" && !limited.requiresRetry)
        }

        let missing = try await MetadataCore.parse(format: .jpeg, source: MetadataTestSource(jpeg(withExif: false)),
                                                  creation: Date(timeIntervalSince1970: 1000), modified: nil)
        precondition(missing.state == "missing" && missing.resolution.source == .smbCreationTime)
        let unknown = try await MetadataCore.parse(format: .jpeg, source: MetadataTestSource(jpeg(withExif: false)), creation: nil, modified: nil)
        precondition(unknown.resolution.displayDate == nil)
        let network = MetadataTestSource(raw); network.fail = true
        let retry = try await MetadataCore.parse(format: .jpeg, source: network, creation: Date(), modified: nil)
        precondition(retry.requiresRetry && retry.state != "missing")
        for kind in [DateDiagnosticKind.missing, .unsupported, .limit, .corrupt, .unconfirmed] {
            let outcome = MetadataCore.outcome(format: .heic, evidence: .init(diagnostics: [.init(kind: kind, message: "fixture")]), creation: nil, modified: nil)
            precondition(!outcome.requiresRetry)
        }
        for kind in [DateDiagnosticKind.smb, .cleanup, .temporary] {
            precondition(MetadataCore.outcome(format: .heic, evidence: .init(diagnostics: [.init(kind: kind, message: "fixture")]), creation: nil, modified: nil).requiresRetry)
        }
        // Task自体が未キャンセルでも、sourceのCancellationErrorをretryへ変換しない。
        for format in [MediaDateFormat.jpeg, .heic, .mov, .mp4] {
            let cancelledSource = MetadataTestSource(late); cancelledSource.cancelRead = true
            do {
                _ = try await MetadataCore.parse(format: format, source: cancelledSource, creation: nil, modified: nil)
                fatalError("CancellationError converted to metadata outcome")
            } catch is CancellationError { }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await MetadataCore.parse(format: .jpeg, source: source, creation: nil, modified: nil)
                fatalError("cancel ignored")
            } catch is CancellationError { }
        }
        try await cancelled.value
        print("Metadata core checks passed (ImageIO JPEG, staged prefix, fallback, unknown, retry, cancellation)")
    }
}
