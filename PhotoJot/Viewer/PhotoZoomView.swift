import SwiftUI
import UIKit

// The logical image rectangle never depends on the replacement CGImage's pixel count.
struct PhotoZoomView: UIViewRepresentable {
    let state: PhotoZoomState
    let epoch: UUID
    let image: CGImage
    let refined: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIScrollView {
        let view = PhotoZoomScrollView()
        view.minimumZoomScale = 1; view.maximumZoomScale = PhotoZoomState.maximumScale
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.delegate = context.coordinator
        view.addSubview(context.coordinator.imageView)
        view.didLayout = { [weak coordinator = context.coordinator] view in coordinator?.update(view) }
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PhotoZoomView
        let imageView = UIImageView()
        private var extent = CGSize.zero
        private var applying = false
        init(_ parent: PhotoZoomView) { self.parent = parent; imageView.contentMode = .scaleAspectFit }
        private var current: Bool { parent.epoch == parent.state.epoch }

        func update(_ view: UIScrollView) {
            guard !applying, current else { return }
            applying = true
            defer { applying = false }
            // UIImage orientation changes presentation only; the decoded pixels stay shared.
            let orientation: UIImage.Orientation = [.up, .right, .down, .left][parent.state.quarterTurns]
            if imageView.image?.cgImage !== parent.image || imageView.image?.imageOrientation != orientation {
                imageView.image = UIImage(cgImage: parent.image, scale: 1, orientation: orientation)
            }
            guard !view.isZooming, !view.isDragging, !view.isDecelerating else { return }
            let ratio = parent.state.displayedAspectRatio
            let width = min(view.bounds.width, view.bounds.height * ratio)
            guard width > 0 else { return }
            let target = CGSize(width: width, height: width / ratio)
            if extent != target {
                view.setZoomScale(1, animated: false)
                extent = target
                imageView.frame = CGRect(origin: .zero, size: target)
                view.contentSize = target
            }
            view.setZoomScale(parent.state.scale, animated: false)
            center(view)
            view.contentOffset = parent.state.scale > 1.001 ? parent.state.offset : CGPoint(x: -view.contentInset.left, y: -view.contentInset.top)
            view.panGestureRecognizer.isEnabled = parent.state.scale > 1.001
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        private func center(_ view: UIScrollView) {
            let x = max(0, (view.bounds.width - view.contentSize.width) / 2)
            let y = max(0, (view.bounds.height - view.contentSize.height) / 2)
            view.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            guard !applying, current else { return }
            parent.state.pinching = true
            scrollView.panGestureRecognizer.isEnabled = true
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !applying, current else { return }
            applying = true; center(scrollView); applying = false
            record(scrollView)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { record(scrollView) }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard !applying, current else { return }
            parent.state.pinching = false
            scrollView.panGestureRecognizer.isEnabled = scale > 1.001
            record(scrollView)
            parent.refined(min(PhotoZoomState.maximumScale, max(1, scale)))
        }
        private func record(_ view: UIScrollView) {
            guard !applying, current else { return }
            parent.state.scale = view.zoomScale; parent.state.offset = view.contentOffset
        }
    }
}

private final class PhotoZoomScrollView: UIScrollView {
    var didLayout: ((UIScrollView) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); didLayout?(self) }
}
