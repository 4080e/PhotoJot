import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var controller: ConnectionSettingsController
    let onSaved: () -> Void

    var body: some View {
        Form {
            if controller.savedSettings != nil {
                Section {
                    LabeledContent("最終更新") {
                        if let date = controller.lastSuccessfulUpdateAt {
                            Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                        } else { Text("未更新") }
                    }
                }
            }
            if controller.profile != nil {
                Section {
                    LabeledContent("自宅LAN用IPアドレス") {
                        TextField("IPアドレス", text: $controller.homeHost)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Tailscale用IPアドレス") {
                        TextField("IPアドレス", text: $controller.awayHost)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    Toggle("外出先から接続", isOn: Binding(get: { controller.useAway }, set: { value in
                        Task { await controller.switchEndpoint(useAway: value) }
                    }))
                    if let status = controller.switchStatus {
                        HStack { ProgressView(); Text(status) }
                    }
                    if let message = controller.message {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                } header: { Text("接続先") } footer: {
                    Text("IPアドレスの入力後はキーボードの完了で保存します。切り替え時に接続を確認します。Tailscaleは別途ONにしてください。どちらも同じMac mini・同じ共有フォルダを指定してください。")
                }
                Section("共通設定") {
                    LabeledContent("共有名", value: controller.draft.share)
                    LabeledContent("ルートパス", value: controller.draft.rootPath.isEmpty ? "共有直下" : controller.draft.rootPath)
                    LabeledContent("ポート", value: String(controller.draft.port))
                    LabeledContent("ユーザー名", value: controller.draft.username)
                    LabeledContent("ドメイン", value: controller.draft.domain.isEmpty ? "未指定" : controller.draft.domain)
                    SecureField("パスワード", text: $controller.password).textContentType(.password)
                }
            } else {
                Section("接続先") {
                    TextField("ホスト名 / IPアドレス", text: $controller.draft.host).keyboardType(.URL)
                    TextField("共有名", text: $controller.draft.share)
                    TextField("ルートパス（空欄で共有直下）", text: $controller.draft.rootPath)
                }
                Section {
                    TextField("ユーザー名", text: $controller.draft.username).textContentType(.username)
                    SecureField("パスワード", text: $controller.password).textContentType(.password)
                } header: { Text("認証") } footer: {
                    Text("接続確認に成功すると設定を保存してライブラリを更新します。パスワードはこの端末のKeychainに保存します。")
                }
                Section {
                    Button {
                        Task { await controller.save(onSaved: onSaved) }
                    } label: {
                        HStack {
                            Text(controller.isSaving ? "接続確認・保存中…" : "接続確認して保存")
                            if controller.isSaving { Spacer(); ProgressView() }
                        }
                    }
                }
                if let message = controller.message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .submitLabel(.done)
        .onSubmit {
            if controller.profile != nil { Task { await controller.switchEndpoint(useAway: controller.useAway) } }
        }
        .task(id: controller.savedSettings) { await controller.loadLastSuccessfulUpdate() }
        .onChange(of: controller.updateState) { _, state in
            if state == .completed { Task { await controller.loadLastSuccessfulUpdate() } }
        }
        .disabled(controller.isSaving)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(controller.savedSettings == nil ? "接続先を設定" : "接続設定")
        .onChange(of: controller.draft.credentialAccount) { _, _ in controller.loadPassword() }
    }
}
