import Foundation

/// Parses an O'Reilly Learning Platform monthly report into a `PlatformData` snapshot.
///
/// O'Reilly sends monthly author reports via email. The user should save the email
/// as a plain-text `.txt` file (or forward it and save the body) and import it here.
///
/// Two formats are supported:
///
/// 1. **Tabular** — a fixed-width table where columns are separated by 2+ spaces:
///    ```
///    Title               Page Views   Unique Users   Completions
///    Swift in Depth      4521         1203           87
///    ```
///
/// 2. **Key-value** — one metric per line with a colon separator:
///    ```
///    Page views: 9,432
///    Unique users: 3,105
///    ```
///
/// Key metrics produced:
/// - `total_page_views`   – total page views across all titles
/// - `total_unique_users` – total unique users across all titles
/// - `total_completions`  – total course completions (if present)
/// - `titles_count`       – number of distinct titles in the report
struct OReillyImporter {

    enum ImportError: LocalizedError {
        case emptyFile
        case unrecognisedFormat

        var errorDescription: String? {
            switch self {
            case .emptyFile:          "The selected file contains no data."
            case .unrecognisedFormat: "The file does not look like an O'Reilly monthly report."
            }
        }
    }

    func parse(data: Data) throws -> PlatformData {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.emptyFile
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyFile
        }

        let lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .init(charactersIn: "\r"))
        }

        // Try key-value format first (it has a colon in the relevant lines).
        if let metrics = parseKeyValueReport(lines: lines), !metrics.isEmpty {
            return PlatformData(platform: .oreilly, metrics: metrics)
        }

        // Fall back to tabular format.
        if let metrics = parseTabularReport(lines: lines), !metrics.isEmpty {
            return PlatformData(platform: .oreilly, metrics: metrics)
        }

        throw ImportError.unrecognisedFormat
    }

    // MARK: - Tabular parser

    /// Parses a fixed-width table where columns are delimited by 2+ spaces.
    /// Header detection: a line containing "page" and ("view" or "user") WITHOUT a colon.
    private func parseTabularReport(lines: [String]) -> [String: MetricValue]? {
        // Find header line (no colon, so it's not a key:value line)
        guard let headerIdx = lines.firstIndex(where: { line in
            let l = line.lowercased()
            return l.contains("page") && (l.contains("view") || l.contains("user")) && !l.contains(":")
        }) else { return nil }

        let headerParts = splitOnMultipleSpaces(lines[headerIdx])
            .map { $0.lowercased() }

        // headerParts[0] is assumed to be the "title" column.
        // The remaining parts are metric column names.
        let metricCols = Array(headerParts.dropFirst())
        guard !metricCols.isEmpty else { return nil }

        // Build an ordered list of metric keys from the column names.
        var orderedKeys: [String] = metricCols.map { part in
            if part.contains("view")    { return "total_page_views" }
            if part.contains("user")    { return "total_unique_users" }
            if part.contains("complet") { return "total_completions" }
            return ""           // unknown column — will be skipped
        }

        // Process data rows
        var totals: [String: Int] = [:]
        var titlesCount = 0

        for line in lines[(headerIdx + 1)...] {
            let parts = splitOnMultipleSpaces(line)
            // A data row must have at least 2 parts (title + ≥1 number)
            guard parts.count >= 2 else { continue }
            // The last (parts.count - 1) parts should be numbers matching metricCols
            let numericParts = Array(parts.dropFirst())
            guard numericParts.count == metricCols.count else { continue }
            // Verify at least one is numeric
            guard numericParts.contains(where: { Int($0.replacingOccurrences(of: ",", with: "")) != nil }) else { continue }

            titlesCount += 1
            for (i, rawVal) in numericParts.enumerated() {
                guard i < orderedKeys.count, !orderedKeys[i].isEmpty else { continue }
                let key = orderedKeys[i]
                let v = Int(rawVal.replacingOccurrences(of: ",", with: "")) ?? 0
                totals[key, default: 0] += v
            }
        }

        guard titlesCount > 0 else { return nil }

        var metrics: [String: MetricValue] = ["titles_count": .int(titlesCount)]
        for (key, total) in totals where !key.isEmpty {
            metrics[key] = .int(total)
        }
        return metrics
    }

    // MARK: - Key-value parser

    /// Parses reports formatted as "Label: 1234" lines (one metric per line).
    private func parseKeyValueReport(lines: [String]) -> [String: MetricValue]? {
        var metrics: [String: MetricValue] = [:]

        for line in lines {
            // Must contain exactly one colon
            let parts = line.components(separatedBy: ":").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let value = Int(parts[1].replacingOccurrences(of: ",", with: "")) else { continue }

            let key = parts[0].lowercased()
            if key.contains("page") && key.contains("view") {
                metrics["total_page_views"] = .int(value)
            } else if key.contains("unique") && key.contains("user") {
                metrics["total_unique_users"] = .int(value)
            } else if key.contains("complet") {
                metrics["total_completions"] = .int(value)
            } else if key == "titles" || key == "title count" {
                metrics["titles_count"] = .int(value)
            }
        }

        return metrics.isEmpty ? nil : metrics
    }

    // MARK: - Fixed-width column splitter

    /// Splits a line on runs of 2+ consecutive spaces, preserving single-space words
    /// within the same column (e.g. "Swift in Depth" and "Page Views").
    private func splitOnMultipleSpaces(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var spaceRun = 0

        for ch in s {
            if ch == " " {
                spaceRun += 1
            } else {
                if spaceRun >= 2 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                } else if spaceRun == 1 {
                    current += " "
                }
                spaceRun = 0
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }
}
