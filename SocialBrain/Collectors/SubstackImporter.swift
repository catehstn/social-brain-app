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

        // `is_published` is absent from some exports, and columnIndex signals
        // that with -1 rather than nil — so absence is checked explicitly here.
        // Getting this wrong would silently empty the set rather than fail.
        let publishedColumn = col("is_published")
        let publishedRows = publishedColumn < 0 ? dataRows : dataRows.filter {
            let raw = ($0[safe: publishedColumn] ?? "").lowercased()
            return raw.isEmpty || raw == "true" || raw == "1" || raw == "yes"
        }

        let openRates  = dataRows.compactMap { RateParsing.rate(from: $0[safe: col("open_rate")], isPercentColumn: false) }
        let clickRates = dataRows.compactMap { RateParsing.rate(from: $0[safe: col("click_rate")], isPercentColumn: false) }

        var metrics: [String: MetricValue] = [
            "posts_published": .int(dataRows.count)
        ]
        if !openRates.isEmpty {
            metrics["avg_open_rate"] = .double(openRates.reduce(0, +) / Double(openRates.count))
        }
        if !clickRates.isEmpty {
            metrics["avg_click_rate"] = .double(clickRates.reduce(0, +) / Double(clickRates.count))
        }
        // periodEnd, not collectedAt. The import happened now — that is what
        // orders snapshots and drives the staleness reminder — but the data
        // describes the period ending at the newest post, which is what the
        // chart axis and the prompt should say.
        return PlatformData(
            platform: .substack,
            // Published rows only. The export includes scheduled drafts, whose
            // dates are in the future and describe nothing that has happened.
            periodEnd: ExportDates.latest(in: publishedRows, column: col("post_date")),
            metrics: metrics
        )
    }

    /// Legacy Substack export: Subject, Date, Recipients, Opens, Open rate, …
    private func parseLegacyFormat(header: [String], rows: [[String]]) throws -> PlatformData {
        let col = columnIndex(header)
        let dataRows = rows.filter { !$0.allSatisfy(\.isEmpty) }
        guard !dataRows.isEmpty else { throw ImportError.emptyFile }

        // `is_published` is absent from some exports, and columnIndex signals
        // that with -1 rather than nil — so absence is checked explicitly here.
        // Getting this wrong would silently empty the set rather than fail.
        let publishedColumn = col("is_published")
        let publishedRows = publishedColumn < 0 ? dataRows : dataRows.filter {
            let raw = ($0[safe: publishedColumn] ?? "").lowercased()
            return raw.isEmpty || raw == "true" || raw == "1" || raw == "yes"
        }

        let openRates  = dataRows.compactMap { RateParsing.rate(from: $0[safe: col("open rate")], isPercentColumn: false) }
        let clickRates = dataRows.compactMap { RateParsing.rate(from: $0[safe: col("click rate")], isPercentColumn: false) }

        var metrics: [String: MetricValue] = [
            "posts_published": .int(dataRows.count)
        ]
        if !openRates.isEmpty {
            metrics["avg_open_rate"] = .double(openRates.reduce(0, +) / Double(openRates.count))
        }
        if !clickRates.isEmpty {
            metrics["avg_click_rate"] = .double(clickRates.reduce(0, +) / Double(clickRates.count))
        }
        // periodEnd, same as the current format. This path computed
        // publishedRows and then dropped it on the floor, so a legacy import was
        // stamped with the import clock and filed as today — the staleness the
        // periodEnd work exists to prevent.
        //
        // The dead binding did produce "initialization of immutable value
        // 'publishedRows' was never used" — verified with swiftc on a reduction
        // of the same construct. So the compiler said so all along and nobody
        // read it; there is no warning configuration to go and fix.
        //
        // The column is "Date" per the header this parser detects on. That name
        // comes from this file's own doc comment rather than an observed export,
        // which is exactly how the CTR (%) mistake happened — so it is used as a
        // lookup that returns nil when absent, never as an assumption. Where the
        // column is missing or unparseable, periodEnd stays nil and behaviour is
        // unchanged.
        return PlatformData(
            platform: .substack,
            periodEnd: ExportDates.latest(in: publishedRows, column: col("date")),
            metrics: metrics
        )
    }

    // MARK: - CSV helpers

    /// Returns a closure mapping a column name to its index, or -1 if absent.
    private func columnIndex(_ header: [String]) -> (String) -> Int {
        { name in header.firstIndex(of: name) ?? -1 }
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
