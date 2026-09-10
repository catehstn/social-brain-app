import Foundation

/// A credential left behind when a platform was retired.
///
/// `KeychainStore` keys items by `"\(platform.rawValue):\(instanceName)"`. When
/// a `Platform` case is removed, its stored items keep those keys — and every
/// other method here takes a `Platform`, so nothing could name them again. The
/// app could not show, revoke or delete them (#118).
///
/// That is worse than a stranded snapshot row, which #43 was careful to keep:
/// a snapshot is inert, while a stranded credential is a **live API token**
/// sitting in the login Keychain that its owner has no reason to remember.
struct OrphanedCredential: Identifiable, Equatable, Sendable {
    /// The raw Keychain account, e.g. `"vercel:default"`.
    let id: String
    /// The platform part, e.g. `"vercel"`.
    let platformName: String
    /// The instance part, e.g. `"default"`.
    let instanceName: String

    /// Where the user goes to revoke the token. Deleting the Keychain item does
    /// not revoke anything, so this is the half that actually matters.
    var revocationURL: URL? {
        switch platformName {
        case "vercel":  URL(string: "https://vercel.com/account/settings/tokens")
        case "amazon":  nil  // KDP had no API token; the importer read a file.
        default:        nil
        }
    }

    var displayName: String {
        instanceName == "default" ? platformName : "\(platformName) (\(instanceName))"
    }
}

enum OrphanedCredentials {

    /// Stored credentials whose platform the app no longer knows about.
    ///
    /// Takes the accounts rather than reading the Keychain itself, so this is
    /// testable without touching a real store — and so the caller decides which
    /// store to ask.
    static func find(in accounts: [String]) -> [OrphanedCredential] {
        accounts.compactMap { account in
            guard !account.isEmpty else { return nil }

            // Split on the first colon only: an instance name may contain one.
            //
            // No colon at all means a key written before multi-instance landed,
            // when credentials were stored under the bare platform name. No
            // migration was ever written, so a Vercel token saved before then is
            // still sitting under `"vercel"` — exactly the stranded credential
            // this exists to surface, and the shape it is most likely to take,
            // since after multi-instance the app would have shown Vercel as
            // unconfigured and prompted a re-save that stranded the old key.
            //
            // Safe to treat as an orphan because a live key *always* contains a
            // colon: `PlatformInstance.id` is "\(rawValue):\(instanceName)".
            let platformName: String
            let instanceName: String
            if let separator = account.firstIndex(of: ":") {
                platformName = String(account[account.startIndex..<separator])
                instanceName = String(account[account.index(after: separator)...])
            } else {
                platformName = account
                instanceName = "default"
            }

            // A colon-prefixed account has no platform to name, so there is
            // nothing useful to show and nothing this app could have written.
            guard !platformName.isEmpty else { return nil }

            // Known platform, so not orphaned.
            guard Platform(rawValue: platformName) == nil else { return nil }

            return OrphanedCredential(
                id: account,
                platformName: platformName,
                instanceName: instanceName
            )
        }
    }
}
