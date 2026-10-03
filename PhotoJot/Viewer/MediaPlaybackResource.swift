import Foundation
import AVFoundation
import UniformTypeIdentifiers

@MainActor final class MediaPlaybackResource {
    let asset: AVURLAsset
    private let loader: RangeThumbnailLoader
    private var cleanup: Task<Void, Never>?
    init(format: String, size: UInt64, read: @escaping @Sendable (UInt64, Int) async throws -> Data) throws {
        guard VideoThumbnailPolicy.supports(format) else { throw ViewerFailure.unavailable }
        loader = RangeThumbnailLoader(size: size,
            type: format == "mov" ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier,
            limit: try RangePlaybackPolicy.byteLimit(size: size),
            requestLimit: RangePlaybackPolicy.requestLimit, callLimit: RangePlaybackPolicy.callLimit, read: read)
        asset = AVURLAsset(url: URL(string: "photojot-range-playback://video/\(UUID()).\(format)")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }
    func cancel() { loader.cancelAll(); asset.cancelLoading() }
    // player解除→open処理終了→loader drain→reader closeの順序をControllerが守る。
    func stop() async {
        if let cleanup { await cleanup.value; return }
        cancel()
        let task = Task {
            _ = await loader.finish()
            asset.resourceLoader.setDelegate(nil, queue: nil)
        }
        cleanup = task
        await task.value
    }
}
