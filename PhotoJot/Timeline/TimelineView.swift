import SwiftUI

struct TimelineView: View {
    @Environment(MediaViewerController.self) private var viewer
    @State private var viewingItem: TimelineItem?
    @State private var viewerReturnItem: TimelineItem?
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
                                 contentVersion: model.contentVersion, jumpID: model.displayGeneration, scrollRequest: model.scrollRequest,
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
        .fullScreenCover(item: $viewingItem, onDismiss: {
            guard let item = viewerReturnItem else { return }
            viewerReturnItem = nil
            Task { await model.returnFromViewer(to: item) }
        }) { item in
            MediaViewerView(item: item, model: viewer, repository: repository, thumbnails: thumbnails) {
                viewerReturnItem = $0
            }
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
            if model.selectedMonth != nil || model.isViewerWindow {
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
                if state == .completed { Task { await model.reloadAfterUpdate() } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if update.isRunning {
                HStack {
                    ProgressView()
                    Text(update.state == .cancelling ? "更新を中断中…" : update.recoveryMessage ??
                        (update.phase == .metadata ? metadataProgressText : "ライブラリを更新中…"))
                        .font(.footnote)
                    Spacer()
                }.padding().background(.bar)
            } else if update.state == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.blocks.isEmpty ? "ライブラリを更新できませんでした。" : "更新できませんでした。保存済みの内容を表示しています。")
                    Text(update.errorMessage ?? "右上の更新ボタンで再試行するか、接続設定を確認してください。")
                        .foregroundStyle(.secondary)
                }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding().background(.bar)
            }
        }
        #if DEBUG
        .sheet(item: $selectedItem) { item in DeveloperMediaDetailsView(item: item, repository: repository) }
        #endif
    }

    private var metadataProgressText: String {
        let progress = update.metadataProgress
        guard progress.total > 0 else { return "撮影日時を更新中…" }
        let format = IntegerFormatStyle<Int>.number.grouping(.automatic).locale(Locale(identifier: "ja_JP"))
        return "撮影日時を更新中… \(progress.completed.formatted(format)) / \(progress.total.formatted(format))件"
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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if let months {
                    if months.isEmpty {
                        ContentUnavailableView("年月を選べるメディアはありません", systemImage: "calendar")
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(Array(Set(months.map(\.year))).sorted(by: >), id: \.self) { year in
                                    NavigationLink {
                                        ScrollView {
                                            LazyVGrid(columns: columns, spacing: 16) {
                                                ForEach(months.filter { $0.year == year }) { month in
                                                    Button {
                                                        Task {
                                                            await model.jump(to: month)
                                                            dismiss()
                                                        }
                                                    } label: {
                                                        Text("\(month.month)月")
                                                            .font(.title3.weight(.semibold))
                                                            .foregroundStyle(.primary)
                                                            .frame(maxWidth: .infinity, minHeight: 44)
                                                            .padding(.vertical, 12)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .disabled(model.isLoading)
                                                }
                                            }
                                            .padding()
                                        }
                                        .navigationTitle("\(String(year))年")
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbar {
                                            ToolbarItem(placement: .principal) {
                                                Text("\(String(year))年").font(.title2.weight(.bold))
                                            }
                                        }
                                    } label: {
                                        Text("\(String(year))年")
                                            .font(.title2.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding()
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
            .navigationBarTitleDisplayMode(.inline)
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
