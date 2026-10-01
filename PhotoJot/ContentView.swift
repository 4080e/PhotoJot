import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scan = ScanController()
    @State private var metadata = MetadataController()
    @State private var timelineDiagnostics = TimelineDiagnosticsController()
    @State private var settings = SMBConnectionSettings()
    @State private var password = ""
    @State private var isChecking = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var didLoad = false
    @State private var coordinator = SMBAccessCoordinator()
    private let credentials = CredentialStore()

    var body: some View {
        NavigationStack {
            Form {
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
                .disabled(isChecking || scan.isScanning || metadata.isProcessing || timelineDiagnostics.isRunning)
                if let message {
                    Section("確認結果") {
                        Label(message, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(succeeded ? Color.primary : Color.red)
                    }
                }
                Section {
                    Button("保存済みの接続先を走査") { scan.start(access: coordinator) }
                        .disabled(isChecking || scan.isScanning || metadata.isProcessing || timelineDiagnostics.isRunning)
                    if scan.isScanning {
                        ProgressView("走査中")
                        Button("中断", role: .cancel) { scan.cancel() }
                    }
                    if let name = scan.libraryName { Text(name).foregroundStyle(.secondary) }
                    if let status = scan.status {
                        Text(status)
                        Text("対象メディア：\(scan.progress.media)件")
                        Text("ファイル：\(scan.progress.files)件・フォルダ：\(scan.progress.folders)件")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ライブラリの走査")
                } footer: {
                    Text("最後に接続確認で保存した共有・ルートを走査します。画面の未保存の変更は使用しません。")
                }
                Section {
                    Button("撮影日時を解析") { metadata.start(access: coordinator) }
                        .disabled(isChecking || scan.isScanning || metadata.isProcessing || timelineDiagnostics.isRunning)
                    if metadata.isProcessing {
                        ProgressView("解析中")
                        Button("解析を中断", role: .cancel) { metadata.cancel() }
                    }
                    if let status = metadata.status {
                        Text(status)
                        Text("処理済み：\(metadata.progress.completed) / \(metadata.progress.total)件")
                        Text("今回の解析で日時不明：\(metadata.progress.unknown)件")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("撮影日時")
                } footer: {
                    Text("保存済みの接続先のindexを使用します。未処理・更新されたメディアを解析し、取得できない場合はファイルの日時を使用します。")
                }
                Section {
                    Button("timeline診断（ローカルのみ）") { timelineDiagnostics.start() }
                        .disabled(isChecking || scan.isScanning || metadata.isProcessing || timelineDiagnostics.isRunning)
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
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { scan.cancel(); metadata.cancel(); timelineDiagnostics.cancel() }
            }
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

#Preview {
    ContentView()
}
