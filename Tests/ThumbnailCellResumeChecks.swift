import SwiftUI
import UIKit

struct TimelineItem {
    var id = UUID()
    var libraryID = UUID()
    var generation = UUID()
    var mediaType = "photo"
}
@MainActor @Observable final class ThumbnailSession {
    var revision = 0
    @ObservationIgnored var cached: CGImage?
    @ObservationIgnored var suspended = true
    @ObservationIgnored var result: ThumbnailKey?
    func cachedImage(for key: ThumbnailKey) -> CGImage? { key == result ? cached : nil }
    static func placeholderKey(for item: TimelineItem) -> ThumbnailKey {
        ThumbnailKey(libraryID: item.libraryID, mediaEntryID: item.id, generation: item.generation,
                     specificationVersion: "test", pixelSize: 300)
    }
    func imageKey(id: UUID, libraryID: UUID) async throws -> ThumbnailKey? {
        while suspended { try Task.checkCancellation(); await Task.yield() }
        try Task.checkCancellation()
        return result
    }
}
@main struct ResumeChecks {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ResumeApp.self)) }
}
@MainActor final class ResumeApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Tests", sessionRole: session.role)
        config.delegateClass = ResumeScene.self
        return config
    }
}
@MainActor final class ResumeScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController(); window.rootViewController = root
        self.window = window; window.makeKeyAndVisible()
        Task { await run(root) }
    }
    func run(_ root: UIViewController) async {
        var item = TimelineItem()
        let session = ThumbnailSession()
        let red = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.cgImage!
        session.cached = red; session.result = ThumbnailSession.placeholderKey(for: item)
        var host: UIHostingController<TimelineThumbnailCell>?
        func mount() {
            host?.willMove(toParent: nil); host?.view.removeFromSuperview(); host?.removeFromParent()
            let value = UIHostingController(rootView: TimelineThumbnailCell(item: item, session: session))
            root.addChild(value); value.view.frame = CGRect(x: 20, y: 100, width: 100, height: 100)
            root.view.addSubview(value.view); value.didMove(toParent: root); host = value
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)); host?.view.layoutIfNeeded() }
        func isRed() -> Bool {
            let view = host!.view!
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }.cgImage!
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel[0] > 180 && pixel[1] < 80 && pixel[2] < 80
        }
        mount(); await settle()
        precondition(isRed(), "new cell uses memory hit before async validation")
        session.cached = nil; session.revision += 1
        await settle()
        precondition(isRed(), "visible image survives cache loss and foreground revalidation")
        session.cached = red; mount(); await settle()
        precondition(isRed(), "recreated cell uses cache without repository wait")
        item.generation = UUID()
        host!.rootView = TimelineThumbnailCell(item: item, session: session)
        await settle()
        precondition(!isRed(), "different generation does not retain old image")
        session.result = ThumbnailSession.placeholderKey(for: item)
        mount(); await settle(); precondition(isRed())
        session.result = nil; session.suspended = false; session.revision += 1
        await settle()
        precondition(!isRed(), "invalidated target removes previously accepted image")
        print("PASS: thumbnail cell resume, cache loss, recreation, generation rejection, invalidation")
        fflush(stdout); exit(0)
    }
}
