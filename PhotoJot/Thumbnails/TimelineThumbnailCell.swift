import SwiftUI

struct TimelineThumbnailCell: View {
    let item: TimelineItem
    let session: ThumbnailSession
    @State private var accepted: Accepted?
    private struct Accepted {
        let request: RequestID
        let key: ThumbnailKey
    }
    private struct RequestID: Equatable {
        let generation: UUID
        let revision: Int
    }
    private var isVideo: Bool { item.mediaType == "video" }
    private var request: RequestID { RequestID(generation: item.generation, revision: session.revision) }
    private var image: CGImage? {
        guard let accepted, accepted.request == request else { return nil }
        return session.cachedImage(for: accepted.key)
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
                accepted = Accepted(request: requested, key: key)
            } catch is CancellationError {
                // 画面外へ出ても採用済みキーは残す。画像の保持／退避はNSCacheへ任せる。
            } catch { if !Task.isCancelled { accepted = nil } }
        }
    }
}
