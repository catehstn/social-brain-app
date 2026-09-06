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

    enum ParseError: LocalizedError, Equatable {
        case notXLSX
        case noUsableData
        case unsafeXML

        var errorDescription: String? {
            switch self {
            case .notXLSX:       "The file is not a valid LinkedIn XLSX export."
            case .noUsableData:  "No usable metrics were found in the LinkedIn XLSX file."
            case .unsafeXML:     "The file contains a document type declaration, which a spreadsheet export never has."
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
        let sharedStrings = try extractSharedStrings(from: zip)

        var metrics: [String: MetricValue] = [:]

        // -- DISCOVERY (sheet1) --
        if let doc = try parsePart(zip, named: "xl/worksheets/sheet1.xml") {
            if let v = numericCell(doc, ref: "B2") { metrics["total_impressions"] = .int(v) }
            if let v = numericCell(doc, ref: "B3") { metrics["members_reached"]   = .int(v) }
        }

        // -- ENGAGEMENT (sheet2): sum Engagements column from row 2 onward --
        if let doc = try parsePart(zip, named: "xl/worksheets/sheet2.xml") {
            // Detect which column holds Engagements (typically "C") from the header row.
            let engCol = engagementsColumn(in: doc, sharedStrings: sharedStrings) ?? "C"
            let total  = sumColumn(in: doc, col: engCol, startRow: 2)
            if total > 0 { metrics["total_engagements"] = .int(total) }
        }

        // -- FOLLOWERS (sheet4) --
        if let doc = try parsePart(zip, named: "xl/worksheets/sheet4.xml") {
            if let v = numericCell(doc, ref: "B1") { metrics["total_followers"] = .int(v) }
            let newF = sumColumn(in: doc, col: "B", startRow: 4)
            if newF > 0 { metrics["new_followers"] = .int(newF) }
        }

        guard !metrics.isEmpty else { throw ParseError.noUsableData }
        return PlatformData(platform: .linkedin, metrics: metrics)
    }

    // MARK: - XML

    /// Parses a spreadsheet part, refusing any document that carries a DTD.
    ///
    /// A `.xlsx` is a file the user drags in from outside the app, so every part
    /// inside it is untrusted input. Two separate attacks arrive through the DTD:
    ///
    /// **External entities (XXE).** `XMLDocument(data:)` resolves them by
    /// default, so `<!ENTITY x SYSTEM "file:///etc/hosts">` puts that file's
    /// contents into a parsed cell. Confirmed against this parser, not inferred:
    /// with the guard removed, the shared-string table came back holding the
    /// contents of the named file. Network fetches are *not* reachable:
    /// Foundation sets `XML_PARSE_NONET` and refuses them with "Attempt to load
    /// network entity" — so this is a local file read, not an SSRF.
    ///
    /// **Entity expansion.** `.nodeLoadExternalEntitiesNever` does nothing about
    /// entities defined inline. Ten levels of ten-fold nesting is 602 bytes of
    /// XML that expands to a gigabyte, and libxml2 applies no limit. The 32 MB
    /// cap in `MiniZIPReader` does not help: the amplification is against the
    /// *compressed* size, so a legal file well under the cap can still drive the
    /// app into multi-GB allocation.
    ///
    /// Rejecting the DTD outright closes both, and is stricter than the option
    /// alone. Nothing a spreadsheet producer writes has one — the check costs a
    /// substring scan and no legitimate export has ever tripped it. It has to
    /// happen *before* parsing: by the time `XMLDocument` hands back a document
    /// whose `.dtd` is non-nil, the expansion has already run.
    ///
    /// The scan covers UTF-16 as well as UTF-8, since ECMA-376 permits it and a
    /// UTF-8-only scan would miss `<\0!\0D\0O\0…`. A cell whose *text* contains
    /// "&lt;!DOCTYPE" is escaped in the part and does not trip this.
    static func parseXML(_ data: Data) throws -> XMLDocument {
        guard !containsDoctype(data) else { throw ParseError.unsafeXML }
        // Belt and braces: if the scan above is ever bypassed, external entities
        // still do not resolve.
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    /// Reads and parses one part, tolerating a missing or malformed one but
    /// never a refused one.
    ///
    /// Which sheets exist varies between exports, so a part that will not load
    /// is normal and the caller skips it. A part carrying a DTD is not normal —
    /// no spreadsheet producer writes one — so that refusal propagates rather
    /// than being flattened into "no usable metrics", which would send someone
    /// looking for a problem with their export.
    private func parsePart(_ zip: MiniZIPReader, named name: String) throws -> XMLDocument? {
        guard let xml = try? zip.extractEntry(named: name) else { return nil }
        do {
            return try Self.parseXML(xml)
        } catch ParseError.unsafeXML {
            throw ParseError.unsafeXML
        } catch {
            return nil
        }
    }

    private static func containsDoctype(_ data: Data) -> Bool {
        let token = Data("<!DOCTYPE".utf8)
        if data.range(of: token) != nil { return true }
        // UTF-16 of ASCII is the same bytes interleaved with nulls, either
        // endianness. Dropping the nulls reduces both to the UTF-8 case.
        if data.contains(0x00) {
            return Data(data.filter { $0 != 0x00 }).range(of: token) != nil
        }
        return false
    }

    // MARK: - Shared strings

    /// Reads the shared-string table, one entry per `<si>`.
    ///
    /// The previous XPath was `si/t`, which only matches a plain string. When
    /// any part of a cell is styled differently, Excel splits it into rich-text
    /// runs — `<si><r><t>Hello </t></r><r><t>world</t></r></si>` — and that
    /// XPath matched **none** of them. Because the table is addressed by index,
    /// a skipped entry shifts every subsequent lookup by one, so all text after
    /// the first styled cell came back as the wrong string. Header detection
    /// then failed to find its column and silently fell back to a hard-coded
    /// one. Wrong data, not a failed import.
    ///
    /// One entry is emitted per `<si>` whether or not it has runs, which is what
    /// keeps the indices aligned; runs are concatenated in document order.
    /// Phonetic hints (`<rPh>`, used in Japanese workbooks) carry their own `<t>`
    /// and are excluded — they are pronunciation guides, not content.
    ///
    /// Internal rather than private so the index-alignment behaviour can be
    /// tested directly; a shift here corrupts every later lookup silently.
    func extractSharedStrings(from zip: MiniZIPReader) throws -> [String] {
        guard let doc = try parsePart(zip, named: "xl/sharedStrings.xml"),
              let items = try? doc.nodes(forXPath: "//*[local-name()='si']")
        else { return [] }

        return items.map { item in
            let texts = (try? item.nodes(forXPath:
                ".//*[local-name()='t'][not(ancestor::*[local-name()='rPh'])]")) ?? []
            return texts.compactMap(\.stringValue).joined()
        }
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
              let raw = vNodes.first?.stringValue else { return nil }
        return Self.safeInt(raw)
    }

    /// Converts a spreadsheet cell to an `Int`, refusing values that would trap.
    ///
    /// `Int(Double)` is a **trapping** conversion: `Double("1e999")` parses as
    /// infinity, and `Int(.infinity)` crashes the process. `try?` does not catch
    /// a trap. A crafted `.xlsx` containing `<v>1e999</v>` therefore killed the
    /// app outright — verified — which made hardening the ZIP layer beside it
    /// beside the point.
    static func safeInt(_ raw: String) -> Int? {
        guard let value = Double(raw), value.isFinite else { return nil }
        // Well inside Int's range and far beyond any real metric, so the
        // conversion below cannot trap and a nonsense cell cannot dominate a sum.
        guard value.magnitude < 1e15 else { return nil }
        return Int(value)
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
                  let value  = Self.safeInt(raw) else { continue }
            // Overflow-safe: two 9e14 cells would otherwise trap on +=.
            let (sum, overflowed) = total.addingReportingOverflow(value)
            guard !overflowed else { continue }
            total = sum
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
