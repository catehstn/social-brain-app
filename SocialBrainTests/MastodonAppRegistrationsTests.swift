import Testing
import Foundation
@testable import SocialBrain

@Suite("Mastodon app registrations")
struct MastodonAppRegistrationsTests {

    // MARK: - Keying

    /// A registration belongs to a server, not to a `PlatformInstance`. Two
    /// accounts on the same host must resolve to one registration, or signing
    /// into the second creates a duplicate application — the bug this fixes.
    @Test("The account is the host, ignoring path, host case, user info and default port")
    func accountIsTheHost() throws {
        let cases = [
            "https://mastodon.social",
            "https://mastodon.social/",
            "https://mastodon.social/@someone",
            "https://MASTODON.SOCIAL",
            "https://Mastodon.Social/settings",
            // Userinfo is not part of the server. `evil.com@` in particular
            // must not be read as the host.
            "https://someone:secret@mastodon.social",
            "https://evil.com@mastodon.social",
            // The scheme's own default port, written out.
            "https://mastodon.social:443",
            // A fully-qualified name with the root dot.
            "https://mastodon.social."
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
    @Test("A non-default port is part of the account")
    func portIsPartOfTheAccount() throws {
        let plain = try #require(URL(string: "https://example.org"))
        let ported = try #require(URL(string: "https://example.org:8443"))
        #expect(MastodonAppRegistrations.account(for: plain) == "example.org")
        #expect(MastodonAppRegistrations.account(for: ported) == "example.org:8443")
    }

    /// Splitting these would cost a duplicate application, which is the whole
    /// problem this type exists to prevent.
    @Test("The scheme's default port does not split a server in two")
    func defaultPortDoesNotSplit() throws {
        let httpsPlain = try #require(URL(string: "https://example.org"))
        let https443   = try #require(URL(string: "https://example.org:443"))
        let httpPlain  = try #require(URL(string: "http://example.org"))
        let http80     = try #require(URL(string: "http://example.org:80"))

        #expect(MastodonAppRegistrations.account(for: https443)
                == MastodonAppRegistrations.account(for: httpsPlain))
        #expect(MastodonAppRegistrations.account(for: http80)
                == MastodonAppRegistrations.account(for: httpPlain))
        // 443 is not http's default, so it still counts there.
        let http443 = try #require(URL(string: "http://example.org:443"))
        #expect(MastodonAppRegistrations.account(for: http443) == "example.org:443")
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

    /// CLAUDE.md says the app uses two Keychain services and that the split is
    /// load-bearing. That is a claim about the whole source tree, so it is
    /// checked against the source rather than asserted in prose: a third
    /// service, or a new key shape written into the credential store, fails
    /// here and names the file.
    @Test("Production constructs exactly the two known Keychain services")
    func onlyTwoKeychainServicesExist() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SocialBrainTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("SocialBrain")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let paths = (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(!paths.isEmpty, "No Swift sources under \(root.path) — this would pass vacuously")

        var constructions: [String] = []
        for file in paths {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), trimmed.contains("KeychainStore(service:") else {
                    continue
                }
                constructions.append("\(file.lastPathComponent): \(trimmed)")
            }
        }

        #expect(constructions.count == 2,
                "Expected two KeychainStore services, found \(constructions.count): \(constructions)")
        #expect(constructions.contains { $0.contains("\"com.catehuston.SocialBrain\")") })
        #expect(constructions.contains { $0.contains("\"com.catehuston.SocialBrain.mastodon-apps\")") })
    }
}
