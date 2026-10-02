import Foundation
import ImageIO

nonisolated enum MetadataPolicy {
    // parser / resolverの対応範囲や解釈を変更した場合は増やす。
    static let version = 1
    static let batchSize = 100
}

nonisolated struct MetadataOutcome: Sendable {
    let resolution: DisplayDateResolution
    let state: String
    var requiresRetry: Bool { state == "retry" }
}

nonisolated enum MetadataCore {
    static func parse(format: MediaDateFormat, source: any MetadataRangeSource,
                      creation: Date?, modified: Date?) async throws -> MetadataOutcome {
        var evidence = InternalDateEvidence()
        do {
            try Task.checkCancellation()
            switch format {
            case .jpeg:
                try await jpeg(source, evidence: &evidence)
            case .heic:
                let plan = try await LimitedHEIFParser.locate(source)
                evidence.exif = try LimitedExifParser.parse(item: await plan.readExif(from: source))
            case .mov, .mp4:
                let parser = LimitedVideoParser(VideoRangeReader(source))
                try await parser.inspect()
                try Task.checkCancellation()
                let metadata = parser.metadata
                evidence.video = metadata
                if metadata.transportFailure { evidence.diagnostics.append(.init(kind: .smb, message: "SMB読み込み失敗")) }
                if metadata.unclassifiedFailure { evidence.diagnostics.append(.init(kind: .temporary, message: "原因を判別できない解析失敗")) }
                if metadata.limited { evidence.diagnostics.append(.init(kind: .limit, message: "動画parserの取得・構造上限")) }
                if metadata.unsupported { evidence.diagnostics.append(.init(kind: .unsupported, message: "動画parser非対応の構造")) }
                // PoC同様、mvhdの未設定／範囲外だけをcontainer破損と混同しない。
                let structuralIssues = metadata.issues.filter { !$0.contains("mvhd creation_timeが0または対応日時範囲外") }
                if metadata.failed && !metadata.transportFailure && structuralIssues.contains(where: { $0.hasPrefix("破損:") }) {
                    evidence.diagnostics.append(.init(kind: .corrupt, message: "動画の構造または日時が不正"))
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as MetadataFailure {
            let kind: DateDiagnosticKind
            switch error {
            case .missing: kind = .missing
            case .unsupported: kind = .unsupported
            case .limit: kind = .limit
            case .corrupt: kind = .corrupt
            case .smb: kind = .smb
            }
            evidence.diagnostics.append(.init(kind: kind, message: error.description))
        } catch {
            // 未分類エラーを恒久的な破損・欠落として確定しない。
            evidence.diagnostics.append(.init(kind: .temporary, message: "原因を判別できない解析失敗"))
        }
        try Task.checkCancellation()
        return outcome(format: format, evidence: evidence, creation: creation, modified: modified)
    }

    static func outcome(format: MediaDateFormat, evidence: InternalDateEvidence,
                        creation: Date?, modified: Date?) -> MetadataOutcome {
        let resolution = DisplayDateResolver.resolve(format: format, evidence: evidence,
                                                       creationTime: creation, lastWriteTime: modified)
        let kinds = Set(resolution.diagnostics.map(\.kind))
        let state: String
        if !kinds.isDisjoint(with: [.smb, .cleanup, .temporary]) { state = "retry" }
        else if kinds.contains(.limit) { state = "limit" }
        else if kinds.contains(.unsupported) { state = "unsupported" }
        else if kinds.contains(.corrupt) { state = "corrupt" }
        else if kinds.contains(.invalid) { state = "invalid" }
        else if kinds.contains(.unconfirmed) { state = "unconfirmed" }
        else if !resolution.internalSuccess { state = "missing" }
        else { state = "complete" }
        return MetadataOutcome(resolution: resolution, state: state)
    }

    // PoCと同じ差分prefix読み。ImageIOによるpixel decode / 全体fallbackは行わない。
    private static func jpeg(_ input: any MetadataRangeSource, evidence: inout InternalDateEvidence) async throws {
        var data = Data()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let image = CGImageSourceCreateIncremental(options)
        for kib in [16, 32, 64, 128] {
            try Task.checkCancellation()
            let limit = Int(min(input.size, UInt64(kib * 1024)))
            while data.count < limit {
                let count = limit - data.count
                let chunk = try await input.read(offset: UInt64(data.count), length: count,
                                                 kind: .management, purpose: "JPEG prefix")
                guard !chunk.isEmpty, chunk.count <= count else { throw MetadataFailure.smb("短いEOF／応答長不正") }
                data.append(chunk)
            }
            autoreleasepool {
                CGImageSourceUpdateData(image, data as CFData, UInt64(data.count) == input.size)
                if let properties = CGImageSourceCopyPropertiesAtIndex(image, CGImageSourceGetPrimaryImageIndex(image), options) as? [String: Any],
                   let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
                   let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                    evidence.exif = ExifDateFields(original: raw,
                        offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
                        subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)
                }
            }
            if evidence.exif != nil { return }
            if UInt64(data.count) == input.size { break }
        }
        let status = CGImageSourceGetStatus(image)
        if status == .statusInvalidData || status == .statusUnknownType || (UInt64(data.count) == input.size && status == .statusUnexpectedEOF) {
            evidence.diagnostics.append(.init(kind: .corrupt, message: "ImageIOデータ不正"))
        } else if UInt64(data.count) == input.size && status == .statusComplete {
            evidence.diagnostics.append(.init(kind: .missing, message: "DateTimeOriginalなし"))
        } else {
            evidence.diagnostics.append(.init(kind: .unconfirmed, message: "128 KiBまでで未確認。欠落と部分取得の制約は区別不能"))
        }
    }
}
