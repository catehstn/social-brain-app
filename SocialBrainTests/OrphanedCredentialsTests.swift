import Testing
import Foundation
@testable import SocialBrain

/// #118: retiring a platform leaves its credential in the Keychain under a key
/// nothing can name any more.
///
/// `KeychainStore` builds every key from a `Platform`, so once the case is gone
/// the item is unreachable — the app can neither show it nor delete it. Two
/// platforms have been retired so far (Vercel in #116, Amazon KDP in #149), and
/// anyone who configured either has a credential sitting there.
@Suite("Orphaned credentials")
struct OrphanedCredentialsTests {

    @Test("A credential for a platform the app no longer knows is found")
    func retiredPlatformsAreOrphans() {
        let found = OrphanedCredentials.find(in: [
            "vercel:default", "amazon:default", "mastodon:default"
        ])
        #expect(found.map(\.id) == ["vercel:default", "amazon:default"])
        // The live platform is not swept up with them — a bug here would
        // offer the user a "Remove" button for a credential still in use.
        #expect(!found.contains { $0.platformName == "mastodon" })
    }

    @Test("Every current platform's default key is recognised",
          arguments: Platform.allCases)
    func currentPlatformsAreNeverOrphans(platform: Platform) {
        let account = PlatformInstance(platform: platform).id
        #expect(OrphanedCredentials.find(in: [account]).isEmpty,
                "\(account) was treated as orphaned")
    }

    @Test("An instance name containing a colon is split on the first one only")
    func instanceNamesMayContainColons() {
        // Instance names come from the user, so this is not hypothetical: an
        // account of "vercel:team:prod" is one orphan named "team:prod", not a
        // parse failure that hides it.
        let found = OrphanedCredentials.find(in: ["vercel:team:prod"])
        #expect(found.count == 1)
        #expect(found.first?.platformName == "vercel")
        #expect(found.first?.instanceName == "team:prod")
    }

    @Test("A key written before multi-instance is still an orphan")
    func preMultiInstanceKeysAreFound() {
        // Credentials used to be stored under the bare platform name, with no
        // colon, and no migration was ever written. So a Vercel token saved
        // before that change is sitting under "vercel" — and it is the *likeliest*
        // stranded key, because once multi-instance landed the app would have
        // shown Vercel as unconfigured and prompted a re-save under the new
        // format, leaving the old one behind.
        //
        // An earlier version of this suite asserted these were correctly
        // ignored, which pinned the gap as intentional.
        let found = OrphanedCredentials.find(in: ["vercel", "mastodon", "nonsense"])
        #expect(found.map(\.id) == ["vercel", "nonsense"])
        #expect(found.first?.instanceName == "default")
        // A live platform's bare name is still not an orphan.
        #expect(!found.contains { $0.platformName == "mastodon" })
    }

    @Test("An account with no platform part is ignored")
    func emptyPlatformNamesAreIgnored() {
        // ":default" and "" name nothing this app could have written, and would
        // render a blank row with a Remove button.
        #expect(OrphanedCredentials.find(in: ["", ":default"]).isEmpty)
    }

    @Test("A named instance reads differently from a default one")
    func displayNames() {
        let found = OrphanedCredentials.find(in: ["vercel:default", "vercel:staging"])
        #expect(found.map(\.displayName) == ["vercel", "vercel (staging)"])
    }

    @Test("Vercel carries a revocation link; a file-import platform does not")
    func revocationLinks() {
        let found = OrphanedCredentials.find(in: ["vercel:default", "amazon:default"])
        // The link is the half that matters — deleting the Keychain item does
        // not revoke anything.
        #expect(found.first { $0.platformName == "vercel" }?.revocationURL?.host == "vercel.com")
        // Amazon KDP was a file import with no API token, so offering a
        // "revoke" link would send the user somewhere pointless.
        #expect(found.first { $0.platformName == "amazon" }?.revocationURL == nil)
    }

    // MARK: - Against a real store

    @Test("Stored accounts come back, and only for this service")
    func storedAccountsAreEnumerable() throws {
        try ScratchKeychain.withStore { store in
            try store.save(Credentials(["api_key": "a"]), for: PlatformInstance(platform: .mastodon))
            try store.save(Credentials(["api_key": "b"]), for: PlatformInstance(platform: .bluesky))

            let accounts = try store.storedAccounts()
            #expect(accounts == ["bluesky:default", "mastodon:default"])
            // Scoped to this store's service, so a test cannot see — or later
            // delete — anything in the developer's real Keychain.
            #expect(!accounts.contains { $0.hasPrefix("vercel") })
        }
    }

    @Test("An orphan can be deleted by account name, which is the only handle there is")
    func orphansCanBeDeleted() throws {
        try ScratchKeychain.withStore { store in
            // Written the way an older build would have, under a platform the
            // enum no longer has. `delete(for:)` cannot address this at all.
            try store.save(Credentials(["token": "live"]), for: PlatformInstance(platform: .mastodon))
            let account = "vercel:default"
            try store.saveRaw(Credentials(["token": "stranded"]), account: account)

            #expect(try store.storedAccounts().contains(account))
            try store.deleteAccount(account)
            #expect(!(try store.storedAccounts().contains(account)))
            // The live credential is untouched.
            #expect(try store.storedAccounts() == ["mastodon:default"])
        }
    }

    @Test("Sweeping a store removes every item, not just one")
    func deleteAllRemovesEverything() throws {
        // SecItemDelete with only a service in the query removes a *single*
        // match on the file-based keychain. deleteAll used to make one call and
        // report success, so ScratchKeychain's teardown left items behind in the
        // developer's real login Keychain — the failure audit item 1 records,
        // reintroduced the moment a test first used `withStore`.
        let store = ScratchKeychain.make()
        for i in 0..<5 {
            try store.saveRaw(Credentials(["k": "v"]), account: "retired\(i):default")
        }
        #expect(try store.storedAccounts().count == 5)
        try store.deleteAll()
        #expect(try store.storedAccounts().isEmpty)
    }

    @Test("A store with nothing in it reports nothing, rather than failing")
    func emptyStoreIsNotAnError() throws {
        // The ordinary case for anyone who has configured no platforms: the
        // query returns errSecItemNotFound, which is an absence and not an error.
        let store = ScratchKeychain.make()
        #expect(try store.storedAccounts().isEmpty)
    }

    @Test("Accounts come back in a stable order")
    func accountsAreSorted() throws {
        try ScratchKeychain.withStore { store in
            for name in ["zulu", "alpha", "mike"] {
                try store.saveRaw(Credentials(["k": "v"]), account: "\(name):default")
            }
            #expect(try store.storedAccounts() == ["alpha:default", "mike:default", "zulu:default"])
        }
    }

    @Test("Saving the same account twice replaces it rather than duplicating")
    func saveRawOverwrites() throws {
        try ScratchKeychain.withStore { store in
            try store.saveRaw(Credentials(["k": "first"]), account: "vercel:default")
            try store.saveRaw(Credentials(["k": "second"]), account: "vercel:default")
            #expect(try store.storedAccounts() == ["vercel:default"])
        }
    }

    @Test("An unknown platform has no revocation link rather than a guessed one")
    func unknownPlatformsHaveNoLink() {
        // Sending someone to a plausible-looking but wrong revocation page is
        // worse than sending them nowhere.
        let found = OrphanedCredentials.find(in: ["someservice:default"])
        #expect(found.first?.revocationURL == nil)
    }

    @Test("Deleting an account that is not there is not an error")
    func deletingAbsentAccountIsFine() throws {
        try ScratchKeychain.withStore { store in
            // The Settings row and the store can disagree if two windows are
            // open; a second click must not throw.
            try store.deleteAccount("vercel:default")
        }
    }
}
