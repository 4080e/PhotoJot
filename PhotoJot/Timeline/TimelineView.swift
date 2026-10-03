import SwiftUI

struct TimelineView: View {
    @Environment(MediaViewerController.self) private var viewer
    @State private var viewingItem: TimelineItem?
    @State private var model: TimelineController
    let update: LibraryUpdateController
    let thumbnails: ThumbnailSession
    #if DEBUG
    @State private var selectedItem: TimelineItem?
    #endif
    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    init(repository: TimelineRepository, settings: SMBConnectionSettings, update: LibraryUpdateController, thumbnails: ThumbnailSession) {
        self.update = update
        self.thumbnails = thumbnails
        _model = State(initialValue: TimelineController(source: .local(repository: repository, settings: settings)))
    }

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
                    ContentUnavailableView("保存済みの写真・動画はまだありません", systemImage: "photo.on.rectangle",
                                           description: Text(update.isRunning ? "ライブラリを読み込み中です。" :
                                                (update.state == .failed ? "更新できませんでした。接続を確認して、右上の更新ボタンから再試行してください。" : model.emptyMessage)))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(model.blocks) { block in
                            Section {
                                ForEach(block.items) { item in
                                    Button { viewingItem = item } label: {
                                        TimelineThumbnailCell(item: item, session: thumbnails)
                                    }.buttonStyle(.plain).disabled(viewer.isClosing)
                                        #if DEBUG
                                        .contextMenu {
                                            Button("開発用情報") { selectedItem = item }
                                        }
                                        #endif
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
        .fullScreenCover(item: $viewingItem) { item in
            MediaViewerView(item: item, model: viewer)
        }
        .navigationTitle("timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("今すぐ更新", systemImage: "arrow.clockwise") { update.requestUpdate() }
                    .disabled(update.isCheckingConnection || update.isEditingSettings)
            }
        }
        .task { await model.loadInitial() }
        .onChange(of: update.phase) { _, phase in
            if phase == .metadata {
                thumbnails.revalidateVisibleItems()
                Task { await model.reloadIfEmpty() }
            }
        }
        .onChange(of: update.state) { _, state in
            if state == .completed || state == .failed || state == .cancelled {
                thumbnails.revalidateVisibleItems()
                Task { await model.reloadIfEmpty() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if update.isRunning {
                HStack {
                    ProgressView()
                    Text(update.state == .cancelling ? "更新を中断中…" :
                        (update.phase == .metadata ? "撮影日時を更新中…" : "ライブラリを更新中…"))
                        .font(.footnote)
                    Spacer()
                }.padding().background(.bar)
            } else if update.state == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.blocks.isEmpty ? "ライブラリを更新できませんでした。" : "更新できませんでした。保存済みの内容を表示しています。")
                    Text("右上の更新ボタンで再試行するか、接続設定を確認してください。")
                        .foregroundStyle(.secondary)
                }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding().background(.bar)
            }
        }
        #if DEBUG
        .sheet(item: $selectedItem) { item in DeveloperMediaDetailsView(item: item) }
        #endif
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
