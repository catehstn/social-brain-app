import Testing
import Foundation
@testable import SocialBrain

@Suite("InstanceRegistry Tests", .serialized)
struct InstanceRegistryTests {

    private let suiteName = "com.test.InstanceRegistryTests"

    init() {
        // Inject test defaults and clear them
        InstanceRegistry.defaults = UserDefaults(suiteName: suiteName)!
        InstanceRegistry.resetAll()
    }

    @Test("Fresh platform auto-seeds default instance")
    func autoSeeds() {
        let names = InstanceRegistry.instances(for: .buttondown)
        #expect(names == ["default"])
    }

    @Test("Adding an instance appends to the list")
    func addInstance() {
        InstanceRegistry.add(instanceName: "newsletter-2", to: .buttondown)
        let names = InstanceRegistry.instances(for: .buttondown)
        #expect(names.contains("newsletter-2"))
        #expect(names.count == 2)
    }

    @Test("Adding the same name twice is idempotent")
    func addDuplicateIsIdempotent() {
        InstanceRegistry.add(instanceName: "dup", to: .buttondown)
        InstanceRegistry.add(instanceName: "dup", to: .buttondown)
        let names = InstanceRegistry.instances(for: .buttondown)
        #expect(names.filter { $0 == "dup" }.count == 1)
    }

    @Test("Removing an instance removes it")
    func removeInstance() {
        InstanceRegistry.add(instanceName: "extra", to: .mastodon)
        InstanceRegistry.remove(instanceName: "extra", from: .mastodon)
        let names = InstanceRegistry.instances(for: .mastodon)
        #expect(!names.contains("extra"))
    }

    @Test("Cannot remove the last instance")
    func cannotRemoveLast() {
        InstanceRegistry.remove(instanceName: "default", from: .bluesky)
        let names = InstanceRegistry.instances(for: .bluesky)
        #expect(names == ["default"])  // still present
    }

    @Test("allInstances returns one entry per configured (platform, name) pair")
    func allInstances() {
        InstanceRegistry.add(instanceName: "second", to: .buttondown)
        let all = InstanceRegistry.allInstances()
        // buttondown should have 2 entries; every other platform should have 1
        let buttondownInstances = all.filter { $0.platform == .buttondown }
        #expect(buttondownInstances.count == 2)
    }

    @Test("Registry survives UserDefaults round-trip")
    func roundTrip() {
        InstanceRegistry.add(instanceName: "persisted", to: .vercel)
        // Simulate restart by re-reading from the same defaults
        let names = InstanceRegistry.instances(for: .vercel)
        #expect(names.contains("persisted"))
    }

    @Test("resetAll clears all stored instance lists")
    func resetAll() {
        InstanceRegistry.add(instanceName: "extra", to: .mastodon)
        InstanceRegistry.resetAll()
        let names = InstanceRegistry.instances(for: .mastodon)
        #expect(names == ["default"])  // auto-seeded after reset
    }
}
