import Testing
import Foundation
@testable import SocialBrain

@Suite("Mastodon app registrations")
struct MastodonAppRegistrationsTests {

    // MARK: - Keying

    /// A registration belongs to a server, not to a `PlatformInstance`. Two
    /// accounts on the same host must resolve to one registration, or signing
    /// into the second creates a duplicate application — the bug this fixes.
    @Test("The account is the host, ignoring path, scheme case and user info")
    func accountIsTheHost() throws {
        let cases = [
            "https://mastodon.social",
            "https://mastodon.social/",
            "https://mastodon.social/@someone",
            "https://MASTODON.SOCIAL",
            "https://Mastodon.Social/settings"
        ]
        for string in cases {
            let url = try #require(URL(string: string))
            #expect(MastodonAppRegistrations.account(for: url) == "mastodon.social",
                    "\(string) should key on the host alone")
        }
    }

    @Test("Different hosts get different accounts")
    func differentHostsDiffer() throws {
        let a = try #require(URL(string: "https://mastodon.social"))
        let b = try #require(URL(string: "https://hachyderm.io"))
        #expect(MastodonAppRegistrations.account(for: a)
                != MastodonAppRegistrations.account(for: b))
    }

    /// A self-hosted instance on a non-default port is a different server from
    /// one on the same host without it.
    @Test("A port is part of the account")
    func portIsPartOfTheAccount() throws {
        let plain = try #require(URL(string: "https://example.org"))
        let ported = try #require(URL(string: "https://example.org:8443"))
        #expect(MastodonAppRegistrations.account(for: plain) == "example.org")
        #expect(MastodonAppRegistrations.account(for: ported) == "example.org:8443")
    }

    @Test("A URL with no host has no account")
    func noHostNoAccount() throws {
        #expect(MastodonAppRegistrations.account(for: try #require(URL(string: "file:///tmp/x")))
                == nil)
    }

    // MARK: - Round trip

    @Test("A saved registration is returned for the same server")
    func savedRegistrationRoundTrips() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let url = try #require(URL(string: "https://mastodon.social"))
            let reg = MastodonAppRegistration(clientID: "ID", clientSecret: "SECRET")

            #expect(try registrations.registration(for: url) == nil)
            try registrations.save(reg, for: url)
            #expect(try registrations.registration(for: url) == reg)
        }
    }

    /// The point of the whole change: the second sign-in must find the first
    /// sign-in's registration, even from a different account on that server.
    @Test("A second account on the same server reuses the registration")
    func sameServerReusesRegistration() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let first  = try #require(URL(string: "https://mastodon.social/@alice"))
            let second = try #require(URL(string: "https://mastodon.social/@bob"))
            let reg = MastodonAppRegistration(clientID: "ID", clientSecret: "SECRET")

            try registrations.save(reg, for: first)
            #expect(try registrations.registration(for: second) == reg)
        }
    }

    @Test("A different server does not see another's registration")
    func differentServersAreIsolated() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let mastodon = try #require(URL(string: "https://mastodon.social"))
            let hachyderm = try #require(URL(string: "https://hachyderm.io"))

            try registrations.save(
                MastodonAppRegistration(clientID: "ID", clientSecret: "SECRET"), for: mastodon)
            #expect(try registrations.registration(for: hachyderm) == nil)
        }
    }

    @Test("Saving twice for one server replaces rather than duplicates")
    func savingTwiceReplaces() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let url = try #require(URL(string: "https://mastodon.social"))

            try registrations.save(
                MastodonAppRegistration(clientID: "OLD", clientSecret: "OLD"), for: url)
            try registrations.save(
                MastodonAppRegistration(clientID: "NEW", clientSecret: "NEW"), for: url)

            #expect(try registrations.registration(for: url)?.clientID == "NEW")
            #expect(try store.storedAccounts() == ["mastodon.social"])
        }
    }

    @Test("A removed registration is gone")
    func removalWorks() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let url = try #require(URL(string: "https://mastodon.social"))

            try registrations.save(
                MastodonAppRegistration(clientID: "ID", clientSecret: "SECRET"), for: url)
            try registrations.removeRegistration(for: url)
            #expect(try registrations.registration(for: url) == nil)
        }
    }

    /// A half-written item reads as "no registration", because the caller's
    /// response to both is to register again. Throwing would strand the user
    /// with a sign-in that cannot proceed.
    @Test("A registration missing its secret reads as absent")
    func partialRegistrationReadsAsAbsent() throws {
        try ScratchKeychain.withStore { store in
            let registrations = MastodonAppRegistrations(keychain: store)
            let url = try #require(URL(string: "https://mastodon.social"))

            try store.save(Credentials(["client_id": "ID"]), account: "mastodon.social")
            #expect(try registrations.registration(for: url) == nil)
        }
    }

    // MARK: - Separation from platform credentials

    /// `OrphanedCredentials.find` treats any account it cannot parse as a
    /// platform as a stranded API token, and Settings offers to remove it. A
    /// registration keyed `"mastodon.social"` would be reported that way, which
    /// is why registrations live in their own Keychain service.
    ///
    /// This asserts the consequence rather than the configuration: the accounts
    /// a registration store writes must not be reachable from the credential
    /// store's own listing.
    @Test("Registrations are not visible to the credential store's orphan scan")
    func registrationsAreNotSeenAsOrphans() throws {
        try ScratchKeychain.withStore { credentialStore in
            try ScratchKeychain.withStore("registrations") { registrationStore in
                let registrations = MastodonAppRegistrations(keychain: registrationStore)
                let url = try #require(URL(string: "https://mastodon.social"))

                try credentialStore.save(Credentials(["token": "t"]),
                                         for: PlatformInstance(platform: .mastodon))
                try registrations.save(
                    MastodonAppRegistration(clientID: "ID", clientSecret: "SECRET"), for: url)

                let accounts = try credentialStore.storedAccounts()
                #expect(accounts == ["mastodon:default"])
                #expect(OrphanedCredentials.find(in: accounts).isEmpty)
            }
        }
    }

    /// The production store must not share a service with the production
    /// credential store, which is the whole basis of the test above.
    @Test("The shared registration store uses its own Keychain service")
    func sharedStoreIsSeparate() {
        #expect(MastodonAppRegistrations.shared.keychain.service != KeychainStore.shared.service)
    }
}
