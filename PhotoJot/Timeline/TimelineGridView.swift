import SwiftUI
import UIKit

struct TimelineGridSection {
    let id: UUID
    let title: String
    let items: [TimelineItem]
}

// セルの実測座標で位置を維持する標準CollectionView。画像は既存SwiftUIセルをそのまま使う。
struct TimelineGridView: UIViewRepresentable {
    let model: TimelineController
    let thumbnails: ThumbnailSession
    let sections: [TimelineGridSection]
    let contentVersion: Int
    let jumpID: UUID
    var scrollRequest: TimelineScrollRequest? = nil
    let footer: AnyView
    let footerHeight: CGFloat
    let select: (TimelineItem) -> Void
    let inspect: (TimelineItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        context.coordinator.install(view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(self, in: view)
    }

    final class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
        var parent: TimelineGridView
        var dataSource: UICollectionViewDiffableDataSource<UUID, UUID>!
        var items: [UUID: TimelineItem] = [:]
        var titles: [UUID: String] = [:]
        var appliedVersion: Int?
        var consumedJumpID: UUID?
        var consumedReturnID: UUID?
        var applying = false
        var lastOffset: CGFloat = 0
        private var reportedMonth: TimelineMonth?
        private var titleTask: Task<Void, Never>?
        init(_ parent: TimelineGridView) { self.parent = parent }

        func install(_ view: UICollectionView) {
            let cell = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
                guard let self, let item = self.items[id] else { return }
                cell.contentConfiguration = UIHostingConfiguration {
                    TimelineThumbnailCell(item: item, session: self.parent.thumbnails).id(item.id)
                }.margins(.all, 0)
            }
            view.register(TimelineSupplement.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
            view.register(TimelineSupplement.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "footer")
            dataSource = UICollectionViewDiffableDataSource<UUID, UUID>(collectionView: view) { view, path, id in
                view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
            }
            dataSource.supplementaryViewProvider = { [weak self] view, kind, path in
                guard let self else { return nil }
                let header = kind == UICollectionView.elementKindSectionHeader
                let supplement = view.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: header ? "header" : "footer", for: path) as! TimelineSupplement
                if header, let id = self.dataSource.sectionIdentifier(for: path.section) {
                    supplement.show(AnyView(Text(self.titles[id] ?? "").font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                        .accessibilityAddTraits(.isHeader)))
                } else { supplement.show(self.parent.footer) }
                return supplement
            }
        }

        // 取得を開始した時点ではなく、snapshot反映の直前に現在の可視セルを計測する。
        func anchor(in view: UICollectionView) -> TimelineViewportAnchor? {
            let top = view.contentOffset.y + view.adjustedContentInset.top
            let paths = view.indexPathsForVisibleItems.sorted()
            for path in paths {
                guard let frame = view.layoutAttributesForItem(at: path)?.frame, frame.maxY > top,
                      let id = dataSource.itemIdentifier(for: path) else { continue }
                return TimelineViewportAnchor(id: id, distanceFromTop: Double(frame.minY - top))
            }
            return nil
        }

        func update(_ value: TimelineGridView, in view: UICollectionView) {
            parent = value
            // サムネイル完了やloading表示変更はsnapshot／位置指定を発行しない。
            for supplement in view.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
                (supplement as? TimelineSupplement)?.show(value.footer)
            }
            guard appliedVersion != value.contentVersion || consumedJumpID != value.jumpID else {
                applyReturnRequest(in: view)
                return
            }
            guard !applying else { return }
            view.layoutIfNeeded()
            let jump = consumedJumpID != value.jumpID
            let saved = jump ? nil : anchor(in: view)
            let oldItems = items
            items = Dictionary(uniqueKeysWithValues: value.sections.flatMap(\.items).map { ($0.id, $0) })
            titles = Dictionary(uniqueKeysWithValues: value.sections.map { ($0.id, $0.title) })
            var snapshot = NSDiffableDataSourceSnapshot<UUID, UUID>()
            for section in value.sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { oldItems[$0] != nil && oldItems[$0] != items[$0] })
            appliedVersion = value.contentVersion
            consumedJumpID = value.jumpID
            applying = true
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                view.layoutIfNeeded()
                if jump {
                    view.setContentOffset(CGPoint(x: view.contentOffset.x, y: -view.adjustedContentInset.top), animated: false)
                } else if let saved {
                    // 削除された基準entryは、新しいwindowの先頭へ自然に引き継ぐ。
                    let id = items[saved.id] == nil ? snapshot.itemIdentifiers.first : saved.id
                    if let id, let path = dataSource.indexPath(for: id), let frame = view.layoutAttributesForItem(at: path)?.frame {
                        let proposed = saved.contentOffset(itemMinY: Double(frame.minY), topInset: Double(view.adjustedContentInset.top))
                        let maximum = max(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
                        let offset = min(max(CGFloat(proposed), -view.adjustedContentInset.top), maximum)
                        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: offset), animated: false)
                    }
                }
            }
            applying = false
            lastOffset = view.contentOffset.y
            recordViewport(view)
            applyReturnRequest(in: view)
        }

        private func applyReturnRequest(in view: UICollectionView) {
            guard !applying, let request = parent.scrollRequest,
                  consumedReturnID != request.id,
                  let path = dataSource.indexPath(for: request.mediaID) else { return }
            consumedReturnID = request.id
            applying = true
            view.layoutIfNeeded()
            view.scrollToItem(at: path, at: .centeredVertically, animated: false)
            view.layoutIfNeeded()
            applying = false
            lastOffset = view.contentOffset.y
            recordViewport(view)
            let model = parent.model
            Task { @MainActor in model.consumeScrollRequest(request.id) }
        }

        func recordViewport(_ view: UICollectionView) {
            let id = anchor(in: view)?.id
            parent.model.visibleItemID = id
            guard let id, let month = items[id]?.date.month, month != reportedMonth else { return }
            reportedMonth = month
            titleTask?.cancel()
            let model = parent.model
            // updateUIView内のlayoutからも呼ばれるため、表示状態の更新を次のMainActor処理へ渡す。
            titleTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                model.updateDisplayedMonth(month)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UICollectionView, !applying else { return }
            let upward = view.contentOffset.y < lastOffset
            lastOffset = view.contentOffset.y
            recordViewport(view)
            guard view.isDragging || view.isDecelerating else { return }
            if upward, let id = parent.model.visibleItemID {
                Task { await parent.model.loadNewerIfNeeded(visibleID: id) }
            }
            if let path = view.indexPathsForVisibleItems.max(), let id = dataSource.itemIdentifier(for: path) {
                Task { await parent.model.loadMoreIfNeeded(visibleID: id) }
            }
        }

        func collectionView(_ view: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt path: IndexPath) {
            guard let id = dataSource.itemIdentifier(for: path) else { return }
            Task {
                recordViewport(view)
                await parent.model.loadMoreIfNeeded(visibleID: id)
            }
        }

        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            if let id = dataSource.itemIdentifier(for: path), let item = items[id] { parent.select(item) }
        }

        #if DEBUG
        func collectionView(_ view: UICollectionView, contextMenuConfigurationForItemAt path: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let id = dataSource.itemIdentifier(for: path), let item = items[id] else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [UIAction(title: "開発用情報") { _ in self?.parent.inspect(item) }])
            }
        }
        #endif

        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt path: IndexPath) -> CGSize {
            guard let flow = layout as? UICollectionViewFlowLayout else { return .zero }
            let spacing = flow.minimumInteritemSpacing
            let available = max(1, view.bounds.width - view.adjustedContentInset.left - view.adjustedContentInset.right
                                - flow.sectionInset.left - flow.sectionInset.right)
            let columns = max(1, floor((available + spacing) / (88 + spacing)))
            let side = floor((available - (columns - 1) * spacing) / columns)
            return CGSize(width: side, height: side)
        }
        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
            CGSize(width: view.bounds.width, height: UIFont.preferredFont(forTextStyle: .headline).lineHeight + 24)
        }
        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
            CGSize(width: view.bounds.width, height: section == parent.sections.count - 1 ? parent.footerHeight : 0)
        }
    }
}

// bounds変更の通知時点では古い幅／insetが使われることがあるため、実際のlayout時に確認する。
final class TimelineCollectionView: UICollectionView {
    private struct Metrics: Equatable {
        let width: CGFloat
        let leftInset: CGFloat
        let rightInset: CGFloat
        let sectionInset: UIEdgeInsets
        let interitemSpacing: CGFloat
        let lineSpacing: CGFloat
    }
    private var lastMetrics: Metrics?

    override func layoutSubviews() {
        invalidateMetricsIfNeeded()
        super.layoutSubviews()
        // super内でsafe area由来のadjustedContentInsetが更新された場合も最新値へ収束させる。
        if invalidateMetricsIfNeeded() { super.layoutSubviews() }
    }

    @discardableResult
    private func invalidateMetricsIfNeeded() -> Bool {
        guard let flow = collectionViewLayout as? UICollectionViewFlowLayout else { return false }
        let metrics = Metrics(width: bounds.width, leftInset: adjustedContentInset.left,
                              rightInset: adjustedContentInset.right, sectionInset: flow.sectionInset,
                              interitemSpacing: flow.minimumInteritemSpacing, lineSpacing: flow.minimumLineSpacing)
        guard metrics != lastMetrics else { return false }
        lastMetrics = metrics
        let context = UICollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        context.invalidateFlowLayoutAttributes = true
        flow.invalidateLayout(with: context)
        return true
    }
}

private final class TimelineSupplement: UICollectionReusableView {
    private var hosted: UIView?
    func show(_ content: AnyView) {
        hosted?.removeFromSuperview()
        let view = UIHostingConfiguration { content }.margins(.all, 0).makeContentView()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hosted = view
    }
}
