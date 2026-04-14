import Foundation

/// Parses LinkedIn's Creator Analytics XLSX export.
///
/// The export (from linkedin.com/analytics/creator/content → Export) produces an
/// XLSX file with five sheets:
///
///   Sheet 1 – DISCOVERY:  Row 2 col A = "Impressions",   col B = total count.
///                          Row 3 col A = "Members reached", col B = count.
///   Sheet 2 – ENGAGEMENT: Row 1 = headers (Date, Impressions, Engagements).
///                          Rows 2+ = daily data.
///   Sheet 3 – TOP POSTS:  Per-post metrics (not parsed).
///   Sheet 4 – FOLLOWERS:  Row 1 col B = total follower count.
///                          Row 3 = headers (Date, New followers).
///                          Rows 4+ = daily data.
///   Sheet 5 – DEMOGRAPHICS: (not parsed)
///
/// Key metrics produced:
/// - `total_impressions`  – impressions total from the DISCOVERY sheet
/// - `members_reached`    – unique members reached (DISCOVERY sheet)
/// - `total_engagements`  – sum of the Engagements column (ENGAGEMENT sheet)
/// - `total_followers`    – follower count as of the report date (FOLLOWERS sheet)
/// - `new_followers`      – sum of new followers in the period (FOLLOWERS sheet)
struct LinkedInXLSXParser {

    enum ParseError: LocalizedError {
        case notXLSX
        case noUsableData

        var errorDescription: String? {
            switch self {
            case .notXLSX:       "The file is not a valid LinkedIn XLSX export."
            case .noUsableData:  "No usable metrics were found in the LinkedIn XLSX file."
            }
        }
    }

    func parse(data: Data) throws -> PlatformData {
        // Verify ZIP/XLSX magic bytes before attempting to parse.
        guard data.count > 4,
              data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B else {
            throw ParseError.notXLSX
        }

        let zip = try MiniZIPReader(data: data)
        let sharedStrings = extractSharedStrings(from: zip)

        var metrics: [String: MetricValue] = [:]

        // -- DISCOVERY (sheet1) --
        if let xml = try? zip.extractEntry(named: "xl/worksheets/sheet1.xml"),
           let doc = try? XMLDocument(data: xml) {
            if let v = numericCell(doc, ref: "B2") { metrics["total_impressions"] = .int(v) }
            if let v = numericCell(doc, ref: "B3") { metrics["members_reached"]   = .int(v) }
        }

        // -- ENGAGEMENT (sheet2): sum Engagements column from row 2 onward --
        if let xml = try? zip.extractEntry(named: "xl/worksheets/sheet2.xml"),
           let doc = try? XMLDocument(data: xml) {
            // Detect which column holds Engagements (typically "C") from the header row.
            let engCol = engagementsColumn(in: doc, sharedStrings: sharedStrings) ?? "C"
            let total  = sumColumn(in: doc, col: engCol, startRow: 2)
            if total > 0 { metrics["total_engagements"] = .int(total) }
        }

        // -- FOLLOWERS (sheet4) --
        if let xml = try? zip.extractEntry(named: "xl/worksheets/sheet4.xml"),
           let doc = try? XMLDocument(data: xml) {
            if let v = numericCell(doc, ref: "B1") { metrics["total_followers"] = .int(v) }
            let newF = sumColumn(in: doc, col: "B", startRow: 4)
            if newF > 0 { metrics["new_followers"] = .int(newF) }
        }

        guard !metrics.isEmpty else { throw ParseError.noUsableData }
        return PlatformData(platform: .linkedin, metrics: metrics)
    }

    // MARK: - Shared strings

    private func extractSharedStrings(from zip: MiniZIPReader) -> [String] {
        guard let xml  = try? zip.extractEntry(named: "xl/sharedStrings.xml"),
              let doc  = try? XMLDocument(data: xml),
              let nodes = try? doc.nodes(forXPath:
                  "//*[local-name()='si']/*[local-name()='t']") else { return [] }
        return nodes.map { $0.stringValue ?? "" }
    }

    // MARK: - Cell lookup

    /// Returns the integer value of a specific cell (e.g. "B2"), or nil if absent or non-numeric.
    private func numericCell(_ doc: XMLDocument, ref: String) -> Int? {
        guard let nodes = try? doc.nodes(forXPath:
                  "//*[local-name()='c'][@r='\(ref)']"),
              let cell = nodes.first as? XMLElement else { return nil }
        // Skip string-typed cells.
        guard cell.attribute(forName: "t")?.stringValue != "s" else { return nil }
        guard let vNodes = try? cell.nodes(forXPath: "*[local-name()='v']"),
              let raw = vNodes.first?.stringValue,
              let d   = Double(raw) else { return nil }
        return Int(d)
    }

    /// Finds the column letter (e.g. "C") whose header in row 1 contains "engagement".
    private func engagementsColumn(in doc: XMLDocument, sharedStrings: [String]) -> String? {
        guard let cells = try? doc.nodes(forXPath:
                  "//*[local-name()='row'][@r='1']/*[local-name()='c']") else { return nil }
        for cell in cells {
            guard let el  = cell as? XMLElement,
                  let ref = el.attribute(forName: "r")?.stringValue,
                  el.attribute(forName: "t")?.stringValue == "s",
                  let vNodes = try? el.nodes(forXPath: "*[local-name()='v']"),
                  let idxStr = vNodes.first?.stringValue,
                  let idx    = Int(idxStr),
                  let label  = sharedStrings[safe: idx],
                  label.lowercased().contains("engagement") else { continue }
            return String(ref.prefix(while: { $0.isLetter })).uppercased()
        }
        return nil
    }

    /// Sums all numeric values in `col` (e.g. "B") for rows >= `startRow`.
    private func sumColumn(in doc: XMLDocument, col: String, startRow: Int) -> Int {
        guard let cells = try? doc.nodes(forXPath: "//*[local-name()='c']") else { return 0 }
        var total = 0
        for cell in cells {
            guard let el  = cell as? XMLElement,
                  let ref = el.attribute(forName: "r")?.stringValue else { continue }
            let cellCol = String(ref.prefix(while: { $0.isLetter })).uppercased()
            guard cellCol == col.uppercased() else { continue }
            let rowStr = String(ref.drop(while: { $0.isLetter }))
            guard let row = Int(rowStr), row >= startRow else { continue }
            // Skip string-typed cells.
            guard el.attribute(forName: "t")?.stringValue != "s" else { continue }
            guard let vNodes = try? el.nodes(forXPath: "*[local-name()='v']"),
                  let raw    = vNodes.first?.stringValue,
                  let d      = Double(raw) else { continue }
            total += Int(d)
        }
        return total
    }
}

// MARK: - Safe subscript (reused across importer files in this module)

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
