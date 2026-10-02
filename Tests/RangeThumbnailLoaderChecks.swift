import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

@main struct RangeThumbnailLoaderChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; precondition(value,message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RangeLoaderFixture-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at:root) }
        // テスト専用の小さな動画。製品PoCには一時動画の生成経路はない。
        let writer = try AVAssetWriter(outputURL:root,fileType:.mov)
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
        let data = try Data(contentsOf:root)
        let loader = RangeThumbnailLoader(size:UInt64(data.count),type:UTType.quickTimeMovie.identifier) { offset,length in
            try await Task.sleep(for:.milliseconds(1))
            return data.subdata(in:Int(offset)..<(Int(offset)+length))
        }
        let asset = AVURLAsset(url:URL(string:"photojot-range://fixture/a.mov")!)
        asset.resourceLoader.setDelegate(loader,queue:loader.queue)
        let duration = try await asset.load(.duration).seconds
        check(duration > 0,"duration through delegate")
        let generator = AVAssetImageGenerator(asset:asset)
        generator.maximumSize = CGSize(width:300,height:300)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at:CMTime(seconds:0.5,preferredTimescale:600))
        check(image.image.width > 0,"image through delegate")
        generator.cancelAllCGImageGeneration(); asset.cancelLoading()
        let snapshot = await loader.finish()
        asset.resourceLoader.setDelegate(nil,queue:nil)
        check(snapshot.error == nil,"loader no error")
        check(snapshot.content > 0 && snapshot.data > 0,"both request types")
        check(snapshot.ledger.bytes > 0 && snapshot.ledger.calls > 0,"transfer measured")
        check(snapshot.logs.reduce(UInt64(0)) { $0 + $1.bytes } == snapshot.ledger.bytes,"per request byte totals")
        check(snapshot.logs.allSatisfy { $0.status == "完了" || $0.status == "cancel" },"requests terminated")
        let limited = RangeThumbnailLoader(size:UInt64(data.count),type:UTType.quickTimeMovie.identifier,limit:1) { offset,length in
            data.subdata(in:Int(offset)..<(Int(offset)+length))
        }
        let limitedAsset = AVURLAsset(url:URL(string:"photojot-range://fixture/limit.mov")!)
        limitedAsset.resourceLoader.setDelegate(limited,queue:limited.queue)
        do { _ = try await limitedAsset.load(.duration); check(false,"cap fails") } catch { check(true,"cap fails") }
        let limitedSnapshot = await limited.finish()
        check(limitedSnapshot.error != nil && limitedSnapshot.ledger.bytes <= 1,"cap error and no overrun")
        limitedAsset.resourceLoader.setDelegate(nil,queue:nil)
        print("Range thumbnail loader: \(count) checks passed (synthetic local MOV; no SMB)")
    }
}
