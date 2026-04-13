import Testing
import Foundation
@testable import SocialBrain

@Suite("Multi-Instance CollectorRegistry Tests")
struct MultiInstanceCollectorRegistryTests {

    @Test("configured() returns one collector per credentialed instance")
    func configuredReturnsTwoCollectorsForTwoButtondownInstances() {
        let inst1 = PlatformInstance(platform: .buttondown, instanceName: "nl-a")
        let inst2 = PlatformInstance(platform: .buttondown, instanceName: "nl-b")
        let credentialed: Set<String> = [inst1.id, inst2.id]

        let mockInstances: (Platform) -> [String] = { platform in
            platform == .buttondown ? ["nl-a", "nl-b"] : ["default"]
        }
        let mockHasCredentials: (PlatformInstance) -> Bool = { credentialed.contains($0.id) }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        let buttondownCollectors = collectors.filter { $0.platform == .buttondown }
        #expect(buttondownCollectors.count == 2)
        let names = Set(buttondownCollectors.map(\.instanceName))
        #expect(names == ["nl-a", "nl-b"])
    }

    @Test("Instance without credentials is excluded")
    func configuredExcludesUncredentialedInstances() {
        let mockInstances: (Platform) -> [String] = { _ in ["default"] }
        let mockHasCredentials: (PlatformInstance) -> Bool = { _ in false }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        #expect(collectors.isEmpty)
    }

    @Test("File-export platforms never appear in API collector list")
    func fileExportPlatformsNeverInApiCollectorList() {
        let mockInstances: (Platform) -> [String] = { _ in ["default"] }
        let mockHasCredentials: (PlatformInstance) -> Bool = { _ in true }

        let collectors = CollectorRegistry.configured(
            instances: mockInstances,
            hasCredentials: mockHasCredentials
        )
        let fileExportPlatforms: Set<Platform> = [.amazon, .linkedin, .oreilly, .substack]
        let collectorPlatforms = Set(collectors.map(\.platform))
        #expect(collectorPlatforms.isDisjoint(with: fileExportPlatforms))
    }

    @Test("collector(for:) returns collector carrying the correct instanceName")
    func collectorForInstanceCarriesInstanceName() {
        let inst = PlatformInstance(platform: .buttondown, instanceName: "nl-x")
        let collector = CollectorRegistry.collector(for: inst)
        #expect(collector?.instanceName == "nl-x")
    }

    @Test("CollectionResult.instance returns correct PlatformInstance for success")
    func collectionResultInstanceComputedProperty() {
        let data = PlatformData(platform: .mastodon, instanceName: "work", metrics: [:])
        let result = CollectionResult.success(data)
        #expect(result.instance == PlatformInstance(platform: .mastodon, instanceName: "work"))
    }

    @Test("CollectionResult.failure carries instanceName via .instance")
    func collectionResultFailureCarriesInstanceName() {
        let result = CollectionResult.failure(
            platform: .mastodon,
            instanceName: "personal",
            error: CollectorError.missingCredential("test")
        )
        #expect(result.instance == PlatformInstance(platform: .mastodon, instanceName: "personal"))
    }
}
