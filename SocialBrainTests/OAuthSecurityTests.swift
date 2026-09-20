import Testing
import Foundation
@testable import SocialBrain

@Suite("OAuth security")
struct OAuthSecurityTests {

    // MARK: - PKCE

    /// RFC 7636 Appendix B's published verifier/challenge pair.
    ///
    /// Checking the derivation against the spec's own vector rather than
    /// against our implementation's output — the latter passes just as happily
    /// when the hash is wrong.
    @Test("S256 challenge matches the RFC 7636 test vector")
    func pkceMatchesRFCVector() {
        let security = OAuthSecurity(
            state: "unused",
            codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(security.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("base64url uses no padding and no + or /")
    func base64URLIsURLSafe() {
        // Two bytes, so the group is short and standard base64 pads it:
        // 0xFB 0xFF encodes to "+/8=", exercising all three substitutions at
        // once. Three bytes would be a whole group, and the padding assertion
        // could then never fail.
        let encoded = OAuthSecurity.base64URL(Data([0xFB, 0xFF]))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(encoded == "-_8")
    }

    @Test("Generated values are unreserved characters of a length RFC 7636 allows")
    func generatedValuesAreWellFormed() {
        let security = OAuthSecurity.generate()
        // RFC 7636 §4.1: 43-128 characters from ALPHA / DIGIT / "-" / "." / "_" / "~".
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect((43...128).contains(security.codeVerifier.count))
        #expect(security.codeVerifier.unicodeScalars.allSatisfy(unreserved.contains))
        #expect(security.state.unicodeScalars.allSatisfy(unreserved.contains))
    }

    @Test("Each call generates different values")
    func generatedValuesAreUnique() {
        let a = OAuthSecurity.generate()
        let b = OAuthSecurity.generate()
        #expect(a.state != b.state)
        #expect(a.codeVerifier != b.codeVerifier)
        // The state must not be reused as the verifier — one travels in the
        // clear through the browser, the other must not.
        #expect(a.state != a.codeVerifier)
    }

    // MARK: - Callback verification

    private let security = OAuthSecurity(state: "STATE123", codeVerifier: "VERIFIER")

    @Test("A callback carrying the matching state yields the code")
    func matchingStateReturnsCode() throws {
        let url = URL(string: "socialbrain://oauth/mastodon?code=abc&state=STATE123")
        #expect(try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123") == "abc")
    }

    /// The reason this file exists: before #84 the callback was parsed for
    /// `code` and nothing else, so a substituted or replayed callback was
    /// indistinguishable from ours and its token was stored as the user's.
    @Test("A callback whose state does not match is rejected")
    func mismatchedStateThrows() {
        let url = URL(string: "socialbrain://oauth/mastodon?code=attacker&state=WRONG")
        #expect(throws: OAuthError.stateMismatch) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    @Test("A callback with no state at all is rejected")
    func missingStateThrows() {
        let url = URL(string: "socialbrain://oauth/mastodon?code=abc")
        #expect(throws: OAuthError.stateMismatch) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    @Test("State is compared exactly, not by prefix")
    func stateComparisonIsExact() {
        let url = URL(string: "socialbrain://oauth/mastodon?code=abc&state=STATE123456")
        #expect(throws: OAuthError.stateMismatch) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    @Test("A server error is reported as itself, not as a missing code")
    func serverErrorIsPropagated() {
        let url = URL(string:
            "socialbrain://oauth/mastodon?error=access_denied&error_description=User%20denied")
        #expect(throws: OAuthError.server("access_denied", description: "User denied")) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    /// RFC 6749 §4.1.2.1 makes `state` REQUIRED on an error response only if the
    /// client sent one. These flows always do, but not every server complies.
    /// Reading the error first means a declined consent screen says so, rather
    /// than reporting a mismatch.
    @Test("A server error is reported even when the callback has no state")
    func serverErrorBeatsStateCheck() {
        let url = URL(string: "socialbrain://oauth/mastodon?error=access_denied")
        #expect(throws: OAuthError.server("access_denied", description: nil)) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    @Test("A nil callback URL is a missing code, not a crash")
    func nilCallbackThrows() {
        #expect(throws: OAuthError.noCode) {
            try OAuthSecurity.code(fromCallback: nil, expectedState: "STATE123")
        }
    }

    /// Hardening rather than a live bug — `generate()` never produces an empty
    /// state — but without the guard a caller passing "" would accept a
    /// callback carrying `state=`.
    @Test("An empty expected state matches nothing")
    func emptyExpectedStateIsRejected() {
        let url = URL(string: "socialbrain://oauth/mastodon?code=abc&state=")
        #expect(throws: OAuthError.stateMismatch) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "")
        }
    }

    @Test("A matching state with no code is a missing code")
    func matchingStateWithoutCodeThrows() {
        let url = URL(string: "socialbrain://oauth/mastodon?state=STATE123")
        #expect(throws: OAuthError.noCode) {
            try OAuthSecurity.code(fromCallback: url, expectedState: "STATE123")
        }
    }

    // MARK: - Error text

    /// `OAuthError.server` carries two server-controlled strings, and
    /// `PlatformCredentialSheet` renders `localizedDescription` straight into
    /// the credentials sheet. Bounding the length is a deliberate behaviour
    /// change, so it gets assertions rather than only a comment.
    /// Asserts the boundary exactly rather than "shorter than some slack
    /// figure": with `< 300` here, widening the limit to 250 was still a pass.
    @Test("A long server description is clipped to exactly 200 characters")
    func longServerDescriptionIsClipped() throws {
        let long = String(repeating: "A", count: 5_000)
        let message = try #require(OAuthError.server("access_denied", description: long)
            .errorDescription)
        #expect(message.hasPrefix(String(repeating: "A", count: 200) + "\u{2026}"))
        #expect(message == String(repeating: "A", count: 200) + "\u{2026} (access_denied)")
    }

    @Test("A long error code is clipped to exactly 60 characters")
    func longServerCodeIsClipped() throws {
        let message = try #require(OAuthError.server(String(repeating: "B", count: 5_000),
                                                     description: nil).errorDescription)
        #expect(message == "The server refused the sign-in: "
                + String(repeating: "B", count: 60) + "\u{2026}.")
    }

    /// The limit itself is not a clip — one character over is.
    @Test("A description of exactly the limit is not marked as clipped")
    func descriptionAtTheLimitIsNotClipped() throws {
        let exact = String(repeating: "A", count: 200)
        let atLimit = try #require(OAuthError.server("e", description: exact).errorDescription)
        #expect(atLimit == exact + " (e)")

        let overBy1 = try #require(OAuthError.server("e", description: exact + "A")
            .errorDescription)
        #expect(overBy1 == exact + "\u{2026} (e)")
    }

    /// The marker must mean "cut", so a description that fits keeps its exact
    /// text and gains nothing.
    @Test("A short server description is passed through unchanged")
    func shortServerDescriptionIsNotClipped() throws {
        let message = try #require(OAuthError.server("access_denied", description: "User denied")
            .errorDescription)
        #expect(message == "User denied (access_denied)")
        #expect(!message.contains("\u{2026}"))
    }

    // MARK: - Authorisation URLs

    @Test("Mastodon's authorisation URL carries state and an S256 challenge")
    func mastodonAuthorizationURLCarriesPKCE() throws {
        let url = try MastodonOAuth.authorizationURL(
            instanceURL: URL(string: "https://mastodon.social")!,
            clientID: "CLIENT",
            security: security)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }

        #expect(value("state") == "STATE123")
        #expect(value("code_challenge") == security.codeChallenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("response_type") == "code")
        #expect(value("client_id") == "CLIENT")
        // The verifier itself must never travel in the authorisation request —
        // sending it would defeat the point of the challenge.
        #expect(!url.absoluteString.contains(security.codeVerifier))
    }

    @Test("Mastodon's authorisation URL keeps the instance's own host and path")
    func mastodonAuthorizationURLRespectsInstance() throws {
        let url = try MastodonOAuth.authorizationURL(
            instanceURL: URL(string: "https://social.example.org")!,
            clientID: "CLIENT",
            security: security)
        #expect(url.host == "social.example.org")
        #expect(url.path == "/oauth/authorize")
    }

    /// WordPress.com documents `state` but no PKCE parameters, so a challenge
    /// there would be sent and ignored. Asserting its absence pins that as a
    /// decision rather than an oversight.
    @Test("WordPress's authorisation URL carries state and no PKCE")
    func wordPressAuthorizationURLCarriesStateOnly() throws {
        let url = try WordPressOAuth.authorizationURL(clientID: "CLIENT", security: security)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }

        #expect(value("state") == "STATE123")
        #expect(value("code_challenge") == nil)
        #expect(value("code_challenge_method") == nil)
        #expect(value("response_type") == "code")
        #expect(url.host == "public-api.wordpress.com")
    }
}
