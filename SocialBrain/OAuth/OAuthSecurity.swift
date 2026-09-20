import Foundation
import CryptoKit

/// The `state` and PKCE values for one authorisation attempt.
///
/// Kept separate from the two flow types so the interesting parts — building
/// the authorisation URL and deciding whether a callback is acceptable — are
/// pure functions a test can call. The flows themselves need a browser and a
/// live server, which is why they had no tests at all before this (#50, #84).
struct OAuthSecurity: Sendable, Equatable {

    /// Opaque value echoed back by the server, tying a callback to the request
    /// that started it. Without one, nothing distinguishes our callback from a
    /// substituted or replayed one.
    let state: String

    /// PKCE code verifier. Only Mastodon uses it — WordPress.com's OAuth2
    /// documents `state` but no PKCE parameters, so sending a challenge there
    /// would be noise that the server ignores.
    let codeVerifier: String

    /// `S256` challenge derived from the verifier, per RFC 7636 §4.2.
    /// Mastodon supports only this method.
    var codeChallenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    /// Fresh random values. 32 bytes each, which base64url-encodes to 43
    /// characters — the minimum RFC 7636 §4.1 allows for a verifier, and all
    /// of it from the unreserved set, so neither value ever needs escaping.
    ///
    /// `UInt8.random(in:)` draws from `SystemRandomNumberGenerator`, which is
    /// `arc4random_buf` on Darwin and cannot fail. `SecRandomCopyBytes` would
    /// be equivalent but returns a status nothing can act on.
    static func generate() -> OAuthSecurity {
        OAuthSecurity(state: randomToken(), codeVerifier: randomToken())
    }

    private static func randomToken() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    /// base64url without padding, per RFC 4648 §5.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Pulls the authorisation code out of a callback URL, rejecting anything
    /// whose `state` is not the one we sent.
    ///
    /// The state check is the whole point: a callback carrying a valid-looking
    /// `code` from some other authorisation is otherwise indistinguishable from
    /// ours, and we would exchange it and store the resulting token as the
    /// user's own.
    ///
    /// An `error` in the callback is reported as itself rather than as "no
    /// code" — a denied consent screen and a malformed redirect are different
    /// problems, and the old code called both `.noCode`.
    ///
    /// The error is read before the state check. RFC 6749 §4.1.2.1 makes `state`
    /// REQUIRED on an error response *if the client sent one* — which these
    /// flows now always do — so in theory the order does not matter; in
    /// practice not every server complies, and the only thing traded is which
    /// message the user sees. No error-carrying callback can yield a code
    /// either way: the single `return` below sits under the state guard.
    static func code(fromCallback url: URL?, expectedState: String) throws -> String {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw OAuthError.noCode }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let serverError = value("error") {
            throw OAuthError.server(serverError, description: value("error_description"))
        }

        // The empty check is hardening, not a live bug: `generate()` always
        // produces 43 characters. Without it, a caller that passed "" would
        // accept a callback carrying `state=`.
        guard !expectedState.isEmpty,
              let returned = value("state"), returned == expectedState else {
            throw OAuthError.stateMismatch
        }
        guard let code = value("code") else { throw OAuthError.noCode }
        return code
    }
}
