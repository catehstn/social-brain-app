// OAuthError, decodeJSON, and ContextProvider are defined in MastodonOAuth.swift
// (same module — no import needed)
import Foundation
import AuthenticationServices

/// Runs the WordPress.com OAuth 2.0 authorisation flow.
///
/// Requires a pre-registered WordPress.com app (create at developer.wordpress.com).
/// The app must have `socialbrain://oauth/wordpress` set as a redirect URI.
///
/// Flow:
/// 1. Opens ASWebAuthenticationSession → user logs in and approves in their browser.
/// 2. Exchanges the returned code for an access token.
@MainActor
enum WordPressOAuth {

    private static let callbackScheme = "socialbrain"
    private static let callbackURI    = "socialbrain://oauth/wordpress"

    static let authURL  = URL(string: "https://public-api.wordpress.com/oauth2/authorize")!
    static let tokenURL = URL(string: "https://public-api.wordpress.com/oauth2/token")!

    // Strong references kept for the duration of the ASWebAuthenticationSession.
    // These stay MainActor-isolated on purpose — see the matching note in
    // MastodonOAuth. The completion handler is @Sendable and therefore
    // nonisolated, so nonisolated(unsafe) here would let a future edit write to
    // them from the XPC callback thread, racing the main-thread write below.
    // As isolated, that edit gets a compiler warning instead of silence.
    private static var _session:  ASWebAuthenticationSession?
    private static var _provider: ContextProvider?

    // MARK: - Public

    /// Opens the WordPress.com sign-in browser and returns an access token.
    static func authenticate(clientID: String, clientSecret: String) async throws -> String {
        let code = try await authorise(clientID: clientID)
        return try await exchangeCode(code: code, clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: - Steps

    private static func authorise(clientID: String) async throws -> String {
        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: callbackURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: "global")
        ]
        guard let url = comps.url else { throw OAuthError.badURL }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { @Sendable callbackURL, error in
                    // @Sendable is load-bearing. This enum is @MainActor, so
                    // without it the closure inherits that isolation — but
                    // ASWebAuthenticationSession invokes the handler on an XPC
                    // reply queue (com.apple.NSXPCConnection…SafariLaunchAgent),
                    // not the main queue. Under Swift 6 that trips an executor
                    // precondition (swift_task_isCurrentExecutor →
                    // dispatch_assert_queue → EXC_BREAKPOINT) the instant the
                    // callback fires, crashing the app on every completed
                    // sign-in. Marking it @Sendable stops the inheritance so it
                    // runs wherever AuthenticationServices calls it.
                    // Clearing hops back to the main queue — the same lane the
                    // assignment above uses, so the two stay FIFO-ordered with
                    // respect to each other. (An unstructured Task would also
                    // work today, but reaches the main actor by a different
                    // route and makes the ordering harder to reason about.)
                    DispatchQueue.main.async {
                        _session  = nil
                        _provider = nil
                    }
                    if let error {
                        let nsErr = error as NSError
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                            || (nsErr.domain == "com.apple.ViewBridge" && nsErr.code == 18)
                        continuation.resume(throwing: cancelled ? OAuthError.cancelled : error)
                        return
                    }
                    guard let code = callbackURL
                        .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                    else {
                        continuation.resume(throwing: OAuthError.noCode)
                        return
                    }
                    continuation.resume(returning: code)
                }
                let provider = ContextProvider()
                session.presentationContextProvider = provider
                // Already on the main thread — DispatchQueue.main.async put us
                // here — so asserting the isolation is sound.
                MainActor.assumeIsolated {
                    _session  = session
                    _provider = provider
                }
                // A second hop defers start() past the current layout cycle,
                // avoiding the "-layoutSubtreeIfNeeded on a view which is already
                // being laid out" recursion on macOS.
                DispatchQueue.main.async { session.start() }
            }
        }
    }

    private static func exchangeCode(
        code: String, clientID: String, clientSecret: String
    ) async throws -> String {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            ("grant_type",    "authorization_code"),
            ("code",          code),
            ("client_id",     clientID),
            ("client_secret", clientSecret),
            ("redirect_uri",  callbackURI)
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let tokenResp = try decodeJSON(TokenResponse.self, from: data, response: response)
        return tokenResp.accessToken
    }

    // MARK: - Helpers

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

