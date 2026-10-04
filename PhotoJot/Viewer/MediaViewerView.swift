import SwiftUI
import AVKit

struct MediaViewerView: View {
    @State private var session: ViewerSession
    let thumbnails: ThumbnailSession
    let model: MediaViewerController
    let onClose: (TimelineItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @ScaledMetric(relativeTo: .footnote) private var informationMaximumHeight = 104.0
    @State private var informationContentHeight: CGFloat = 0
    init(item: TimelineItem, model: MediaViewerController, repository: TimelineRepository, thumbnails: ThumbnailSession, onClose: @escaping (TimelineItem) -> Void) {
        self.thumbnails = thumbnails
        self.model = model
        self.onClose = onClose
        let source = TimelinePageSource(prepare: { item.libraryID },
                                        page: { try await repository.page(libraryID: $0, after: $1) },
                                        newerPage: { try await repository.newerPage(libraryID: $0, before: $1) },
                                        anchorPage: { try await repository.page(libraryID: $0, around: $1) })
        _session = State(initialValue: ViewerSession(item: item, source: source))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let viewport = FullPhotoViewport(width: geometry.size.width, height: geometry.size.height, scale: scale)
                ViewerPagerView(session: session, model: model, viewport: viewport, thumbnails: thumbnails)
                    .onChange(of: session.currentItem, initial: true) { _, item in
                        model.select(item: item, viewport: viewport)
                    }
                    .onChange(of: geometry.size) { _, _ in
                        model.select(item: session.currentItem, viewport: viewport)
                    }
                    .overlay(alignment: .top) {
                        if let message = session.errorMessage {
                            VStack {
                                Text(message)
                                Button("再試行") { session.retry() }
                            }.font(.footnote).padding().background(.bar)
                        }
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                information
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        let lastItem = session.close()
                        Task { await model.stop(); onClose(lastItem); dismiss() }
                    }.disabled(model.isClosing)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task { session.begin() }
        .onDisappear {
            session.close()
            model.cancelAutomaticResume()
            Task { await model.stop() }
        }
    }

    private var information: some View {
        let item = session.currentItem
        let value = MediaViewerInformation(calendarDateTime: item.date.calendarDateTime, relativePath: item.relativePath)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value.dateText)
                Text(value.folder)
                Text(value.filename)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                informationContentHeight = $0
            }
        }
        .frame(height: min(informationContentHeight, informationMaximumHeight))
        .background(.bar)
    }

}
