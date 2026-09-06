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
        case tooDeeplyNested

        /// Whether this is a refusal to parse a file we *did* recognise, as
        /// opposed to "this is not our format". A refusal has to reach the user
        /// even when the caller is trying several parsers in turn.
        var isRefusal: Bool {
            switch self {
            case .unsafeXML, .unsupportedEncoding, .malformedProlog, .tooDeeplyNested: true
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
            case .tooDeeplyNested:
                "The file's XML nests far deeper than a spreadsheet ever does."
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
            if let v = numericCell(doc, ref: "B2", sharedStrings: sharedStrings) { metrics["total_impressions"] = .int(v) }
            if let v = numericCell(doc, ref: "B3", sharedStrings: sharedStrings) { metrics["members_reached"]   = .int(v) }
        }

        // -- ENGAGEMENT (sheet2): sum Engagements column from row 2 onward --
        if let doc = try parsePart(zip, named: "xl/worksheets/sheet2.xml") {
            // Detect which column holds Engagements (typically "C") from the header row.
            let engCol = engagementsColumn(in: doc, sharedStrings: sharedStrings) ?? "C"
            let total  = sumColumn(in: doc, col: engCol, startRow: 2, sharedStrings: sharedStrings)
            if total > 0 { metrics["total_engagements"] = .int(total) }
        }

        // -- FOLLOWERS (sheet4) --
        if let doc = try parsePart(zip, named: "xl/worksheets/sheet4.xml") {
            if let v = numericCell(doc, ref: "B1", sharedStrings: sharedStrings) { metrics["total_followers"] = .int(v) }
            let newF = sumColumn(in: doc, col: "B", startRow: 4, sharedStrings: sharedStrings)
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
        let bytes = [UInt8](data)
        guard let (form, offset) = textForm([UInt8](bytes.prefix(prologScanLimit))) else {
            throw ParseError.unsupportedEncoding
        }
        let (prolog, truncated) = asciiPrefix(bytes, form: form, offset: offset)
        guard declaredEncodingIsPermitted(prolog) else { throw ParseError.unsupportedEncoding }
        switch prologVerdict(prolog, truncated: truncated) {
        case .declaresDoctype:  throw ParseError.unsafeXML
        case .unreadable:       throw ParseError.malformedProlog
        case .clean:            break
        }
        guard nestingDepthIsSane(bytes, form: form, offset: offset) else {
            throw ParseError.tooDeeplyNested
        }
    }

    /// How deeply elements may nest before the part is refused.
    ///
    /// A spreadsheet part is under ten deep — `worksheet/sheetData/row/c/v` is
    /// five — so this is two orders of magnitude of headroom and still nowhere
    /// near what breaks.
    private static let maximumNestingDepth = 256

    /// Refuses a part that nests deeply enough to overflow the stack.
    ///
    /// `XMLDocument` **parses** a deeply nested document happily and then dies
    /// releasing it: the tree is destroyed recursively, so around 50,000 levels
    /// the process dies in `deinit` — SIGILL on one machine here, SIGSEGV on
    /// another, which is what a blown stack looks like either way. That
    /// ordering is the whole problem: the parse has already returned, so no
    /// `try` can catch it, and the app is simply gone.
    ///
    /// Neither existing limit helps. There is no DTD, so the prolog walk never
    /// looks; and `<a>` repeated deflates to almost nothing, so 350 KB of it is
    /// a **647-byte** `.xlsx`, three orders of magnitude under the 32 MB entry
    /// cap. See #129.
    ///
    /// The scan has to understand enough XML not to miscount: comments, CDATA
    /// and processing instructions can all contain `<` and `>`, and attribute
    /// values can contain `>`. Getting any of those wrong reads a legitimate
    /// file as hostile. It deliberately does *not* try to validate — an
    /// unbalanced or malformed document is libxml2's problem, and this only
    /// answers "could this nest deeply enough to kill us".
    private static func nestingDepthIsSane(_ b: [UInt8], form: TextForm, offset: Int) -> Bool {
        let step = (form == .utf8) ? 1 : 2
        let first = offset + (form == .utf16BigEndian ? 1 : 0)

        var depth = 0
        var i = first

        /// The byte of the character at position `i`, ignoring the UTF-16 zero.
        func byte(_ at: Int) -> UInt8? { at < b.count ? b[at] : nil }

        func lookingAt(_ token: String, at: Int) -> Bool {
            var j = at
            for c in token.utf8 {
                guard j < b.count, b[j] == c else { return false }
                j += step
            }
            return true
        }

        /// Advances past `token`, or to the end if it never appears.
        func skipPast(_ token: String, from: Int) -> Int {
            var j = from
            while j < b.count {
                if lookingAt(token, at: j) { return j + step * token.utf8.count }
                j += step
            }
            return b.count
        }

        while i < b.count {
            guard byte(i) == 0x3C else { i += step; continue }  // '<'

            if lookingAt("<!--", at: i) { i = skipPast("-->", from: i); continue }
            if lookingAt("<![CDATA[", at: i) { i = skipPast("]]>", from: i); continue }
            if lookingAt("<?", at: i) { i = skipPast("?>", from: i); continue }
            if lookingAt("<!", at: i) { i = skipPast(">", from: i); continue }

            let closing = lookingAt("</", at: i)
            if closing { depth -= 1 }

            // Walk the tag to its '>', stepping over quoted attribute values so
            // a '>' inside one does not end it early.
            var j = i + step
            var quote: UInt8?
            var previous: UInt8 = 0
            while j < b.count {
                let c = b[j]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == 0x22 || c == 0x27 {      // " or '
                    quote = c
                } else if c == 0x3E {                   // '>'
                    break
                }
                previous = c
                j += step
            }
            // `<x/>` opens and closes in one tag, so it must not count.
            if !closing && previous != 0x2F {           // '/'
                depth += 1
                if depth > maximumNestingDepth { return false }
            }
            i = j + step
        }
        return true
    }

    /// The leading bytes of the part reduced to ASCII, and whether the part
    /// continued past what was read.
    private static func asciiPrefix(
        _ bytes: [UInt8], form: TextForm, offset: Int
    ) -> (bytes: [UInt8], truncated: Bool) {
        let window = bytes.prefix(prologScanLimit)
        let truncated = bytes.count > prologScanLimit
        let body = window[offset...]
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
        // Skip leading whitespace before looking for the declaration. Not
        // because it is legal there — libxml2 answers "XML declaration allowed
        // only at the start of the document" — but because anchoring at byte 0
        // meant a part opening with a space skipped this check entirely and
        // fell through to "no declaration, therefore permitted". Nothing
        // exploits that today; it is the seam a future encoding evasion would
        // use, and it costs two lines to close.
        var start = 0
        while start < b.count, isSpace(b[start]) { start += 1 }
        guard matches(b, at: start, "<?xml"), let declEnd = find(b, from: start, "?>") else {
            // No declaration. The sniff already established UTF-8 or UTF-16,
            // which is what a part without one has to be.
            return true
        }
        let declaration = String(decoding: b[start ..< declEnd], as: UTF8.self).lowercased()
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
    private func numericCell(
        _ doc: XMLDocument, ref: String, sharedStrings: [String]
    ) -> Int? {
        guard let nodes = try? doc.nodes(forXPath:
                  "//*[local-name()='c'][@r='\(ref)']"),
              let cell = nodes.first as? XMLElement else { return nil }
        return cellNumber(cell, sharedStrings: sharedStrings)
    }

    /// A cell's value as a whole number, or `nil` if it does not hold one.
    ///
    /// Text cells are parsed **more strictly** than numeric ones, and that
    /// asymmetry is deliberate. A numeric `<v>` is unambiguous — the producer
    /// already committed to a value. Text is not: a European export writing
    /// `4.200` for four thousand two hundred parses as `4.2` and records **4**,
    /// which is silently wrong where the old code failed loudly. Same for
    /// `4,200` and `4 200`, and there is no way to tell `4.200` meaning 4200
    /// from `4.200` meaning four-point-two without knowing the locale.
    ///
    /// So a text cell must be a bare integer or it is refused. Nothing is lost:
    /// these metrics are counts, and every caller wants an `Int`, so a decimal
    /// was being truncated anyway — this only makes the truncation loud.
    private func cellNumber(_ cell: XMLElement, sharedStrings: [String]) -> Int? {
        switch cell.attribute(forName: "t")?.stringValue {
        case "s", "inlineStr":
            return cellText(cell, sharedStrings: sharedStrings).flatMap(Self.strictInt)
        default:
            return cellText(cell, sharedStrings: sharedStrings).flatMap(Self.safeInt)
        }
    }

    /// A bare integer, with optional sign and surrounding whitespace, or `nil`.
    ///
    /// `Int(_:)` returns nil on overflow rather than trapping, so a huge value
    /// is refused rather than crashing — the same hazard `safeInt` exists for.
    static func strictInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = Substring(trimmed)
        if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    /// The text a cell holds, whatever shape it is stored in.
    ///
    /// A cell's `t` attribute decides where its value lives, and reading `<v>`
    /// blindly is wrong for two of the shapes ECMA-376 defines:
    ///
    /// - `t="s"` — `<v>` is an **index into the shared-string table**, not the
    ///   value. Reading it as the value records a table offset as the metric.
    ///   That is why the previous code skipped these cells rather than reading
    ///   them, and skipping was the right call versus reading the index.
    /// - `t="inlineStr"` — there is no `<v>` at all; the text is in `<is><t>`,
    ///   split into `<r>` runs if any part is styled. Reading `<v>` finds
    ///   nothing and the cell disappears.
    /// - everything else — `n` (the default), `str` for a formula result, `b`,
    ///   `d`, `e` — keeps its value in `<v>`. An error cell's `#N/A` simply
    ///   fails to parse as a number, which is the right answer anyway.
    ///
    /// Skipping `t="s"` avoided recording nonsense but meant a metric LinkedIn
    /// chose to write as a string was silently unreadable, and the import failed
    /// with no usable data (#53, #55). Resolving keeps the safety and handles
    /// the shape.
    private func cellText(_ cell: XMLElement, sharedStrings: [String]) -> String? {
        switch cell.attribute(forName: "t")?.stringValue {
        case "s":
            guard let raw = firstChild(cell, named: "v"),
                  let index = Int(raw.trimmingCharacters(in: .whitespaces)),
                  sharedStrings.indices.contains(index)
            else { return nil }
            return sharedStrings[index]

        case "inlineStr":
            // Same run-concatenation and phonetic-hint rule as the shared-string
            // table: an inline string is the same content model.
            let texts = (try? cell.nodes(forXPath:
                ".//*[local-name()='t'][not(ancestor::*[local-name()='rPh'])]")) ?? []
            return texts.compactMap(\.stringValue).joined()

        default:
            return firstChild(cell, named: "v")
        }
    }

    private func firstChild(_ cell: XMLElement, named name: String) -> String? {
        guard let nodes = try? cell.nodes(forXPath: "*[local-name()='\(name)']")
        else { return nil }
        return nodes.first?.stringValue
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
            // Through the shared resolver, not a hand-rolled `t="s"` branch.
            // Requiring a shared string here meant a header row written as
            // *inline* strings — one of the two shapes this parser exists to
            // support — defeated column detection, fell back to the hard-coded
            // "C", and summed whichever metric happened to sit there.
            guard let el  = cell as? XMLElement,
                  let ref = el.attribute(forName: "r")?.stringValue,
                  let label = cellText(el, sharedStrings: sharedStrings),
                  label.lowercased().contains("engagement") else { continue }
            return String(ref.prefix(while: { $0.isLetter })).uppercased()
        }
        return nil
    }

    /// Sums all numeric values in `col` (e.g. "B") for rows >= `startRow`.
    private func sumColumn(
        in doc: XMLDocument, col: String, startRow: Int, sharedStrings: [String]
    ) -> Int {
        guard let cells = try? doc.nodes(forXPath: "//*[local-name()='c']") else { return 0 }
        var total = 0
        for cell in cells {
            guard let el  = cell as? XMLElement,
                  let ref = el.attribute(forName: "r")?.stringValue else { continue }
            let cellCol = String(ref.prefix(while: { $0.isLetter })).uppercased()
            guard cellCol == col.uppercased() else { continue }
            let rowStr = String(ref.drop(while: { $0.isLetter }))
            guard let row = Int(rowStr), row >= startRow else { continue }
            guard let value = cellNumber(el, sharedStrings: sharedStrings) else { continue }
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
