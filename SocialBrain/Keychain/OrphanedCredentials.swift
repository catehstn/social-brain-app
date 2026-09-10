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
        case "vercel":  URL(string: "https://vercel.com/account/tokens")
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
            // Split on the first colon only: an instance name may contain one.
            guard let separator = account.firstIndex(of: ":") else { return nil }
            let platformName = String(account[account.startIndex..<separator])
            let instanceName = String(account[account.index(after: separator)...])

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
