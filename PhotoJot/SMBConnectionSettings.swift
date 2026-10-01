import Foundation

nonisolated struct SMBConnectionSettings: Codable, Equatable, Sendable {
    var host = ""
    var port = 445
    var username = ""
    var domain = ""
    var share = ""
    var rootPath = ""

    // パスワードはこのモデルに含めない。
    static let storageKey = "smbConnectionSettings"

    func validated() throws -> Self {
        var value = self
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.host.isEmpty, !value.host.contains("://"),
              !value.host.contains("/"), !value.host.contains("\\"),
              !value.share.isEmpty, !value.share.contains("/"), !value.share.contains("\\"),
              (1...65535).contains(port), !username.isEmpty else {
            throw SettingsError.invalidConnection
        }
        let path = rootPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains("://"),
              !path.split(separator: "/").contains("..") else {
            throw SettingsError.invalidPath
        }
        value.rootPath = path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        return value
    }

    var credentialAccount: String {
        // 区切り文字を含む入力でも別の認証情報と衝突させない。
        let parts = [host.lowercased(), String(port), domain, username]
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

private nonisolated enum SettingsError: LocalizedError {
    case invalidConnection, invalidPath

    var errorDescription: String? {
        switch self {
        case .invalidConnection:
            return "ホスト名（またはIPアドレス）、共有名、ユーザー名を確認してください。ホストにsmb://や共有パスは含めません。"
        case .invalidPath:
            return "ルートパスは共有からの相対パス（例：Photos/2026）で入力してください。共有直下は空欄にします。先頭の/や..は使用できません。"
        }
    }
}
