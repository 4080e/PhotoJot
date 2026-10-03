import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

actor ReadGate {
    var start: CheckedContinuation<Void, Never>?
    var finish: CheckedContinuation<Void, Never>?
    var started = false
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { start = $0 }
    }
    func suspendRead() async {
        started = true; start?.resume(); start = nil
        await withCheckedContinuation { finish = $0 }
    }
    func release() { finish?.resume(); finish = nil }
}
final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var r = 0, w = 0
    func read() { lock.lock(); r += 1; lock.unlock() }
    func write(_ n: Int) { lock.lock(); w += n; lock.unlock() }
    var values: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (r,w) }
}

@main struct FullPhotoChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { fatalError(message) } }
        let phone = FullPhotoViewport(width: 390, height: 844, scale: 3)
        check(try FullPhotoSizing.longEdge(width: 4032, height: 3024, orientation: 1, viewport: phone) == 1170, "landscape aspectFit")
        check(try FullPhotoSizing.longEdge(width: 4032, height: 3024, orientation: 6, viewport: phone) == 1560, "orientation swap")
        check(try FullPhotoSizing.longEdge(width: 100, height: 200, orientation: 1, viewport: phone) == 200, "no upsample")
        for orientation in 1...8 {
            let edge = try FullPhotoSizing.longEdge(width: 4032, height: 3024, orientation: orientation, viewport: phone)
            check(edge == (orientation < 5 ? 1170 : 1560), "orientation \(orientation)")
        }
        for viewport in [FullPhotoViewport(width: 0, height: 100, scale: 3), .init(width: .nan, height: 1, scale: 1),
                         .init(width: .infinity, height: 1, scale: 1), .init(width: 20000, height: 1, scale: 1), .init(width: 100, height: 100, scale: -1)] {
            do { _ = try FullPhotoSizing.longEdge(width: 1000, height: 1000, orientation: 1, viewport: viewport); check(false,"invalid viewport") }
            catch { check(true,"invalid viewport") }
        }
        for (w,h,o) in [(0,1,1),(-1,1,1),(Int.max,Int.max,1),(100,100,0),(100,100,9)] {
            do { _ = try FullPhotoSizing.longEdge(width:w,height:h,orientation:o,viewport:phone); check(false,"invalid source") }
            catch { check(true,"invalid source") }
        }
        let io = Counters()
        try await FullPhotoTransfer.copy(size: 10, chunk: 4, read: { offset,count in
            io.read(); return Data(repeating: UInt8(offset), count:count)
        }, write: { io.write($0.count) })
        check(io.values.0 == 3 && io.values.1 == 10,"chunk/remainder")
        let gate = ReadGate(), cancelledIO = Counters()
        let task = Task {
            do {
                try await FullPhotoTransfer.copy(size: 12, chunk: 4, read: { _,count in
                    cancelledIO.read(); await gate.suspendRead(); return Data(repeating:0,count:count)
                }, write: { cancelledIO.write($0.count) })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        await gate.waitStarted()
        task.cancel()
        await gate.release()
        check(await task.value,"cancellation after in-flight read")
        check(cancelledIO.values.0 == 1 && cancelledIO.values.1 == 0,"no next read/write after cancel")
        let beforeIO = Counters(), beforeGate = ReadGate()
        let beforeTask = Task {
            await beforeGate.suspendRead()
            do {
                try await FullPhotoTransfer.copy(size: 4, read: { _,n in beforeIO.read(); return Data(count:n) }, write: { beforeIO.write($0.count) })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        await beforeGate.waitStarted(); beforeTask.cancel(); await beforeGate.release()
        check(await beforeTask.value && beforeIO.values.0 == 0,"cancel before first read")
        do {
            try await FullPhotoTransfer.copy(size: 4, read: { _,_ in Data(count:1) }, write: { _ in check(false,"short read write") })
            check(false,"short read")
        } catch { check(true,"short read") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FullPhotoChecks-\(UUID())")
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let context = CGContext(data:nil,width:600,height:300,bitsPerComponent:8,bytesPerRow:2400,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:600,height:300))
        let image = context.makeImage()!
        for orientation in 1...8 {
            let url = dir.appendingPathComponent("\(orientation).jpg")
            let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:orientation] as CFDictionary)
            check(CGImageDestinationFinalize(dest),"fixture JPEG")
            let result = try FullPhotoImages.decode(url,viewport:.init(width:100,height:200,scale:2))
            check(result.1 == 600 && result.2 == 300 && result.3 == orientation,"source dimensions/orientation")
            check(result.0.width == 200 && result.0.height == (orientation < 5 ? 100 : 400),"ImageIO oriented output")
        }
        let bad = dir.appendingPathComponent("bad.heic"); try Data([1,2,3]).write(to:bad)
        do { _ = try FullPhotoImages.decode(bad,viewport:phone); check(false,"bad image") }
        catch { check(true,"bad image") }
        print("Full photo checks: \(checks) passed")
    }
}
