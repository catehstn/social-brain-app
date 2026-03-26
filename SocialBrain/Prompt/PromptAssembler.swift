import Foundation

// MARK: - Public API

/// Assembles a structured analytics prompt from a set of `PlatformData` snapshots.
///
/// Mirrors the trimming behaviour of the original `analyse.py`: produces counts
/// and short summaries rather than raw dumps so that the prompt stays within a
/// reasonable token budget.
struct PromptAssembler {

    /// A period label and the corresponding snapshots to include.
    struct Input {
        let periodLabel: String           // e.g. "Last 30 days"
        let reportDate: Date
        let snapshots: [PlatformData]
    }

    /// Builds the prompt string from the given input.
    func assemble(_ input: Input) -> String {
        var lines: [String] = []

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.dateStyle = .long
        dateFmt.timeStyle = .none

        lines.append("# Social Media & Publishing Analytics Report")
        lines.append("Date: \(dateFmt.string(from: input.reportDate))")
        lines.append("Period: \(input.periodLabel)")
        lines.append("")

        // Sort platforms alphabetically for a stable output order.
        let sorted = input.snapshots.sorted { $0.platform.displayName < $1.platform.displayName }

        for snap in sorted {
            if let section = platformSection(snap) {
                lines.append(section)
                lines.append("")
            }
        }

        lines.append("---")
        lines.append("")
        lines.append(analysisRequest)

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func platformSection(_ data: PlatformData) -> String? {
        let lines = platformLines(data)
        guard !lines.isEmpty else { return nil }
        var out = "## \(data.platform.displayName)\n"
        out += lines.map { "- \($0)" }.joined(separator: "\n")
        return out
    }

    private func platformLines(_ data: PlatformData) -> [String] {
        switch data.platform {
        case .mastodon:    return mastodonLines(data)
        case .bluesky:     return blueskyLines(data)
        case .buttondown:  return buttondownLines(data)
        case .goatCounter: return goatCounterLines(data)
        case .vercel:      return vercelLines(data)
        case .calendly:    return calendlyLines(data)
        case .amazon:      return amazonLines(data)
        case .jetpack:     return jetpackLines(data)
        case .linkedin:    return linkedinLines(data)
        case .oreilly:     return oreillyLines(data)
        case .substack:    return substackLines(data)
        }
    }

    // MARK: - Per-platform formatters

    private func mastodonLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("followers_count")  { lines.append("Followers: \(formatted(v))") }
        if let v = data.intMetric("following_count")  { lines.append("Following: \(formatted(v))") }
        if let v = data.intMetric("statuses_count")   { lines.append("All-time posts: \(formatted(v))") }
        if let v = data.intMetric("recent_posts")     { lines.append("Posts this period: \(v)") }
        var engagement: [String] = []
        if let v = data.doubleMetric("avg_reblogs")    { engagement.append("\(pct1(v)) boosts") }
        if let v = data.doubleMetric("avg_favourites") { engagement.append("\(pct1(v)) favourites") }
        if let v = data.doubleMetric("avg_replies")    { engagement.append("\(pct1(v)) replies") }
        if !engagement.isEmpty {
            lines.append("Average engagement per post: \(engagement.joined(separator: ", "))")
        }
        return lines
    }

    private func blueskyLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("followers_count") { lines.append("Followers: \(formatted(v))") }
        if let v = data.intMetric("follows_count")   { lines.append("Following: \(formatted(v))") }
        if let v = data.intMetric("posts_count")     { lines.append("All-time posts: \(formatted(v))") }
        if let v = data.intMetric("recent_posts")    { lines.append("Posts this period: \(v)") }
        var engagement: [String] = []
        if let v = data.doubleMetric("avg_likes")    { engagement.append("\(pct1(v)) likes") }
        if let v = data.doubleMetric("avg_reposts")  { engagement.append("\(pct1(v)) reposts") }
        if let v = data.doubleMetric("avg_replies")  { engagement.append("\(pct1(v)) replies") }
        if !engagement.isEmpty {
            lines.append("Average engagement per post: \(engagement.joined(separator: ", "))")
        }
        return lines
    }

    private func buttondownLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let total = data.intMetric("subscriber_count") {
            var sub = "Subscribers: \(formatted(total))"
            if let new = data.intMetric("new_subscribers"), new > 0 {
                sub += " (+\(new) new)"
            }
            lines.append(sub)
        }
        if let v = data.intMetric("emails_sent") { lines.append("Newsletters sent: \(v)") }
        if let open = data.doubleMetric("avg_open_rate") {
            var rate = "Average open rate: \(pct(open))"
            if let click = data.doubleMetric("avg_click_rate") {
                rate += ", click rate: \(pct(click))"
            }
            lines.append(rate)
        }
        return lines
    }

    private func goatCounterLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("total_pageviews") { lines.append("Pageviews: \(formatted(v))") }
        if let v = data.intMetric("unique_visitors")  { lines.append("Unique visitors: \(formatted(v))") }
        var topPages: [String] = []
        for i in 1...5 {
            if let page = data.stringMetric("top_page_\(i)") {
                topPages.append(page)
            }
        }
        if !topPages.isEmpty {
            lines.append("Top pages: \(topPages.joined(separator: ", "))")
        }
        return lines
    }

    private func vercelLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let total = data.intMetric("deployments") {
            var dep = "Deployments: \(total)"
            if let prod = data.intMetric("production_deployments") { dep += " (\(prod) production)" }
            lines.append(dep)
        }
        if let v = data.intMetric("error_deployments"), v > 0 {
            lines.append("Failed deployments: \(v)")
        }
        return lines
    }

    private func calendlyLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let total = data.intMetric("events_count") {
            var ev = "Scheduled events: \(total)"
            if let cancelled = data.intMetric("cancelled_count"), cancelled > 0 {
                ev += " (\(cancelled) cancelled)"
            }
            lines.append(ev)
        }
        if let v = data.intMetric("unique_invitees") { lines.append("Unique invitees: \(v)") }
        var types: [String] = []
        for i in 1...3 {
            if let t = data.stringMetric("top_event_type_\(i)") { types.append(t) }
        }
        if !types.isEmpty { lines.append("Top event types: \(types.joined(separator: ", "))") }
        return lines
    }

    private func amazonLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("units_ordered")   { lines.append("Units ordered: \(formatted(v))") }
        if let v = data.doubleMetric("royalties_usd") { lines.append("Royalties: $\(String(format: "%.2f", v))") }
        if let v = data.intMetric("page_reads_kenp") { lines.append("KENP reads: \(formatted(v))") }
        return lines
    }

    private func jetpackLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("views")   { lines.append("Views: \(formatted(v))") }
        if let v = data.intMetric("visitors") { lines.append("Visitors: \(formatted(v))") }
        if let v = data.intMetric("likes")   { lines.append("Likes: \(formatted(v))") }
        if let v = data.intMetric("comments") { lines.append("Comments: \(formatted(v))") }
        return lines
    }

    private func linkedinLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("followers")    { lines.append("Followers: \(formatted(v))") }
        if let v = data.intMetric("impressions")  { lines.append("Post impressions: \(formatted(v))") }
        if let v = data.intMetric("engagements")  { lines.append("Engagements: \(formatted(v))") }
        return lines
    }

    private func oreillyLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("page_views")  { lines.append("Page views: \(formatted(v))") }
        if let v = data.intMetric("unique_users") { lines.append("Unique users: \(formatted(v))") }
        if let v = data.intMetric("completions") { lines.append("Course completions: \(v)") }
        return lines
    }

    private func substackLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let total = data.intMetric("subscriber_count") {
            var sub = "Subscribers: \(formatted(total))"
            if let paid = data.intMetric("paid_subscribers") { sub += " (\(paid) paid)" }
            lines.append(sub)
        }
        if let v = data.intMetric("posts_published") { lines.append("Posts published: \(v)") }
        if let open = data.doubleMetric("avg_open_rate") { lines.append("Average open rate: \(pct(open))") }
        return lines
    }

    // MARK: - Formatting helpers

    private let numFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func formatted(_ n: Int) -> String {
        numFmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func pct(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }

    private func pct1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - Analysis request text

    private let analysisRequest = """
    Please analyse the above analytics data and provide:

    1. **Key trends** — what changed meaningfully compared to previous periods?
    2. **Platform highlights** — which platforms showed the strongest growth or engagement?
    3. **Content performance** — any signals about what topics or formats resonated?
    4. **Actionable recommendations** — 2–3 specific things to focus on in the coming period.

    Keep the analysis concise and focused on insights that are actionable.
    """
}
