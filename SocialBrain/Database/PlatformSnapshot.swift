import Foundation
import GRDB

/// Persisted analytics snapshot for one platform captured during a collection run.
struct PlatformSnapshot: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var runID: Int64
    /// Raw platform identifier (matches `Platform.rawValue`).
    var platform: String
    /// Instance name; `"default"` for single-instance setups.
    var instanceName: String
    var collectedAt: Date
    /// For file imports, the end of the period the export covers.
    ///
    /// Separate from `collectedAt` on purpose. `collectedAt` is the observation
    /// clock — it orders snapshots, decides which is latest, drives the staleness
    /// reminder and picks the pair `SpikeDetector` compares. `periodEnd` is what
    /// the chart axis and the prompt should say the data is *about*. Making one
    /// field do both meant a re-import produced two rows with an identical
    /// timestamp, which crashed `latestSnapshots()`, and an export more than
    /// three days old was born stale.
    var periodEnd: Date?
    /// JSON-encoded `[String: MetricValue]` dictionary.
    var metricsJSON: Data

    static let databaseTableName = "platformSnapshot"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PlatformSnapshot {
    static let run = belongsTo(CollectionRun.self)

    var platformEnum: Platform? { Platform(rawValue: platform) }

    /// The `PlatformInstance` for this snapshot, or nil if the platform raw value is unknown.
    var instanceEnum: PlatformInstance? {
        guard let p = platformEnum else { return nil }
        return PlatformInstance(platform: p, instanceName: instanceName)
    }

    /// Decode the stored metrics back into a dictionary.
    func decodedMetrics() throws -> [String: MetricValue] {
        try JSONDecoder().decode([String: MetricValue].self, from: metricsJSON)
    }

    /// Create a snapshot from a `PlatformData` value returned by a collector.
    init(runID: Int64, data: PlatformData) throws {
        self.runID = runID
        self.platform = data.platform.rawValue
        self.instanceName = data.instanceName
        self.collectedAt = data.collectedAt
        self.periodEnd = data.periodEnd
        self.metricsJSON = try JSONEncoder().encode(data.metrics)
    }

    /// Memberwise initialiser for tests that create snapshots directly.
    init(runID: Int64, platform: String, instanceName: String = "default",
         collectedAt: Date, periodEnd: Date? = nil, metricsJSON: Data) {
        self.id = nil
        self.periodEnd = periodEnd
        self.runID = runID
        self.platform = platform
        self.instanceName = instanceName
        self.collectedAt = collectedAt
        self.metricsJSON = metricsJSON
    }
}
