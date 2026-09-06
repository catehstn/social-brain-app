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
        case unsupportedEncoding
        case malformedProlog

        /// Whether this is a refusal to parse a file we *did* recognise, as
        /// opposed to "this is not our format". A refusal has to reach the user
        /// even when the caller is trying several parsers in turn.
        var isRefusal: Bool {
            switch self {
            case .unsafeXML, .unsupportedEncoding, .malformedProlog: true
            case .notXLSX, .noUsableData:                            false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notXLSX:       "The file is not a valid LinkedIn XLSX export."
            case .noUsableData:  "No usable metrics were found in the LinkedIn XLSX file."
            case .unsafeXML:
                "The file contains a document type declaration, which a spreadsheet export never has."
            case .unsupportedEncoding:
                "The file's XML is not UTF-8 or UTF-16, which is all a spreadsheet export uses."
            case .malformedProlog:
                "The file's XML does not start the way a spreadsheet export does."
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
    /// entities defined inline. Eight levels of ten-fold nesting is a ~530-byte
    /// part that expands to a gigabyte; ten levels reaches 10^11 characters.
    /// libxml2 applies no limit. The 32 MB cap in `MiniZIPReader` does not help:
    /// the amplification is against the *compressed* size, so a legal file well
    /// under the cap can still drive the app into multi-GB allocation.
    ///
    /// Rejecting the DTD outright closes both, and is stricter than the option
    /// alone. Nothing a spreadsheet producer writes has one. It has to happen
    /// *before* parsing: by the time `XMLDocument` hands back a document whose
    /// `.dtd` is non-nil, the expansion has already run.
    ///
    /// The refusal is in two parts, because a byte scan alone is not sound.
    ///
    /// First the encoding has to be one we can scan. A previous version looked
    /// for the ASCII bytes of `<!DOCTYPE`, plus a null-stripping pass for
    /// UTF-16 — and libxml2 auto-detects **EBCDIC** from the first four bytes,
    /// where the token is neither ASCII nor null-padded. A 510-byte cp037 part
    /// expanded to ten million characters straight through the guard. OPC only
    /// permits UTF-8 and UTF-16, so anything else is refused rather than
    /// scanned; that closes the whole family instead of one codepage.
    ///
    /// Then the prolog is walked rather than the whole part searched. Searching
    /// everything meant a cell whose *text* legitimately contained the token —
    /// inside CDATA, where it is not escaped — was refused. A DTD can only
    /// appear before the root element, so that is the only place worth looking.
    static func parseXML(_ data: Data) throws -> XMLDocument {
        try rejectUnparseablePart(data)
        // Belt and braces: if the checks above are ever bypassed, external
        // entities still do not resolve. That is not redundant — the EBCDIC
        // evasion above defeated the scan, and this option still held.
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    /// Reads and parses one part, tolerating a missing or malformed one but
    /// never a refused one.
    ///
    /// Which sheets exist varies between exports, so a part that will not load
    /// is normal and the caller skips it. A refused part is not normal — no
    /// spreadsheet producer writes a DTD, or a part in EBCDIC — so that refusal
    /// propagates rather than being flattened into "no usable metrics", which
    /// would send someone looking for a problem with their export.
    private func parsePart(_ zip: MiniZIPReader, named name: String) throws -> XMLDocument? {
        guard let xml = try? zip.extractEntry(named: name) else { return nil }
        do {
            return try Self.parseXML(xml)
        } catch let error as ParseError {
            throw error
        } catch {
            return nil
        }
    }

    // MARK: - Refusing a part before it is parsed

    /// How far into a part the prolog is allowed to run. A real one is well
    /// under a kilobyte; the allowance is for a producer that writes a long
    /// comment. Past this the part is refused rather than scanned further,
    /// because the alternative is letting a DTD hide behind a megabyte of
    /// comment.
    private static let prologScanLimit = 64 * 1024

    /// The encodings OPC permits, which are also the ones the prolog scan can
    /// read. Anything else is refused: see the EBCDIC note on `parseXML`.
    private enum TextForm {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
    }

    private static func rejectUnparseablePart(_ data: Data) throws {
        guard let (prolog, truncated) = asciiProlog(data) else {
            throw ParseError.unsupportedEncoding
        }
        guard declaredEncodingIsPermitted(prolog) else { throw ParseError.unsupportedEncoding }
        switch prologVerdict(prolog, truncated: truncated) {
        case .clean:            return
        case .declaresDoctype:  throw ParseError.unsafeXML
        case .unreadable:       throw ParseError.malformedProlog
        }
    }

    /// The leading bytes of the part reduced to ASCII, and whether the part
    /// continued past what was read. `nil` if it is not in an encoding OPC
    /// permits.
    private static func asciiProlog(_ data: Data) -> (bytes: [UInt8], truncated: Bool)? {
        let bytes = [UInt8](data.prefix(prologScanLimit))
        let truncated = data.count > prologScanLimit
        guard let (form, offset) = textForm(bytes) else { return nil }
        let body = bytes[offset...]
        switch form {
        case .utf8:
            return (Array(body), truncated)
        case .utf16LittleEndian:
            // ASCII in UTF-16 is the character byte followed (LE) or preceded
            // (BE) by a zero. Anything else in the prolog is not ASCII, and the
            // walk stops at it — the safe direction.
            return (stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { body[$0] }, truncated)
        case .utf16BigEndian:
            return (stride(from: body.startIndex + 1, to: body.endIndex, by: 2).map { body[$0] }, truncated)
        }
    }

    /// Identifies the encoding from the BOM, or from the first character being
    /// `<`. Returns the byte offset past any BOM.
    private static func textForm(_ b: [UInt8]) -> (TextForm, Int)? {
        // UTF-32 BOMs first: FF FE also prefixes UTF-32LE, and reading one as
        // UTF-16 would scan it wrongly rather than refuse it.
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return nil }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return nil }
        if b.starts(with: [0xEF, 0xBB, 0xBF])       { return (.utf8, 3) }
        if b.starts(with: [0xFF, 0xFE])             { return (.utf16LittleEndian, 2) }
        if b.starts(with: [0xFE, 0xFF])             { return (.utf16BigEndian, 2) }
        // No BOM. XML must begin with `<`, so the encoding is readable from how
        // that character is laid out.
        if b.count >= 2, b[0] == 0x3C, b[1] == 0x00 { return (.utf16LittleEndian, 0) }
        if b.count >= 2, b[0] == 0x00, b[1] == 0x3C { return (.utf16BigEndian, 0) }
        // `prolog ::= XMLDecl? Misc*`, so a part may legally open with
        // whitespace and no declaration. Only handled for UTF-8: the
        // equivalent in UTF-16 would have to be disambiguated before the
        // encoding is known, and no producer writes it.
        var i = 0
        while i < b.count, isSpace(b[i]) { i += 1 }
        if i < b.count, b[i] == 0x3C { return (.utf8, 0) }
        return nil
    }

    /// Refuses a part whose XML declaration names an encoding OPC does not
    /// permit.
    ///
    /// Sniffing the first bytes is not enough on its own. UTF-7 encodes `<` as
    /// itself, so it passes the sniff — and then encodes `!` as `+ACE-`, which
    /// hides the DOCTYPE token from a walk that assumes the rest of the prolog
    /// is ASCII. A 436-byte UTF-7 part expanded to ten million characters
    /// through the sniff alone. libxml2 honours the declaration via iconv, so
    /// the declaration has to be honoured here too.
    private static func declaredEncodingIsPermitted(_ b: [UInt8]) -> Bool {
        guard matches(b, at: 0, "<?xml"), let declEnd = find(b, from: 0, "?>") else {
            // No declaration. The sniff already established UTF-8 or UTF-16,
            // which is what a part without one has to be.
            return true
        }
        let declaration = String(decoding: b[0 ..< declEnd], as: UTF8.self).lowercased()
        guard let keyword = declaration.range(of: "encoding") else { return true }

        let after = declaration[keyword.upperBound...]
        guard let openIndex = after.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return false }
        let quote = after[openIndex]
        let valueStart = after.index(after: openIndex)
        guard let closeIndex = after[valueStart...].firstIndex(of: quote) else { return false }

        return permittedEncodings.contains(String(after[valueStart ..< closeIndex]))
    }

    /// What ECMA-376 permits for a part, plus the spellings libxml2 accepts for
    /// them. Anything else is refused rather than scanned.
    private static let permittedEncodings: Set<String> = [
        "utf-8", "utf8", "utf-16", "utf16", "utf-16le", "utf-16be"
    ]

    private enum PrologVerdict {
        case clean
        case declaresDoctype
        case unreadable
    }

    /// Walks the prolog — the XML declaration, comments and processing
    /// instructions before the root element — and stops at the first thing that
    /// is not one of those.
    ///
    /// - Parameter truncated: whether the part continued past `b`. If it did,
    ///   a decision taken near the end of the buffer may be an artefact of
    ///   where the buffer stopped rather than of what the part says, so the
    ///   walk refuses instead. This is what the boundary-padding attack needed
    ///   — 65 KB of whitespace, which deflates to nothing, putting the `<` of
    ///   `<!DOCTYPE` on the last readable byte so every token test ran off the
    ///   end and the fall-through read it as a root element.
    ///
    ///   Belt and braces rather than load-bearing: the `NameStartChar` rule
    ///   below independently refuses that case, because `!` cannot start a
    ///   name. Removing this changes no test. Kept because "the buffer ended
    ///   mid-decision" and "the decision was reached" are different states, and
    ///   conflating them is how the two previous versions of this guard were
    ///   evaded.
    private static func prologVerdict(_ b: [UInt8], truncated: Bool) -> PrologVerdict {
        var i = 0
        while true {
            while i < b.count, isSpace(b[i]) { i += 1 }
            // Longest token tested below is "<!DOCTYPE", nine bytes.
            if truncated, i + 9 > b.count { return .unreadable }
            guard i < b.count else { return .unreadable }
            guard b[i] == 0x3C else { return .unreadable }

            if matches(b, at: i, "<!DOCTYPE") { return .declaresDoctype }

            let terminator: String
            if matches(b, at: i, "<?")        { terminator = "?>" }
            else if matches(b, at: i, "<!--") { terminator = "-->" }
            else if matches(b, at: i, "<!")   { return .unreadable }
            else {
                // A root element start tag, and nothing else. The byte after
                // `<` must be an XML NameStartChar — this is what closes UTF-7
                // and anything else that hides a declaration behind a byte the
                // walk cannot read, rather than assuming "not a declaration"
                // means "the document body".
                guard i + 1 < b.count, isNameStart(b[i + 1]) else { return .unreadable }
                return .clean
            }

            guard let end = find(b, from: i, terminator) else { return .unreadable }
            i = end
        }
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }

    /// XML `NameStartChar`, restricted to what can appear in a single byte.
    /// Anything above ASCII is permitted: the multi-byte ranges are all names.
    private static func isNameStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || c == 0x5F || c == 0x3A || c > 0x7F
    }

    private static func matches(_ b: [UInt8], at i: Int, _ token: String) -> Bool {
        let t = Array(token.utf8)
        guard i + t.count <= b.count else { return false }
        return Array(b[i ..< i + t.count]) == t
    }

    private static func find(_ b: [UInt8], from: Int, _ token: String) -> Int? {
        let t = Array(token.utf8)
        guard t.count <= b.count else { return nil }
        for i in from ... (b.count - t.count) where Array(b[i ..< i + t.count]) == t {
            return i + t.count
        }
        return nil
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
