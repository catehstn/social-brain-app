import Foundation
import GRDB

/// A record of one full analytics collection run across all configured platforms.
struct CollectionRun: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var startedAt: Date
    var completedAt: Date?
    var platformCount: Int
    var errorCount: Int

    static let databaseTableName = "collectionRun"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension CollectionRun {
    static let snapshots = hasMany(PlatformSnapshot.self)
}
