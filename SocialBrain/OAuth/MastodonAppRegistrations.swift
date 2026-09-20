import Foundation

/// The OAuth client credentials Mastodon hands back when an application
/// registers on an instance.
struct MastodonAppRegistration: Equatable, Sendable {
    let clientID: String
    let clientSecret: String
}

/// Remembers the application registration per Mastodon server, so signing in
/// twice does not create two applications.
///
/// Mastodon's `POST /api/v1/apps` creates a **new** application every time it
/// is called, and returns a `client_secret` that is the only thing identifying
/// it afterwards. Registering on every sign-in therefore left an application on
/// the user's instance that they could not revoke, because the app had already
/// thrown away the credentials naming it (#84).
///
/// Kept across a disconnect on purpose: reconnecting then reuses the
/// registration instead of creating another unrevocable application. That also
/// means a stored registration has no removal path in the UI — #188.
///
/// Keyed by server, not by `PlatformInstance`: a registration belongs to the
/// instance's *host*, so two accounts on mastodon.social share one, while an
/// account on another server needs its own.
///
/// ## Why a separate Keychain service
///
/// `KeychainStore.shared`'s service holds one kind of thing — a platform's
/// credentials, keyed `"\(platform.rawValue):\(instanceName)"` — and
/// `OrphanedCredentials.find` relies on that, treating any account it cannot
/// parse as a platform as a stranded token to show the user with a Remove
/// button. A registration stored alongside them would be reported as one.
/// Its own service keeps that invariant true rather than teaching the scanner
/// an exception.
struct MastodonAppRegistrations: Sendable {

    /// The production store.
    static let shared = MastodonAppRegistrations(
        keychain: KeychainStore(service: "com.catehuston.SocialBrain.mastodon-apps"))

    let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    /// The registration for `instanceURL`'s server, or `nil` if there is none.
    ///
    /// Returns `nil` rather than throwing when the stored item is missing a
    /// field: a half-written registration is indistinguishable from none, and
    /// the caller's response to both is to register again.
    func registration(for instanceURL: URL) throws -> MastodonAppRegistration? {
        guard let account = Self.account(for: instanceURL),
              let credentials = try keychain.load(account: account),
              let id = credentials.values["client_id"],
              let secret = credentials.values["client_secret"]
        else { return nil }
        return MastodonAppRegistration(clientID: id, clientSecret: secret)
    }

    func save(_ registration: MastodonAppRegistration, for instanceURL: URL) throws {
        guard let account = Self.account(for: instanceURL) else { return }
        try keychain.save(Credentials([
            "client_id":     registration.clientID,
            "client_secret": registration.clientSecret
        ]), account: account)
    }

    /// Forgets the registration for a server, so the next sign-in makes a new
    /// one. Called when the instance rejects the stored credentials.
    func removeRegistration(for instanceURL: URL) throws {
        guard let account = Self.account(for: instanceURL) else { return }
        try keychain.delete(account: account)
    }

    /// The Keychain account for a server.
    ///
    /// Host and port only, lowercased: `https://Mastodon.Social/@someone` and
    /// `https://mastodon.social` are the same server and must not register
    /// twice. `nil` for a URL with no host, which cannot name a server.
    ///
    /// A port that is the scheme's default is dropped, so `https://host` and
    /// `https://host:443` agree; a trailing root dot is dropped for the same
    /// reason. Both are the same server spelled differently, and splitting them
    /// costs the user a duplicate application — the thing this type exists to
    /// prevent. Scheme is deliberately *not* part of the key: the registration
    /// belongs to the server, not to how it was reached.
    static func account(for instanceURL: URL) -> String? {
        guard var host = instanceURL.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        guard let port = instanceURL.port else { return host }
        let scheme = instanceURL.scheme?.lowercased()
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
            return host
        }
        return "\(host):\(port)"
    }
}
