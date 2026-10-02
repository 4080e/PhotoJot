import Foundation
import AVFoundation
import UniformTypeIdentifiers
#if DEBUG
import os
#endif

nonisolated enum VideoThumbnailPolicy {
    static let version = "video-range-v1-300-sdr-jpeg85-time-half-max05-tolerance025"
    static func supports(_ ext: String) -> Bool { ["mov", "mp4"].contains(ext) }
    // PoCと同じ代表時刻。短い動画では中央、それ以外は0.5秒。
    static func time(_ duration: Double) throws -> Double {
        guard duration.isFinite, duration > 0 else { throw ThumbnailError.invalid("duration不正") }
        return min(0.5, duration / 2)
    }
}

nonisolated enum VideoThumbnailGenerator {
    // RangeThumbnailProbeの生成／終了順序を流用。接続とreaderのcloseはCoordinatorが所有。
    static func generate(format: String, size: UInt64,
                         read: @escaping @Sendable (UInt64, Int) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        guard VideoThumbnailPolicy.supports(format), size > 0, size <= UInt64(Int64.max) else {
            throw RangeThumbnailError.invalid("動画形式／サイズ不正")
        }
        let loader = RangeThumbnailLoader(size: size,
            type: format == "mov" ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier, read: read)
        // NASパスと認証情報をURLに含めない。動画全体の一時ファイルも作らない。
        let asset = AVURLAsset(url: URL(string: "photojot-range://thumbnail/\(UUID().uuidString).\(format)")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 300, height: 300)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let result: Result<CGImage, Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let duration = try await asset.load(.duration).seconds
                let time = try VideoThumbnailPolicy.time(duration)
                try Task.checkCancellation()
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                try Task.checkCancellation()
                return frame.image
            } onCancel: {
                loader.cancelAll(); generator.cancelAllCGImageGeneration(); asset.cancelLoading()
            })
        } catch { result = .failure(error) }
        generator.cancelAllCGImageGeneration(); asset.cancelLoading()
        // SMBのin-flight readは強制終了しない。返却後にloaderが次readを止めるまで待つ。
        let snapshot = await loader.finish()
        asset.resourceLoader.setDelegate(nil, queue: nil)
        try Task.checkCancellation()
        let image = try result.get()
        guard snapshot.error == nil else { throw RangeThumbnailError.invalid("動画range取得失敗") }
        #if DEBUG
        Logger(subsystem: "PhotoJot", category: "Thumbnail").debug("video format=\(format, privacy: .public), bytes=\(snapshot.ledger.bytes), reads=\(snapshot.ledger.calls)")
        #endif
        let data = try autoreleasepool { try ThumbnailImages.encode(image) }
        try Task.checkCancellation()
        return data
    }
}
