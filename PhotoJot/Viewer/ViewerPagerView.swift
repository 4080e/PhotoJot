import SwiftUI
import AVKit

// UIKit owns the swipe gesture and settles one full-width page at a time.
// Neighbour cells never start media work; the shared controller serves only the committed page.
struct ViewerPagerView: UIViewControllerRepresentable {
    let session: ViewerSession
    let model: MediaViewerController
    let viewport: FullPhotoViewport
    let thumbnails: ThumbnailSession
    var dismissProgress: (CGFloat, Bool) -> Void = { _, _ in }
    var dismissRequested: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController {
        let owner = ViewerPagerContainerController()
        context.coordinator.owner = owner
        let layout = ViewerPageLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = ViewerCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.semanticContentAttribute = .forceLeftToRight
        view.register(ViewerPageCell.self, forCellWithReuseIdentifier: "media")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.didLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator else { return }
            coordinator.update(view, items: coordinator.parent.session.items)
        }
        owner.install(view)
        context.coordinator.installDismiss(on: view)
        return owner
    }
    func updateUIViewController(_ owner: UIViewController, context: Context) {
        guard let view = (owner as? ViewerPagerContainerController)?.collectionView else { return }
        context.coordinator.parent = self
        view.isScrollEnabled = model.photo.zoom.pagingEnabled && !context.coordinator.dismissGesture.isBusy
        // Observe the window here, rather than only inside the UIKit data source.
        context.coordinator.update(view, items: session.items)
    }

    static func dismantleUIViewController(_ owner: UIViewController, coordinator: Coordinator) {
        coordinator.dismissGesture.detach()
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: ViewerPagerView
        weak var owner: UIViewController?
        let dismissGesture = ViewerDismissGesture()
        private var rendered: [TimelineItem] = []
        private var size: CGSize = .zero
        private var applying = false
        init(_ parent: ViewerPagerView) { self.parent = parent }

        func installDismiss(on view: UICollectionView) {
            dismissGesture.canBegin = { [weak self] in
                guard let self else { return false }
                return !self.parent.session.isClosed && !self.parent.model.isClosing && self.parent.model.photo.zoom.pagingEnabled
            }
            dismissGesture.pagingEnabled = { [weak self] in self?.parent.model.photo.zoom.pagingEnabled ?? false }
            dismissGesture.isVideo = { [weak self] in self?.parent.session.currentItem.mediaType == "video" }
            dismissGesture.progress = { [weak self] value, animated in self?.parent.dismissProgress(value, animated) }
            dismissGesture.completed = { [weak self] in self?.parent.dismissRequested() }
            dismissGesture.restored = { [weak self, weak view] in
                guard let self, let view else { return }
                self.update(view, items: self.parent.session.items)
            }
            dismissGesture.install(on: view)
        }

        func update(_ view: UICollectionView, items: [TimelineItem]) {
            // A window rebase/prepend must not change the page underneath an unfinished swipe.
            guard !applying else { return }
            view.isScrollEnabled = parent.model.photo.zoom.pagingEnabled && !dismissGesture.isBusy
            guard !dismissGesture.isBusy, !view.isTracking, !view.isDragging, !view.isDecelerating, !parent.model.photo.zoom.pinching else { return }
            let nextSize = view.bounds.size
            guard nextSize.width > 0, nextSize.height > 0 else { return }
            guard rendered != items || size != nextSize else { return }
            applying = true
            defer { applying = false }
            size = nextSize
            rendered = items
            (view.collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize = size
            view.reloadData()
            view.layoutIfNeeded()
            if let index = rendered.firstIndex(where: { $0.id == parent.session.currentItem.id }) {
                view.setContentOffset(CGPoint(x: CGFloat(index) * size.width, y: 0), animated: false)
            }
        }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rendered.count }
        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! ViewerPageCell
            configure(cell, at: indexPath)
            return cell
        }
        private func configure(_ cell: ViewerPageCell, at indexPath: IndexPath) {
            guard let owner, rendered.indices.contains(indexPath.item) else { return }
            cell.show(AnyView(ViewerMediaPage(item: rendered[indexPath.item], session: parent.session,
                                             model: parent.model, viewport: parent.viewport, thumbnails: parent.thumbnails)), in: owner)
        }
        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            if let cell = cell as? ViewerPageCell { configure(cell, at: indexPath) }
        }
        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            (cell as? ViewerPageCell)?.clear()
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(scrollView) }
        }
        private func settle(_ scrollView: UIScrollView) {
            guard !dismissGesture.isBusy, !parent.session.isClosed, let view = scrollView as? UICollectionView, size.width > 0, !rendered.isEmpty else { return }
            let index = min(rendered.count - 1, max(0, Int((view.contentOffset.x / size.width).rounded())))
            parent.session.commit(rendered[index])
            parent.model.select(item: parent.session.currentItem, viewport: parent.viewport)
            update(view, items: parent.session.items)
        }
    }
}

private struct ViewerMediaPage: View {
    let item: TimelineItem
    let session: ViewerSession
    let model: MediaViewerController
    let viewport: FullPhotoViewport
    let thumbnails: ThumbnailSession
    var body: some View {
        ZStack {
            Color.clear
            if item.id != session.currentItem.id || item.generation != session.currentItem.generation {
                placeholder(loading: false)
            } else if model.showsLoading || model.activeItem?.id != item.id || model.activeItem?.generation != item.generation {
                placeholder(loading: true)
            } else if let player = model.player {
                VideoPlayer(player: player)
            } else if let image = model.image {
                PhotoZoomView(state: model.photo.zoom, epoch: model.photo.zoom.epoch, image: image) {
                    model.photo.request(scale: $0)
                }
            } else if let message = model.message {
                ContentUnavailableView {
                    Label("表示できません", systemImage: "exclamationmark.triangle")
                } description: { Text(message) } actions: {
                    Button("再読み込み") { model.select(item: session.currentItem, viewport: viewport, force: true) }
                        .disabled(model.isClosing)
                }
            } else { placeholder(loading: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func placeholder(loading: Bool) -> some View {
        let key = ThumbnailSession.placeholderKey(for: item)
        return ViewerCachedThumbnail(key: key, thumbnails: thumbnails, video: item.mediaType == "video", loading: loading,
                                     retainedImage: model.previewKey == key ? model.previewImage : nil)
            .id(key)
    }
}

private struct ViewerCachedThumbnail: View {
    let key: ThumbnailKey
    let thumbnails: ThumbnailSession
    let video: Bool
    let loading: Bool
    let retainedImage: CGImage?
    @State private var image: CGImage?

    init(key: ThumbnailKey, thumbnails: ThumbnailSession, video: Bool, loading: Bool, retainedImage: CGImage? = nil) {
        self.key = key; self.thumbnails = thumbnails; self.video = video; self.loading = loading
        self.retainedImage = retainedImage
        // 同じキーのdecode済み画像なら初回描画から利用する。
        _image = State(initialValue: thumbnails.cachedImage(for: key))
    }
    var body: some View {
        Group {
            if let image = retainedImage ?? image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .overlay {
                        if loading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                                .padding(8)
                                .background(.black.opacity(0.45), in: Circle())
                                .allowsHitTesting(false)
                        }
                    }
            } else if loading { ProgressView("読み込み中…") }
            else { Image(systemName: video ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: thumbnails.revision) {
            do {
                let result = try await thumbnails.cachedImageOnly(for: key)
                try Task.checkCancellation()
                image = result
            } catch {
                if !Task.isCancelled { image = nil }
            }
        }
    }
}

// Size pages from UIKit's actual bounds, including initial layout and changes in the information footer.
// This avoids applying pixel dimensions or a previous-height layout during rotation.
class ViewerCollectionView: UICollectionView {
    var didLayout: ((UICollectionView) -> Void)?
    override func layoutSubviews() {
        if bounds.width > 0, bounds.height > 0,
           let layout = collectionViewLayout as? UICollectionViewFlowLayout, layout.itemSize != bounds.size {
            layout.itemSize = bounds.size
        }
        super.layoutSubviews()
        didLayout?(self)
    }
}

final class ViewerPageLayout: UICollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if collectionView?.bounds.size != newBounds.size {
            (context as? UICollectionViewFlowLayoutInvalidationContext)?.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}

// VideoPlayer requires a real controller hierarchy. UIHostingConfiguration cannot host it.
// These controllers own only presentation; MediaViewerController owns playback and SMB cleanup.
final class ViewerPageCell: UICollectionViewCell {
    private var host: UIHostingController<AnyView>?
    func show(_ content: AnyView, in owner: UIViewController) {
        if let host { host.rootView = content; return }
        let host = UIHostingController(rootView: content)
        self.host = host
        owner.addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = contentView.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(host.view)
        host.didMove(toParent: owner)
    }
    func clear() {
        guard let host else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        self.host = nil
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }
}

// SwiftUI owns the representable root's frame. Keep the transformed media view
// below that boundary so progress-driven SwiftUI layout cannot counteract its translation.
final class ViewerPagerContainerController: UIViewController {
    private(set) var collectionView: UICollectionView?
    func install(_ collectionView: UICollectionView) {
        loadViewIfNeeded()
        view.backgroundColor = .clear
        self.collectionView = collectionView
        view.addSubview(collectionView)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let collectionView else { return }
        // Do not assign frame while transform is nonidentity: preserve translation
        // and lay out the untransformed geometry explicitly.
        collectionView.bounds.size = view.bounds.size
        collectionView.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }
}
