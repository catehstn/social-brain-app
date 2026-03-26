import Foundation

// MARK: - Result types

/// The outcome of running a single platform collector.
enum CollectionResult: Sendable {
    case success(PlatformData)
    case failure(platform: Platform, error: Error)

    var platform: Platform {
        switch self {
        case .success(let d):       return d.platform
        case .failure(let p, _):    return p
        }
    }

    var platformData: PlatformData? {
        guard case .success(let d) = self else { return nil }
        return d
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Summary of a completed collection run.
struct CollectionSummary: Sendable {
    let runID: Int64
    let startedAt: Date
    let completedAt: Date
    let results: [CollectionResult]

    var successCount: Int { results.filter(\.isSuccess).count }
    var errorCount:   Int { results.filter { !$0.isSuccess }.count }
    var platformCount: Int { results.count }
}

// MARK: - Engine

/// Orchestrates running all configured collectors, persisting results, and reporting progress.
///
/// Each collector runs concurrently (via a TaskGroup). Results are saved to the
/// `AppDatabase` even when some collectors fail, so partial data is never lost.
actor CollectionEngine {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// Runs every collector in `collectors`, saves results to the database, and returns a summary.
    ///
    /// - Parameters:
    ///   - collectors: The platform collectors to run (typically one per configured platform).
    ///   - credentials: A function that returns stored credentials for a given platform.
    ///   - since: Optional date; collectors only fetch data since this point in time.
    ///   - progress: Optional closure called after each collector completes with its result.
    func run(
        collectors: [any Collector],
        credentials: @escaping @Sendable (Platform) throws -> Credentials?,
        since: Date? = nil,
        progress: (@Sendable (CollectionResult) async -> Void)? = nil
    ) async throws -> CollectionSummary {
        let startedAt = Date()
        var run = CollectionRun(
            id: nil,
            startedAt: startedAt,
            completedAt: nil,
            platformCount: collectors.count,
            errorCount: 0
        )
        try await database.saveRun(&run)
        let runID = run.id!

        // Run all collectors concurrently, accumulating results.
        var results: [CollectionResult] = []
        await withTaskGroup(of: CollectionResult.self) { group in
            for collector in collectors {
                group.addTask {
                    do {
                        guard let creds = try credentials(collector.platform) else {
                            throw CollectorError.missingCredential("(no credentials stored for \(collector.platform.displayName))")
                        }
                        let data = try await collector.collect(since: since, credentials: creds)
                        return .success(data)
                    } catch {
                        return .failure(platform: collector.platform, error: error)
                    }
                }
            }
            for await result in group {
                results.append(result)
                if let progress { await progress(result) }
            }
        }

        // Persist successful snapshots.
        for result in results {
            if let data = result.platformData {
                var snapshot = try PlatformSnapshot(runID: runID, data: data)
                try await database.saveSnapshot(&snapshot)
            }
        }

        // Mark the run as completed.
        let errorCount = results.filter { !$0.isSuccess }.count
        try await database.completeRun(id: runID, errorCount: errorCount)

        let completedAt = Date()
        return CollectionSummary(
            runID: runID,
            startedAt: startedAt,
            completedAt: completedAt,
            results: results
        )
    }
}

// MARK: - Registry

/// Maps each `Platform` to its collector implementation.
///
/// Only platforms that have credentials stored in the Keychain are included,
/// so this always returns collectors that are ready to run.
enum CollectorRegistry {
    /// Returns all collectors for which the user has stored credentials.
    static func configured(
        hasCredentials: (Platform) -> Bool = KeychainStore.hasCredentials
    ) -> [any Collector] {
        Platform.allCases.compactMap { platform in
            guard hasCredentials(platform) else { return nil }
            return collector(for: platform)
        }
    }

    /// Returns the collector implementation for a given platform, or nil for
    /// file-export platforms that don't have an API collector.
    static func collector(for platform: Platform) -> (any Collector)? {
        switch platform {
        case .buttondown:  return ButtondownCollector()
        case .goatCounter: return GoatCounterCollector()
        case .vercel:      return VercelCollector()
        case .calendly:    return CalendlyCollector()
        case .mastodon:    return MastodonCollector()
        case .bluesky:     return BlueskyCollector()
        // File-export platforms and unimplemented platforms return nil.
        case .amazon, .jetpack, .linkedin, .oreilly, .substack:
            return nil
        }
    }
}
