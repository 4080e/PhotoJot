import SwiftUI
import AVKit

// The real collection view / session run here; media I/O is deliberately absent.
@MainActor @Observable final class MediaViewerController {
    let photo = PhotoResolution()
    var activeItem: TimelineItem?
    var showsLoading = false
    var player: AVPlayer?
    var image: CGImage?
    var message: String?
    var isClosing = false
    var selections: [UUID] = []
    func select(item: TimelineItem, viewport: FullPhotoViewport, force: Bool = false) {
        activeItem = item; selections.append(item.id)
    }
}
private final class DraggingCollection: ViewerCollectionView {
    var simulatedDrag = false
    var simulatedDeceleration = false
    override var isDragging: Bool { simulatedDrag || super.isDragging }
    override var isDecelerating: Bool { simulatedDeceleration || super.isDecelerating }
}
@main struct ViewerPagerChecks {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PagerApp.self)) }
}
@MainActor final class PagerApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Tests", sessionRole: session.role)
        configuration.delegateClass = PagerScene.self
        return configuration
    }
}
@MainActor final class PagerScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible(); self.window = window
        Task { await run(root) }
    }
    func run(_ root: UIViewController) async {
        let library = UUID()
        let all = (0..<800).reversed().map { n -> TimelineItem in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            let date = TimelineDate(calendarDateTime: "2024-01-01T00:00:00", recordedOffset: nil, kind: .provisional, source: nil, quality: nil)
            return TimelineItem(id: id, libraryID: library, relativePath: "\(n).jpg", mediaType: n % 2 == 0 ? "photo" : "video",
                                fileExtension: n % 2 == 0 ? "jpg" : "mov", generation: id, date: date,
                                sortKey: date.sortKey(id: id), metadataState: nil, metadataIsCurrent: false)
        }
        let seed = all[300]
        let source = TimelinePageSource(prepare: { library }, page: { _, _ in TimelinePage(items: [], next: nil, revision: 1) },
            newerPage: { _, _ in TimelinePage(items: Array(all[100..<300]), next: nil, revision: 1) },
            anchorPage: { _, _ in TimelinePage(items: Array(all[300..<500]), next: nil, revision: 1) })
        let session = ViewerSession(item: seed, source: source)
        let model = MediaViewerController()
        let cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func tile(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            }
        }
        try! await cache.save(tile(.green).jpegData(compressionQuality: 1)!, for: ThumbnailSession.placeholderKey(for: all[299]))
        try! await cache.save(tile(.red).jpegData(compressionQuality: 1)!, for: ThumbnailSession.placeholderKey(for: all[300]))
        let thumbnails = ThumbnailSession(cache: cache,
            resolve: { id, library in
                guard let item = all.first(where: { $0.id == id && $0.libraryID == library }) else { return nil }
                return MediaThumbnailTarget(key: ThumbnailSession.placeholderKey(for: item), path: item.relativePath,
                    fileSize: 1, fileExtension: item.fileExtension, settings: SMBConnectionSettings())
            }, generate: { _ in fatalError("Viewer placeholder must never generate") }, disconnect: {})
        let size = CGSize(width: 320, height: 500)
        let pager = ViewerPagerView(session: session, model: model, viewport: .init(width: 960, height: 1500, scale: 1), thumbnails: thumbnails)
        let coordinator = pager.makeCoordinator()
        coordinator.owner = root
        let layout = ViewerPageLayout()
        layout.scrollDirection = .horizontal; layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0
        let view = DraggingCollection(frame: CGRect(origin: .zero, size: size), collectionViewLayout: layout)
        view.contentInsetAdjustmentBehavior = .never
        view.register(ViewerPageCell.self, forCellWithReuseIdentifier: "media")
        view.dataSource = coordinator; view.delegate = coordinator; view.isPagingEnabled = true
        view.didLayout = { [weak coordinator] view in
            guard let coordinator else { return }
            coordinator.update(view, items: coordinator.parent.session.items)
        }
        root.view.addSubview(view)
        coordinator.update(view, items: session.items)
        precondition(view.contentOffset.x == 0)
        model.photo.zoom.pinching = true
        coordinator.update(view, items: session.items)
        precondition(!view.isScrollEnabled, "pinch disables outer paging")
        model.photo.zoom.pinching = false; model.photo.zoom.scale = 2
        coordinator.update(view, items: session.items)
        precondition(!view.isScrollEnabled, "zoomed photo disables outer paging")
        model.photo.zoom.reset()
        coordinator.update(view, items: session.items)
        precondition(view.isScrollEnabled, "minimum scale restores outer paging")
        session.begin(); await session.waitForSupply()
        coordinator.update(view, items: session.items)
        precondition(view.contentOffset.x == 200 * size.width, "prepend preserves seed by ID")
        precondition(layout.itemSize == size, "page geometry uses points, not decoded image pixels")
        precondition(model.selections.isEmpty, "adjacent cells never start media loading")

        view.simulatedDrag = true
        view.setContentOffset(CGPoint(x: 201 * size.width, y: 0), animated: false)
        coordinator.update(view, items: [seed])
        precondition(view.numberOfItems(inSection: 0) == 400, "simulatedDrag defers window replacement")
        precondition(session.currentItem == seed && model.selections.isEmpty, "swipe in progress is not committed")
        view.simulatedDrag = false; view.simulatedDeceleration = true
        coordinator.scrollViewDidEndDragging(view, willDecelerate: true)
        precondition(model.selections.isEmpty, "deceleration is not committed early")
        view.simulatedDeceleration = false
        coordinator.scrollViewDidEndDecelerating(view)
        precondition(session.currentItem == all[301] && model.selections == [all[301].id], "left swipe commits older media")
        precondition(view.contentOffset.x == 201 * size.width, "commit does not snap to seed")
        view.setContentOffset(CGPoint(x: 199 * size.width, y: 0), animated: false)
        coordinator.scrollViewDidEndDragging(view, willDecelerate: false)
        precondition(session.currentItem == all[299], "right swipe commits newer media")
        coordinator.update(view, items: session.items)
        precondition(view.contentOffset.x == 199 * size.width, "ordinary rerender never returns to original item")
        // Resizing retains the committed ID and doesn't issue another media request.
        let resized = CGSize(width: 300, height: 320)
        coordinator.parent = ViewerPagerView(session: session, model: model, viewport: .init(width: 1500, height: 960, scale: 1), thumbnails: thumbnails)
        view.frame.origin = CGPoint(x: root.view.safeAreaInsets.left, y: root.view.safeAreaInsets.top)
        view.frame.size = resized
        coordinator.update(view, items: session.items)
        precondition(view.contentOffset.x == 199 * resized.width && model.selections.count == 2)
        // Check the actual rendered page, with distinct cached and full-image colours.
        func imageChannel(_ channel: Int, centred: Bool = false) -> Bool {
            let shot = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
                view.drawHierarchy(in: CGRect(origin: .zero, size: view.bounds.size), afterScreenUpdates: true)
            }.cgImage!
            let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let width = CGFloat(shot.width), height = CGFloat(shot.height)
            let crop = CGRect(x: -width * (centred ? 0.5 : 0.6), y: -height / 2, width: width, height: height)
            pixel.draw(shot, in: crop)
            let bytes = pixel.data!.assumingMemoryBound(to: UInt8.self)
            return bytes[channel] > 200 && bytes[(channel + 1) % 3] < 50 && bytes[(channel + 2) % 3] < 50
        }
        func expectColour(_ channel: Int, _ label: String) async {
            let deadline = Date().addingTimeInterval(5)
            while !imageChannel(channel) && Date() < deadline { await Task.yield() }
            precondition(imageChannel(channel), label)
        }
        func expectProgress(_ channel: Int) async {
            let deadline = Date().addingTimeInterval(5)
            while imageChannel(channel, centred: true) && Date() < deadline { await Task.yield() }
            precondition(!imageChannel(channel, centred: true), "small progress overlays cached thumbnail centre")
        }
        model.showsLoading = true
        await expectColour(1, "cached photo replaces loading placeholder")
        await expectProgress(1)
        model.image = tile(.blue).cgImage
        model.showsLoading = false
        await expectColour(2, "full image replaces thumbnail")
        precondition(imageChannel(2, centred: true), "progress overlay disappears with full photo")
        model.image = nil
        view.setContentOffset(CGPoint(x: 200 * resized.width, y: 0), animated: false)
        coordinator.scrollViewDidEndDragging(view, willDecelerate: false)
        model.showsLoading = true
        await expectColour(0, "video thumbnail is red, never the previous photo")
        await expectProgress(0)
        model.showsLoading = false
        // Exercise VideoPlayer itself: a nil-player stub never exercised its controller embedding.
        model.activeItem = session.currentItem
        model.player = AVPlayer()
        func players(_ controller: UIViewController) -> [AVPlayerViewController] {
            (controller as? AVPlayerViewController).map { [$0] } ?? controller.children.flatMap { players($0) }
        }
        let deadline = Date().addingTimeInterval(2)
        while players(root).isEmpty && Date() < deadline {
            root.view.layoutIfNeeded()
            await Task.yield()
        }
        guard let embeddedPlayer = players(root).first else {
            let screenshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("unsupported-video.png")
            try? screenshot.pngData()?.write(to: url)
            print("Screenshot: \(url.path)")
            print("FAIL: VideoPlayer has no AVPlayerViewController in the parent controller hierarchy")
            fflush(stdout); exit(1)
        }
        precondition(embeddedPlayer.player === model.player, "same player reaches the standard video UI")
        precondition(embeddedPlayer.view.window != nil, "video UI is actually attached to the visible window")
        let retainedPlayer = model.player
        // Cell destruction is presentation-only; it must not clear the controller-owned player.
        let path = IndexPath(item: 200, section: 0)
        let cell = view.cellForItem(at: path) as! ViewerPageCell
        coordinator.collectionView(view, didEndDisplaying: cell, forItemAt: path)
        precondition(root.children.isEmpty && model.player === retainedPlayer, "hosting is removed without stopping media ownership")
        coordinator.collectionView(view, willDisplay: cell, forItemAt: path)
        let reattachDeadline = Date().addingTimeInterval(2)
        while players(root).isEmpty && Date() < reattachDeadline { await Task.yield() }
        precondition(players(root).first?.player === retainedPlayer, "same player survives cell reattachment")
        cell.prepareForReuse()
        precondition(root.children.isEmpty, "reuse removes child controller containment")
        let settledBeforeClose = session.currentItem
        view.simulatedDrag = true
        view.setContentOffset(CGPoint(x: view.contentOffset.x + resized.width * 0.6, y: 0), animated: false)
        let returnItem = session.close()
        view.simulatedDrag = false
        coordinator.scrollViewDidEndDecelerating(view)
        precondition(returnItem == settledBeforeClose && session.currentItem == settledBeforeClose, "closing during swipe returns only last settled media")
        print("PASS: Viewer UIKit paging, settled selection, mixed IDs, deferred window replacement, anchor retention, point sizing, rotation, cached placeholders, full-image replacement and VideoPlayer containment")
        fflush(stdout)
        exit(0)
    }
}
