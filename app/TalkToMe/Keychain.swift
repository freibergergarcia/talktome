import Foundation
import Security

/// Generic passwords under the app's bundle identifier.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "TalkToMe" }

    static func read(account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stores `value`, or deletes the item when it is empty.
    static func write(_ value: String, account: String) {
        let query = base(account)
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
