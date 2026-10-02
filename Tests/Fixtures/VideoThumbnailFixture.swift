import Foundation
import AVFoundation
import CoreVideo

nonisolated enum VideoThumbnailFixture {
    static func make(format: String = "mov") async throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RangeLoaderFixture-\(UUID()).\(format)")
        defer { try? FileManager.default.removeItem(at:root) }
        // テスト専用の小さな動画。製品PoCには一時動画の生成経路はない。
        let writer = try AVAssetWriter(outputURL:root,fileType: format == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType:.video, outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264, AVVideoWidthKey:64, AVVideoHeightKey:64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input, sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String:64, kCVPixelBufferHeightKey as String:64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime:.zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer) == kCVReturnSuccess, let buffer else { fatalError("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer,[])
            memset(CVPixelBufferGetBaseAddress(buffer),0,CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer,[])
            guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw writer.error! }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        var data = try Data(contentsOf:root)
        // 有効なfree atomで大きなresourceを模擬。全体コピーなしの検証用。
        let padding = 8 * 1_048_576
        var length = UInt32(padding).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: [102, 114, 101, 101])
        data.append(Data(count: padding - 8))
        return data
    }
}
