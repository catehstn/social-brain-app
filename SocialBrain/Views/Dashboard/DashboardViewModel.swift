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
    var selectedPlatform: Platform = .mastodon
    var timeRange: TimeRange = .month

    var series: [MetricSeries] = []
    var isLoading = false

    private let database: AppDatabase

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

    init(database: AppDatabase, initialPlatform: Platform = .mastodon) {
        self.database = database
        self.selectedPlatform = initialPlatform
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshots = try await database.snapshots(
                for: selectedPlatform,
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

        let keys = metricKeys(for: selectedPlatform)
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
                    MetricPoint(date: snap.collectedAt, value: value)
                )
            }
        }

        return keys.compactMap { (key, label) -> MetricSeries? in
            guard let points = pointsPerKey[key], !points.isEmpty else { return nil }
            return MetricSeries(label: label, key: key, points: points)
        }
    }

    /// Returns the ordered (key, display label) pairs to chart for each platform.
    private func metricKeys(for platform: Platform) -> [(key: String, label: String)] {
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
            return [("total_pageviews", "Pageviews"),
                    ("unique_visitors", "Visitors")]
        case .vercel:
            return [("deployments", "Deployments"),
                    ("production_deployments", "Production"),
                    ("error_deployments", "Errors")]
        case .calendly:
            return [("events_count", "Events"),
                    ("unique_invitees", "Invitees")]
        case .jetpack:
            return [("followers_blog", "Followers"),
                    ("total_views", "Views"),
                    ("total_visitors", "Visitors")]
        case .amazon:
            return [("units_sold", "Units Sold"),
                    ("royalties_usd", "Royalties (USD)"),
                    ("kenp_pages_read", "KENP Pages Read")]
        case .linkedin:
            return [("total_impressions", "Impressions"),
                    ("total_likes", "Likes"),
                    ("total_comments", "Comments")]
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
