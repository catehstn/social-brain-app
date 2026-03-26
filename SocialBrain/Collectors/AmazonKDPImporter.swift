import Foundation

/// Parses an Amazon KDP "Prior Months' Royalties" TSV export into a `PlatformData` snapshot.
///
/// Amazon KDP exports are tab-separated files downloaded from the KDP dashboard under
/// Reports → Prior Months' Royalties (or KENP Read). The exact column set varies by
/// report type; this importer detects the available columns and produces the subset it
/// can compute.
///
/// Key metrics produced:
/// - `titles_with_sales`  – distinct titles with net units sold > 0
/// - `units_sold`         – total net units sold across all titles and marketplaces
/// - `royalties_usd`      – total royalties in the report's currency (USD for US marketplace)
/// - `kenp_pages_read`    – total Kindle Unlimited page reads (KENP report only)
struct AmazonKDPImporter {

    enum ImportError: LocalizedError {
        case emptyFile
        case unrecognisedFormat

        var errorDescription: String? {
            switch self {
            case .emptyFile:          "The selected file contains no data."
            case .unrecognisedFormat: "The file does not look like an Amazon KDP royalties export."
            }
        }
    }

    /// Parses `data` from an Amazon KDP TSV export and returns `PlatformData`.
    func parse(data: Data) throws -> PlatformData {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.emptyFile
        }
        // KDP reports sometimes lead with a BOM or a report-title line before the header.
        // Find the first row that looks like a real header (contains "Title" or "ASIN").
        let rawRows = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\r\t ")) }
            .filter { !$0.isEmpty }

        guard !rawRows.isEmpty else { throw ImportError.emptyFile }

        // Find the header row index — first row containing "Title" and "ASIN"
        guard let headerIdx = rawRows.firstIndex(where: { row in
            let low = row.lowercased()
            return low.contains("title") && low.contains("asin")
        }) else {
            throw ImportError.unrecognisedFormat
        }

        let header = rawRows[headerIdx].components(separatedBy: "\t")
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let dataRows = rawRows.dropFirst(headerIdx + 1)
            .map { $0.components(separatedBy: "\t") }
            .filter { $0.count > 1 }

        guard !dataRows.isEmpty else { throw ImportError.emptyFile }

        return buildMetrics(header: header, rows: dataRows)
    }

    // MARK: - Metric extraction

    private func buildMetrics(header: [String], rows: [[String]]) -> PlatformData {
        let col = columnIndex(header)

        // Net units sold — try several known column-name variants
        let unitsCol = col("net units sold") ?? col("net units") ?? col("units sold")
        // Royalties — try several known variants
        let royaltiesCol = col("royalties (usd)") ?? col("royalties") ?? col("royalty")
        // KENP / Kindle Unlimited pages read
        let kenpCol = col("kenp read") ?? col("pages read") ?? col("kenp")
        // Title column for counting distinct titles
        let titleCol = col("title") ?? 0

        var totalUnits     = 0
        var totalRoyalties = 0.0
        var totalKenp      = 0
        var titlesWithSales = Set<String>()

        for row in rows {
            let title = row[safe: titleCol]?.trimmingCharacters(in: .whitespaces) ?? ""

            if let uc = unitsCol, let units = Int(row[safe: uc]?.trimmingCharacters(in: .whitespaces) ?? "") {
                totalUnits += units
                if units > 0, !title.isEmpty { titlesWithSales.insert(title) }
            }

            if let rc = royaltiesCol,
               let raw = row[safe: rc]?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""),
               let royalty = Double(raw) {
                totalRoyalties += royalty
            }

            if let kc = kenpCol, let pages = Int(row[safe: kc]?.trimmingCharacters(in: .whitespaces) ?? "") {
                totalKenp += pages
            }
        }

        var metrics: [String: MetricValue] = [:]

        if unitsCol != nil {
            metrics["units_sold"]        = .int(totalUnits)
            metrics["titles_with_sales"] = .int(titlesWithSales.count)
        }
        if royaltiesCol != nil {
            metrics["royalties_usd"] = .double(totalRoyalties)
        }
        if kenpCol != nil, totalKenp > 0 {
            metrics["kenp_pages_read"] = .int(totalKenp)
        }

        return PlatformData(platform: .amazon, metrics: metrics)
    }

    // MARK: - Helpers

    /// Returns a closure mapping a column name to its index, or nil if absent.
    private func columnIndex(_ header: [String]) -> (String) -> Int? {
        { name in header.firstIndex(of: name) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
