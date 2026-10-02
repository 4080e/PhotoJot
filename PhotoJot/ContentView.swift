import SwiftUI

struct ContentView: View {
    let update: LibraryUpdateController
    let coordinator: SMBAccessCoordinator
    let timelineRepository: TimelineRepository
    @State private var timelineDiagnostics: TimelineDiagnosticsController
    @State private var settings = SMBConnectionSettings()
    @State private var password = ""
    @State private var isChecking = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var didLoad = false
    private let credentials = CredentialStore()

    init(update: LibraryUpdateController, coordinator: SMBAccessCoordinator, timelineRepository: TimelineRepository) {
        self.update = update
        self.coordinator = coordinator
        self.timelineRepository = timelineRepository
        _timelineDiagnostics = State(initialValue: TimelineDiagnosticsController(repository: timelineRepository))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        TimelineView(repository: timelineRepository)
                    } label: {
                        Label("timelineを開く", systemImage: "photo.on.rectangle")
                    }
                } footer: {
                    Text("保存済みindexを表示します。SMB接続・走査・撮影日時の解析は開始しません。")
                }
                Group {
                    Section("接続先") {
                        TextField("ホスト名 / IPアドレス", text: $settings.host)
                            .keyboardType(.URL)
                        TextField("共有名", text: $settings.share)
                        TextField("ルートパス（空欄で共有直下）", text: $settings.rootPath)
                    }
                    Section {
                        TextField("ユーザー名", text: $settings.username)
                            .textContentType(.username)
                        SecureField("パスワード", text: Binding(
                            get: { password },
                            set: { password = $0; message = nil }
                        ))
                            .textContentType(.password)
                    } header: {
                        Text("認証")
                    } footer: {
                        Text("接続確認に成功すると設定を保存します。パスワードはこの端末のKeychainに保存します。ルートパスは共有からの相対パス（例：Photos/2026）です。")
                    }
                    Section {
                        Button {
                            Task { await checkConnection() }
                        } label: {
                            HStack {
                                Text(isChecking ? "接続確認中…" : "接続確認")
                                if isChecking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isChecking)
                    }
                }
                .disabled(isChecking || update.isRunning || timelineDiagnostics.isRunning)
                if let message {
                    Section("確認結果") {
                        Label(message, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(succeeded ? Color.primary : Color.red)
                    }
                }
                Section {
                    Button(update.state == .cancelling ? "中断後に更新" : "保存済みの接続先を更新") { update.requestUpdate() }
                        .disabled(isChecking || update.state == .running || update.restartRequested || timelineDiagnostics.isRunning)
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
                        .disabled(isChecking || update.isRunning || timelineDiagnostics.isRunning)
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
            .navigationTitle("PhotoJot")
            .onAppear(perform: loadSettings)
            .onChange(of: settings) { old, new in
                message = nil
                if old.credentialAccount != new.credentialAccount { loadPassword() }
            }
        }
    }

    private func loadSettings() {
        guard !didLoad else { return }
        didLoad = true
        if let data = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey),
           let saved = try? JSONDecoder().decode(SMBConnectionSettings.self, from: data) {
            settings = saved
        }
        loadPassword()
    }

    private func loadPassword() {
        password = ""
        do {
            password = try credentials.password(account: settings.credentialAccount) ?? ""
        } catch {
            message = error.localizedDescription
            succeeded = false
        }
    }

    @MainActor
    private func checkConnection() async {
        guard !isChecking else { return }
        isChecking = true
        message = nil
        succeeded = false
        defer { isChecking = false }
        do {
            let connection = try settings.validated()
            let count = try await coordinator.checkConnection(settings: connection, password: password)
            do {
                let data = try JSONEncoder().encode(connection)
                let previous = UserDefaults.standard.data(forKey: SMBConnectionSettings.storageKey)
                    .flatMap { try? JSONDecoder().decode(SMBConnectionSettings.self, from: $0) }
                try credentials.save(password: password, account: connection.credentialAccount)
                UserDefaults.standard.set(data, forKey: SMBConnectionSettings.storageKey)
                if let previous, previous.credentialAccount != connection.credentialAccount {
                    try credentials.delete(account: previous.credentialAccount)
                }
                succeeded = true
                message = "接続成功\nルート直下の項目数：\(count)"
            } catch {
                message = "接続成功（ルート直下：\(count)項目）\n設定の保存処理に失敗しました。\n\(error.localizedDescription)"
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
