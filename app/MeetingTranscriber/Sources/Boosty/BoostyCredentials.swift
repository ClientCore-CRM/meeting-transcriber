import CryptoKit
import Foundation
import Security

/// The active-account reference is public; each secret is scoped to origin+user.
struct BoostyCredentials {
    private let defaults: UserDefaults
    private let service = "ru.clientcore.meeting-transcriber.boosty"
    private let activeKey = "boosty.activeAccount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func account(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> BoostyCredential? {
        guard let key = defaults.string(forKey: activeKey) else { return nil }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? BoostyAPIClient.decoder().decode(BoostyCredential.self, from: data)
    }

    func save(_ credential: BoostyCredential) throws {
        let key = account(credential.accountKey)
        let data = try BoostyAPIClient.encoder().encode(credential)
        let base = query(key)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BoostyError.keychain(added) }
        } else if status != errSecSuccess {
            throw BoostyError.keychain(status)
        }
        defaults.set(key, forKey: activeKey)
    }

    func deleteActive() throws {
        guard let key = defaults.string(forKey: activeKey) else { return }
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BoostyError.keychain(status) }
        defaults.removeObject(forKey: activeKey)
    }
}
