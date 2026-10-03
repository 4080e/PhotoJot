import SwiftUI

struct TimelineView: View {
    @Environment(MediaViewerController.self) private var viewer
    @State private var viewingItem: TimelineItem?
    @State private var selectingMonth = false
    @State private var model: TimelineController
    private let repository: TimelineRepository
    let update: LibraryUpdateController
    let thumbnails: ThumbnailSession
    #if DEBUG
    @State private var selectedItem: TimelineItem?
    #endif

    init(repository: TimelineRepository, settings: SMBConnectionSettings, update: LibraryUpdateController, thumbnails: ThumbnailSession) {
        self.repository = repository
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
                TimelineGridView(model: model, thumbnails: thumbnails,
                                 sections: model.blocks.map { TimelineGridSection(id: $0.id, title: model.heading(for: $0), items: $0.items) },
                                 contentVersion: model.contentVersion, jumpID: model.displayGeneration,
                                 footer: AnyView(footer), footerHeight: model.errorMessage == nil ? 60 : 120,
                                 select: { if !viewer.isClosing { viewingItem = $0 } },
                                 inspect: { item in
                                     #if DEBUG
                                     selectedItem = item
                                     #endif
                                 })
                .overlay(alignment: .top) {
                    if model.isLoadingNewer { ProgressView().padding().background(.bar) }
                    else if let error = model.newerErrorMessage {
                        VStack {
                            Text(error)
                            Button("再試行") { Task { await model.loadNewer() } }
                                .disabled(model.isLoading)
                        }.padding().background(.bar)
                    }
                }
            }
        }
        .fullScreenCover(item: $viewingItem) { item in
            MediaViewerView(item: item, model: viewer, repository: repository)
        }
        .sheet(isPresented: $selectingMonth) { TimelineMonthPicker(model: model) }
        .navigationTitle(model.displayedMonth?.title ?? "年月")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { selectingMonth = true } label: {
                    HStack(spacing: 4) {
                        Text(model.displayedMonth?.title ?? "年月").font(.headline)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("年月を選択して移動")
            }
            if model.selectedMonth != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("最新") { Task { await model.jump(to: nil) } }
                        .disabled(model.isLoading)
                }
            }
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
        if model.isLoading && !model.isLoadingNewer {
            ProgressView("読み込み中…")
        } else if let error = model.errorMessage {
            VStack(spacing: 8) {
                Text(error).foregroundStyle(.secondary)
                Button("再試行") { Task { await model.retry() } }
            }
        } else if !model.hasMore {
            Text(model.hasNewer ? "\(model.loadedCount)件・最も古い項目まで表示しました" : "\(model.loadedCount)件・すべて表示しました")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct TimelineMonthPicker: View {
    let model: TimelineController
    @Environment(\.dismiss) private var dismiss
    @State private var months: [TimelineMonth]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let months {
                    if months.isEmpty {
                        ContentUnavailableView("年月を選べるメディアはありません", systemImage: "calendar")
                    } else {
                        List(Array(Set(months.map(\.year))).sorted(by: >), id: \.self) { year in
                            NavigationLink("\(String(year))年") {
                                List(months.filter { $0.year == year }) { month in
                                    Button("\(month.month)月") {
                                        Task {
                                            await model.jump(to: month)
                                            dismiss()
                                        }
                                    }.disabled(model.isLoading)
                                }
                                .navigationTitle("\(String(year))年")
                            }
                        }
                    }
                } else if let error {
                    ContentUnavailableView {
                        Label("年月を取得できません", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("再試行") { Task { await load() } }
                    }
                } else { ProgressView("年月を読み込み中…") }
            }
            .navigationTitle("年月へ移動")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        error = nil
        do { months = try await model.availableMonths() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
