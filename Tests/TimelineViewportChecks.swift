import SwiftUI
import UIKit

// 通信・画像decodeを除き、本番のTimelineGridView.CoordinatorとUIKit layoutを実行する。
@MainActor final class ThumbnailSession { }
struct TimelineThumbnailCell: View {
    let item: TimelineItem
    let session: ThumbnailSession
    var body: some View { Color.gray.aspectRatio(1, contentMode: .fit) }
}

@main struct ViewportChecks {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ViewportApp.self)) }
}

@MainActor final class ViewportApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Tests", sessionRole: session.role)
        configuration.delegateClass = ViewportScene.self
        return configuration
    }
}

@MainActor final class ViewportScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Task { await run(in: root) }
    }

    func run(in root: UIViewController) async {
        let library = UUID()
        let session = ThumbnailSession()
        func items(_ range: Range<Int>) -> [TimelineItem] {
            range.map { number in
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
                let date = TimelineDate(calendarDateTime: "2023-12-31T12:00:00", recordedOffset: nil, kind: .provisional, source: nil, quality: nil)
                return TimelineItem(id: id, libraryID: library, relativePath: "\(number).jpg", mediaType: "photo", fileExtension: "jpg", generation: id, date: date, sortKey: date.sortKey(id: id), metadataState: nil, metadataIsCurrent: false)
            }
        }
        let original = items(0..<400), newer = items(1000..<1200), newest = items(1200..<1400)
        let model = TimelineController(source: TimelinePageSource(prepare: { library }, page: { _, _ in TimelinePage(items: original, next: nil, revision: 1) }))
        await model.loadInitial()
        let oldSection = UUID(), newSection = UUID(), jump = UUID()
        func value(_ sections: [TimelineGridSection], _ version: Int, _ jumpID: UUID = jump) -> TimelineGridView {
            TimelineGridView(model: model, thumbnails: session, sections: sections, contentVersion: version, jumpID: jumpID, scrollRequest: model.scrollRequest,
                             footer: AnyView(Text("test")), footerHeight: 60, select: { _ in }, inspect: { _ in })
        }
        let initial = value([.init(id: oldSection, title: "2023年12月31日", items: original)], 1)
        let coordinator = initial.makeCoordinator()
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let view = UICollectionView(frame: root.view.bounds, collectionViewLayout: layout)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.delegate = coordinator
        coordinator.install(view)
        root.view.addSubview(view)
        root.view.layoutIfNeeded()
        coordinator.update(initial, in: view)
        view.layoutIfNeeded()
        view.setContentOffset(CGPoint(x: 0, y: 505), animated: false)
        let anchor = coordinator.anchor(in: view)!
        func verify(_ anchor: TimelineViewportAnchor, _ label: String) {
            view.layoutIfNeeded()
            let path = coordinator.dataSource.indexPath(for: anchor.id)!
            let frame = view.layoutAttributesForItem(at: path)!.frame
            let actual = frame.minY - view.contentOffset.y - view.adjustedContentInset.top
            precondition(abs(Double(actual) - anchor.distanceFromTop) < 1, "\(label): \(actual) != \(anchor.distanceFromTop)")
        }
        let sections: [TimelineGridSection] = [.init(id: newSection, title: "2024年1月1日", items: newer), .init(id: oldSection, title: "2023年12月31日", items: original)]
        coordinator.update(value(sections, 2), in: view)
        verify(anchor, "prepend across day")
        await Task.yield()
        verify(anchor, "subsequent layout")
        view.setContentOffset(CGPoint(x: 0, y: view.contentOffset.y + 367), animated: false)
        let moved = coordinator.anchor(in: view)!
        let secondSections: [TimelineGridSection] = [.init(id: newSection, title: "2024年1月1日", items: newest + newer), .init(id: oldSection, title: "2023年12月31日", items: original)]
        coordinator.update(value(secondSections, 3), in: view)
        verify(moved, "second prepend uses current viewport")
        let restingOffset = view.contentOffset
        coordinator.update(value(secondSections, 3), in: view)
        await Task.yield()
        precondition(view.contentOffset == restingOffset, "same content update must not reapply jump")
        let all = newest + newer + original
        let index = all.firstIndex { $0.id == moved.id }!
        coordinator.update(value([.init(id: oldSection, title: "viewport", items: Array(all.dropFirst(index).prefix(200)))], 4), in: view)
        verify(moved, "revision rebase uses viewport coordinate")
        coordinator.update(value([.init(id: oldSection, title: "latest", items: original)], 5, UUID()), in: view)
        precondition(abs(view.contentOffset.y + view.adjustedContentInset.top) < 1, "explicit latest jumps once")
        let returnJump = UUID()
        let returnSections: [TimelineGridSection] = [.init(id: oldSection, title: "return", items: original)]
        await model.returnFromViewer(to: original[180])
        coordinator.update(value(returnSections, 6, returnJump), in: view)
        let returnedPath = coordinator.dataSource.indexPath(for: original[180].id)!
        precondition(view.indexPathsForVisibleItems.contains(returnedPath), "returned item visible")
        await Task.yield()
        precondition(model.scrollRequest == nil && model.displayedMonth == original[180].date.month, "return consumed and month follows viewport")
        view.setContentOffset(CGPoint(x: 0, y: view.contentOffset.y + 400), animated: false)
        let afterReturn = coordinator.anchor(in: view)!
        coordinator.update(value(returnSections, 6, returnJump), in: view)
        verify(afterReturn, "thumbnail update cannot reapply return")
        coordinator.update(value(returnSections, 7, returnJump), in: view)
        verify(afterReturn, "content update cannot reapply return")
        coordinator.update(value(secondSections, 8, returnJump), in: view)
        verify(afterReturn, "prepend after return keeps user viewport")
        print("PASS: viewer return visible, consumed once, month observation, no snap back on content or prepend")
        print("PASS: UIKit measured anchor survives 200-item prepend, day boundary, second prepend after user scrolling, repeat layout, unchanged snapshot, revision rebase; explicit jump consumed once")
        fflush(stdout)
        exit(0)
    }
}
