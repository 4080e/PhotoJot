import Foundation
import CoreGraphics
import Observation

@MainActor @Observable final class PhotoZoomState {
    static let maximumScale: CGFloat = 3
    private(set) var epoch = UUID()
    private(set) var quarterTurns = 0
    var aspectRatio: CGFloat = 1
    var displayedAspectRatio: CGFloat { quarterTurns.isMultiple(of: 2) ? aspectRatio : 1 / aspectRatio }
    var scale: CGFloat = 1
    var offset: CGPoint = .zero
    var pinching = false
    var pagingEnabled: Bool { !pinching && scale <= 1.001 }
    func rotateRight() {
        let next = (quarterTurns + 1) % 4
        reset()
        quarterTurns = next
    }
    func reset() { epoch = UUID(); scale = 1; offset = .zero; pinching = false; quarterTurns = 0 }
}

// Only one current-photo decode and one latest pending resolution. No NAS dependencies.
@MainActor @Observable final class PhotoResolution {
    private(set) var image: CGImage?
    let zoom = PhotoZoomState()
    @ObservationIgnored private var original: PhotoOriginal?
    @ObservationIgnored private var accepting = false
    @ObservationIgnored private var edge = 0
    @ObservationIgnored private var requestedEdge: Int?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var isCurrent: @Sendable () async throws -> Bool = { false }
    @ObservationIgnored private let decode: @Sendable (URL, Int) async throws -> CGImage

    init(decode: @escaping @Sendable (URL, Int) async throws -> CGImage = { url, edge in
        let task = Task.detached { try Task.checkCancellation(); return try FullPhotoImages.decode(url, maximumPixelSize: edge) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }) { self.decode = decode }

    func install(_ photo: LoadedPhoto, isCurrent: @escaping @Sendable () async throws -> Bool) {
        precondition(original == nil && work == nil)
        accepting = true
        original = photo.original; image = photo.image
        edge = max(photo.image.width, photo.image.height); self.isCurrent = isCurrent
        zoom.reset()
        zoom.aspectRatio = CGFloat(photo.image.width) / CGFloat(photo.image.height)
    }

    static func requestedSize(displayEdge: Int, originalEdge: Int, scale: CGFloat) -> Int {
        let scale = scale.isFinite ? min(max(scale, 1), PhotoZoomState.maximumScale) : 1
        return min(originalEdge, max(1, Int(ceil(Double(displayEdge) * Double(scale)))))
    }

    // Called when a pinch finishes, not on every pinch frame.
    func request(scale: CGFloat) {
        guard accepting, let original else { return }
        let needed = Self.requestedSize(displayEdge: original.displayEdge, originalEdge: original.originalEdge, scale: scale)
        requestedEdge = needed > edge ? needed : nil
        guard work == nil, requestedEdge != nil else { return }
        work = Task {
            defer { work = nil }
            while !Task.isCancelled, let target = requestedEdge {
                do {
                    guard try await isCurrent() else { requestedEdge = nil; return }
                    try Task.checkCancellation()
                    let decoded = try await decode(original.url, target)
                    try Task.checkCancellation()
                    guard try await isCurrent() else { requestedEdge = nil; return }
                    try Task.checkCancellation()
                    // A later pinch may have replaced the target while ImageIO was busy.
                    guard requestedEdge == target else { continue }
                    image = decoded; edge = max(decoded.width, decoded.height); requestedEdge = nil
                } catch {
                    // Refinement failure never replaces a usable image with an error screen.
                    if requestedEdge == target { requestedEdge = nil }
                }
            }
        }
    }
    func cancel() { accepting = false; requestedEdge = nil; work?.cancel(); zoom.reset() }
    func clear() async {
        cancel()
        await work?.value
        work = nil; image = nil; original?.remove(); original = nil; edge = 0
        isCurrent = { false }
    }
    func waitForDecode() async { await work?.value }
}
