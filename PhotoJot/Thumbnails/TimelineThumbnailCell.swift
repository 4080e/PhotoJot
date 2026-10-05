import SwiftUI

struct TimelineThumbnailCell: View {
    let item: TimelineItem
    let session: ThumbnailSession
    @State private var accepted: Accepted?
    private struct Accepted {
        let request: RequestID
        let key: ThumbnailKey
        let image: CGImage
    }
    private struct RequestID: Equatable {
        let key: ThumbnailKey
        let revision: Int
    }
    init(item: TimelineItem, session: ThumbnailSession) {
        self.item = item
        self.session = session
        let key = ThumbnailSession.placeholderKey(for: item)
        let initial = session.cachedImage(for: key).map {
            Accepted(request: RequestID(key: key, revision: session.revision), key: key, image: $0)
        }
        _accepted = State(initialValue: initial)
    }
    private var isVideo: Bool { item.mediaType == "video" }
    private var request: RequestID {
        RequestID(key: ThumbnailSession.placeholderKey(for: item), revision: session.revision)
    }
    private var image: CGImage? {
        // revision restarts validation; it does not invalidate an already displayed image.
        // Keep the source identity separate from the resolved key: the repository may
        // resolve a newer generation than the currently loaded TimelineItem.
        guard let accepted, accepted.request.key == request.key else { return nil }
        return accepted.image
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                Image(systemName: isVideo ? "video.fill" : "photo").font(.title2).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if isVideo, image != nil {
                Image(systemName: "video.fill")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(isVideo ? "動画" : "写真")
        .task(id: request) {
            let requested = request
            do {
                let key = try await session.imageKey(id: item.id, libraryID: item.libraryID)
                try Task.checkCancellation()
                guard let key else {
                    accepted = nil
                    return
                }
                if let image = session.cachedImage(for: key) {
                    accepted = Accepted(request: requested, key: key, image: image)
                } else if accepted?.key != key {
                    accepted = nil
                }
            } catch is CancellationError {
                // 再確認の中断では表示済み画像を消さない。保持はこのセルの生存期間だけ。
            } catch { if !Task.isCancelled { accepted = nil } }
        }
    }
}
