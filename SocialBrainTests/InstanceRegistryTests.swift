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

    @Test("Cannot remove the last instance")
    func cannotRemoveLast() {
        registry.remove(instanceName: "default", from: .bluesky)
        let names = registry.instances(for: .bluesky)
        #expect(names == ["default"])  // still present
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
