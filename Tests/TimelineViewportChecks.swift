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
        let view = TimelineCollectionView(frame: root.view.bounds, collectionViewLayout: layout)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.delegate = coordinator
        coordinator.install(view)
        root.view.addSubview(view)
        root.view.layoutIfNeeded()
        coordinator.update(initial, in: view)
        view.layoutIfNeeded()
        // 実際のFlowLayout属性を検査し、計算式だけをテストして済ませない。
        let originalFrame = view.frame
        view.autoresizingMask = []
        view.contentInsetAdjustmentBehavior = .never
        func verifyGrid(_ label: String) {
            view.layoutIfNeeded()
            let inset = view.adjustedContentInset
            let available = view.bounds.width - inset.left - inset.right - layout.sectionInset.left - layout.sectionInset.right
            let spacing = layout.minimumInteritemSpacing
            let columns = Int(floor((available + spacing) / (88 + spacing)))
            let side = floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let frames = (0..<32).map { view.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))!.frame }
            let firstRow = frames.filter { abs($0.minY - frames[0].minY) < 0.5 }
            precondition(firstRow.count == columns, "\(label): expected \(columns) columns, got \(firstRow.count)")
            for (index, frame) in frames.enumerated() {
                precondition(abs(frame.width - side) < 0.5 && abs(frame.height - side) < 0.5, "\(label): stale cell size \(frame), expected \(side)")
                precondition(frame.minX >= inset.left + layout.sectionInset.left - 0.5 && frame.maxX <= view.bounds.width - inset.right - layout.sectionInset.right + 0.5, "\(label): cell outside horizontal margins")
                for other in frames.dropFirst(index + 1) {
                    precondition(!frame.intersects(other), "\(label): overlapping cells")
                }
            }
            // floorによる端数以外の空白が行末やセル間に残っていないこと。
            precondition(abs(firstRow[0].minX - inset.left - layout.sectionInset.left) < 1, "\(label): leading gap")
            precondition(view.bounds.width - inset.right - layout.sectionInset.right - firstRow.last!.maxX < CGFloat(columns) + 1, "\(label): trailing gap")
            for pair in zip(firstRow, firstRow.dropFirst()) {
                let gap = pair.1.minX - pair.0.maxX
                precondition(gap >= spacing - 0.5 && gap < spacing + 2, "\(label): unexpected gap \(gap)")
            }
            let offset = view.contentOffset
            view.setNeedsLayout()
            view.layoutIfNeeded()
            precondition(view.contentOffset == offset, "\(label): unchanged layout moved scroll position")
            print("PASS: grid \(label), \(columns) columns, side=\(side)")
        }
        view.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        verifyGrid("initial portrait")
        for cycle in 1...3 {
            view.frame.size = CGSize(width: 932, height: 350)
            verifyGrid("landscape before inset \(cycle)")
            view.contentInset = UIEdgeInsets(top: 0, left: 62, bottom: 0, right: 62)
            verifyGrid("landscape with inset \(cycle)")
            // 幅とinsetが別々のlayoutで更新される回転を再現。
            view.frame.size = CGSize(width: 430, height: 800)
            verifyGrid("portrait before inset settles \(cycle)")
            view.contentInset = .zero
            verifyGrid("returned portrait \(cycle)")
        }
        view.contentInsetAdjustmentBehavior = .always
        root.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 20)
        root.view.layoutIfNeeded()
        verifyGrid("safe area changes without width change")
        root.additionalSafeAreaInsets = .zero
        root.view.layoutIfNeeded()
        verifyGrid("safe area restored")
        layout.sectionInset = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        view.setNeedsLayout()
        verifyGrid("section margins and spacing changed")
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        view.contentInsetAdjustmentBehavior = .automatic
        view.frame = originalFrame
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.setNeedsLayout()
        view.layoutIfNeeded()
        coordinator.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: 505), animated: false)
        let anchor = coordinator.anchor(in: view)!
        func verify(_ anchor: TimelineViewportAnchor, _ label: String) {
            view.layoutIfNeeded()
            let path = coordinator.dataSource.indexPath(for: anchor.id)!
            let frame = view.layoutAttributesForItem(at: path)!.frame
            let actual = frame.minY - view.contentOffset.y - view.adjustedContentInset.top
            precondition(abs(Double(actual) - anchor.distanceFromTop) < 1, "\(label): \(actual) != \(anchor.distanceFromTop)")
        }
        for cycle in 1...4 {
            view.frame.size = CGSize(width: 932, height: 350)
            view.layoutIfNeeded()
            verify(anchor, "landscape media anchor \(cycle)")
            view.frame = originalFrame
            view.layoutIfNeeded()
            verify(anchor, "portrait media anchor \(cycle)")
        }
        precondition(coordinator.dataSource.snapshot().itemIdentifiers == original.map(\.id), "rotation changed snapshot")
        // 回転途中のsnapshot更新も同じ回転基準で補正する。
        view.frame.size = CGSize(width: 932, height: 350)
        let sections: [TimelineGridSection] = [.init(id: newSection, title: "2024年1月1日", items: newer), .init(id: oldSection, title: "2023年12月31日", items: original)]
        coordinator.update(value(sections, 2), in: view)
        verify(anchor, "prepend during rotation")
        view.frame = originalFrame
        view.layoutIfNeeded()
        verify(anchor, "return portrait after prepend")
        await Task.yield()
        verify(anchor, "subsequent layout")
        coordinator.scrollViewWillBeginDragging(view)
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
        coordinator.scrollViewWillBeginDragging(view)
        view.setContentOffset(CGPoint(x: 0, y: view.contentOffset.y + 400), animated: false)
        let afterReturn = coordinator.anchor(in: view)!
        coordinator.update(value(returnSections, 6, returnJump), in: view)
        verify(afterReturn, "thumbnail update cannot reapply return")
        coordinator.update(value(returnSections, 7, returnJump), in: view)
        verify(afterReturn, "content update cannot reapply return")
        coordinator.update(value(secondSections, 8, returnJump), in: view)
        verify(afterReturn, "prepend after return keeps user viewport")
        // 前後100件のwindowで、対象日の枚数に関係なく見出しと先頭セルを表示する。
        for count in [1, 4, 5, 8, 9, 10, 101] {
            func datedItems(_ range: Range<Int>, _ day: String) -> [TimelineItem] {
                items(range).map { item in
                    let date = TimelineDate(calendarDateTime: day + "T12:00:00", recordedOffset: nil, kind: .provisional, source: nil, quality: nil)
                    return TimelineItem(id: item.id, libraryID: library, relativePath: item.relativePath,
                                        mediaType: item.mediaType, fileExtension: item.fileExtension, generation: item.generation,
                                        date: date, sortKey: date.sortKey(id: item.id), metadataState: nil, metadataIsCurrent: false)
                }
            }
            let before = datedItems(2000..<(2101 - count), "2024-01-02")
            let target = datedItems(3000..<(3000 + count), "2024-01-01")
            let after = datedItems(4000..<4100, "2023-12-31")
            let windowItems = before + target + after
            let monthSource = TimelinePageSource(prepare: { library },
                                                page: { _, _ in fatalError("unexpected older load near jump") },
                                                monthPage: { _, _ in
                TimelinePage(items: windowItems, next: nil, revision: 1,
                             initialAnchorID: target.last!.id, newerNext: nil)
            })
            let monthModel = TimelineController(source: monthSource)
            await monthModel.jump(to: TimelineMonth(year: 2024, month: 1))
            let monthView = TimelineGridView(model: monthModel, thumbnails: session,
                                            sections: monthModel.blocks.map { .init(id: $0.id, title: monthModel.heading(for: $0), items: $0.items) },
                                            contentVersion: monthModel.contentVersion, jumpID: monthModel.displayGeneration,
                                            footer: AnyView(Text("test")), footerHeight: 60, select: { _ in }, inspect: { _ in })
            coordinator.update(monthView, in: view)
            view.layoutIfNeeded()
            let targetPath = coordinator.dataSource.indexPath(for: target.first!.id)!
            let header = view.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                                                                      at: IndexPath(item: 0, section: targetPath.section))!
            precondition(abs(header.frame.minY - view.contentOffset.y - view.adjustedContentInset.top) < 1, "month day header aligns to top: \(count)")
            precondition(view.indexPathsForVisibleItems.contains(targetPath), "first media of day visible: \(count)")
            precondition(coordinator.dataSource.snapshot().numberOfItems == 201, "both sides installed together")
            let portraitFrame = view.frame
            for cycle in 1...3 {
                view.frame.size = CGSize(width: 932, height: 350)
                view.layoutIfNeeded()
                view.frame = portraitFrame
                view.layoutIfNeeded()
                let restored = view.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                                                                            at: IndexPath(item: 0, section: targetPath.section))!
                precondition(abs(restored.frame.minY - view.contentOffset.y - view.adjustedContentInset.top) < 1,
                             "month header survives rotation \(cycle), count \(count)")
            }
            await Task.yield()
            for delta in [-80.0, 160.0] {
                coordinator.scrollViewWillBeginDragging(view)
                view.setContentOffset(CGPoint(x: 0, y: view.contentOffset.y + delta), animated: false)
                let offset = view.contentOffset
                coordinator.update(monthView, in: view)
                await Task.yield()
                precondition(view.contentOffset == offset && monthModel.loadedCount == 201, "nearby scrolling does not reapply jump or add pages")
            }
        }
        print("PASS: month jump day header and first media visible for 1, 4, 5, 8, 9, 10, 101 items; nearby scrolling stays stable")
        print("PASS: viewer return visible, consumed once, month observation, no snap back on content or prepend")
        print("PASS: UIKit measured anchor survives 200-item prepend, day boundary, second prepend after user scrolling, repeat layout, unchanged snapshot, revision rebase; explicit jump consumed once")
        fflush(stdout)
        exit(0)
    }
}
