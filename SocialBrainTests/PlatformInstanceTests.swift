import Testing
import Foundation
@testable import SocialBrain

@Suite("PlatformInstance Tests")
struct PlatformInstanceTests {

    @Test("id is platform:instanceName")
    func idFormat() {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "newsletter-1")
        #expect(inst.id == "buttondown:newsletter-1")
    }

    /// These two go through `displayName(using:)` rather than the `displayName`
    /// property, which reads `InstanceLabels.shared` and so the real
    /// preferences. With the property, a stored label for either instance made
    /// them fail — planting `instanceLabel_mastodon:default` and
    /// `instanceLabel_goat_counter:my-blog` reproduced it (#58, #90).
    @Test("displayName omits label for default instance")
    func displayNameDefault() {
        let inst = PlatformInstance(platform: .mastodon)
        let labels = InstanceLabels(defaults: InMemoryKeyValueStore())
        #expect(inst.displayName(using: labels) == "Mastodon")
    }

    @Test("displayName includes label for non-default instance")
    func displayNameNonDefault() {
        let inst = PlatformInstance(platform: .goatCounter, instanceName: "my-blog")
        let labels = InstanceLabels(defaults: InMemoryKeyValueStore())
        #expect(inst.displayName(using: labels) == "GoatCounter — my-blog")
    }

    @Test("Two instances with same platform+name are equal")
    func hashableEquality() {
        let a = PlatformInstance(platform: .bluesky, instanceName: "work")
        let b = PlatformInstance(platform: .bluesky, instanceName: "work")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Two instances with different names are not equal")
    func hashableInequality() {
        let a = PlatformInstance(platform: .bluesky, instanceName: "work")
        let b = PlatformInstance(platform: .bluesky, instanceName: "personal")
        #expect(a != b)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = PlatformInstance(platform: .buttondown, instanceName: "test-nl")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlatformInstance.self, from: data)
        #expect(decoded.platform == original.platform)
        #expect(decoded.instanceName == original.instanceName)
        #expect(decoded.id == original.id)
    }

    @Test("Default parameter is 'default'")
    func defaultInstanceName() {
        let inst = PlatformInstance(platform: .bluesky)
        #expect(inst.instanceName == "default")
    }
}
