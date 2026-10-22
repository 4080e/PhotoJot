import SwiftUI
import AVKit

struct MediaViewerView: View {
    @State private var session: ViewerSession
    let thumbnails: ThumbnailSession
    let model: MediaViewerController
    let onClose: (TimelineItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @State private var dismissProgress: CGFloat = 0
    @State private var closing = false
    @State private var showsInformation = false
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
                ViewerPagerView(session: session, model: model, viewport: viewport, thumbnails: thumbnails,
                                dismissProgress: { value, animated in
                                    if animated { withAnimation(.easeOut(duration: 0.25)) { dismissProgress = value } }
                                    else { dismissProgress = value }
                                }, dismissRequested: { close(animated: false) })
                    .safeAreaInset(edge: .bottom) { SMBRecoveryBanner() }
                    .onChange(of: session.currentItem, initial: true) { _, item in
                        model.select(item: item, viewport: viewport)
                        model.preparePreview(for: item, thumbnails: thumbnails)
                    }
                    .onChange(of: geometry.size) { _, _ in
                        model.select(item: session.currentItem, viewport: viewport)
                        model.preparePreview(for: session.currentItem, thumbnails: thumbnails)
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
            .navigationTitle(session.currentItem.date.dayTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { close(animated: true) }
                        .disabled(model.isClosing || closing || dismissProgress > 0)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("ファイル情報", systemImage: "info.circle") { showsInformation = true }
                        .labelStyle(.iconOnly)
                        .disabled(model.isClosing || closing || dismissProgress > 0)
                    if session.currentItem.mediaType == "photo" {
                        Button("右に90°回転", systemImage: "rotate.right") { model.rotatePhotoRight() }
                            .labelStyle(.iconOnly)
                            .disabled(model.image == nil || model.showsLoading || model.isClosing || closing ||
                                      model.activeItem?.id != session.currentItem.id ||
                                      model.photo.zoom.pinching || dismissProgress > 0)
                    } else if session.currentItem.mediaType == "video" {
                        Button("右に90°回転", systemImage: "rotate.right") { model.rotateVideoRight() }
                            .labelStyle(.iconOnly)
                            .disabled(model.player == nil || model.showsLoading || model.isClosing || closing ||
                                      model.isRotatingVideo || model.activeItem?.id != session.currentItem.id || dismissProgress > 0)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .background { Color.black.opacity(1 - dismissProgress).ignoresSafeArea() }
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showsInformation) {
            ViewerInformationSheet(calendarDateTime: session.currentItem.date.calendarDateTime,
                                   relativePath: session.currentItem.relativePath)
                .interactiveDismissDisabled(false)
        }
        .alert("回転角度の保存", isPresented: Binding(
            get: { model.rotationError != nil },
            set: { if !$0 { model.rotationError = nil } }
        )) {
            Button("OK", role: .cancel) { model.rotationError = nil }
        } message: {
            Text(model.rotationError ?? "")
        }
        .task { session.begin() }
        .alert("動画の回転", isPresented: Binding(
            get: { model.videoRotationError != nil },
            set: { if !$0 { model.videoRotationError = nil } }
        )) {
            Button("OK", role: .cancel) { model.videoRotationError = nil }
        } message: {
            Text(model.videoRotationError ?? "")
        }
        .onDisappear {
            session.close()
            model.cancelAutomaticResume()
            Task { await model.stop() }
        }
    }

    private func close(animated: Bool) {
        guard !closing, !session.isClosed else { return }
        closing = true
        let lastItem = session.close()
        Task {
            await model.stop()
            onClose(lastItem)
            var transaction = Transaction()
            transaction.disablesAnimations = !animated
            withTransaction(transaction) { dismiss() }
        }
    }

}

private struct ViewerInformationSheet: View {
    let calendarDateTime: String?
    let relativePath: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let value = MediaViewerInformation(calendarDateTime: calendarDateTime, relativePath: relativePath)
        NavigationStack {
            Form {
                Section("撮影日時") { informationText(value.dateText) }
                Section("ファイル名") { informationText(value.filename) }
                Section("フォルダ名") { informationText(value.folder) }
            }
            .navigationTitle("ファイル情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func informationText(_ text: String) -> some View {
        Text(text)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
