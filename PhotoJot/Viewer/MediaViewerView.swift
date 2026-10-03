import SwiftUI
import AVKit

struct MediaViewerView: View {
    let item: TimelineItem
    let model: MediaViewerController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
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
}
