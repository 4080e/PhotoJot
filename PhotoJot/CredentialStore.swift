import Foundation
import Security

struct CredentialStore {
    private let service = (Bundle.main.bundleIdentifier ?? "PhotoJot") + ".smb"

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func password(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw StoreError(status: errSecDecode)
        }
        return password
    }

    func save(password: String, account: String) throws {
        let query = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    private struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "パスワードのKeychain処理に失敗しました（\(status)）。端末のロックを解除して再試行してください。" }
    }
}
