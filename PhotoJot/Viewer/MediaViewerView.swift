import SwiftUI
import AVKit

struct MediaViewerView: View {
    let item: TimelineItem
    let model: MediaViewerController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @ScaledMetric(relativeTo: .footnote) private var informationMaximumHeight = 104.0
    @State private var informationContentHeight: CGFloat = 0
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let viewport = FullPhotoViewport(width: geometry.size.width, height: geometry.size.height, scale: scale)
                ZStack {
                    Color.black
                    if model.showsLoading { ProgressView("読み込み中…") }
                    else if let player = model.player { VideoPlayer(player: player) }
                    else if let image = model.image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else if let message = model.message {
                        ContentUnavailableView {
                            Label("表示できません", systemImage: "exclamationmark.triangle")
                        } description: { Text(message) } actions: {
                            Button("再読み込み") {
                                Task { await model.stop(); model.start(item: item, viewport: viewport) }
                            }.disabled(model.isClosing)
                        }
                    } else { ProgressView("読み込み中…") }
                    if model.isClosing { ProgressView("終了処理中…") }
                }
                .onChange(of: geometry.size, initial: true) { _, _ in model.start(item: item, viewport: viewport) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                information
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { Task { await model.stop(); dismiss() } }.disabled(model.isClosing)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onDisappear {
            model.cancelAutomaticResume()
            Task { await model.stop() }
        }
    }

    private var information: some View {
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
