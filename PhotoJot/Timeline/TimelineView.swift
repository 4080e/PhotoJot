import SwiftUI

struct TimelineView: View {
    @State private var model = TimelineController()
    @State private var selectedItem: TimelineItem?
    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        Group {
            if !model.hasLoaded && model.errorMessage == nil {
                ProgressView("保存済みindexを読み込み中…")
            } else if model.blocks.isEmpty {
                if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("timelineを読み込めません", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("再試行") { Task { await model.retry() } }
                            .disabled(model.isLoading)
                    }
                } else {
                    ContentUnavailableView("表示するメディアがありません", systemImage: "photo.on.rectangle",
                                           description: Text(model.emptyMessage))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(model.blocks) { block in
                            Section {
                                ForEach(block.items) { item in
                                    TimelinePlaceholder(item: item) { selectedItem = item }
                                        .task { await model.loadMoreIfNeeded(visibleID: item.id) }
                                }
                            } header: {
                                Text(model.heading(for: block))
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal)
                    footer.padding()
                }
                // cursor失効後は先頭pageの新しい表示へ切り替える。
                .id(model.displayGeneration)
            }
        }
        .navigationTitle("timeline")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadInitial() }
        .sheet(item: $selectedItem) { item in TimelineItemDetails(item: item) }
    }

    @ViewBuilder private var footer: some View {
        if model.isLoading {
            ProgressView("読み込み中…")
        } else if let error = model.errorMessage {
            VStack(spacing: 8) {
                Text(error).foregroundStyle(.secondary)
                Button("再試行") { Task { await model.retry() } }
            }
        } else if model.hasMore {
            // 自動triggerが取消された場合も、末尾から確実に再試行できる。
            Button("続きを読み込む") { Task { await model.retry() } }
        } else {
            Text("\(model.loadedCount)件・すべて表示しました")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// thumbnail導入時はこのセル内容を置換する。今回は画像取得処理を持たない。
private struct TimelinePlaceholder: View {
    let item: TimelineItem
    let action: () -> Void
    private var isVideo: Bool { item.mediaType == "video" }
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: isVideo ? "video.fill" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isVideo ? "動画" : "写真")
        .accessibilityHint("タップして開発用情報を表示")
    }
}

private struct TimelineItemDetails: View {
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("ファイル", value: (item.relativePath as NSString).lastPathComponent)
                LabeledContent("種類", value: item.mediaType == "video" ? "動画" : "写真")
                LabeledContent("暦日時", value: item.date.calendarDateTime ?? "日時不明")
                LabeledContent("記録offset", value: item.date.recordedOffset ?? "なし")
                LabeledContent("分類", value: item.date.kind.rawValue)
                LabeledContent("source", value: item.date.source ?? "なし")
                LabeledContent("quality", value: item.date.quality ?? "なし")
                LabeledContent("metadata状態", value: item.metadataState ?? "未処理")
                LabeledContent("現generationの解析完了", value: item.metadataIsCurrent ? "はい" : "いいえ")
                Section("共有からの相対パス") { Text(item.relativePath) }
            }
            .navigationTitle("開発用情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
