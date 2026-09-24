import Testing
import Foundation
@testable import SocialBrain

@Suite("InstanceRegistry Tests", .serialized)
struct InstanceRegistryTests {

    // Each instance of the suite gets its own registry on a throwaway defaults
    // suite. Previously this reassigned the global `InstanceRegistry.defaults`,
    // which stayed repointed for the rest of the process — so whether other
    // suites wrote to test defaults or to the real app preferences depended on
    // execution order.
    private let registry: InstanceRegistry

    init() {
        registry = ScratchRegistry.make("InstanceRegistryTests")
        registry.resetAll()
    }

    @Test("Fresh platform auto-seeds default instance")
    func autoSeeds() {
        let names = registry.instances(for: .buttondown)
        #expect(names == ["default"])
    }

    @Test("Adding an instance appends to the list")
    func addInstance() {
        registry.add(instanceName: "newsletter-2", to: .buttondown)
        let names = registry.instances(for: .buttondown)
        #expect(names.contains("newsletter-2"))
        #expect(names.count == 2)
    }

    @Test("Adding the same name twice is idempotent")
    func addDuplicateIsIdempotent() {
        registry.add(instanceName: "dup", to: .buttondown)
        registry.add(instanceName: "dup", to: .buttondown)
        let names = registry.instances(for: .buttondown)
        #expect(names.filter { $0 == "dup" }.count == 1)
    }

    @Test("Removing an instance removes it")
    func removeInstance() {
        registry.add(instanceName: "extra", to: .mastodon)
        registry.remove(instanceName: "extra", from: .mastodon)
        let names = registry.instances(for: .mastodon)
        #expect(!names.contains("extra"))
    }

    @Test("The default instance cannot be removed when it is the only one")
    func cannotRemoveOnlyInstance() {
        // Named for what it now asserts: the `"default"` guard trips before
        // the last-instance one, so this no longer covers that.
        registry.remove(instanceName: "default", from: .bluesky)
        let names = registry.instances(for: .bluesky)
        #expect(names == ["default"])  // still present
    }

    @Test("A list that lost its default gets it back")
    func legacyListWithoutDefaultIsRepaired() {
        // The backward case. A build before the guard could remove
        // `"default"`, and the old auto-seed only ran when the key was absent
        // — so anyone who hit it stayed broken, with every platform-level API
        // addressing an instance the registry did not list.
        let store = InMemoryKeyValueStore()
        store.set(["work"], forKey: "instanceNames_mastodon")
        let registry = InstanceRegistry(defaults: store)

        let names = registry.instances(for: .mastodon)

        #expect(names.contains("default"))
        #expect(names.contains("work"))
        // Repaired in storage, not just in the answer.
        #expect(store.stringArray(forKey: "instanceNames_mastodon")?.contains("default") == true)
    }

    @Test("Cannot remove the default instance, even with others alongside it")
    func cannotRemoveDefault() {
        // The previous guard only stopped the list being emptied, so with a
        // second instance present "default" could go — and every
        // platform-level API resolves to it, so they carried on writing to an
        // instance nothing listed (#90).
        registry.add(instanceName: "work", to: .mastodon)
        registry.remove(instanceName: "default", from: .mastodon)

        #expect(registry.instances(for: .mastodon).contains("default"))
        #expect(registry.instances(for: .mastodon).contains("work"))
    }

    @Test("A named instance can still be removed while default stays")
    func namedInstanceStillRemovable() {
        registry.add(instanceName: "work", to: .mastodon)
        registry.remove(instanceName: "work", from: .mastodon)

        #expect(registry.instances(for: .mastodon) == ["default"])
    }

    @Test("allInstances returns one entry per configured (platform, name) pair")
    func allInstances() {
        registry.add(instanceName: "second", to: .buttondown)
        let all = registry.allInstances()
        // buttondown should have 2 entries; every other platform should have 1
        let buttondownInstances = all.filter { $0.platform == .buttondown }
        #expect(buttondownInstances.count == 2)
    }

    @Test("Registry survives UserDefaults round-trip")
    func roundTrip() {
        registry.add(instanceName: "persisted", to: .buffer)
        // Simulate restart by re-reading from the same defaults
        let names = registry.instances(for: .buffer)
        #expect(names.contains("persisted"))
    }

    @Test("resetAll clears all stored instance lists")
    func resetAll() {
        registry.add(instanceName: "extra", to: .mastodon)
        registry.resetAll()
        let names = registry.instances(for: .mastodon)
        #expect(names == ["default"])  // auto-seeded after reset
    }
}
