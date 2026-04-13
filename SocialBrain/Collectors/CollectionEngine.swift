import Foundation

// MARK: - Result types

/// The outcome of running a single platform collector.
enum CollectionResult: Sendable {
    case success(PlatformData)
    case failure(platform: Platform, instanceName: String, error: Error)

    /// The `PlatformInstance` for this result.
    var instance: PlatformInstance {
        switch self {
        case .success(let d):
            return PlatformInstance(platform: d.platform, instanceName: d.instanceName)
        case .failure(let p, let i, _):
            return PlatformInstance(platform: p, instanceName: i)
        }
    }

    var platform: Platform { instance.platform }

    var platformData: PlatformData? {
        guard case .success(let d) = self else { return nil }
        return d
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var error: Error? {
        guard case .failure(_, _, let e) = self else { return nil }
        return e
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
    ///   - collectors: The platform collectors to run (typically one per configured instance).
    ///   - credentials: A function that returns stored credentials for a given `PlatformInstance`.
    ///   - since: Optional date; collectors only fetch data since this point in time.
    ///   - progress: Optional closure called after each collector completes with its result.
    func run(
        collectors: [any Collector],
        credentials: @escaping @Sendable (PlatformInstance) throws -> Credentials?,
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
                    let instance = PlatformInstance(
                        platform: collector.platform,
                        instanceName: collector.instanceName
                    )
                    do {
                        guard let creds = try credentials(instance) else {
                            throw CollectorError.missingCredential("(no credentials stored for \(instance.displayName))")
                        }
                        let data = try await collector.collect(since: since, credentials: creds)
                        return .success(data)
                    } catch {
                        return .failure(
                            platform: collector.platform,
                            instanceName: collector.instanceName,
                            error: error
                        )
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

/// Maps each `PlatformInstance` to its collector implementation.
///
/// Only instances that have credentials stored in the Keychain are included,
/// so this always returns collectors that are ready to run.
enum CollectorRegistry {
    /// Returns all collectors for all instances with stored credentials.
    static func configured(
        instances: (Platform) -> [String] = InstanceRegistry.instances,
        hasCredentials: (PlatformInstance) -> Bool = KeychainStore.hasCredentials
    ) -> [any Collector] {
        Platform.allCases.flatMap { platform in
            instances(platform).compactMap { instanceName in
                let instance = PlatformInstance(platform: platform, instanceName: instanceName)
                guard hasCredentials(instance) else { return nil }
                return collector(for: instance)
            }
        }
    }

    /// Returns the collector implementation for a given `PlatformInstance`, or nil for
    /// file-export platforms that don't have an API collector.
    static func collector(for instance: PlatformInstance) -> (any Collector)? {
        switch instance.platform {
        case .buttondown:
            var c = ButtondownCollector(); c.instanceName = instance.instanceName; return c
        case .goatCounter:
            var c = GoatCounterCollector(); c.instanceName = instance.instanceName; return c
        case .vercel:
            var c = VercelCollector(); c.instanceName = instance.instanceName; return c
        case .calendly:
            var c = CalendlyCollector(); c.instanceName = instance.instanceName; return c
        case .mastodon:
            var c = MastodonCollector(); c.instanceName = instance.instanceName; return c
        case .bluesky:
            var c = BlueskyCollector(); c.instanceName = instance.instanceName; return c
        case .jetpack:
            var c = JetpackCollector(); c.instanceName = instance.instanceName; return c
        case .googleSearchConsole:
            var c = GoogleSearchConsoleCollector(); c.instanceName = instance.instanceName; return c
        case .buffer:
            var c = BufferCollector(); c.instanceName = instance.instanceName; return c
        case .hackerNews:
            var c = HackerNewsCollector(); c.instanceName = instance.instanceName; return c
        // File-export platforms return nil — they're imported manually.
        case .amazon, .linkedin, .oreilly, .substack:
            return nil
        }
    }
}
