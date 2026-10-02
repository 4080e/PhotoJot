import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var controller: ConnectionSettingsController
    let onSaved: () -> Void

    var body: some View {
        Form {
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
            if let message = controller.message { Section { Text(message).foregroundStyle(.red) } }
        }
        .disabled(controller.isSaving)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(controller.savedSettings == nil ? "接続先を設定" : "接続設定")
        .onChange(of: controller.draft.credentialAccount) { _, _ in controller.loadPassword() }
    }
}
