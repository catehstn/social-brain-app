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
        /// Snapshots keyed by `PlatformInstance`.
        let snapshots: [PlatformInstance: PlatformSnapshot]
        var goal: AnalyticsGoal = .growReach
        var goalCustomText: String = ""
    }

    /// Builds the prompt string from the given input.
    func assemble(_ input: Input) -> String {
        var lines: [String] = []

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.dateFormat = "MMMM d, yyyy"

        lines.append("# Social Media & Publishing Analytics Report")
        lines.append("Date: \(dateFmt.string(from: input.reportDate))")
        lines.append("Period: \(input.periodLabel)")
        let goalLabel = (input.goal == .other && !input.goalCustomText.isEmpty)
            ? input.goalCustomText
            : input.goal.displayName
        lines.append("Goal: \(goalLabel)")
        lines.append("")

        // Group instances by platform to decide header style.
        let byPlatform = Dictionary(grouping: input.snapshots.keys, by: \.platform)

        // Sort platforms alphabetically for a stable output order.
        let sortedPlatforms = byPlatform.keys.sorted { $0.displayName < $1.displayName }

        for platform in sortedPlatforms {
            let instances = (byPlatform[platform] ?? [])
                .sorted { $0.instanceName < $1.instanceName }
            let multiInstance = instances.count > 1

            for instance in instances {
                guard let snap = input.snapshots[instance] else { continue }
                let headerLabel = multiInstance ? instance.displayName : platform.displayName
                // Build PlatformData from snapshot for formatting
                if let metrics = try? snap.decodedMetrics() {
                    let data = PlatformData(platform: platform,
                                            instanceName: instance.instanceName,
                                            collectedAt: snap.periodEnd ?? snap.collectedAt,
                                            metrics: metrics)
                    if let section = platformSection(data, header: headerLabel) {
                        lines.append(section)
                        lines.append("")
                    }
                }
            }
        }

        lines.append("---")
        lines.append("")
        lines.append(analysisRequest(for: input))

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func platformSection(_ data: PlatformData, header: String) -> String? {
        let lines = platformLines(data)
        guard !lines.isEmpty else { return nil }
        var out = "## \(header)\n"
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
        case .linkedin:            return linkedinLines(data)
        case .oreilly:             return oreillyLines(data)
        case .substack:            return substackLines(data)
        case .googleSearchConsole: return googleSearchConsoleLines(data)
        case .buffer:              return bufferLines(data)
        case .hackerNews:          return hackerNewsLines(data)
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
        // Reported independently. Nesting the click rate inside the open rate
        // was safe while the two were always emitted together, but each now
        // guards its own divisor — so an open-absent, click-present snapshot is
        // a real state, and the click rate was being silently dropped.
        var rates: [String] = []
        if let open = data.doubleMetric("avg_open_rate") {
            rates.append("Average open rate: \(pct(open))")
        }
        if let click = data.doubleMetric("avg_click_rate") {
            rates.append("Average click rate: \(pct(click))")
        }
        if !rates.isEmpty {
            lines.append(rates.joined(separator: ", "))
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
        if let units = data.intMetric("units_sold") {
            var s = "Units sold: \(formatted(units))"
            if let titles = data.intMetric("titles_with_sales") { s += " across \(titles) title\(titles == 1 ? "" : "s")" }
            lines.append(s)
        }
        if let v = data.doubleMetric("royalties_usd") { lines.append("Royalties: $\(String(format: "%.2f", v))") }
        if let v = data.intMetric("kenp_pages_read")  { lines.append("KENP pages read: \(formatted(v))") }
        return lines
    }

    private func jetpackLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let followers = data.intMetric("followers_blog") {
            var s = "Followers: \(formatted(followers))"
            if let comments = data.intMetric("followers_comment") { s += " (\(comments) comment subscribers)" }
            lines.append(s)
        }
        if let v = data.intMetric("total_views")    { lines.append("Views: \(formatted(v))") }
        if let v = data.intMetric("total_visitors")  { lines.append("Visitors: \(formatted(v))") }
        if let v = data.intMetric("total_likes")     { lines.append("Likes: \(formatted(v))") }
        if let v = data.intMetric("total_comments")  { lines.append("Comments: \(formatted(v))") }
        return lines
    }

    private func linkedinLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let posts = data.intMetric("posts_published") {
            var s = "Posts: \(posts)"
            if let imp = data.intMetric("total_impressions") { s += ", \(formatted(imp)) impressions" }
            lines.append(s)
        }
        var engagement: [String] = []
        if let v = data.intMetric("total_likes")    { engagement.append("\(formatted(v)) likes") }
        if let v = data.intMetric("total_comments") { engagement.append("\(formatted(v)) comments") }
        if let v = data.intMetric("total_shares")   { engagement.append("\(formatted(v)) shares") }
        if !engagement.isEmpty { lines.append("Engagement: \(engagement.joined(separator: ", "))") }
        if let v = data.doubleMetric("avg_ctr") { lines.append("Average CTR: \(pct(v))") }
        return lines
    }

    private func oreillyLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let titles = data.intMetric("titles_count") { lines.append("Titles: \(titles)") }
        if let v = data.intMetric("total_page_views")   { lines.append("Page views: \(formatted(v))") }
        if let v = data.intMetric("total_unique_users")  { lines.append("Unique users: \(formatted(v))") }
        if let v = data.intMetric("total_completions")  { lines.append("Course completions: \(formatted(v))") }
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

    private func bufferLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("sent_updates")      { lines.append("Posts sent: \(v)") }
        if let v = data.intMetric("scheduled_updates") { lines.append("Posts scheduled: \(v)") }
        if let v = data.intMetric("total_clicks")      { lines.append("Total clicks: \(formatted(v))") }
        if let v = data.intMetric("total_reach")       { lines.append("Total reach: \(formatted(v))") }
        if let v = data.intMetric("total_likes")       { lines.append("Total likes: \(formatted(v))") }
        for i in 1...3 {
            if let p = data.stringMetric("top_profile_\(i)") { lines.append("Top profile \(i): \(p)") }
        }
        return lines
    }

    private func hackerNewsLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let v = data.intMetric("mention_count")  { lines.append("Mentions: \(v)") }
        if let v = data.intMetric("total_points")   { lines.append("Total points: \(v)") }
        if let v = data.intMetric("total_comments") { lines.append("Total comments: \(v)") }
        for i in 1...3 {
            if let s = data.stringMetric("top_story_\(i)") { lines.append("Top story \(i): \(s)") }
        }
        return lines
    }

    private func googleSearchConsoleLines(_ data: PlatformData) -> [String] {
        var lines: [String] = []
        if let clicks      = data.intMetric("clicks")      { lines.append("Clicks: \(formatted(clicks))") }
        if let impressions = data.intMetric("impressions") { lines.append("Impressions: \(formatted(impressions))") }
        if let ctr         = data.doubleMetric("ctr")      { lines.append("CTR: \(pct(ctr))") }
        if let pos         = data.doubleMetric("avg_position") { lines.append("Avg position: \(String(format: "%.1f", pos))") }
        for i in 1...5 {
            if let q = data.stringMetric("top_query_\(i)") { lines.append("Top query \(i): \(q)") }
        }
        for i in 1...5 {
            if let p = data.stringMetric("top_page_\(i)") { lines.append("Top page \(i): \(p)") }
        }
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

    private func analysisRequest(for input: Input) -> String {
        let goalPhrase = (input.goal == .other && !input.goalCustomText.isEmpty)
            ? input.goalCustomText
            : input.goal.promptPhrase
        return """
        My primary goal is to \(goalPhrase).

        Please analyse the above analytics data and provide:

        1. **Key trends** — what changed meaningfully compared to previous periods?
        2. **Platform highlights** — which platforms showed the strongest growth or engagement?
        3. **Content performance** — any signals about what topics or formats resonated?
        4. **Actionable recommendations** — 2–3 specific things to focus on given my goal.

        Keep the analysis concise and focused on insights that are actionable.
        """
    }
}
