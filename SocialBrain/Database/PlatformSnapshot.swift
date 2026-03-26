import Foundation
import GRDB

/// Persisted analytics snapshot for one platform captured during a collection run.
struct PlatformSnapshot: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var runID: Int64
    /// Raw platform identifier (matches `Platform.rawValue`).
    var platform: String
    var collectedAt: Date
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

    /// Decode the stored metrics back into a dictionary.
    func decodedMetrics() throws -> [String: MetricValue] {
        try JSONDecoder().decode([String: MetricValue].self, from: metricsJSON)
    }

    /// Create a snapshot from a `PlatformData` value returned by a collector.
    init(runID: Int64, data: PlatformData) throws {
        self.runID = runID
        self.platform = data.platform.rawValue
        self.collectedAt = data.collectedAt
        self.metricsJSON = try JSONEncoder().encode(data.metrics)
    }
}
