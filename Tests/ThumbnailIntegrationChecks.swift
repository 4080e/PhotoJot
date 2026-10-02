import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

actor PhotoWork {
    let data: Data
    var gate: CheckedContinuation<Void, Never>?
    var started = 0
    var stopped = 0
    var fail = false
    init(_ data: Data) { self.data = data }
    func run() async throws -> Data {
        started += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate = $0 }
        } onCancel: { Task { await self.cancelled() } }
        try Task.checkCancellation()
        if fail { throw CocoaError(.fileReadUnknown) }
        return data
    }
    func cancelled() { stopped += 1 }
    func release() { gate?.resume(); gate = nil }
    func failing() { fail = true }
    func succeeding() { fail = false }
    var waiting: Bool { gate != nil }
}

@main struct ThumbnailIntegrationChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    @MainActor static func wait(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) { check(Date() < deadline); await Task.yield() }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = try MediaRepository(url: root.appendingPathComponent("index.store"))
        var settings = SMBConnectionSettings(); settings.host = "test"; settings.share = "photos"; settings.username = "user"
        let scan = try await repo.begin(settings: settings)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.ingest([ScannedMedia(path: "a.jpg", size: 100, creation: date, modified: date),
                               ScannedMedia(path: "b.mov", size: 200, creation: date, modified: date)], ticket: scan, progress: .init())
        _ = try await repo.finish(scan, progress: .init(), completed: true)
        let timeline = TimelineRepository(store: repo)
        let libraryID = try await timeline.prepare(settings: settings)
        let page = try await timeline.page(libraryID: libraryID)
        let photo = page.items.first { $0.mediaType == "photo" }!, video = page.items.first { $0.mediaType == "video" }!
        let originalTarget = try await repo.thumbnailTarget(id: photo.id, libraryID: libraryID)!
        let videoTarget = try await repo.thumbnailTarget(id: video.id, libraryID: libraryID)!
        check(videoTarget.key.specificationVersion == VideoThumbnailPolicy.version)
        check(try await repo.thumbnailTarget(id: photo.id, libraryID: UUID()) == nil)
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let buffer = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); check(CGImageDestinationFinalize(dest))
        let jpeg = buffer as Data
        let work = PhotoWork(jpeg)
        let cache = ThumbnailCache(directory: root.appendingPathComponent("cache"))
        var disconnects = 0
        let session = ThumbnailSession(cache: cache, resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) },
            generate: { _ in try await work.run() }, disconnect: { await MainActor.run { disconnects += 1 } })
        let pending = Task { try await session.imageKey(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }
        // SMB生成待機中でもローカルpage取得は完了する。
        check(try await timeline.page(libraryID: libraryID).items.count == 2)
        // 取得中にgenerationが変化した結果は採用しない。
        let rescan = try await repo.begin(settings: settings)
        try await repo.ingest([ScannedMedia(path: "a.jpg", size: 101, creation: date, modified: date)], ticket: rescan, progress: .init())
        _ = try await repo.finish(rescan, progress: .init(), completed: false)
        await work.release()
        check(try await pending.value == nil)
        let updated = try await repo.thumbnailTarget(id: photo.id, libraryID: libraryID)!
        check(updated.key != originalTarget.key)
        let next = Task { try await session.imageData(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }; await work.release()
        let adopted = try await next.value!
        check(adopted.key == updated.key && adopted.data == jpeg)
        check(try await session.isCurrent(adopted.key))
        // セルが利用する画像経路でもdiskからmemoryへ登録される。
        check(try await session.imageKey(id: photo.id, libraryID: libraryID) == adopted.key)
        let decoded = session.cachedImage(for: adopted.key)
        check(decoded != nil)
        // cache hitはoffline（generatorが失敗する状態）・編集中・backgroundでも利用可能。
        await work.failing()
        session.setEditing(true)
        session.scenePhaseChanged(.background)
        session.scenePhaseChanged(.active)
        check(!session.canGenerate)
        check(try await session.imageData(id: photo.id, libraryID: libraryID)?.data == jpeg)
        check(try await session.imageKey(id: photo.id, libraryID: libraryID) == adopted.key)
        check(session.cachedImage(for: adopted.key) === decoded)
        check(await work.started == 2)
        let revision = session.revision
        session.setEditing(false)
        await wait { session.revision > revision }
        check(session.canGenerate)
        // cacheのない新世代を中断。checkはcleanup完了前に進まない。
        let thirdScan = try await repo.begin(settings: settings)
        try await repo.ingest([ScannedMedia(path: "a.jpg", size: 102, creation: date, modified: date)], ticket: thirdScan, progress: .init())
        _ = try await repo.finish(thirdScan, progress: .init(), completed: false)
        check(!(try await session.isCurrent(adopted.key)))
        let cancelled = Task { try await session.imageKey(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }
        var checkReady = false
        let checking = Task { await session.beginConnectionCheck(); checkReady = true }
        await wait { await work.stopped == 1 }
        check(!checkReady)
        do { _ = try await cancelled.value; preconditionFailure("cancel") } catch is CancellationError { }
        await work.release(); await checking.value
        check(checkReady && !session.canGenerate)
        let before = session.revision
        session.endConnectionCheck()
        await wait { session.revision > before }
        let failing = Task { try await session.imageData(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }; await work.release()
        do { _ = try await failing.value; preconditionFailure("failure") } catch { check(!(error is CancellationError)) }
        check(try await timeline.page(libraryID: libraryID).items.count == 2)
        check(disconnects > 0)
        // activeが旧生成のcleanupより先に来ても、新生成は終了まで待つ。
        await work.succeeding()
        let interrupted = Task { try await session.imageData(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }
        let starts = await work.started, stops = await work.stopped
        session.scenePhaseChanged(.inactive)
        check(session.canGenerate)
        session.scenePhaseChanged(.background)
        session.scenePhaseChanged(.active)
        await wait { await work.stopped > stops }
        do { _ = try await interrupted.value; preconditionFailure("background cancel") } catch is CancellationError { }
        check(await work.started == starts)
        let restartRevision = session.revision
        await work.release()
        await wait { session.revision > restartRevision }
        let resumed = Task { try await session.imageData(id: photo.id, libraryID: libraryID) }
        await wait { await work.waiting }
        check(await work.started == starts + 1)
        // SwiftUI .taskキャンセル相当。最後の利用者が消えたら生成へ伝播する。
        resumed.cancel()
        await wait { await work.stopped == stops + 2 }
        do { _ = try await resumed.value; preconditionFailure("cell cancel") } catch is CancellationError { }
        await work.release()
        // 動画も同じSessionでgeneration判定・disk/memory cacheを通る。
        let videoWork = PhotoWork(jpeg)
        let videoSession = ThumbnailSession(cache: cache,
            resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) },
            generate: { _ in try await videoWork.run() }, disconnect: {})
        let staleVideo = Task { try await videoSession.imageKey(id: video.id, libraryID: libraryID) }
        await wait { await videoWork.waiting }
        let videoScan = try await repo.begin(settings: settings)
        try await repo.ingest([ScannedMedia(path: "b.mov", size: 201, creation: date, modified: date)], ticket: videoScan, progress: .init())
        _ = try await repo.finish(videoScan, progress: .init(), completed: false)
        await videoWork.release()
        check(try await staleVideo.value == nil)
        let currentVideo = try await repo.thumbnailTarget(id: video.id, libraryID: libraryID)!
        check(currentVideo.key != videoTarget.key)
        let videoRequest = Task { try await videoSession.imageKey(id: video.id, libraryID: libraryID) }
        await wait { await videoWork.waiting }; await videoWork.release()
        check(try await videoRequest.value == currentVideo.key)
        let cachedVideo = videoSession.cachedImage(for: currentVideo.key)
        await videoWork.failing()
        videoSession.setEditing(true)
        check(try await videoSession.imageKey(id: video.id, libraryID: libraryID) == currentVideo.key)
        check(videoSession.cachedImage(for: currentVideo.key) === cachedVideo)
        check(await videoWork.started == 2)
        // memoryが空の新sessionでもoffline disk cacheを利用し、generatorを呼ばない。
        let offlineVideo = ThumbnailSession(cache: cache,
            resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) },
            generate: { _ in preconditionFailure("video disk hit reached generator") }, disconnect: {})
        check(try await offlineVideo.imageKey(id: video.id, libraryID: libraryID) == currentVideo.key)
        check(try await timeline.page(libraryID: libraryID).items.count == 2)
        // 設定Controllerのhook順序・失敗保持・保存成功・未保存終了。
        let defaults = UserDefaults(suiteName: "PhotoJot.ThumbnailSettings.\(UUID())")!
        defaults.set(try JSONEncoder().encode(settings), forKey: SMBConnectionSettings.storageKey)
        var events: [String] = []; var checkFails = true
        let update = LibraryUpdateController(connection: { .init(settings: settings, password: "") }, scan: { _,_ in 0 }, metadata: { _,_ in })
        let connection = ConnectionSettingsController(defaults: defaults, update: update,
            readPassword: { _ in "" }, savePassword: { _,_ in }, deletePassword: { _ in },
            check: { _,_ in events.append("check"); if checkFails { throw CocoaError(.fileReadUnknown) } },
            editingChanged: { session.setEditing($0) },
            beginThumbnailCheck: { await session.beginConnectionCheck(); events.append("drained") },
            endThumbnailCheck: { session.endConnectionCheck() })
        check(connection.beginEditing()); connection.draft.share = "new"
        check(!(await connection.save()))
        check(events == ["drained", "check"] && connection.savedSettings == settings && connection.draft.share == "new")
        connection.endEditing(); check(connection.savedSettings == settings)
        check(connection.beginEditing()); connection.draft.share = "new"; checkFails = false
        check(await connection.save()); connection.endEditing()
        check(connection.savedSettings?.share == "new")
        print("PASS: local paging during generation, photo/video routing, generation before/after adoption, offline cache, settings/background/active, drain-before-check, failed and successful settings, retained local index")
    }
}
