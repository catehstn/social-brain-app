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

    nonisolated(unsafe) private static var _session:  ASWebAuthenticationSession?
    nonisolated(unsafe) private static var _provider: ContextProvider?

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
                ) { callbackURL, error in
                    _session  = nil
                    _provider = nil
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
                _session  = session
                _provider = provider
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

