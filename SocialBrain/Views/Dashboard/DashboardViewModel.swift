import SwiftUI

/// A single data point for a metric chart.
struct MetricPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// Describes one metric series to display on the dashboard.
struct MetricSeries: Identifiable {
    let id = UUID()
    let label: String
    let key: String
    let points: [MetricPoint]
}

@Observable
@MainActor
final class DashboardViewModel {
    var selectedInstance: PlatformInstance = PlatformInstance(platform: .mastodon)
    var timeRange: TimeRange = .month

    var allInstances: [PlatformInstance] = []
    var series: [MetricSeries] = []
    var isLoading = false

    private let database: AppDatabase
    private let labels: InstanceLabels

    enum TimeRange: String, CaseIterable, Identifiable {
        case week  = "7 days"
        case month = "30 days"
        case quarter = "90 days"
        case all = "All time"

        var id: String { rawValue }

        var since: Date {
            switch self {
            case .week:    Calendar.current.date(byAdding: .day, value:  -7, to: .now)!
            case .month:   Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            case .quarter: Calendar.current.date(byAdding: .day, value: -90, to: .now)!
            case .all:     .distantPast
            }
        }
    }

    /// `labels` orders the instance picker by display name. No default: the
    /// bare `displayName` reads `InstanceLabels.shared`, so this view model's
    /// tests were sorting by the developer's own labels (#184).
    init(database: AppDatabase,
         labels: InstanceLabels,
         initialInstance: PlatformInstance = PlatformInstance(platform: .mastodon)) {
        self.database = database
        self.labels = labels
        self.selectedInstance = initialInstance
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Refresh the list of available instances.
            let latestMap = try await database.latestSnapshots()
            allInstances = Array(latestMap.keys).sorted { $0.displayName(using: labels) < $1.displayName(using: labels) }

            let snapshots = try await database.snapshots(
                for: selectedInstance.platform,
                instanceName: selectedInstance.instanceName,
                from: timeRange.since
            )
            series = buildSeries(from: snapshots)
        } catch {
            series = []
        }
    }

    // MARK: - Private

    private func buildSeries(from snapshots: [PlatformSnapshot]) -> [MetricSeries] {
        guard !snapshots.isEmpty else { return [] }

        let keys = Self.metricKeys(for: selectedInstance.platform)
        var pointsPerKey: [String: [MetricPoint]] = [:]

        for snap in snapshots {
            let metrics = (try? snap.decodedMetrics()) ?? [:]
            for (key, label) in keys {
                let value: Double
                switch metrics[key] {
                case .int(let n):    value = Double(n)
                case .double(let d): value = d
                default: continue
                }
                pointsPerKey[key, default: []].append(
                    MetricPoint(date: snap.periodEnd ?? snap.collectedAt, value: value)
                )
            }
        }

        return keys.compactMap { (key, label) -> MetricSeries? in
            guard var points = pointsPerKey[key], !points.isEmpty else { return nil }
            // Sort by the plotted date. LineMark connects points in data order,
            // and rows arrive ordered by the query, so a periodEnd that differs
            // from collectedAt drew the line backwards.
            points.sort { $0.date < $1.date }
            return MetricSeries(label: label, key: key, points: points)
        }
    }

    /// Returns the ordered (key, display label) pairs to chart for each platform.
    /// Internal, not private, so the orphan detector can ask what this charts
    /// for a platform without duplicating the list (#63).
    nonisolated static func metricKeys(for platform: Platform) -> [(key: String, label: String)] {
        switch platform {
        case .mastodon:
            return [("followers_count", "Followers"),
                    ("avg_favourites", "Avg Favourites"),
                    ("avg_reblogs", "Avg Reblogs")]
        case .bluesky:
            return [("followers_count", "Followers"),
                    ("avg_likes", "Avg Likes"),
                    ("avg_reposts", "Avg Reposts")]
        case .buttondown:
            return [("subscriber_count", "Subscribers"),
                    ("avg_open_rate", "Open Rate"),
                    ("avg_click_rate", "Click Rate")]
        case .goatCounter:
            // One series, not two: the second entry read `unique_visitors`,
            // a metric the collector invented and GoatCounter has no endpoint
            // for (#156).
            return [("total_visits", "Visits")]
        case .calendly:
            return [("events_count", "Events"),
                    ("unique_invitees", "Invitees")]
        case .jetpack:
            return [("followers_blog", "Followers"),
                    ("total_views", "Views"),
                    ("total_visitors", "Visitors")]
        case .linkedin:
            // Both follower metrics: total_followers is the cumulative level,
            // new_followers the per-period growth, and the growth is the more
            // informative line — a cumulative series only steps when an export
            // lands. Nothing else in the app reported LinkedIn follower growth
            // at all (#114).
            //
            // members_reached is left off because it says little that
            // total_impressions does not — not because of crowding: each series
            // renders as its own card in an adaptive grid, so one more simply
            // scrolls. Add it if it proves useful.
            return [("total_impressions", "Impressions"),
                    ("total_likes", "Likes"),
                    ("total_comments", "Comments"),
                    ("total_followers", "Followers"),
                    ("new_followers", "New Followers")]
        case .oreilly:
            return [("total_page_views", "Page Views"),
                    ("total_unique_users", "Unique Users")]
        case .substack:
            return [("posts_published", "Posts Published"),
                    ("avg_open_rate", "Avg Open Rate")]
        default:
            return []
        }
    }
}
