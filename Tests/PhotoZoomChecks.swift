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
        state.reset()
        scroll.setZoomScale(2, animated: false); c.scrollViewDidEndZooming(scroll, with: c.imageView, atScale: 2)
        precondition(state.scale == 1 && state.pagingEnabled, "late callback from old page cannot replace reset state")
        print("PASS: photo zoom, pan gating, settled refinement, reload/reconfigure retention, high-resolution swap, stale page reset")
        fflush(stdout); exit(0)
    }
}
