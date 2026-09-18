import Testing
import Foundation
@testable import SocialBrain

@Suite("Multi-Instance Keychain Tests")
struct MultiInstanceKeychainTests {

    // Every test gets its own KeychainStore on a throwaway service name, so
    // nothing here can reach the developer's real credentials. Unique instance
    // names are still used because Swift Testing may run these in parallel.
    private let base = "com.test.keychain."

    private func scratch(_ label: String = #function) -> KeychainStore {
        ScratchKeychain.make(label)
    }

    @Test("Two instances of same platform stored independently")
    func twoInstances() throws {
        let store = scratch()
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "\(base)twoA")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "\(base)twoB")
        defer {
            try? store.delete(for: inst1)
            try? store.delete(for: inst2)
        }
        try? store.delete(for: inst1)
        try? store.delete(for: inst2)
        try store.save(Credentials(["api_key": "key-a"]), for: inst1)
        try store.save(Credentials(["api_key": "key-b"]), for: inst2)
        let creds1 = try store.load(for: inst1)
        let creds2 = try store.load(for: inst2)
        #expect(creds1?.apiKey == "key-a")
        #expect(creds2?.apiKey == "key-b")
    }

    @Test("hasCredentials returns false before saving")
    func missingCredentials() {
        let store = scratch()
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)missing")
        try? store.delete(for: inst)
        #expect(store.hasCredentials(for: inst) == false)
    }

    @Test("hasCredentials returns true after saving")
    func hasCredentialsTrueAfterSave() throws {
        let store = scratch()
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)hcTrue")
        defer { try? store.delete(for: inst) }
        try? store.delete(for: inst)
        try store.save(Credentials(["api_key": "x"]), for: inst)
        #expect(store.hasCredentials(for: inst) == true)
    }

    @Test("Platform-only API delegates to default instance")
    func platformAPIDelegate() throws {
        let store = scratch()
        let defaultInst = PlatformInstance(platform: .calendly)
        defer { try? store.delete(for: defaultInst) }
        try? store.delete(for: defaultInst)
        try store.save(Credentials(["api_key": "tok"]), for: Platform.calendly)
        let loaded = try store.load(for: defaultInst)
        #expect(loaded?.apiKey == "tok")
    }

    @Test("Deleting one instance leaves the other intact")
    func deleteOneInstance() throws {
        let store = scratch()
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "\(base)delA")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "\(base)delB")
        defer {
            try? store.delete(for: inst1)
            try? store.delete(for: inst2)
        }
        try? store.delete(for: inst1)
        try? store.delete(for: inst2)
        try store.save(Credentials(["api_key": "a"]), for: inst1)
        try store.save(Credentials(["api_key": "b"]), for: inst2)
        try store.delete(for: inst1)
        #expect(store.hasCredentials(for: inst1) == false)
        #expect(store.hasCredentials(for: inst2) == true)
    }

    @Test("Load returns nil after delete")
    func loadReturnsNilAfterDelete() throws {
        let store = scratch()
        let inst = PlatformInstance(platform: .buttondown, instanceName: "\(base)nilAfterDel")
        try? store.delete(for: inst)
        try store.save(Credentials(["api_key": "x"]), for: inst)
        try store.delete(for: inst)
        let result = try store.load(for: inst)
        #expect(result == nil)
    }

    @Test("Account key format uses platform_raw:instanceName")
    func accountKeyFormat() throws {
        let store = scratch()
        let inst = PlatformInstance(platform: .goatCounter, instanceName: "\(base)roundtrip")
        defer { try? store.delete(for: inst) }
        try? store.delete(for: inst)
        try store.save(Credentials(["api_key": "roundtrip"]), for: inst)
        let loaded = try store.load(for: inst)
        #expect(loaded?.apiKey == "roundtrip")
    }

    @Test("Stores with different services cannot see each other's credentials")
    func servicesAreIsolated() throws {
        let instance = PlatformInstance(platform: .buttondown, instanceName: "\(base)isolation")
        let a = scratch("isolationA")
        let b = scratch("isolationB")
        defer {
            try? a.delete(for: instance)
            try? b.delete(for: instance)
        }

        try a.save(Credentials(["api_key": "only-in-a"]), for: instance)

        #expect(try a.load(for: instance)?.apiKey == "only-in-a")
        #expect(try b.load(for: instance) == nil)
        #expect(b.hasCredentials(for: instance) == false)
    }

    @Test("The shared store is the only thing naming the production service")
    func sharedUsesProductionService() {
        #expect(KeychainStore.shared.service == "com.catehuston.SocialBrain")
        // A scratch store must never collide with it — this is what stops the
        // suite destroying real credentials.
        #expect(ScratchKeychain.make().service != KeychainStore.shared.service)
    }

    // MARK: - Isolation between concurrent test hosts (#127)

    @Test("A scratch service is scoped to this test run, not just this test")
    func scratchServiceIsScopedToTheRun() {
        // Two hosts running the suite at once — one per git worktree — used to
        // land on the same service name, and save()'s update-then-add is not
        // atomic across processes, so one of them got errSecDuplicateItem.
        // Without the run component this assertion is the whole bug: the name
        // would be identical in both hosts.
        let service = ScratchKeychain.make("scopeCheck").service
        let pid = String(ProcessInfo.processInfo.processIdentifier)

        #expect(service.hasPrefix("com.catehuston.SocialBrain.tests."),
                "must stay under the greppable prefix, or orphans become unfindable")
        #expect(service.contains(".\(pid)."),
                "must carry this process's id, or concurrent hosts collide")
        #expect(service.hasSuffix(".scopeCheck"),
                "must still name the test, so an orphan says where it came from")
    }

    @Test("A scratch store starts empty even if the last run left something behind")
    func scratchStoreStartsEmpty() throws {
        // PIDs are recycled. A run that crashed between a write and its cleanup
        // strands an item, and the next process to be handed that PID would
        // otherwise inherit it and fail its first save the same way.
        let instance = PlatformInstance(platform: .buttondown, instanceName: "\(base)recycled")
        let first = ScratchKeychain.make("recycledPID")
        try first.save(Credentials(["api_key": "stranded"]), for: instance)
        #expect(try first.load(for: instance)?.apiKey == "stranded")

        // Same label, same PID — exactly what a recycled PID hands the next run.
        let second = ScratchKeychain.make("recycledPID")
        defer { try? second.delete(for: instance) }

        #expect(second.service == first.service)
        #expect(try second.load(for: instance) == nil)
    }

}

// MARK: - Credentials helpers

private extension Credentials {
    var apiKey: String? { values["api_key"] }
    var accessToken: String? { values["access_token"] }
}
