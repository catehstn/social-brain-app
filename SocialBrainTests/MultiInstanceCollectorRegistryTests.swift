import Testing
import Foundation
@testable import SocialBrain

// MARK: - Stub collector for engine tests

private struct InstanceStubCollector: Collector {
    let platform: Platform
    var instanceName: String
    let metricsValue: MetricValue

    func collect(since: Date?, credentials: Credentials) async throws -> PlatformData {
        PlatformData(platform: platform, instanceName: instanceName,
                     metrics: ["followers_count": metricsValue])
    }
}

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

    @Test("Engine credentials closure receives PlatformInstance with correct instanceName")
    func collectionEngineUsesInstanceKeyedCredentials() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            InstanceStubCollector(platform: .buttondown, instanceName: "nl-a",
                                  metricsValue: .int(100)),
            InstanceStubCollector(platform: .buttondown, instanceName: "nl-b",
                                  metricsValue: .int(200))
        ]

        // Use a thread-safe box to verify PlatformInstance ids passed to the credentials closure.
        let box = CredentialCaptureBox()
        let creds: @Sendable (PlatformInstance) throws -> Credentials? = { instance in
            box.append(instance.id)
            return Credentials(["api_key": "test"])
        }

        _ = try await engine.run(collectors: collectors, credentials: creds)

        #expect(box.ids.contains("buttondown:nl-a"))
        #expect(box.ids.contains("buttondown:nl-b"))
    }

    @Test("PlatformData instanceName is passed through collector result")
    func platformDataPassedThroughWithInstanceName() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = CollectionEngine(database: db)

        let collector = InstanceStubCollector(platform: .mastodon, instanceName: "site-b",
                                              metricsValue: .int(42))
        let creds: @Sendable (PlatformInstance) throws -> Credentials? = { _ in
            Credentials(["api_key": "test"])
        }

        let summary = try await engine.run(collectors: [collector], credentials: creds)
        let successData = summary.results.compactMap(\.platformData).first
        #expect(successData?.instanceName == "site-b")
    }

    @Test("Snapshot saved with instanceName from collector")
    func snapshotSavedWithInstanceNameFromCollector() async throws {
        let db = try AppDatabase.makeInMemory()
        let engine = CollectionEngine(database: db)

        let collectors: [any Collector] = [
            InstanceStubCollector(platform: .buttondown, instanceName: "btn-1",
                                  metricsValue: .int(100)),
            InstanceStubCollector(platform: .buttondown, instanceName: "btn-2",
                                  metricsValue: .int(200))
        ]
        let creds: @Sendable (PlatformInstance) throws -> Credentials? = { _ in
            Credentials(["api_key": "test"])
        }

        let summary = try await engine.run(collectors: collectors, credentials: creds)
        let snapshots = try await db.snapshots(forRunID: summary.runID)
        let instanceNames = Set(snapshots.map(\.instanceName))
        #expect(instanceNames == ["btn-1", "btn-2"])
    }
}

// MARK: - Thread-safe capture box

/// @unchecked Sendable wrapper for capturing values from @Sendable closures.
private final class CredentialCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []

    func append(_ id: String) {
        lock.withLock { _ids.append(id) }
    }

    var ids: [String] {
        lock.withLock { _ids }
    }
}
