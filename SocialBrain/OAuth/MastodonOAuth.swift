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

    private nonisolated static let callbackScheme = "socialbrain"
    private nonisolated static let callbackURI    = "socialbrain://oauth/mastodon"

    // Strong references kept for the duration of the ASWebAuthenticationSession.
    // These stay MainActor-isolated on purpose. The completion handler below is
    // @Sendable (and so nonisolated) to avoid an executor-precondition crash, so
    // marking these nonisolated(unsafe) would let someone write to them straight
    // from that handler — on the XPC callback thread, racing the main-thread
    // write below, and releasing an ObjC object cross-thread. That is exactly
    // the bug this file already had once. Keeping the isolation means the
    // compiler flags it — "main actor-isolated static property '_session' can
    // not be mutated from a Sendable closure". Verified: it is a warning, not
    // an error, so it is a tripwire rather than a barrier. Still infinitely
    // better than nonisolated(unsafe), which says nothing at all.
    private static var _session:  ASWebAuthenticationSession?
    private static var _provider: ContextProvider?

    // MARK: - Public

    /// Authenticates with the given Mastodon instance and returns an access token.
    /// Authenticates with the given Mastodon instance and returns an access token.
    ///
    /// Reuses the stored application registration for this server if there is
    /// one. `POST /api/v1/apps` creates a new application on every call and the
    /// returned `client_secret` is the only handle on it, so registering each
    /// time left the user with applications they could not revoke (#84).
    ///
    /// - Parameter registrations: injected, with no production default, so a
    ///   test cannot reach the real Keychain by omitting it.
    static func authenticate(instanceURL: URL,
                             registrations: MastodonAppRegistrations) async throws -> String {
        let security = OAuthSecurity.generate()
        // `try?` to match the save below: a Keychain the app cannot read is a
        // reason to register afresh, not to refuse to sign in before the
        // browser has even opened.
        let stored = try? registrations.registration(for: instanceURL)
        let reg: MastodonAppRegistration
        if let stored {
            reg = stored
        } else {
            reg = try await registerAndStore(on: instanceURL, in: registrations)
        }

        let code = try await authorise(instanceURL: instanceURL,
                                       clientID: reg.clientID,
                                       security: security)
        do {
            return try await exchangeCode(
                code:         code,
                clientID:     reg.clientID,
                clientSecret: reg.clientSecret,
                instanceURL:  instanceURL,
                codeVerifier: security.codeVerifier
            )
        } catch let error as CollectorError {
            // A stored registration the instance no longer recognises — the
            // user revoked the application, or the instance was reset. Only
            // reachable when the credentials came from the Keychain: a
            // registration made seconds ago cannot be unknown, and treating a
            // fresh one this way would loop.
            //
            // Matched on `invalid_client` rather than on the status alone.
            // Doorkeeper answers a stale or replayed `code` with 400
            // `invalid_grant`, which is ordinary — the user left the consent
            // screen open too long — and discarding a good registration for it
            // would cause the exact bug this change removes: one more
            // unrevocable application on the next sign-in.
            //
            // Erring towards deleting on a genuine match, because there is no
            // UI anywhere to clear a stored registration: a false negative is
            // an unrecoverable loop, a false positive costs one duplicate app.
            //
            // Forgotten rather than retried inline: a retry would send the user
            // through a second browser consent screen inside one action, with
            // no explanation of why the first did not take.
            guard stored != nil,
                  case let .httpError(status, body) = error,
                  status == 400 || status == 401,
                  body.contains("invalid_client")
            else { throw error }
            // Not `try?`: if the delete fails — a locked Keychain — the next
            // attempt loads the same bad registration and fails the same way,
            // for ever. Better to say the Keychain could not be written.
            try registrations.removeRegistration(for: instanceURL)
            throw OAuthError.staleRegistration
        }
    }

    private static func registerAndStore(
        on instanceURL: URL, in registrations: MastodonAppRegistrations
    ) async throws -> MastodonAppRegistration {
        let wire = try await registerApp(on: instanceURL)
        let reg = MastodonAppRegistration(clientID: wire.clientID,
                                          clientSecret: wire.clientSecret)
        // A failure to store is not a failure to sign in — it costs a duplicate
        // application next time, which is the old behaviour, not a broken flow.
        try? registrations.save(reg, for: instanceURL)
        return reg
    }

    /// The authorisation URL, as a pure function so a test can inspect it.
    ///
    /// PKCE is sent to every instance. Mastodon added it in 4.3.0 and accepts
    /// only `S256`; older instances ignore the two parameters, and then ignore
    /// the `code_verifier` at the token step, so the flow still completes
    /// without the protection rather than breaking.
    nonisolated static func authorizationURL(instanceURL: URL,
                                 clientID: String,
                                 security: OAuthSecurity) throws -> URL {
        var comps = URLComponents(url: instanceURL.appendingPathComponent("oauth/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: callbackURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "read"),
            URLQueryItem(name: "state",                 value: security.state),
            URLQueryItem(name: "code_challenge",        value: security.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = comps.url else { throw OAuthError.badURL }
        return url
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

    private static func authorise(instanceURL: URL,
                                  clientID: String,
                                  security: OAuthSecurity) async throws -> String {
        let authURL = try authorizationURL(instanceURL: instanceURL,
                                           clientID: clientID,
                                           security: security)
        let expectedState = security.state

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(
                    url: authURL,
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
                    do {
                        continuation.resume(returning: try OAuthSecurity.code(
                            fromCallback: callbackURL, expectedState: expectedState))
                    } catch {
                        continuation.resume(throwing: error)
                    }
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
        code: String, clientID: String, clientSecret: String, instanceURL: URL,
        codeVerifier: String
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
            ("scope",         "read"),
            ("code_verifier", codeVerifier)
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
    /// The callback's `state` was absent or did not match the one we sent, so
    /// it does not belong to the sign-in the user started. Never retried
    /// automatically — a mismatch is a reason to stop, not to try again.
    case stateMismatch
    /// The stored application registration was rejected by the instance, and
    /// has been forgotten. Signing in again makes a new one.
    case staleRegistration
    /// The authorisation server refused, e.g. the user declined consent.
    /// Both strings come from the server, so `errorDescription` truncates the
    /// free-text half rather than rendering unbounded remote text in a
    /// credentials sheet.
    case server(String, description: String?)

    /// Bounds a server-supplied string, marking it when it has been cut so a
    /// truncated message does not read as a complete one.
    ///
    /// Length is the smaller half of the problem: the text still renders
    /// verbatim, so newlines or copy imitating the app survive this (#186).
    private static func clip(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : s.prefix(limit) + "\u{2026}"
    }

    var errorDescription: String? {
        switch self {
        case .badURL:    "Could not build the OAuth URL."
        case .noCode:    "The server did not return an authorisation code."
        case .cancelled: "Sign-in was cancelled."
        case .staleRegistration:
            "This Mastodon application registration is no longer recognised by the instance, so it has been discarded. Please try signing in again."
        case .stateMismatch:
            "The sign-in response did not match the request that started it, so it was rejected. Please try signing in again."
        case let .server(code, description):
            description.map { "\(Self.clip($0, to: 200)) (\(Self.clip(code, to: 60)))" }
                ?? "The server refused the sign-in: \(Self.clip(code, to: 60))."
        }
    }
}

// MARK: - Presentation context

final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
