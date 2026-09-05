import Foundation

/// Parses a LinkedIn `Share Statistics.csv` export into a `PlatformData` snapshot.
///
/// LinkedIn's personal data export (Settings → Data Privacy → Get a copy of your data)
/// includes a ZIP archive. Inside is `Share Statistics.csv` with per-post analytics.
/// The user should extract this file and import it directly.
///
/// Expected columns (order-independent, case-insensitive):
///   Date, ShareLink, ShareCommentary, Impressions, Clicks, CTR (%), Likes, Comments, Shares
///
/// **This header list is unverified.** It was written alongside the importer,
/// not copied from a real export, and no LinkedIn fixture exists in the repo to
/// check it against. Real exports found elsewhere disagree — see `ctrColumn`.
/// #70 is blocked on obtaining one genuine file.
///
/// Key metrics produced:
/// - `posts_published`    – total number of posts in the file
/// - `total_impressions`  – sum of impressions across all posts
/// - `total_clicks`       – sum of clicks
/// - `total_likes`        – sum of likes / reactions
/// - `total_comments`     – sum of comments
/// - `total_shares`       – sum of shares
/// - `avg_ctr`            – mean click-through rate, normalised to 0–1
struct LinkedInImporter {

    enum ImportError: LocalizedError {
        case emptyFile
        case unrecognisedFormat

        var errorDescription: String? {
            switch self {
            case .emptyFile:          "The selected CSV file contains no data."
            case .unrecognisedFormat: "The file does not look like a LinkedIn Share Statistics export."
            }
        }
    }

    func parse(data: Data) throws -> PlatformData {
        // Detect XLSX (ZIP magic bytes PK\x03\x04) and delegate to the XLSX parser.
        if data.count > 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            return try LinkedInXLSXParser().parse(data: data)
        }

        guard let csv = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.emptyFile
        }
        let rows = parseCSV(csv)
        guard rows.count >= 2 else { throw ImportError.emptyFile }

        let header = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        // Require at least "impressions" to consider this a LinkedIn share stats file.
        guard header.contains("impressions") else { throw ImportError.unrecognisedFormat }

        let col = columnIndex(header)
        let dataRows = Array(rows.dropFirst()).filter { !$0.allSatisfy(\.isEmpty) }
        guard !dataRows.isEmpty else { throw ImportError.emptyFile }

        var totalImpressions = 0
        var totalClicks      = 0
        var totalLikes       = 0
        var totalComments    = 0
        var totalShares      = 0
        var ctrs: [Double]   = []

        for row in dataRows {
            if let v = intValue(row[safe: col("impressions")])  { totalImpressions += v }
            if let v = intValue(row[safe: col("clicks")])       { totalClicks      += v }
            if let v = intValue(row[safe: col("likes")])        { totalLikes       += v }
            if let v = intValue(row[safe: col("comments")])     { totalComments    += v }
            if let v = intValue(row[safe: col("shares")])       { totalShares      += v }
            // Header handling here is on shaky ground and deliberately
            // conservative — see the note above `ctrColumns`.
            if let resolved = ctrColumn(col),
               let v = RateParsing.rate(from: row[safe: resolved.index],
                                        isPercentColumn: resolved.isPercent) {
                ctrs.append(v)
            }
        }

        var metrics: [String: MetricValue] = [
            "posts_published":   .int(dataRows.count),
            "total_impressions": .int(totalImpressions),
        ]
        if totalClicks   > 0 { metrics["total_clicks"]   = .int(totalClicks) }
        if totalLikes    > 0 { metrics["total_likes"]    = .int(totalLikes) }
        if totalComments > 0 { metrics["total_comments"] = .int(totalComments) }
        if totalShares   > 0 { metrics["total_shares"]   = .int(totalShares) }
        if !ctrs.isEmpty {
            metrics["avg_ctr"] = .double(ctrs.reduce(0, +) / Double(ctrs.count))
        }

        return PlatformData(platform: .linkedin, metrics: metrics)
    }

    // MARK: - Helpers

    private func columnIndex(_ header: [String]) -> (String) -> Int? {
        { name in header.firstIndex(of: name) }
    }

    private func intValue(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(raw)
    }

    /// Resolves the click-through-rate column, and whether its values are
    /// percentages or fractions.
    ///
    /// **The units here are not confirmed against a real export.** This file's
    /// own doc comment claims the column is headed `CTR (%)`, but that string
    /// originates in the commit that wrote this importer (451be0f) rather than
    /// in any observed file, and the repo contains no LinkedIn fixture to check
    /// it against. Evidence gathered from real exports published elsewhere says:
    ///
    /// - The personal data archive has no CTR column at all.
    /// - The Creator analytics XLSX has no CTR column.
    /// - The company Page CSV has `Click through rate (CTR)`, holding a
    ///   **fraction** — 328 clicks / 1369 impressions appears as `0.239590943`.
    ///
    /// So a header saying `%` is treated as percentages, and the real observed
    /// header is treated as a fraction. A bare `ctr` falls back to magnitude,
    /// which is right for fractions and wrong only for a sub-1% percentage
    /// column that nobody has yet shown exists.
    ///
    /// Localisation defeats any header rule: the Spanish Page export heads this
    /// column `Porcentaje de clics` — literally "percentage of clicks" — while
    /// still holding a fraction. Matching on `%` would get that exactly wrong,
    /// which is why this matches known headers rather than looking for a marker.
    ///
    /// Settling this needs one real export. Tracked in #70.
    private func ctrColumn(_ col: (String) -> Int?) -> (index: Int, isPercent: Bool)? {
        // Percentage-valued headers first, then fraction-valued, then unknown.
        if let i = col("ctr (%)") { return (i, true) }
        if let i = col("click through rate (ctr)") { return (i, false) }
        if let i = col("ctr") { return (i, false) }
        return nil
    }

    // MARK: - RFC 4180 CSV parser (shared with SubstackImporter)

    private func parseCSV(_ input: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(input)
        var i = chars.startIndex

        while i < chars.endIndex {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    let next = chars.index(after: i)
                    if next < chars.endIndex && chars[next] == "\"" {
                        field.append("\"")
                        i = chars.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":
                    fields.append(field); field = ""
                case "\r": break
                case "\n":
                    fields.append(field)
                    rows.append(fields)
                    fields = []; field = ""
                default: field.append(c)
                }
            }
            i = chars.index(after: i)
        }

        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(fields)
        }

        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Overload for optional index from columnIndex returning Int?
private extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index else { return nil }
        return indices.contains(index) ? self[index] : nil
    }
}
