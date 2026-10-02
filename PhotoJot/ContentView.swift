import SwiftUI

struct ContentView: View {
    let update: LibraryUpdateController
    let connection: ConnectionSettingsController
    let timelineRepository: TimelineRepository
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if let settings = connection.savedSettings {
                TimelineView(repository: timelineRepository, settings: settings, update: update)
                    .id(settings)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("設定", systemImage: "gearshape") {
                                connection.prepareDraft()
                                showingSettings = true
                            }
                        }
                    }
            } else {
                settingsView
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                settingsView
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showingSettings = false }
                                .disabled(connection.isSaving)
                        }
                    }
            }
            .interactiveDismissDisabled(connection.isSaving)
        }
    }

    private var settingsView: some View {
        ConnectionSettingsView(controller: connection) { showingSettings = false }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink("更新・診断") {
                        LibraryDevelopmentView(update: update, repository: timelineRepository)
                    }
                    .disabled(connection.isSaving)
                }
            }
    }
}

private struct LibraryDevelopmentView: View {
    let update: LibraryUpdateController
    @State private var timelineDiagnostics: TimelineDiagnosticsController
    init(update: LibraryUpdateController, repository: TimelineRepository) {
        self.update = update
        _timelineDiagnostics = State(initialValue: TimelineDiagnosticsController(repository: repository))
    }
    var body: some View {
        Form {
                Section {
                    Button(update.state == .cancelling ? "中断後に更新" : "保存済みの接続先を更新") { update.requestUpdate() }
                        .disabled(update.state == .running || update.restartRequested || timelineDiagnostics.isRunning)
                    if update.isRunning {
                        ProgressView(update.state == .cancelling ? "中断待ち…" :
                            (update.phase == .metadata ? "撮影日時を解析中…" : "走査中…"))
                        Button("中断", role: .cancel) { update.cancel() }
                    }
                    if let name = update.libraryName { Text(name).foregroundStyle(.secondary) }
                    if update.restartRequested { Text("中断処理の終了後に更新を再開します。") }
                    if update.state != .idle {
                        Text("対象メディア：\(update.scanProgress.media)件")
                        Text("ファイル：\(update.scanProgress.files)件・フォルダ：\(update.scanProgress.folders)件")
                            .foregroundStyle(.secondary)
                    }
                    if let missing = update.missingCount { Text("未確認（missing）：\(missing)件") }
                    if let error = update.errorMessage { Text(error).foregroundStyle(.red) }
                    if update.state == .completed { Text("更新が完了しました。") }
                    if update.state == .cancelled { Text("更新を中断しました。保存済みの結果は残ります。") }
                } header: {
                    Text("ライブラリの走査")
                } footer: {
                    Text("保存済みの共有・ルートを走査した後、撮影日時を解析します。画面の未保存の変更は使用しません。")
                }
                Section {
                    Text("処理済み：\(update.metadataProgress.completed) / \(update.metadataProgress.total)件")
                    Text("今回の解析で日時不明：\(update.metadataProgress.unknown)件")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("撮影日時")
                } footer: {
                    Text("未処理・更新されたメディアを解析し、取得できない場合はファイルの日時を使用します。")
                }
                Section {
                    Button("timeline診断（ローカルのみ）") { timelineDiagnostics.start() }
                        .disabled(update.isRunning || timelineDiagnostics.isRunning)
                    if timelineDiagnostics.isRunning {
                        ProgressView("日付キー構築・集計中")
                        Button("診断を中断", role: .cancel) { timelineDiagnostics.cancel() }
                    }
                    if let status = timelineDiagnostics.status { Text(status) }
                    if let result = timelineDiagnostics.result {
                        LabeledContent("timeline対象", value: "\(result.total)")
                        LabeledContent("内部撮影日時", value: "\(result.kinds[.internalMetadata, default: 0])")
                        LabeledContent("コンテナ日時", value: "\(result.kinds[.containerDate, default: 0])")
                        LabeledContent("確定fallback", value: "\(result.kinds[.confirmedFallback, default: 0])")
                        LabeledContent("暫定日時", value: "\(result.kinds[.provisional, default: 0])")
                        LabeledContent("日時不明", value: "\(result.kinds[.unknown, default: 0])")
                        LabeledContent("記録offsetあり", value: "\(result.withOffset)")
                        LabeledContent("記録offsetなし", value: "\(result.withoutOffset)")
                        ForEach(result.offsets.keys.sorted(), id: \.self) { offset in
                            LabeledContent(offset, value: "\(result.offsets[offset, default: 0])")
                        }
                        LabeledContent("metadata未処理（診断前 → 後）",
                                       value: "\(result.pendingMetadataBefore) → \(result.pendingMetadataAfter)")
                    }
                } header: {
                    Text("timeline基盤の診断（開発用）")
                } footer: {
                    Text("保存済み設定のindexだけを使用します。missingは対象外。SMB・mvhdのUTC表現は撮影地offsetに数えず、日時不明もoffsetなしに含みます。")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("更新・診断")
    }
}
