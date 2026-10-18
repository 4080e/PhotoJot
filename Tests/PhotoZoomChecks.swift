import SwiftUI
import AVKit

// The real collection view / session run here; media I/O is deliberately absent.
@MainActor @Observable final class MediaViewerController {
    let photo = PhotoResolution()
    var activeItem: TimelineItem?
    var showsLoading = false
    var previewKey: ThumbnailKey?
    var previewImage: CGImage?
    var player: AVPlayer?
    var image: CGImage?
    var message: String?
    var isClosing = false
    var selections: [UUID] = []
    func select(item: TimelineItem, viewport: FullPhotoViewport, force: Bool = false) {
        activeItem = item; selections.append(item.id)
    }
}

@main struct ZoomChecks {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ZoomApp.self)) }
}
@MainActor final class ZoomApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Test", sessionRole: session.role); config.delegateClass = ZoomScene.self; return config
    }
}
@MainActor final class ZoomScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible(); self.window = window
        Task { await run(root) }
    }
    func run(_ root: UIViewController) async {
        await checkViewerDismiss(root)
        let state = PhotoZoomState()
        state.aspectRatio = 0.75
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 900, height: 1200)) }.cgImage!
        var requests: [CGFloat] = []
        let page = PhotoZoomView(state: state, epoch: state.epoch, image: image, refined: { requests.append($0) })
        let c = page.makeCoordinator()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = PhotoZoomState.maximumScale
        scroll.delegate = c; scroll.addSubview(c.imageView); root.view.addSubview(scroll)
        c.update(scroll)
        precondition(!scroll.panGestureRecognizer.isEnabled && scroll.pinchGestureRecognizer!.isEnabled && state.pagingEnabled)
        c.scrollViewWillBeginZooming(scroll, with: c.imageView)
        scroll.setZoomScale(2, animated: false)
        precondition(!state.pagingEnabled && requests.isEmpty, "no refinement during pinch")
        c.scrollViewDidEndZooming(scroll, with: c.imageView, atScale: 2)
        precondition(!state.pagingEnabled && scroll.panGestureRecognizer.isEnabled && state.scale == 2 && requests == [2])
        scroll.contentOffset = CGPoint(x: 70, y: 90); c.scrollViewDidScroll(scroll)
        let saved = state.offset
        let replacement = page.makeCoordinator()
        let newScroll = UIScrollView(frame: scroll.frame); newScroll.minimumZoomScale = 1; newScroll.maximumZoomScale = 3
        newScroll.delegate = replacement; newScroll.addSubview(replacement.imageView)
        replacement.update(newScroll)
        precondition(newScroll.zoomScale == 2 && newScroll.contentOffset == saved, "reload keeps current zoom/pan")
        let bounds = replacement.imageView.bounds
        let larger = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 2400)).image { c in UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1800, height: 2400)) }.cgImage!
        replacement.parent = PhotoZoomView(state: state, epoch: state.epoch, image: larger, refined: { requests.append($0) })
        replacement.update(newScroll)
        precondition(newScroll.zoomScale == 2 && newScroll.contentOffset == saved && replacement.imageView.bounds == bounds, "higher pixel image keeps logical bounds and viewport")
        precondition(replacement.imageView.image?.cgImage === larger)
        scroll.setZoomScale(1, animated: false); c.scrollViewDidEndZooming(scroll, with: c.imageView, atScale: 1)
        precondition(state.pagingEnabled && !scroll.panGestureRecognizer.isEnabled)
        // Rotate while zoomed, fit the swapped aspect, then refine without changing rotation.
        for turn in 1...4 {
            state.scale = 2; state.offset = CGPoint(x: 70, y: 90)
            state.rotateRight()
            precondition(state.quarterTurns == turn % 4 && state.scale == 1 && state.offset == .zero && state.pagingEnabled)
            replacement.parent = PhotoZoomView(state: state, epoch: state.epoch, image: larger, refined: { requests.append($0) })
            replacement.update(newScroll)
            let expected: UIImage.Orientation = [.up, .right, .down, .left][turn % 4]
            precondition(replacement.imageView.image?.imageOrientation == expected && replacement.imageView.image?.cgImage === larger)
            precondition(newScroll.zoomScale == 1)
            precondition(abs(replacement.imageView.bounds.width / replacement.imageView.bounds.height - state.displayedAspectRatio) < 0.001)
            precondition(replacement.imageView.bounds.width <= newScroll.bounds.width && replacement.imageView.bounds.height <= newScroll.bounds.height)
            replacement.scrollViewWillBeginZooming(newScroll, with: replacement.imageView)
            newScroll.setZoomScale(2, animated: false)
            replacement.scrollViewDidEndZooming(newScroll, with: replacement.imageView, atScale: 2)
            let rotatedBounds = replacement.imageView.bounds
            let rotatedOffset = newScroll.contentOffset
            replacement.parent = PhotoZoomView(state: state, epoch: state.epoch, image: image, refined: { requests.append($0) })
            replacement.update(newScroll)
            precondition(newScroll.zoomScale == 2 && newScroll.contentOffset == rotatedOffset && replacement.imageView.bounds == rotatedBounds)
            precondition(replacement.imageView.image?.imageOrientation == expected && !state.pagingEnabled)
        }
        state.rotateRight(); state.reset()
        precondition(state.quarterTurns == 0)
        print("PASS: temporary rotation cycle, swapped fit, zoom reset, rotated refinement and lifecycle reset")
        scroll.setZoomScale(2, animated: false); c.scrollViewDidEndZooming(scroll, with: c.imageView, atScale: 2)
        precondition(state.scale == 1 && state.pagingEnabled, "late callback from old page cannot replace reset state")
        print("PASS: photo zoom, pan gating, settled refinement, reload/reconfigure retention, high-resolution swap, stale page reset")
        fflush(stdout); exit(0)
    }
}

@MainActor private func checkViewerDismiss(_ root: UIViewController) async {
    let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 600), collectionViewLayout: UICollectionViewFlowLayout())
    let container = ViewerPagerContainerController()
    root.addChild(container)
    container.install(view)
    container.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    root.view.addSubview(container.view)
    container.didMove(toParent: root)
    container.view.layoutIfNeeded()
    // The previous root-view implementation loses visible translation when its
    // parent reapplies frame, then exposes a negative origin on transform reset.
    let previousRoot = UIView(frame: container.view.bounds)
    previousRoot.transform = CGAffineTransform(translationX: 0, y: 120)
    previousRoot.frame = container.view.bounds
    precondition(previousRoot.frame.minY == 0)
    previousRoot.transform = .identity
    precondition(previousRoot.frame.minY == -120)
    let gesture = ViewerDismissGesture()
    var permitted = true
    var paging = true
    var progress: CGFloat = 0
    var closes = 0
    gesture.canBegin = { permitted }
    gesture.pagingEnabled = { paging }
    gesture.progress = { value, _ in progress = value }
    gesture.completed = { closes += 1 }
    gesture.install(on: view)
    precondition(ViewerDismissGesture.downward(CGPoint(x: 100, y: 200)))
    for velocity in [CGPoint(x: 200, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: -100)] {
        precondition(!ViewerDismissGesture.downward(velocity))
    }
    precondition(ViewerDismissGesture.finishes(distance: 150, velocity: .zero, height: 600))
    precondition(!ViewerDismissGesture.finishes(distance: 149, velocity: .zero, height: 600))
    precondition(ViewerDismissGesture.finishes(distance: 44, velocity: CGPoint(x: 0, y: 900), height: 600))
    precondition(!ViewerDismissGesture.finishes(distance: 20, velocity: CGPoint(x: 0, y: 1000), height: 600))
    precondition(!ViewerDismissGesture.finishes(distance: 200, velocity: CGPoint(x: 0, y: -100), height: 600))
    let button = UIButton(); let label = UILabel(); button.addSubview(label); view.addSubview(button)
    precondition(ViewerDismissGesture.isControl(label, within: view))
    let slider = UISlider(); view.addSubview(slider)
    precondition(ViewerDismissGesture.isControl(slider, within: view))
    let playerSurface = UIView(); view.addSubview(playerSurface)
    let playerPan = UIPanGestureRecognizer(); playerSurface.addGestureRecognizer(playerPan)
    gesture.isVideo = { true }
    precondition(gesture.gestureRecognizer(gesture.pan, shouldRecognizeSimultaneouslyWith: playerPan))
    precondition(!gesture.gestureRecognizer(gesture.pan, shouldRecognizeSimultaneouslyWith: view.panGestureRecognizer))
    let playerTap = UITapGestureRecognizer(); playerSurface.addGestureRecognizer(playerTap)
    precondition(!gesture.gestureRecognizer(gesture.pan, shouldRecognizeSimultaneouslyWith: playerTap))
    let unrelatedPan = UIPanGestureRecognizer(); root.view.addGestureRecognizer(unrelatedPan)
    precondition(!gesture.gestureRecognizer(gesture.pan, shouldRecognizeSimultaneouslyWith: unrelatedPan))
    root.view.removeGestureRecognizer(unrelatedPan)
    gesture.isVideo = { false }
    precondition(!gesture.gestureRecognizer(gesture.pan, shouldRecognizeSimultaneouslyWith: playerPan))
    permitted = false; gesture.begin(); precondition(!gesture.isBusy)
    permitted = true; gesture.begin(); gesture.move(to: 120)
    precondition(!view.isScrollEnabled && view.transform.ty == 120 && progress == 0.2)
    // Reproduce the representable root layout performed after each progress update.
    for distance: CGFloat in [20, 60, 120] {
        gesture.move(to: distance)
        container.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        container.view.setNeedsLayout(); container.view.layoutIfNeeded()
        precondition(view.convert(.zero, to: container.view).y == distance,
                     "visible media follows translation through parent relayout")
        precondition(view.contentOffset == .zero && container.view.transform == .identity)
    }
    paging = false; gesture.cancel(animated: false)
    precondition(!gesture.isBusy && !view.isScrollEnabled && view.transform == .identity && progress == 0 && closes == 0)
    paging = true; gesture.begin(); gesture.move(to: 80)
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    precondition(!gesture.isBusy && view.isScrollEnabled && view.transform == .identity && progress == 0 && closes == 0)
    gesture.begin(); gesture.finishDrag()
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    let deadline = Date().addingTimeInterval(0.4)
    while Date() < deadline { await Task.yield() }
    precondition(closes == 0 && !gesture.isBusy, "interruption invalidates animation completion")
    gesture.begin(); gesture.finishDrag(); gesture.finishDrag()
    let finishDeadline = Date().addingTimeInterval(2)
    while closes == 0 && Date() < finishDeadline { await Task.yield() }
    precondition(closes == 1, "one completion closes via the shared route")
    gesture.detach()
    container.willMove(toParent: nil); container.view.removeFromSuperview(); container.removeFromParent()
    print("PASS: viewer dismiss direction, controls, zoom gate, cancellation, interruption, single completion")
}
