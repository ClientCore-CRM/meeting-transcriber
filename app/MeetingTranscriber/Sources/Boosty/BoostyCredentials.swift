import CryptoKit
import Foundation
import Security

/// Public account metadata. Tokens live exclusively in the scoped secret store.
struct BoostyAccount: Codable, Identifiable, Sendable {
    let id: String
    let origin: String
    let email: String
    var uploadEnabled: Bool

    var company: String {
        switch URL(string: origin)?.host {
        case "meets.clientcore.ru": "ClientCore"
        case "boosty.retailrocket.ru": "Retail Rocket"
        default: URL(string: origin)?.host ?? origin
        }
    }

    var badge: String {
        switch URL(string: origin)?.host {
        case "meets.clientcore.ru": "CC"
        case "boosty.retailrocket.ru": "RR"
        default: company
        }
    }
}

protocol BoostySecretStorage {
    func read(_ key: String) -> Data?
    func write(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

struct BoostyKeychainSecrets: BoostySecretStorage {
    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ru.clientcore.meeting-transcriber.boosty",
            kSecAttrAccount as String: key,
        ]
    }

    func read(_ key: String) -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data, for key: String) throws {
        let base = query(key)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BoostyError.keychain(added) }
        } else if status != errSecSuccess { throw BoostyError.keychain(status) }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BoostyError.keychain(status) }
    }
}

struct BoostyCredentials {
    private let defaults: UserDefaults
    private let secrets: any BoostySecretStorage
    private let activeKey = "boosty.activeAccount"
    private let accountsKey = "boosty.accounts.v1"

    init(defaults: UserDefaults = .standard, secrets: any BoostySecretStorage = BoostyKeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    private func key(_ accountKey: String) -> String {
        SHA256.hash(data: Data(accountKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var accounts: [BoostyAccount] {
        if let data = defaults.data(forKey: accountsKey), let result = try? JSONDecoder().decode([BoostyAccount].self, from: data) { return result }
        // Existing installs keep their active grant and upload preference without reauthentication.
        guard let credential = load() else { return [] }
        return [.init(
            id: credential.accountKey,
            origin: credential.origin,
            email: credential.user.email,
            uploadEnabled: defaults.bool(forKey: "boosty.uploadEnabled"),
        )]
    }

    private func saveAccounts(_ accounts: [BoostyAccount]) throws {
        try defaults.set(JSONEncoder().encode(accounts), forKey: accountsKey)
    }

    func load() -> BoostyCredential? {
        guard let active = defaults.string(forKey: activeKey), let data = secrets.read(active) else { return nil }
        return try? BoostyAPIClient.decoder().decode(BoostyCredential.self, from: data)
    }

    func load(accountKey: String) -> BoostyCredential? {
        guard let data = secrets.read(key(accountKey)),
              let value = try? BoostyAPIClient.decoder().decode(BoostyCredential.self, from: data), value.accountKey == accountKey else { return nil }
        return value
    }

    func save(_ credential: BoostyCredential, makeActive: Bool = true) throws {
        var profiles = accounts
        try secrets.write(BoostyAPIClient.encoder().encode(credential), for: key(credential.accountKey))
        let enabled = profiles.first { $0.id == credential.accountKey }?.uploadEnabled ?? true
        profiles.removeAll { $0.id == credential.accountKey }
        profiles.append(.init(id: credential.accountKey, origin: credential.origin, email: credential.user.email, uploadEnabled: enabled))
        try saveAccounts(profiles)
        if makeActive { try activate(accountKey: credential.accountKey) }
    }

    func activate(accountKey: String) throws {
        guard load(accountKey: accountKey) != nil, accounts.contains(where: { $0.id == accountKey }) else { throw BoostyError.disconnected }
        // Materialize migrated metadata before changing the legacy active pointer.
        try saveAccounts(accounts)
        defaults.set(key(accountKey), forKey: activeKey)
    }

    func setUploadEnabled(accountKey: String, enabled: Bool) throws {
        var profiles = accounts
        guard let index = profiles.firstIndex(where: { $0.id == accountKey }) else { throw BoostyError.disconnected }
        profiles[index].uploadEnabled = enabled
        try saveAccounts(profiles)
    }

    func remove(accountKey: String) throws {
        let profiles = accounts.filter { $0.id != accountKey }
        try secrets.remove(key(accountKey))
        try saveAccounts(profiles)
        if defaults.string(forKey: activeKey) == key(accountKey) { defaults.removeObject(forKey: activeKey) }
    }

    func deleteActive() throws {
        if let credential = load() { try remove(accountKey: credential.accountKey) }
    }
}
