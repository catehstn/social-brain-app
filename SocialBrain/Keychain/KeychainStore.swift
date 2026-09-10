import Foundation
import Security

/// Stores and retrieves platform credentials in the macOS Keychain.
///
/// Credentials are serialised as a JSON object and stored as a generic
/// password item keyed by the platform's raw string value.
///
/// The Keychain service name is a stored property rather than a constant, so a
/// test can construct a store scoped to its own throwaway service. Use
/// `KeychainStore.shared` in production; **never** construct a store with the
/// production service name in a test. Before this was injectable the suite wrote
/// to the developer's real login Keychain on every run, overwriting live
/// credentials.
struct KeychainStore: Sendable {

    /// The production store. The only place the real service name appears.
    static let shared = KeychainStore(service: "com.catehuston.SocialBrain")

    let service: String

    init(service: String) {
        self.service = service
    }

    // MARK: - Save (instance-keyed)

    /// Encodes `credentials` and stores them under the given `PlatformInstance` key.
    /// Overwrites any existing entry for that instance.
    func save(_ credentials: Credentials, for instance: PlatformInstance) throws {
        let data = try JSONSerialization.data(withJSONObject: credentials.values)
        let account = instance.id

        let updateQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass:            kSecClassGenericPassword,
                kSecAttrService:      service,
                kSecAttrAccount:      account,
                kSecValueData:        data,
                // Allow access after first unlock without requiring user confirmation.
                kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Encodes `credentials` and stores them under the platform's default instance key.
    /// Delegates to the instance-keyed overload.
    func save(_ credentials: Credentials, for platform: Platform) throws {
        try save(credentials, for: PlatformInstance(platform: platform))
    }

    // MARK: - Load (instance-keyed)

    /// Returns the stored `Credentials` for the given `PlatformInstance`, or `nil` if none.
    func load(for instance: PlatformInstance) throws -> Credentials? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: instance.id,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw KeychainError.invalidData
        }
        return Credentials(dict)
    }

    /// Returns the stored `Credentials` for the platform's default instance, or `nil` if none.
    func load(for platform: Platform) throws -> Credentials? {
        try load(for: PlatformInstance(platform: platform))
    }

    // MARK: - Delete (instance-keyed)

    /// Removes any stored credentials for the given `PlatformInstance`.
    func delete(for instance: PlatformInstance) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: instance.id
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes any stored credentials for the platform's default instance.
    func delete(for platform: Platform) throws {
        try delete(for: PlatformInstance(platform: platform))
    }

    // MARK: - Existence check (instance-keyed)

    /// Returns true if credentials exist for the given `PlatformInstance`.
    ///
    /// Does NOT request the secret data — avoids triggering Keychain ACL prompts
    /// when used purely for existence checks (e.g. in `reload()`).
    func hasCredentials(for instance: PlatformInstance) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: instance.id,
            kSecReturnData:  false,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Returns true if credentials exist for the platform's default instance.
    func hasCredentials(for platform: Platform) -> Bool {
        hasCredentials(for: PlatformInstance(platform: platform))
    }

    // MARK: - Bulk delete

    /// Removes every item under this store's service.
    ///
    /// Exists so tests can sweep their own service in teardown. Deleting
    /// per-account can't recover from a crash between save and cleanup, and an
    /// orphaned item is unfindable without knowing its exact service name.
    /// Safe on the production store only in the sense that it is never called
    /// there — it would delete all of the user's credentials.
    /// Every account name stored under this service.
    ///
    /// The rest of this type takes a `Platform` and builds the key from it, so
    /// there was no way to ask what is *actually* in the Keychain — and that is
    /// the question that matters after a platform is retired. Removing
    /// `Platform.vercel` in #116 and `Platform.amazon` in #149 left their
    /// credentials stored under keys nothing can now name, so the app could
    /// neither show them nor delete them (#118).
    ///
    /// Returns raw account strings rather than `PlatformInstance` values,
    /// because the whole point is the ones that no longer parse as a platform.
    func storedAccounts() throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecMatchLimit:       kSecMatchLimitAll,
            kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount] as? String }.sorted()
    }

    /// Saves under a raw account name.
    ///
    /// Internal and test-only in practice: production always goes through
    /// `save(_:for:)`, which builds the key from a `Platform`. This exists so a
    /// test can write an item the way an older build did — under a platform the
    /// enum no longer has — which is otherwise impossible to construct.
    func saveRaw(_ credentials: Credentials, account: String) throws {
        let data = try JSONSerialization.data(withJSONObject: credentials.values)
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    account,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Deletes one stored item by its raw account name.
    ///
    /// Deliberately separate from `delete(for:)`, which requires a `Platform`
    /// and therefore cannot address an orphan at all. Nothing calls this
    /// automatically: an orphaned credential is deleted only when the user asks,
    /// because the token also has to be revoked at the provider and the app
    /// cannot do that — removing it quietly would hide the half that matters.
    func deleteAccount(_ account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let s): "Keychain error: OSStatus \(s)"
        case .invalidData:             "Keychain item data could not be decoded"
        }
    }
}
