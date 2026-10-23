import Foundation

nonisolated struct SMBConnectionSettings: Codable, Equatable, Hashable, Sendable {
    var host = ""
    var port = 445
    var username = ""
    var domain = ""
    var share = ""
    var rootPath = ""

    var libraryID: UUID?
    var routeVersion: UUID?
    var credentialReference: String?

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
        if let credentialReference { return credentialReference }
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

// A persisted logical library binding, independent of either network address.
nonisolated struct LibraryConnectionProfile: Codable, Equatable, Sendable {
    static let storageKey = "libraryConnectionProfile.v1"
    var schemaVersion = 1
    var libraryID: UUID
    var homeHost: String
    var awayHost = "100.92.22.5"
    var useAway = false
    var common: SMBConnectionSettings
    var revision = UUID()
    var credentialID: UUID?
    var credentialReference: String {
        "library." + libraryID.uuidString + (credentialID.map { "." + $0.uuidString } ?? "")
    }

    var settings: SMBConnectionSettings {
        var result = common
        result.host = useAway ? awayHost : homeHost
        result.libraryID = libraryID
        result.routeVersion = revision
        result.credentialReference = credentialReference
        return result
    }

    func validated() throws -> Self {
        guard schemaVersion == 1 else { throw LibraryBindingError.invalidProfile }
        var copy = self
        var home = common; home.host = homeHost
        var away = common; away.host = awayHost
        copy.homeHost = try home.validated().host
        copy.awayHost = try away.validated().host
        copy.common = try common.validated()
        return copy
    }

    static func sameRoot(_ a: SMBConnectionSettings, _ b: SMBConnectionSettings) -> Bool {
        a.port == b.port && a.share == b.share && a.rootPath == b.rootPath &&
        a.username == b.username && a.domain == b.domain
    }

    static func isLANAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}

nonisolated enum LibraryBindingError: LocalizedError {
    case ambiguous, invalidProfile, changedRoot, excessiveMissing
    var errorDescription: String? {
        switch self {
        case .ambiguous: "自宅LAN側の既存ライブラリを一意に特定できません。データは変更していません。保存済みの接続設定を確認してください。"
        case .invalidProfile: "保存済みのライブラリ接続設定を確認できません。データは変更していません。"
        case .changedRoot: "この設定は同じ共有・フォルダ・アカウントへの接続先切り替え専用です。"
        case .excessiveMissing: "多数のファイルが見つからないため、missing判定を確定せず更新を停止しました。同じMac miniの同じ共有フォルダか確認してください。"
        }
    }
}

// Copy first, publish last. Neither the legacy defaults nor its Keychain item is deleted.
@MainActor enum LibraryConnectionMigration {
    static func persist(_ profile: LibraryConnectionProfile, legacy: SMBConnectionSettings,
                        defaults: UserDefaults, read: (String) throws -> String?,
                        write: (String, String) throws -> Void) throws {
        let data = try JSONEncoder().encode(profile.validated())
        if try read(profile.credentialReference) == nil,
           let secret = try read(legacy.credentialAccount) {
            try write(profile.credentialReference, secret)
            guard try read(profile.credentialReference) == secret else { throw LibraryBindingError.invalidProfile }
        }
        defaults.set(data, forKey: LibraryConnectionProfile.storageKey)
    }
}
