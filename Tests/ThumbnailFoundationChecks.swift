import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

actor ControlledGenerator {
    let image: Data
    var starts: [ThumbnailKey] = []
    var cancellations = 0
    var active = 0
    var peak = 0
    var gates: [CheckedContinuation<Void, Never>] = []
    init(image: Data) { self.image = image }
    func run(_ key: ThumbnailKey) async throws -> Data {
        starts.append(key); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        await withTaskCancellationHandler {
            await withCheckedContinuation { gates.append($0) }
        } onCancel: { Task { await self.noteCancellation() } }
        // gateは通信返却＋cleanupの完了を模す。cancelだけでは解放しない。
        try Task.checkCancellation()
        return image
    }
    func noteCancellation() { cancellations += 1 }
    func release() { gates.removeFirst().resume() }
    var count: Int { starts.count }
}

@main struct ThumbnailFoundationChecks {
    static func check(_ value: Bool, _ message: String = "check failed", line: UInt = #line) {
        precondition(value, "\(message) at line \(line)")
    }
    static func wait(_ condition: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            check(Date() < deadline, "condition timed out")
            await Task.yield()
        }
    }
    static func cancelled(_ task: Task<Data, Error>) async {
        do { _ = try await task.value; preconditionFailure("expected cancellation") }
        catch is CancellationError { }
        catch { preconditionFailure("cancellation converted: \(error)") }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cache = ThumbnailCache(directory: root)
        let library = UUID(), entry = UUID(), generation = UUID()
        func key(_ gen: UUID = generation, pixels: Int = 300, version: String = "photo-v1") -> ThumbnailKey {
            .init(libraryID: library, mediaEntryID: entry, generation: gen, specificationVersion: version, pixelSize: pixels)
        }
        let a = key(), b = key(UUID()), c = key(UUID())
        check(a.filename == key().filename && a.filename.count == 68)
        check(a.filename != b.filename && a.filename != key(pixels: 600).filename && a.filename != key(version: "photo-v2").filename)
        check(a.filename != ThumbnailKey(libraryID: UUID(), mediaEntryID: entry, generation: generation, specificationVersion: "photo-v1", pixelSize: 300).filename)
        check(a.filename != ThumbnailKey(libraryID: library, mediaEntryID: UUID(), generation: generation, specificationVersion: "photo-v1", pixelSize: 300).filename)
        check(a.filename.dropLast(4).allSatisfy { "0123456789abcdef".contains($0) })
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination))
        let jpeg = buffer as Data
        let miss = await cache.load(a); check(miss == nil)
        try await cache.save(jpeg, for: a)
        let hit = await cache.load(a); check(hit == jpeg)
        // 並行save/readでも有効JPEGだけを返す。独自temporaryファイルは残さない。
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try await cache.save(jpeg, for: a) }
                group.addTask { let value = await cache.load(a); check(value == jpeg) }
            }
            try await group.waitForAll()
        }
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == [a.filename])
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(b.filename))
        let corrupt = await cache.load(b); check(corrupt == nil)
        try await cache.removeCorruptEntry(b)
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(b.filename).path))
        try await cache.removeCorruptEntry(a)
        check(await cache.load(a) == jpeg)
        do { try await cache.save(Data([0]), for: a); preconditionFailure("invalid JPEG accepted") }
        catch ThumbnailCache.CacheError.invalidJPEG { }
        check(await cache.load(a) == jpeg)
        // JPEG以外の正常画像と途中で切れたJPEGもhitにしない。
        let png = NSMutableData()
        let pngDestination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(pngDestination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(pngDestination))
        for bad in [png as Data, Data(jpeg.prefix(jpeg.count / 2))] {
            try bad.write(to: root.appendingPathComponent(b.filename))
            check(await cache.load(b) == nil)
            try await cache.removeCorruptEntry(b)
        }
        let controlled = ControlledGenerator(image: jpeg)
        let service = ThumbnailService(cache: cache) { try await controlled.run($0) }
        check(try await service.thumbnail(for: a) == jpeg)
        check(await controlled.count == 0)
        let first = Task { try await service.thumbnail(for: b) }
        let second = Task { try await service.thumbnail(for: b) }
        await wait { await service.requestCount(for: b) == 2 }
        await wait { await controlled.count == 1 }
        first.cancel(); await cancelled(first)
        check(await service.requestCount(for: b) == 1)
        check(await controlled.cancellations == 0)
        // 別keyは待機、cache hitは生成が止まっていても完了する。
        let third = Task { try await service.thumbnail(for: c) }
        await wait { await service.requestCount(for: c) == 1 }
        check(try await service.thumbnail(for: a) == jpeg)
        check(await controlled.count == 1)
        await controlled.release()
        check(try await second.value == jpeg)
        await wait { await controlled.count == 2 }
        await controlled.release()
        check(try await third.value == jpeg)
        check(await controlled.peak == 1)
        // 全利用者cancel→cleanup待ち→同じkeyの新利用者＋別keyを直列処理。
        let d = key(UUID()), e = key(UUID())
        let fourth = Task { try await service.thumbnail(for: d) }
        let fifth = Task { try await service.thumbnail(for: d) }
        await wait { await service.requestCount(for: d) == 2 }
        await wait { await controlled.count == 3 }
        fourth.cancel(); fifth.cancel()
        await cancelled(fourth); await cancelled(fifth)
        await wait { await controlled.cancellations == 1 }
        let replacement = Task { try await service.thumbnail(for: d) }
        let next = Task { try await service.thumbnail(for: e) }
        await wait { await service.requestCount(for: d) == 1 }
        await wait { await service.requestCount(for: e) == 1 }
        check(await controlled.count == 3)
        check(await cache.load(d) == nil)
        await controlled.release()
        await wait { await controlled.count == 4 }
        await controlled.release()
        await wait { await controlled.count == 5 }
        await controlled.release()
        check(try await replacement.value == jpeg)
        check(try await next.value == jpeg)
        check(await controlled.peak == 1)
        // 待機中の全利用者cancelはgeneratorへ到達しない。
        let f = key(UUID()), g = key(UUID())
        let running = Task { try await service.thumbnail(for: f) }
        await wait { await controlled.count == 6 }
        let queued = Task { try await service.thumbnail(for: g) }
        await wait { await service.requestCount(for: g) == 1 }
        queued.cancel(); await cancelled(queued)
        await controlled.release(); _ = try await running.value
        check(await controlled.count == 6)
        enum Expected: Error { case failed }
        let failureKey = key(UUID())
        let failure = ThumbnailService(cache: cache) { _ in throw Expected.failed }
        do { _ = try await failure.thumbnail(for: failureKey); preconditionFailure("expected error") }
        catch Expected.failed { }
        check(await cache.load(failureKey) == nil)
        let invalid = ThumbnailService(cache: cache) { _ in Data([1, 2]) }
        do { _ = try await invalid.thumbnail(for: failureKey); preconditionFailure("invalid output") }
        catch ThumbnailCache.CacheError.invalidJPEG { }
        check(await cache.load(failureKey) == nil)
        let cancelling = ThumbnailService(cache: cache) { _ in throw CancellationError() }
        await cancelled(Task { try await cancelling.thumbnail(for: failureKey) })
        check(await cache.load(failureKey) == nil)
        // 生成失敗は全利用者に同じエラーを返し、次のjobは開始できる。
        let failingKey = key(UUID()), followingKey = key(UUID())
        let failureGate = ControlledGenerator(image: jpeg)
        let recoverable = ThumbnailService(cache: cache) { target in
            let data = try await failureGate.run(target)
            if target == failingKey { throw Expected.failed }
            return data
        }
        let failed1 = Task { try await recoverable.thumbnail(for: failingKey) }
        let failed2 = Task { try await recoverable.thumbnail(for: failingKey) }
        await wait { await recoverable.requestCount(for: failingKey) == 2 }
        await wait { await failureGate.count == 1 }
        let following = Task { try await recoverable.thumbnail(for: followingKey) }
        await wait { await recoverable.requestCount(for: followingKey) == 1 }
        await failureGate.release()
        for task in [failed1, failed2] {
            do { _ = try await task.value; preconditionFailure("expected shared failure") }
            catch Expected.failed { }
        }
        await wait { await failureGate.count == 2 }
        await failureGate.release()
        check(try await following.value == jpeg)
        check(await cache.load(failingKey) == nil)
        print("PASS: key isolation, disk miss/hit/corruption/atomic save, generator bypass, coalescing, per-user cancellation, drain-before-restart, serial generation, queued cancellation, failure and CancellationError")
    }
}
