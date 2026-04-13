import Testing
import Foundation
@testable import SocialBrain

@Suite("Multi-Instance Keychain Tests")
struct MultiInstanceKeychainTests {

    // Use unique instance names per test to avoid cross-test interference
    // (Swift Testing may run tests in parallel; Keychain state is global).
    private let base = "com.test.keychain."

    @Test("Two instances of same platform stored independently")
    func twoInstances() throws {
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "\(base)twoA")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "\(base)twoB")
        defer {
            try? KeychainStore.delete(for: inst1)
            try? KeychainStore.delete(for: inst2)
        }
        try? KeychainStore.delete(for: inst1)
        try? KeychainStore.delete(for: inst2)
        try KeychainStore.save(Credentials(["api_key": "key-a"]), for: inst1)
        try KeychainStore.save(Credentials(["api_key": "key-b"]), for: inst2)
        let creds1 = try KeychainStore.load(for: inst1)
        let creds2 = try KeychainStore.load(for: inst2)
        #expect(creds1?.apiKey == "key-a")
        #expect(creds2?.apiKey == "key-b")
    }

    @Test("hasCredentials returns false before saving")
    func missingCredentials() {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)missing")
        try? KeychainStore.delete(for: inst)
        #expect(KeychainStore.hasCredentials(for: inst) == false)
    }

    @Test("hasCredentials returns true after saving")
    func hasCredentialsTrueAfterSave() throws {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)hcTrue")
        defer { try? KeychainStore.delete(for: inst) }
        try? KeychainStore.delete(for: inst)
        try KeychainStore.save(Credentials(["api_key": "x"]), for: inst)
        #expect(KeychainStore.hasCredentials(for: inst) == true)
    }

    @Test("Platform-only API delegates to default instance")
    func platformAPIDelegate() throws {
        let defaultInst = PlatformInstance(platform: .calendly)
        defer { try? KeychainStore.delete(for: defaultInst) }
        try? KeychainStore.delete(for: defaultInst)
        try KeychainStore.save(Credentials(["api_key": "tok"]), for: Platform.calendly)
        let loaded = try KeychainStore.load(for: defaultInst)
        #expect(loaded?.apiKey == "tok")
    }

    @Test("Deleting one instance leaves the other intact")
    func deleteOneInstance() throws {
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "\(base)delA")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "\(base)delB")
        defer {
            try? KeychainStore.delete(for: inst1)
            try? KeychainStore.delete(for: inst2)
        }
        try? KeychainStore.delete(for: inst1)
        try? KeychainStore.delete(for: inst2)
        try KeychainStore.save(Credentials(["api_key": "a"]), for: inst1)
        try KeychainStore.save(Credentials(["api_key": "b"]), for: inst2)
        try KeychainStore.delete(for: inst1)
        #expect(KeychainStore.hasCredentials(for: inst1) == false)
        #expect(KeychainStore.hasCredentials(for: inst2) == true)
    }

    @Test("Load returns nil after delete")
    func loadReturnsNilAfterDelete() throws {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)nilAfterDel")
        try? KeychainStore.delete(for: inst)
        try KeychainStore.save(Credentials(["api_key": "x"]), for: inst)
        try KeychainStore.delete(for: inst)
        let result = try KeychainStore.load(for: inst)
        #expect(result == nil)
    }

    @Test("Account key format uses platform_raw:instanceName")
    func accountKeyFormat() throws {
        let inst = PlatformInstance(platform: .goatCounter, instanceName: "\(base)roundtrip")
        defer { try? KeychainStore.delete(for: inst) }
        try? KeychainStore.delete(for: inst)
        try KeychainStore.save(Credentials(["api_key": "roundtrip"]), for: inst)
        let loaded = try KeychainStore.load(for: inst)
        #expect(loaded?.apiKey == "roundtrip")
    }
}

// MARK: - Credentials helpers

private extension Credentials {
    var apiKey: String? { values["api_key"] }
    var accessToken: String? { values["access_token"] }
}
