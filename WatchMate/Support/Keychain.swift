import Foundation
import Security

enum Keychain {
    static let service = (Bundle.main.bundleIdentifier ?? "WatchMate") + ".credentials"
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    static func string(_ key: String) -> String { read(key).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func write(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Could not save credentials to Keychain.") }
        } else if status != errSecSuccess { throw APIError.message("Could not update credentials in Keychain.") }
    }
    static func write(_ value: String, key: String) throws { try write(Data(value.utf8), key: key) }
    static func delete(_ key: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIError.message("Could not delete credentials from Keychain.")
        }
    }
}
