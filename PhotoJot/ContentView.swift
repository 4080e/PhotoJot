import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scan = ScanController()
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
                .disabled(isChecking || scan.isScanning)
                if let message {
                    Section("確認結果") {
                        Label(message, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(succeeded ? Color.primary : Color.red)
                    }
                }
                Section {
                    Button("保存済みの接続先を走査") { scan.start(access: coordinator) }
                        .disabled(isChecking || scan.isScanning)
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
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("PhotoJot")
            .onAppear(perform: loadSettings)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { scan.cancel() }
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
