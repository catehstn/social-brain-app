import Foundation
import AuthenticationServices

/// Runs the full Mastodon OAuth 2.0 authorisation flow.
///
/// Flow:
/// 1. Dynamically registers "Social Brain" as an application on the instance.
/// 2. Opens ASWebAuthenticationSession → user logs in and approves in their browser.
/// 3. Exchanges the returned code for an access token.
@MainActor
enum MastodonOAuth {

    private static let callbackScheme = "socialbrain"
    private static let callbackURI    = "socialbrain://oauth/mastodon"

    // Strong references kept for the duration of the ASWebAuthenticationSession.
    // nonisolated(unsafe) lets DispatchQueue.main.async assign these
    // without a Swift concurrency actor-isolation error.
    nonisolated(unsafe) private static var _session:  ASWebAuthenticationSession?
    nonisolated(unsafe) private static var _provider: ContextProvider?

    // MARK: - Public

    /// Authenticates with the given Mastodon instance and returns an access token.
    static func authenticate(instanceURL: URL) async throws -> String {
        let reg  = try await registerApp(on: instanceURL)
        let code = try await authorise(instanceURL: instanceURL, clientID: reg.clientID)
        return try await exchangeCode(
            code:         code,
            clientID:     reg.clientID,
            clientSecret: reg.clientSecret,
            instanceURL:  instanceURL
        )
    }

    // MARK: - Steps

    private static func registerApp(on instanceURL: URL) async throws -> AppRegistration {
        let url = instanceURL.appendingPathComponent("api/v1/apps")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            ("client_name",   "Social Brain"),
            ("redirect_uris", callbackURI),
            ("scopes",        "read"),
            ("website",       "https://github.com/catehstn/social-brain-app")
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        return try decodeJSON(AppRegistration.self, from: data, response: response)
    }

    private static func authorise(instanceURL: URL, clientID: String) async throws -> String {
        var comps = URLComponents(url: instanceURL.appendingPathComponent("oauth/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: callbackURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: "read")
        ]
        guard let authURL = comps.url else { throw OAuthError.badURL }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(
                    url: authURL,
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
                session.start()
            }
        }
    }

    private static func exchangeCode(
        code: String, clientID: String, clientSecret: String, instanceURL: URL
    ) async throws -> String {
        let url = instanceURL.appendingPathComponent("oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            ("grant_type",    "authorization_code"),
            ("code",          code),
            ("client_id",     clientID),
            ("client_secret", clientSecret),
            ("redirect_uri",  callbackURI),
            ("scope",         "read")
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let tokenResp = try decodeJSON(TokenResponse.self, from: data, response: response)
        return tokenResp.accessToken
    }

    // MARK: - Helpers

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { "\(rfc3986($0.0))=\(rfc3986($0.1))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func rfc3986(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Response models

    private struct AppRegistration: Decodable {
        let clientID:     String
        let clientSecret: String
        enum CodingKeys: String, CodingKey {
            case clientID     = "client_id"
            case clientSecret = "client_secret"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError, Equatable {
    case badURL
    case noCode
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badURL:    "Could not build the OAuth URL."
        case .noCode:    "The server did not return an authorisation code."
        case .cancelled: "Sign-in was cancelled."
        }
    }
}

// MARK: - Presentation context

private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
