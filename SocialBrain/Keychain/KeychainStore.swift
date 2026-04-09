import Foundation
import Security

/// Stores and retrieves platform credentials in the macOS Keychain.
///
/// Credentials are serialised as a JSON object and stored as a generic
/// password item keyed by the platform's raw string value.
enum KeychainStore: Sendable {
    private static let service = "com.catehuston.SocialBrain"

    // MARK: - Save

    /// Encodes `credentials` and stores them under the given platform's key.
    /// Overwrites any existing entry for that platform.
    static func save(_ credentials: Credentials, for platform: Platform) throws {
        let data = try JSONSerialization.data(withJSONObject: credentials.values)
        let account = platform.rawValue

        // Try to update an existing item first.
        let updateQuery: [CFString: Any] = [
            kSecClass:   kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it.
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

    // MARK: - Load

    /// Returns the stored `Credentials` for the given platform, or `nil` if none.
    static func load(for platform: Platform) throws -> Credentials? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      platform.rawValue,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
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

    // MARK: - Delete

    /// Removes any stored credentials for the given platform.
    static func delete(for platform: Platform) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: platform.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Existence check

    /// Returns true if credentials exist for the platform.
    static func hasCredentials(for platform: Platform) -> Bool {
        (try? load(for: platform)) != nil
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
