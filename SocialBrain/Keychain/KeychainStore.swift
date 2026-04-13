import Foundation
import Security

/// Stores and retrieves platform credentials in the macOS Keychain.
///
/// Credentials are serialised as a JSON object and stored as a generic
/// password item keyed by the platform's raw string value.
enum KeychainStore: Sendable {
    private static let service = "com.catehuston.SocialBrain"

    // MARK: - Save (instance-keyed)

    /// Encodes `credentials` and stores them under the given `PlatformInstance` key.
    /// Overwrites any existing entry for that instance.
    static func save(_ credentials: Credentials, for instance: PlatformInstance) throws {
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
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData:   data
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
    static func save(_ credentials: Credentials, for platform: Platform) throws {
        try save(credentials, for: PlatformInstance(platform: platform))
    }

    // MARK: - Load (instance-keyed)

    /// Returns the stored `Credentials` for the given `PlatformInstance`, or `nil` if none.
    static func load(for instance: PlatformInstance) throws -> Credentials? {
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
    static func load(for platform: Platform) throws -> Credentials? {
        try load(for: PlatformInstance(platform: platform))
    }

    // MARK: - Delete (instance-keyed)

    /// Removes any stored credentials for the given `PlatformInstance`.
    static func delete(for instance: PlatformInstance) throws {
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
    static func delete(for platform: Platform) throws {
        try delete(for: PlatformInstance(platform: platform))
    }

    // MARK: - Existence check (instance-keyed)

    /// Returns true if credentials exist for the given `PlatformInstance`.
    static func hasCredentials(for instance: PlatformInstance) -> Bool {
        (try? load(for: instance)) != nil
    }

    /// Returns true if credentials exist for the platform's default instance.
    static func hasCredentials(for platform: Platform) -> Bool {
        hasCredentials(for: PlatformInstance(platform: platform))
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
