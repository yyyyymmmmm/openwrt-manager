import Foundation
import Security

struct CredentialStore {
    private let service = "app.openwrt.manager.router-credentials.v1"

    func read(id: UUID) throws -> StoredCredential? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
        do { return try JSONDecoder().decode(StoredCredential.self, from: data) }
        catch { throw AppFailure.storage("保存的凭据无法读取，请重新输入密码。") }
    }

    func save(_ credential: StoredCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(id)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw error(updated) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private func error(_ status: OSStatus) -> AppFailure {
        // No credential contents appear in errors or logs.
        .storage("无法访问钥匙串（\(status)），请解锁设备后重试。")
    }
}
