import Foundation
import Security

/// Stores each account's tokens in the macOS login Keychain.
enum Keychain {
    static let service = "local.aiusage.AIUsage"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ data: Data, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    static func setCodable<T: Encodable>(_ value: T, for key: String) {
        if let d = try? JSONEncoder().encode(value) { set(d, for: key) }
    }

    static func getCodable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let d = get(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
