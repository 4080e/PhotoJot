import SwiftUI
import UIKit

struct TimelineItem {
    var id = UUID()
    var libraryID = UUID()
    var generation = UUID()
    var mediaType = "photo"
    var rotationQuarterTurns = 0
}
@MainActor @Observable final class ThumbnailSession {
    var revision = 0
    @ObservationIgnored var cached: CGImage?
    @ObservationIgnored var requests = 0
    @ObservationIgnored var suspended = true
    @ObservationIgnored var result: ThumbnailKey?
    func cachedImage(for key: ThumbnailKey) -> CGImage? { key == result ? cached : nil }
    static func placeholderKey(for item: TimelineItem) -> ThumbnailKey {
        ThumbnailKey(libraryID: item.libraryID, mediaEntryID: item.id, generation: item.generation,
                     specificationVersion: "test", pixelSize: 300)
    }
    func imageKey(id: UUID, libraryID: UUID) async throws -> ThumbnailKey? {
        requests += 1
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
        let quadrants = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill()
                let rects = [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 100, y: 0, width: 100, height: 50),
                             CGRect(x: 100, y: 50, width: 100, height: 50), CGRect(x: 0, y: 50, width: 100, height: 50)]
                context.fill(rects[index])
            }
        }.cgImage!
        func samples() -> [[UInt8]] {
            let view = host!.view!
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }.cgImage!
            return [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                    CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)].map { point in
                let crop = image.cropping(to: CGRect(x: CGFloat(image.width) * point.x, y: CGFloat(image.height) * point.y, width: 1, height: 1))!
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(pixel.prefix(3))
            }
        }
        session.cached = quadrants
        for media in ["photo", "video"] {
            item.mediaType = media; item.rotationQuarterTurns = 0
            mount(); await settle()
            let baseline = samples()
            let requests = session.requests
            for angle in [1, 2, 3, 0] {
                item.rotationQuarterTurns = angle
                host!.rootView = TimelineThumbnailCell(item: item, session: session)
                await settle()
                let actual = samples()
                for index in 0..<4 {
                    precondition(actual[index] == baseline[(index - angle + 4) % 4], "clockwise quadrant rotation for \(media) at \(angle)")
                }
                precondition(session.requests == requests, "rotation must not restart image requests")
                precondition(host!.view.frame.size == CGSize(width: 100, height: 100), "cell frame unchanged")
            }
            item.rotationQuarterTurns = 3; mount(); await settle()
            precondition(samples()[0] == baseline[1], "recreated cell retains rotation")
        }
        item.mediaType = "photo"; item.rotationQuarterTurns = 0
        session.cached = red; mount(); await settle()
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
