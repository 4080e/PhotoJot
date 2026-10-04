import UIKit

// Presentation only: cancelled drags never stop media work or close the session.
@MainActor final class ViewerDismissGesture: NSObject, UIGestureRecognizerDelegate {
    enum Phase { case idle, dragging, restoring, finishing }
    private(set) var phase: Phase = .idle
    var isBusy: Bool { phase != .idle }
    weak var view: UICollectionView?
    var canBegin: () -> Bool = { false }
    var pagingEnabled: () -> Bool = { true }
    var isVideo: () -> Bool = { false }
    var progress: (CGFloat, Bool) -> Void = { _, _ in }
    var completed: () -> Void = {}
    var restored: () -> Void = {}
    private var animator: UIViewPropertyAnimator?
    private var revision = 0
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))

    func install(on view: UICollectionView) {
        self.view = view
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        view.panGestureRecognizer.require(toFail: pan)
        // Cancel the visual interaction before background cleanup. This also safely
        // restores it when Control Center or another transient interruption appears.
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
    }
    static func downward(_ velocity: CGPoint) -> Bool {
        velocity.y > 0 && velocity.y > abs(velocity.x) * 1.5
    }
    static func finishes(distance: CGFloat, velocity: CGPoint, height: CGFloat) -> Bool {
        guard height > 0, distance > 0, velocity.y >= 0 else { return false }
        return distance >= height * 0.25 || (distance >= 44 && velocity.y >= 900 && downward(velocity))
    }
    static func isControl(_ touched: UIView?, within root: UIView) -> Bool {
        var view = touched
        while let current = view, current !== root {
            if current is UIControl || current.accessibilityTraits.contains(.adjustable) || current.accessibilityTraits.contains(.button) || current.accessibilityTraits.contains(.link) { return true }
            view = current.superview
        }
        return false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        return !Self.isControl(touch.view, within: view)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, phase == .idle, canBegin(), !view.isDecelerating,
              view.panGestureRecognizer.state != .began, view.panGestureRecognizer.state != .changed,
              pan.numberOfTouches == 1 else { return false }
        return Self.downward(pan.velocity(in: view.superview))
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        // Give public player gestures first refusal; do not inspect private AVKit views.
        guard isVideo(), let view, other !== view.panGestureRecognizer,
              other !== pan, let otherView = other.view else { return false }
        return otherView !== view && otherView.isDescendant(of: view)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        guard let view else { return }
        let translation = pan.translation(in: view.superview)
        switch pan.state {
        case .began: begin()
        case .changed:
            guard canBegin(), pan.numberOfTouches == 1 else { cancel(animated: true); return }
            move(to: translation.y)
        case .ended:
            guard phase == .dragging else { return }
            let finish = Self.finishes(distance: max(0, translation.y), velocity: pan.velocity(in: view.superview), height: view.bounds.height)
            finish ? finishDrag() : cancel(animated: true)
        case .cancelled, .failed:
            if phase == .dragging { cancel(animated: true) }
        default: break
        }
    }
    func begin() {
        guard phase == .idle, canBegin(), let view else { return }
        phase = .dragging
        view.isScrollEnabled = false
    }
    func move(to distance: CGFloat) {
        guard phase == .dragging, let view else { return }
        let distance = max(0, distance)
        view.transform = CGAffineTransform(translationX: 0, y: distance)
        progress(min(1, distance / max(1, view.bounds.height)), false)
    }
    func finishDrag() {
        guard phase == .dragging, let view else { return }
        phase = .finishing
        animate { view.transform = CGAffineTransform(translationX: 0, y: view.bounds.height); self.progress(1, true) } completion: {
            self.completed()
        }
    }
    func cancel(animated: Bool) {
        guard phase != .idle else { return }
        revision += 1; animator?.stopAnimation(true); animator = nil
        phase = .restoring
        let reset = { self.view?.transform = .identity; self.progress(0, animated) }
        let done = {
            self.phase = .idle
            self.view?.isScrollEnabled = self.pagingEnabled()
            self.restored()
        }
        if animated { animate(reset, completion: done) }
        else { reset(); done() }
    }
    private func animate(_ changes: @escaping () -> Void, completion: @escaping () -> Void) {
        revision += 1
        let token = revision
        let animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeOut, animations: changes)
        self.animator = animator
        animator.addCompletion { [weak self] position in
            guard let self, self.revision == token, position == .end else { return }
            self.animator = nil; completion()
        }
        animator.startAnimation()
    }
    @objc private func interrupted() {
        cancel(animated: false)
        pan.isEnabled = false; pan.isEnabled = true
    }
    func detach() {
        revision += 1; animator?.stopAnimation(true); animator = nil
        view?.transform = .identity
        view?.removeGestureRecognizer(pan)
        NotificationCenter.default.removeObserver(self)
        phase = .idle
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
