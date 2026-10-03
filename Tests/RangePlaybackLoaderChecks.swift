import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

actor PlaybackReadProbe {
    let data: Data
    var active = 0, peak = 0, calls = 0
    var blocked = false
    var gate: CheckedContinuation<Void,Never>?
    init(_ data: Data, blocked: Bool = false) { self.data = data; self.blocked = blocked }
    func read(_ offset: UInt64, _ length: Int) async throws -> Data {
        active += 1; peak = max(peak,active); calls += 1
        defer { active -= 1 }
        if blocked { await withCheckedContinuation { gate = $0 } }
        try await Task.sleep(for:.milliseconds(10))
        return data.subdata(in:Int(offset)..<(Int(offset)+length))
    }
    func release() { blocked = false; gate?.resume(); gate = nil }
    func counts() -> (Int,Int) { (calls,peak) }
}
// AVFoundationのキャンセル通知タイミングに依存せず、実requestでcallback処理を検証。
nonisolated final class CapturingPlaybackDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let loader: RangeThumbnailLoader
    var firstData: AVAssetResourceLoadingRequest?
    init(_ loader: RangeThumbnailLoader) { self.loader = loader }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if firstData == nil, request.dataRequest != nil { firstData = request }
        return loader.resourceLoader(resourceLoader, shouldWaitForLoadingOfRequestedResource: request)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        loader.resourceLoader(resourceLoader,didCancel:request)
    }
    func deliverCancel(_ resourceLoader: AVAssetResourceLoader) async -> Bool {
        await withCheckedContinuation { continuation in
            loader.queue.async {
                guard let request = self.firstData else { continuation.resume(returning:false); return }
                self.loader.resourceLoader(resourceLoader,didCancel:request)
                if !request.isFinished && !request.isCancelled { request.finishLoading(with:URLError(.cancelled)) }
                continuation.resume(returning:true)
            }
        }
    }
}
@main struct RangePlaybackLoaderChecks {
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
        let probe = PlaybackReadProbe(data)
        let loader = RangeThumbnailLoader(size:UInt64(data.count),type:UTType.quickTimeMovie.identifier,
            limit:1_073_741_824,requestLimit:32_768,callLimit:262_144,recordTransfers:true) { try await probe.read($0,$1) }
        let a = AVURLAsset(url:URL(string:"photojot-range-playback://fixture/a.mov")!)
        let b = AVURLAsset(url:URL(string:"photojot-range-playback://fixture/b.mov")!)
        a.resourceLoader.setDelegate(loader,queue:loader.queue)
        b.resourceLoader.setDelegate(loader,queue:loader.queue)
        async let first = a.load(.duration)
        async let second = b.load(.duration)
        let values = try await (first,second)
        check(values.0.seconds > 0 && values.1.seconds > 0,"multiple assets / requests")
        let p = AVPlayer(playerItem:AVPlayerItem(asset:a))
        for _ in 0..<200 {
            if p.currentItem?.status == .readyToPlay || p.currentItem?.status == .failed { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        check(p.currentItem?.status == .readyToPlay,"AVPlayerItem ready through loader")
        let before = await loader.snapshot()
        _ = await p.seek(to:CMTime(seconds:0.5,preferredTimescale:600))
        let after = await loader.snapshot()
        check(after.ledger.bytes >= before.ledger.bytes,"seek snapshot monotonic")
        let counts = await probe.counts()
        check(counts.1 == 1,"multiple requests but exactly one simultaneous read")
        check(after.loading > 1,"multiple loading requests")
        check(after.transfers.reduce(UInt64(0)) { $0 + UInt64($1.bytes) } == after.ledger.bytes,"transfer journal matches totals")
        p.pause(); p.replaceCurrentItem(with:nil); a.cancelLoading(); b.cancelLoading()
        let final = await loader.finish()
        check(final.logs.allSatisfy { $0.status == "完了" || $0.status == "cancel" },"all requests ended")
        let finalCalls = await probe.counts().0
        try await Task.sleep(for:.milliseconds(50))
        check(await probe.counts().0 == finalCalls,"no read after finish")
        a.resourceLoader.setDelegate(nil,queue:nil); b.resourceLoader.setDelegate(nil,queue:nil)

        // 終了中もSMB相当のin-flight readが戻るまで待ち、返却量は保持する。
        let blocked = PlaybackReadProbe(data,blocked:true)
        let closing = RangeThumbnailLoader(size:UInt64(data.count),type:UTType.quickTimeMovie.identifier,recordTransfers:true) { try await blocked.read($0,$1) }
        let c = AVURLAsset(url:URL(string:"photojot-range-playback://fixture/c.mov")!)
        c.resourceLoader.setDelegate(closing,queue:closing.queue)
        let opening = Task { try await c.load(.duration) }
        for _ in 0..<200 {
            if await blocked.counts().0 > 0 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        check(await blocked.counts().0 == 1,"in-flight read started")
        c.cancelLoading(); closing.cancelAll()
        let finish = Task { await closing.finish() }
        await blocked.release()
        let stopped = await finish.value
        _ = try? await opening.value
        check(await blocked.counts().0 == 1,"cancel prevents subsequent reads")
        check(stopped.ledger.bytes > 0 && stopped.logs.contains { $0.status == "cancel" },"late bytes counted on cancelled request")
        c.resourceLoader.setDelegate(nil,queue:nil)
        // 古いAVAssetの要求だけをcancelし、新しい要求は同じloaderで継続する。
        let switching = PlaybackReadProbe(data,blocked:true)
        let shared = RangeThumbnailLoader(size:UInt64(data.count),type:UTType.quickTimeMovie.identifier,recordTransfers:true) { try await switching.read($0,$1) }
        let oldAsset = AVURLAsset(url:URL(string:"photojot-range-playback://fixture/old.mov")!)
        let newAsset = AVURLAsset(url:URL(string:"photojot-range-playback://fixture/new.mov")!)
        let capture = CapturingPlaybackDelegate(shared)
        oldAsset.resourceLoader.setDelegate(capture,queue:shared.queue)
        newAsset.resourceLoader.setDelegate(shared,queue:shared.queue)
        let oldLoad = Task { try await oldAsset.load(.duration) }
        for _ in 0..<200 {
            if await switching.counts().0 > 0 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        check(await capture.deliverCancel(oldAsset.resourceLoader),"captured real loading request")
        let newLoad = Task { try await newAsset.load(.duration) }
        for _ in 0..<200 {
            let s = await shared.snapshot()
            if s.cancelCallbacks > 0 && s.data > 1 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        check(await shared.snapshot().cancelCallbacks > 0,"old request cancel callback")
        await switching.release()
        let newDuration = try await newLoad.value
        _ = try? await oldLoad.value
        check(newDuration.seconds > 0,"new request progresses after old cancel")
        let switched = await shared.finish()
        check(switched.logs.first?.status == "cancel","old request stays cancelled after late data")
        check(await switching.counts().1 == 1,"cancel / new request remain serialized")
        oldAsset.resourceLoader.setDelegate(nil,queue:nil); newAsset.resourceLoader.setDelegate(nil,queue:nil)
        print("Range playback loader: \(count) checks passed (synthetic MOV; no SMB)")
    }
}
