import Foundation

/// Parses a Substack email analytics CSV export into a `PlatformData` snapshot.
///
/// Handles both the current export format (title, post_date, delivered, open_rate, …)
/// and the older format (Subject, Date, Recipients, Opens, Open rate, …).
///
/// Key metrics produced:
/// - `posts_published`  – number of newsletter rows in the file
/// - `avg_open_rate`    – mean open rate, normalised to 0–1
/// - `avg_click_rate`   – mean click rate, normalised to 0–1 (if present)
struct SubstackImporter {

    enum ImportError: LocalizedError {
        case emptyFile
        case unrecognisedFormat

        var errorDescription: String? {
            switch self {
            case .emptyFile:          "The selected CSV file contains no data."
            case .unrecognisedFormat: "The CSV does not look like a Substack analytics export."
            }
        }
    }

    /// Parses `data` from a Substack CSV export and returns `PlatformData`.
    func parse(data: Data) throws -> PlatformData {
        guard let csv = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.emptyFile
        }
        let rows = parseCSV(csv)
        guard rows.count >= 2 else { throw ImportError.emptyFile }

        // Normalise header keys to lowercase with no surrounding whitespace.
        let header = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        // Detect format by which columns are present.
        if header.contains("title") || header.contains("post_date") {
            return try parseCurrentFormat(header: header, rows: Array(rows.dropFirst()))
        } else if header.contains("subject") || header.contains("recipients") {
            return try parseLegacyFormat(header: header, rows: Array(rows.dropFirst()))
        } else {
            throw ImportError.unrecognisedFormat
        }
    }

    // MARK: - Format parsers

    /// Current Substack export: title, post_date, delivered, open_rate, opens, …
    private func parseCurrentFormat(header: [String], rows: [[String]]) throws -> PlatformData {
        let col = columnIndex(header)
        let dataRows = rows.filter { !$0.allSatisfy(\.isEmpty) }
        guard !dataRows.isEmpty else { throw ImportError.emptyFile }

        let openRates  = dataRows.compactMap { openRate(from: $0[safe: col("open_rate")]) }
        let clickRates = dataRows.compactMap { openRate(from: $0[safe: col("click_rate")]) }

        var metrics: [String: MetricValue] = [
            "posts_published": .int(dataRows.count)
        ]
        if !openRates.isEmpty {
            metrics["avg_open_rate"] = .double(openRates.reduce(0, +) / Double(openRates.count))
        }
        if !clickRates.isEmpty {
            metrics["avg_click_rate"] = .double(clickRates.reduce(0, +) / Double(clickRates.count))
        }
        // Date the snapshot from the export's own newest post rather than from
        // the moment of import: a backfill would otherwise land as today.
        return PlatformData(
            platform: .substack,
            collectedAt: ExportDates.latest(in: dataRows, column: col("post_date")) ?? .now,
            metrics: metrics
        )
    }

    /// Legacy Substack export: Subject, Date, Recipients, Opens, Open rate, …
    private func parseLegacyFormat(header: [String], rows: [[String]]) throws -> PlatformData {
        let col = columnIndex(header)
        let dataRows = rows.filter { !$0.allSatisfy(\.isEmpty) }
        guard !dataRows.isEmpty else { throw ImportError.emptyFile }

        let openRates  = dataRows.compactMap { openRate(from: $0[safe: col("open rate")]) }
        let clickRates = dataRows.compactMap { openRate(from: $0[safe: col("click rate")]) }

        var metrics: [String: MetricValue] = [
            "posts_published": .int(dataRows.count)
        ]
        if !openRates.isEmpty {
            metrics["avg_open_rate"] = .double(openRates.reduce(0, +) / Double(openRates.count))
        }
        if !clickRates.isEmpty {
            metrics["avg_click_rate"] = .double(clickRates.reduce(0, +) / Double(clickRates.count))
        }
        return PlatformData(platform: .substack, metrics: metrics)
    }

    // MARK: - CSV helpers

    /// Returns a closure mapping a column name to its index, or -1 if absent.
    private func columnIndex(_ header: [String]) -> (String) -> Int {
        { name in header.firstIndex(of: name) ?? -1 }
    }

    /// Parses an open/click rate string (e.g. "45.2%", "0.452", "45.2") → 0–1 Double.
    private func openRate(from raw: String?) -> Double? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let value = Double(s) else { return nil }
        // If >1 assume percentage stored as 0–100; normalise to 0–1
        return value > 1 ? value / 100 : value
    }

    // MARK: - RFC 4180 CSV parser

    /// Minimal RFC 4180 CSV parser that handles quoted fields with embedded commas/newlines.
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
                case "\"":
                    inQuotes = true
                case ",":
                    fields.append(field)
                    field = ""
                case "\r":
                    break  // skip CR in CRLF
                case "\n":
                    fields.append(field)
                    rows.append(fields)
                    fields = []
                    field = ""
                default:
                    field.append(c)
                }
            }
            i = chars.index(after: i)
        }

        // Flush the last field/row if the file doesn't end with a newline.
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            rows.append(fields)
        }

        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

// MARK: - Collection<String> safe subscript

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
