import Foundation

/// In-memory credentials for a single platform, loaded from Keychain.
///
/// Stored as a flat key/value dictionary so each collector can extract
/// exactly the fields it needs without requiring a proliferation of
/// platform-specific credential types.
///
/// Conventional keys:
/// - `"api_key"`       – static API key or personal access token
/// - `"access_token"`  – OAuth access token
/// - `"username"`      – username or handle (e.g. Bluesky)
/// - `"password"`      – app password (e.g. Bluesky)
/// - `"instance_url"`  – base URL for self-hosted instances (e.g. Mastodon)
/// - `"site_code"`     – subdomain or site identifier (e.g. GoatCounter)
public struct Credentials: Sendable {
    public let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public subscript(_ key: String) -> String? {
        values[key]
    }

    public var apiKey: String?      { self["api_key"] }
    public var accessToken: String? { self["access_token"] }
    public var username: String?    { self["username"] }
    public var password: String?    { self["password"] }
    public var instanceURL: URL? {
        guard let raw = self["instance_url"] else { return nil }
        return URL(string: raw)
    }
    public var siteCode: String?    { self["site_code"] }
}
