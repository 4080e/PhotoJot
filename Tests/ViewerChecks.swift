import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AVFoundation

actor ViewerReadProbe {
    let data: Data
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    var reads = 0, bytes = 0, closes = 0, maximumRead = 0
    init(_ data: Data, hold: Bool = false) { self.data = data; self.hold = hold }
    func read(_ offset: UInt64, _ count: Int) async throws -> Data {
        reads += 1
        maximumRead = max(maximumRead, count)
        if hold { await withCheckedContinuation { waiter = $0 } }
        bytes += count
        return data.subdata(in: Int(offset)..<(Int(offset)+count))
    }
    var waiting: Bool { waiter != nil }
    func release() { hold = false; waiter?.resume(); waiter = nil }
    func close() { closes += 1 }
    nonisolated var stream: MediaViewerStream {
        .init(read: { try await self.read($0,$1) }, close: { await self.close() })
    }
}

@main struct ViewerChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    @MainActor static func wait(_ condition: () async -> Bool, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(20)
        while !(await condition()) { check(Date() < deadline, line: line); await Task.yield() }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let buffer = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyOrientation:6] as CFDictionary)
        check(CGImageDestinationFinalize(dest))
        let jpeg = buffer as Data
        let viewport = FullPhotoViewport(width: 100, height: 200, scale: 2)
        let image = try await PhotoViewerImage.load(size: UInt64(jpeg.count), viewport: viewport, directory: root) { offset, count in
            jpeg.subdata(in: Int(offset)..<(Int(offset)+count))
        }
        check(image.image.width == 200 && image.image.height == 300)
        check(FileManager.default.fileExists(atPath: image.original.url.path))
        image.original.remove()
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        do {
            _ = try await PhotoViewerImage.load(size: 100, viewport: viewport, directory: root) { _,_ in throw CocoaError(.fileReadUnknown) }
            preconditionFailure("failure")
        } catch { }
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let held = ViewerReadProbe(jpeg, hold: true)
        let cancelled = Task { try await PhotoViewerImage.load(size: UInt64(jpeg.count), viewport: viewport, directory: root, read: held.stream.read) }
        await wait { await held.waiting }; cancelled.cancel(); await held.release()
        do { _ = try await cancelled.value; preconditionFailure("cancel") } catch is CancellationError { }
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let orphans = try FileManager.default.contentsOfDirectory(atPath: PhotoOriginal.directory.path)
        check(orphans.isEmpty)
        let movie = try await VideoThumbnailFixture.make()
        let repo = try MediaRepository(url: root.appendingPathComponent("index.store"))
        var settings = SMBConnectionSettings(); settings.host = "test"; settings.share = "photos"; settings.username = "test"
        let scan = try await repo.begin(settings: settings)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.ingest([.init(path: "a.jpg", size: Int64(jpeg.count), creation: date, modified: date),
                               .init(path: "b.mov", size: Int64(movie.count), creation: date, modified: date)], ticket: scan, progress: .init())
        _ = try await repo.finish(scan, progress: .init(), completed: true)
        let timeline = TimelineRepository(store: repo)
        let library = try await timeline.prepare(settings: settings)
        let page = try await timeline.page(libraryID: library)
        let photo = page.items.first { $0.mediaType == "photo" }!, video = page.items.first { $0.mediaType == "video" }!
        let photoProbe = ViewerReadProbe(jpeg)
        let model = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in photoProbe.stream })
        model.start(item: photo, viewport: viewport)
        await wait { !model.isLoading }
        check(model.image != nil && model.message == nil)
        check(await photoProbe.closes == 1)
        let originalReads = await photoProbe.reads
        model.photo.zoom.scale = 2
        model.photo.request(scale: 2)
        await model.photo.waitForDecode()
        check(model.image!.height == 600)
        check(await photoProbe.reads == originalReads) // refinement is local-only
        await model.stop(); check(model.image == nil && model.photo.zoom.scale == 1)
        check(await photoProbe.closes == 1)
        // 写真取得中に閉じてもreaderを早期解放せず、遅れて返った画像を表示しない。
        let photoClosingProbe = ViewerReadProbe(jpeg, hold: true)
        let photoClosing = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in photoClosingProbe.stream })
        photoClosing.setEditing(true)
        photoClosing.start(item: photo, viewport: viewport)
        check((photoClosing.message != nil || photoClosing.isClosing) && !photoClosing.isLoading)
        check(await photoClosingProbe.reads == 0)
        await photoClosing.stop(); photoClosing.setEditing(false)
        photoClosing.start(item: photo, viewport: viewport)
        await wait { await photoClosingProbe.waiting }
        let photoStop = Task { await photoClosing.stop() }
        await wait { photoClosing.isClosing }
        check(await photoClosingProbe.closes == 0)
        await photoClosingProbe.release(); await photoStop.value
        check(photoClosing.image == nil)
        check(await photoClosingProbe.closes == 1)
        // cleanup中の重複activeは一回の再開へ集約。再background中は開始しない。
        let resumeProbe = ViewerReadProbe(jpeg, hold: true)
        var opens = 0
        let resume = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in opens += 1; return resumeProbe.stream })
        resume.start(item: photo, viewport: viewport)
        await wait { await resumeProbe.waiting }
        resume.scenePhaseChanged(.background)
        resume.scenePhaseChanged(.active); resume.scenePhaseChanged(.active)
        check(opens == 1 && resume.isClosing && resume.showsLoading)
        resume.scenePhaseChanged(.background)
        await resumeProbe.release()
        await wait { !resume.isClosing }
        check(opens == 1 && resume.image == nil && resume.showsLoading)
        resume.scenePhaseChanged(.active); resume.scenePhaseChanged(.active)
        check(resume.showsLoading)
        await wait { resume.image != nil }
        check(!resume.showsLoading)
        check(opens == 2)
        resume.scenePhaseChanged(.inactive)
        check(resume.image != nil && opens == 2)
        resume.photo.zoom.scale = 2
        resume.photo.request(scale: 2); await resume.photo.waitForDecode()
        let retained = try FileManager.default.contentsOfDirectory(at: PhotoOriginal.directory, includingPropertiesForKeys: nil)
        check(retained.count == 1)
        resume.scenePhaseChanged(.background)
        await wait { !resume.isClosing }
        check(resume.image == nil && resume.photo.zoom.scale == 1)
        check(!FileManager.default.fileExists(atPath: retained[0].path))
        resume.scenePhaseChanged(.active)
        await wait { resume.image != nil }
        check(resume.image!.height == 300 && resume.photo.zoom.scale == 1)
        await resume.stop()

        let dismissProbe = ViewerReadProbe(jpeg, hold: true)
        var dismissOpens = 0
        let dismissed = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in dismissOpens += 1; return dismissProbe.stream })
        dismissed.start(item: photo, viewport: viewport)
        await wait { await dismissProbe.waiting }
        dismissed.scenePhaseChanged(.background); dismissed.scenePhaseChanged(.active)
        dismissed.cancelAutomaticResume()
        let dismissedStop = Task { await dismissed.stop() }
        await dismissProbe.release(); await dismissedStop.value
        dismissed.scenePhaseChanged(.active)
        check(dismissOpens == 1 && dismissed.image == nil)

        var failedOpens = 0
        let failed = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in failedOpens += 1; throw CocoaError(.fileReadUnknown) })
        failed.start(item: photo, viewport: viewport)
        await wait { !failed.isLoading }
        let failureMessage = failed.message
        failed.select(item: photo, viewport: viewport)
        check(!failed.isClosing)
        failed.scenePhaseChanged(.background); failed.scenePhaseChanged(.active)
        check(failedOpens == 1 && failed.message == failureMessage && !failed.showsLoading)
        await failed.stop()

        // Swipes during a non-cancellable read only retain the last committed selection.
        let switchProbe = ViewerReadProbe(jpeg, hold: true)
        var selections: [UUID] = []
        let switching = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { target in
            selections.append(target.key.mediaEntryID)
            return switchProbe.stream
        })
        switching.select(item: photo, viewport: viewport)
        await wait { await switchProbe.waiting }
        switching.select(item: video, viewport: viewport)
        switching.select(item: photo, viewport: viewport)
        switching.select(item: photo, viewport: viewport)
        check(switching.isClosing && switching.activeItem == nil && selections == [photo.id])
        check(await switchProbe.closes == 0)
        switching.scenePhaseChanged(.background)
        await switchProbe.release()
        await wait { !switching.isClosing }
        check(selections == [photo.id] && switching.showsLoading)
        switching.scenePhaseChanged(.active); switching.scenePhaseChanged(.active)
        await wait { switching.image != nil }
        check(selections == [photo.id, photo.id] && switching.activeItem == photo)
        await switching.stop()

        // Mixed pages share a single loader; each settled video autoplays, then drains on departure.
        let mixedPhoto = ViewerReadProbe(jpeg)
        let mixedVideo = ViewerReadProbe(movie)
        var mixedOpens: [UUID] = []
        let mixed = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { target in
            mixedOpens.append(target.key.mediaEntryID)
            return target.fileExtension == "mov" ? mixedVideo.stream : mixedPhoto.stream
        })
        mixed.select(item: photo, viewport: viewport)
        await wait { mixed.image != nil }
        mixed.photo.zoom.scale = 2
        mixed.photo.request(scale: 2); await mixed.photo.waitForDecode()
        mixed.select(item: video, viewport: viewport)
        await wait { mixed.player?.rate == 1 }
        check(mixed.activeItem == video && mixed.image == nil && mixed.photo.zoom.pagingEnabled)
        mixed.scenePhaseChanged(.background); mixed.scenePhaseChanged(.active)
        await wait { !mixed.isClosing && mixed.player?.rate == 1 }
        check(mixed.activeItem == video && mixedOpens == [photo.id, video.id, video.id])
        mixed.select(item: photo, viewport: viewport)
        await wait { mixed.image != nil }
        check(mixed.player == nil && mixed.activeItem == photo)
        check(await mixedVideo.closes == 2)
        mixed.photo.zoom.scale = 2
        mixed.setEditing(true)
        await wait { !mixed.isClosing }
        check(mixed.image == nil && mixed.photo.zoom.scale == 1)
        await mixed.stop()

        // Closing during selection cleanup drops the pending page permanently.
        let closeSelectionProbe = ViewerReadProbe(jpeg, hold: true)
        var closeSelectionOpens = 0
        let closeSelection = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in
            closeSelectionOpens += 1; return closeSelectionProbe.stream
        })
        closeSelection.select(item: photo, viewport: viewport)
        await wait { await closeSelectionProbe.waiting }
        closeSelection.select(item: video, viewport: viewport)
        closeSelection.cancelAutomaticResume()
        let selectionStop = Task { await closeSelection.stop() }
        await closeSelectionProbe.release(); await selectionStop.value
        closeSelection.scenePhaseChanged(.active)
        check(closeSelectionOpens == 1 && closeSelection.player == nil && closeSelection.image == nil)

        let staleProbe = ViewerReadProbe(jpeg, hold: true)
        let stale = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in staleProbe.stream })
        stale.start(item: photo, viewport: viewport)
        await wait { await staleProbe.waiting }
        let changed = try await repo.begin(settings: settings)
        try await repo.ingest([.init(path: "a.jpg", size: Int64(jpeg.count+1), creation: date, modified: date)], ticket: changed, progress: .init())
        _ = try await repo.finish(changed, progress: .init(), completed: false)
        await staleProbe.release(); await wait { !stale.isLoading }
        check(stale.image == nil && stale.message != nil)
        check(await staleProbe.closes == 1)
        let staleMessage = stale.message
        stale.scenePhaseChanged(.background); stale.scenePhaseChanged(.active)
        check(stale.message == staleMessage && !stale.showsLoading)
        await stale.stop()

        let videoProbe = ViewerReadProbe(movie)
        let playback = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in videoProbe.stream })
        playback.start(item: video, viewport: viewport)
        await wait { !playback.isLoading }
        check(playback.player != nil && playback.message == nil)
        await wait { playback.player?.currentItem?.status == .readyToPlay || playback.message != nil }
        check(playback.player?.currentItem?.status == .readyToPlay)
        await wait { playback.player?.rate == 1 }
        playback.player?.pause()
        let sought = await playback.player!.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        check(sought && abs(playback.player!.currentTime().seconds - 0.4) < 0.1)
        playback.player?.play()
        check(await videoProbe.maximumRead < movie.count)
        playback.scenePhaseChanged(.background)
        await wait { await videoProbe.closes == 1 }
        check(playback.player == nil && playback.showsLoading)
        playback.scenePhaseChanged(.active)
        playback.scenePhaseChanged(.active)
        await wait { playback.player?.rate == 1 }
        check(playback.message == nil && !playback.showsLoading)
        await playback.stop()
        check(await videoProbe.closes == 2)
        let blocked = ViewerReadProbe(movie, hold: true)
        let closing = MediaViewerController(resolve: { try await repo.thumbnailTarget(id: $0, libraryID: $1) }, open: { _ in blocked.stream })
        closing.start(item: video, viewport: viewport)
        await wait { await blocked.waiting }
        var ended = false
        let close = Task { await closing.stop(); ended = true }
        await wait { closing.isClosing }
        check(!ended)
        check(await blocked.closes == 0)
        await blocked.release(); await close.value
        check(closing.player == nil)
        check(await blocked.closes == 1)
        check(await blocked.reads == 1)
        check(try await timeline.page(libraryID: library).items.map(\.id) == page.items.map(\.id))
        check(try FileManager.default.contentsOfDirectory(atPath: PhotoOriginal.directory.path).isEmpty)
        print("PASS: photo source/viewport/orientation/temp cleanup, cancellation, generation rejection, viewer close, AVPlayer via range, no full predownload, background shutdown, drain-before-close, local timeline retained")
    }
}
