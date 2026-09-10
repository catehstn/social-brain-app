import Foundation
import os

// MARK: - URLSession abstraction (for testability)

/// Mirrors the async `URLSession.data(for:)` API so tests can inject a mock.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// MARK: - Collector protocol

/// A platform-specific analytics collector.
protocol Collector: Sendable {
    var platform: Platform { get }
    /// The instance name for this collector. Defaults to `"default"`.
    var instanceName: String { get }
    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData
    /// Returns a human-readable label for this instance (e.g. newsletter name,
    /// site name, handle). Called once after credentials are saved.
    /// Returns `nil` if no label can be determined.
    func fetchLabel(credentials: Credentials) async -> String?
}

extension Collector {
    var instanceName: String { "default" }
    func fetchLabel(credentials: Credentials) async -> String? { nil }
}

// MARK: - Errors

enum CollectorError: LocalizedError, Sendable {

    /// Turns a status code into something actionable, which is what the echoed
    /// response body was standing in for.
    static func hint(forStatus code: Int) -> String {
        switch code {
        case 401, 403: " — the credentials were rejected. Check the token hasn't expired or been revoked."
        case 404:      " — the endpoint or property wasn't found. Check the account or site identifier."
        case 429:      " — rate limited. Try again later."
        case 500...599: " — the service is having problems. This is usually temporary."
        // Anything else, including a 400 and the 1xx/3xx that decodeJSON also
        // rejects. Deliberately does not promise the response body: it is
        // logged, but as private data, so it reads as <private> in Console
        // unless someone has turned private-data logging on. Saying "the
        // details are in Console" would send the user to a redaction.
        default: " — the service rejected the request. That is usually a bug in Social Brain rather than something you can fix; please report it."
        }
    }

    case missingCredential(String)
    /// A credential is present but cannot be used — e.g. a site URL in a form
    /// Search Console does not accept. Distinct from `missingCredential`,
    /// because "you didn't enter it" and "what you entered won't work" need
    /// different things from the user.
    case invalidCredential(key: String, reason: String)
    /// Collected successfully, then could not be written to the database.
    /// Distinct from a collector failure: the data existed and was lost, and
    /// there is nothing the user can re-enter to fix it.
    case persistenceFailed(underlying: any Error)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let key):
            "Missing credential '\(key)'"
        case .invalidCredential(let key, let reason):
            "Credential '\(key)' is not usable: \(reason)"
        case .persistenceFailed(let underlying):
            "Collected, but could not be saved: \(underlying.localizedDescription)"
        case .httpError(let code, _):
            // The body is deliberately not shown. An error response from an
            // authenticated API can carry account details, and this string is
            // rendered on the Run screen — the screen most likely to end up in
            // a screenshot. It goes to the log instead; see decodeJSON.
            "HTTP \(code)\(Self.hint(forStatus: code))"
        case .decodingError(let msg):
            "Failed to decode response: \(msg)"
        case .networkError(let err):
            "Network error: \(err.localizedDescription)"
        }
    }
}

/// Where collector failures go.
///
/// Nothing user-facing points at this — the response body is logged as private
/// data, so it is redacted for anyone who has not deliberately turned that off,
/// and a hint promising otherwise would be pointing at `<private>`. It is here
/// for whoever is debugging a collector, not for the person using the app.
let collectorLog = Logger(subsystem: "com.catehuston.SocialBrain", category: "collector")

// MARK: - Shared HTTP helpers

extension URLRequest {
    /// Adds a `Bearer` Authorization header.
    mutating func setBearerToken(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Adds a `Token` Authorization header (used by Buttondown).
    mutating func setTokenAuth(_ token: String) {
        setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    }
}

// MARK: - Decode failure detail

extension DecodingError {

    /// Which field the error is about, as a dotted path — `statistics.clicks`,
    /// `updates[3].sent_at`. Empty when the error is about the root value.
    ///
    /// Coding keys are schema names, not data, so this is safe to show a user
    /// and to log `.public`. That holds only while nothing *reachable from
    /// `decodeJSON`* decodes a `[String: T]`, where the keys would be data
    /// rather than schema. Nothing reachable from here does today — though the
    /// app does decode `[String: MetricValue]` elsewhere, from its own metrics
    /// JSON, with a separate decoder that never lands in this path.
    ///
    /// If a response type ever gains a dictionary, this leaks twice over: the
    /// payload key renders as a field name, and a *numeric* key renders as an
    /// array index, because the stdlib's dictionary coding key sets `intValue`
    /// from the string. Revisit this before adding one.
    var fieldPath: String {
        var path = context.codingPath
        // `keyNotFound` reports the path of the *container*, so the missing key
        // itself has to be appended or the message names the parent.
        if case .keyNotFound(let key, _) = self { path.append(key) }

        return path.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty { result += "." }
                result += key.stringValue
            }
        }
    }

    /// What went wrong, built only from the error's structured fields — the type
    /// expected and whether the key was absent. Never from `debugDescription`,
    /// which can embed the offending *value*: `iso8601Flexible` in
    /// `ISO8601Decoding.swift` writes the raw timestamp into it. That string is
    /// for the log, at `.private`, not for a screen.
    var expectation: String {
        switch self {
        case .typeMismatch(let type, _):  "expected \(type)"
        case .valueNotFound(let type, _): "expected \(type), got null"
        case .keyNotFound:                "missing"
        case .dataCorrupted:              "not in the expected format"
        @unknown default:                 "could not be decoded"
        }
    }

    /// Foundation's own description of the failure. Useful, and unsafe to show:
    /// it may contain the value that failed. Log it `.private`, never render it.
    var debugDescriptionForLog: String { context.debugDescription }

    private var context: Context {
        switch self {
        case .typeMismatch(_, let c), .valueNotFound(_, let c),
             .keyNotFound(_, let c), .dataCorrupted(let c):
            c
        @unknown default:
            Context(codingPath: [], debugDescription: "")
        }
    }
}

/// Decodes a JSON response, throwing `CollectorError` on HTTP errors or decode failures.
func decodeJSON<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    response: URLResponse,
    decoder: JSONDecoder = JSONDecoder()
) throws -> T {
    guard let http = response as? HTTPURLResponse else {
        throw CollectorError.decodingError("Non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(decoding: data, as: UTF8.self)
        // The body does not go in the user-facing message, but it is the only
        // thing that says *which* field or parameter a 400 objected to, so it
        // has to survive somewhere.
        //
        // `.private` is the right default for an authenticated API's response,
        // and is why no user-facing string promises the body is readable:
        // Console shows it as <private>. Unredacting it needs an
        // `Enable-Private-Data` configuration profile installed — not a `log
        // config` flag; `private_data` is not among the modes `log help config`
        // lists on macOS 26.
        //
        // Note the trap that produced the wrong hint text in the first place:
        // under a debugger — including `xcodebuild test` — private data prints
        // in the clear. It looks readable while developing and is not in a
        // shipped build.
        //
        // The path is private for the same reason: it carries account and site
        // identifiers, e.g. /rest/v1.1/sites/12345678/stats. The host is not.
        collectorLog.error("""
            HTTP \(http.statusCode, privacy: .public) from \
            \(http.url?.host() ?? "?", privacy: .public)\
            \(http.url?.path ?? "", privacy: .private): \
            \(body, privacy: .private)
            """)
        throw CollectorError.httpError(statusCode: http.statusCode, body: body)
    }
    do {
        return try decoder.decode(type, from: data)
    } catch let error as DecodingError {
        // `error.localizedDescription` collapses every case to "The data
        // couldn't be read because it isn't in the correct format" — naming
        // neither the field nor the type expected, so a wrong-typed `sent_at`
        // and a wrong-typed `statistics.clicks` are indistinguishable (#152).
        //
        // Same privacy split as the HTTP branch above: the field path is schema
        // and goes out `.public`, the body and `debugDescription` are the
        // response's own content and stay `.private`. `debugDescription` is
        // private specifically because it can carry the offending value.
        let field = error.fieldPath
        collectorLog.error("""
            Decode failed \(field.isEmpty ? "at the top level" : "at \(field)", privacy: .public): \
            \(error.expectation, privacy: .public). \
            \(error.debugDescriptionForLog, privacy: .private) \
            Body: \(String(decoding: data, as: UTF8.self), privacy: .private)
            """)
        throw CollectorError.decodingError(
            field.isEmpty ? error.expectation : "'\(field)' \(error.expectation)"
        )
    } catch {
        throw CollectorError.decodingError(error.localizedDescription)
    }
}
