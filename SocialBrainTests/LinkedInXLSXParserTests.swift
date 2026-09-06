import Testing
import Foundation
@testable import SocialBrain

/// Covers the shared-string table, which is addressed by index — so an entry
/// skipped while reading it shifts every subsequent lookup and silently returns
/// the wrong text (#72).
///
/// Fixtures are real ZIP archives built with `/usr/bin/zip`, containing
/// hand-written but spec-conformant OOXML — not bytes shaped to match this
/// implementation. (Real *archives*; the XML inside is written for the test
/// rather than extracted from an Excel workbook.) #107 is what happens when a
/// parser is tested only against its own assumptions.
@Suite("LinkedIn XLSX parser")
struct LinkedInXLSXParserTests {

    private let parser = LinkedInXLSXParser()

    /// Packages the given paths into a ZIP.
    ///
    /// Not a valid `.xlsx` — there is no `[Content_Types].xml` or `_rels`, so
    /// Excel would reject it. That does not matter here, because `MiniZIPReader`
    /// only looks entries up by name.
    private func makeXLSX(_ parts: [String: String]) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (path, contents) in parts {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        let archive = dir.appendingPathComponent("book.xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", archive.path] + parts.keys.sorted()
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Otherwise a zip failure surfaces as a confusing file-not-found below.
        guard process.terminationStatus == 0 else {
            Issue.record("zip exited \(process.terminationStatus)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: archive)
    }

    private func sharedStrings(_ items: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(items)</sst>
        """
    }

    @Test("A plain string table reads in order")
    func plainStrings() throws {
        let xml = sharedStrings("<si><t>Alpha</t></si><si><t>Beta</t></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha", "Beta"])
    }

    @Test("Rich-text runs are concatenated, not skipped")
    func richTextRunsAreRead() throws {
        // Excel splits a cell into runs whenever part of it is styled
        // differently. The old XPath (si/t) matched none of them.
        let xml = sharedStrings("<si><r><t>Hello </t></r><r><t>world</t></r></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["Hello world"])
    }

    @Test("A rich-text entry does not shift the indices of later entries")
    func richTextDoesNotShiftIndices() throws {
        // The actual bug. A skipped entry moved everything after it up by one,
        // so every later lookup returned the wrong string — and the parser used
        // those strings to find its columns.
        let xml = sharedStrings("""
            <si><t>Impressions</t></si>\
            <si><r><t>Enga</t></r><r><t>gements</t></r></si>\
            <si><t>Followers</t></si>
            """)
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        // Equality covers the alignment: under the old code this was
        // ["Impressions", "Followers"], so index 2 did not exist at all.
        #expect(try parser.extractSharedStrings(from: zip)
                == ["Impressions", "Engagements", "Followers"])
    }

    @Test("Phonetic hints are excluded rather than concatenated into the value")
    func phoneticHintsAreExcluded() throws {
        // <rPh> carries a pronunciation guide in Japanese workbooks. It has its
        // own <t>, so a naive descendant search would append it to the content.
        let xml = sharedStrings("<si><t>東京</t><rPh sb=\"0\" eb=\"2\"><t>トウキョウ</t></rPh></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["東京"])
    }

    @Test("An empty <t> entry still occupies its index")
    func emptyEntryKeepsItsSlot() throws {
        let xml = sharedStrings("<si><t></t></si><si><t>After</t></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["", "After"])
    }

    @Test("A wholly empty <si/> also keeps its slot")
    func emptySelfClosingEntryKeepsItsSlot() throws {
        // A second index shift the old XPath had: <si/> matched nothing, so it
        // vanished and everything after it moved up. The <t></t> case above
        // passes under both implementations, so this is the one that guards it.
        let xml = sharedStrings("<si/><si><t>After</t></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["", "After"])
    }

    @Test("An entry with both a direct <t> and runs concatenates in document order")
    func directTextAndRunsCombine() throws {
        // CT_Rst is a sequence (t?, r*, …), so document order is schema order.
        let xml = sharedStrings("<si><t>Head</t><r><t>Tail</t></r></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == ["HeadTail"])
    }

    @Test("Significant whitespace around real content survives")
    func preservesSignificantWhitespace() throws {
        let xml = sharedStrings("<si><t xml:space=\"preserve\"> lead</t></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip) == [" lead"])
    }

    @Test("A workbook with no shared strings yields an empty table, not a crash")
    func missingTableIsEmpty() throws {
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/worksheets/sheet1.xml": "<x/>"]))
        #expect(try parser.extractSharedStrings(from: zip).isEmpty)
    }
    // MARK: - End to end

    /// A sheet whose row 1 holds shared-string headers and whose later rows hold
    /// numbers, so the whole path is exercised: shared strings → column
    /// detection → summing.
    private func engagementSheet() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
          <row r="1">
            <c r="A1" t="s"><v>0</v></c>
            <c r="B1" t="s"><v>1</v></c>
            <c r="C1" t="s"><v>2</v></c>
          </row>
          <row r="2"><c r="C2"><v>10</v></c></row>
          <row r="3"><c r="C3"><v>32</v></c></row>
        </sheetData>
        </worksheet>
        """
    }

    @Test("A rich-text header is still found, so the right column is summed")
    func richTextHeaderIsMatchedEndToEnd() throws {
        // The damage path the shared-string bug actually took: extractSharedStrings
        // → engagementsColumn → sumColumn. With the entry dropped, index 2 was
        // out of range, no column matched, and detection fell back to a
        // hard-coded "C" — right by luck here, which is why the unit test above
        // is what proves the fix and this proves the path is wired.
        let strings = sharedStrings("""
            <si><t>Date</t></si>\
            <si><t>Impressions</t></si>\
            <si><r><t>Enga</t></r><r><t>gements</t></r></si>
            """)
        let data = try makeXLSX([
            "xl/sharedStrings.xml": strings,
            "xl/worksheets/sheet2.xml": engagementSheet()
        ])

        let result = try parser.parse(data: data)
        #expect(result.intMetric("total_engagements") == 42)
    }

    @Test("A workbook with no recognisable sheets does not crash")
    func unrecognisedWorkbookIsHandled() throws {
        let data = try makeXLSX(["xl/sharedStrings.xml": sharedStrings("<si><t>x</t></si>")])
        // Whether it throws or returns empty metrics is the parser's business;
        // trapping is not.
        _ = try? parser.parse(data: data)
    }

    // MARK: - Cell types

    /// A DISCOVERY sheet with whatever B2/B3 cells are given.
    private func discoverySheet(b2: String, b3: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="\(Self.spreadsheetNS)"><sheetData>
          <row r="2"><c r="A2" t="s"><v>0</v></c>\(b2)</row>
          <row r="3"><c r="A3" t="s"><v>1</v></c>\(b3)</row>
        </sheetData></worksheet>
        """
    }

    private static let discoveryStrings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="\(Self.spreadsheetNS)">
          <si><t>Impressions</t></si><si><t>Members reached</t></si>
          <si><t>4200</t></si><si><t>1750</t></si>
        </sst>
        """

    @Test("A metric stored as a shared string is read, not skipped")
    func sharedStringMetricIsResolved() throws {
        // #53/#55. `t="s"` means <v> is an *index* into the shared-string
        // table, so reading it as the value records a table offset as the
        // metric. The parser skipped these cells to avoid that — correct
        // against reading the index, but it meant a metric LinkedIn chose to
        // write as a string was silently unreadable and the import failed with
        // no usable data.
        //
        // Index 2 is "4200" and index 3 is "1750", so a parser reading the raw
        // <v> would record 2 and 3.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"s\"><v>2</v></c>",
                b3: "<c r=\"B3\" t=\"s\"><v>3</v></c>")
        ])
        let result = try parser.parse(data: data)

        #expect(result.metrics["total_impressions"] == .int(4200))
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A metric stored as an inline string is read")
    func inlineStringMetricIsResolved() throws {
        // t="inlineStr" has no <v> at all — the text is in <is><t>, split into
        // runs if any part is styled. Reading <v> finds nothing and the cell
        // disappears entirely.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"inlineStr\"><is><t>4200</t></is></c>",
                b3: "<c r=\"B3\" t=\"inlineStr\"><is><r><t>17</t></r><r><t>50</t></r></is></c>")
        ])
        let result = try parser.parse(data: data)

        #expect(result.metrics["total_impressions"] == .int(4200))
        // Runs concatenated, same as the shared-string table does.
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A shared-string index is never recorded as the metric")
    func sharedStringIndexIsNotTheValue() throws {
        // The safety the old skip provided, kept. Index 0 is "Impressions" —
        // a label, not a number — so the cell yields nothing rather than 0.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"s\"><v>0</v></c>",
                b3: "<c r=\"B3\" t=\"n\"><v>1750</v></c>")
        ])
        let result = try parser.parse(data: data)

        #expect(result.metrics["total_impressions"] == nil)
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A shared-string index pointing outside the table yields nothing")
    func outOfRangeSharedStringIndex() throws {
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"s\"><v>99</v></c>",
                b3: "<c r=\"B3\" t=\"n\"><v>1750</v></c>")
        ])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_impressions"] == nil)
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("An error cell is not read as a number")
    func errorCellYieldsNothing() throws {
        // t="e" puts #N/A in <v>. It has never parsed as a number, and must not
        // start now that <v> is read for every non-string type.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"e\"><v>#N/A</v></c>",
                b3: "<c r=\"B3\"><v>1750</v></c>")
        ])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_impressions"] == nil)
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A summed column adds string-typed cells too")
    func summedColumnResolvesSharedStrings() throws {
        // sumColumn skipped t="s" for the same reason and with the same
        // consequence: a whole column written as strings summed to zero, and
        // zero is a plausible-looking answer.
        let strings = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="\(Self.spreadsheetNS)">
              <si><t>Date</t></si><si><t>Impressions</t></si><si><t>Engagements</t></si>
              <si><t>10</t></si><si><t>20</t></si><si><t>12</t></si>
            </sst>
            """
        let sheet = """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="\(Self.spreadsheetNS)"><sheetData>
              <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>
                         <c r="C1" t="s"><v>2</v></c></row>
              <row r="2"><c r="C2" t="s"><v>3</v></c></row>
              <row r="3"><c r="C3" t="s"><v>4</v></c></row>
              <row r="4"><c r="C4" t="s"><v>5</v></c></row>
            </sheetData></worksheet>
            """
        let data = try makeXLSX([
            "xl/sharedStrings.xml": strings,
            "xl/worksheets/sheet2.xml": sheet
        ])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_engagements"] == .int(42))
    }

    @Test("Header detection reads inline-string headers too")
    func inlineStringHeaderIsDetected() throws {
        // The header row decides which column gets summed, and it required a
        // shared string — so a header row written as *inline* strings, one of
        // the two shapes this parser exists to support, fell back to the
        // hard-coded "C" and summed whichever metric happened to sit there.
        //
        // Engagements is in D here and Clicks in C, so getting this wrong
        // reports the clicks as engagements.
        let sheet = """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="\(Self.spreadsheetNS)"><sheetData>
              <row r="1">
                <c r="A1" t="inlineStr"><is><t>Date</t></is></c>
                <c r="C1" t="inlineStr"><is><t>Clicks</t></is></c>
                <c r="D1" t="inlineStr"><is><t>Engagements</t></is></c>
              </row>
              <row r="2"><c r="C2"><v>1000</v></c><c r="D2"><v>7</v></c></row>
              <row r="3"><c r="C3"><v>2000</v></c><c r="D3"><v>9</v></c></row>
            </sheetData></worksheet>
            """
        let data = try makeXLSX(["xl/worksheets/sheet2.xml": sheet])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_engagements"] == .int(16))
    }

    @Test("A formatted number in a text cell is refused, not silently truncated",
          arguments: ["4.200", "4,200", "4 200", "4.2", "1e3", "٤٢٠٠"])
    func formattedTextMetricsAreRefused(raw: String) throws {
        // A numeric <v> is unambiguous — the producer committed to a value. Text
        // is not: a European export writing "4.200" for four thousand two
        // hundred parses as 4.2 and records 4, which is silently wrong where the
        // old code failed loudly. There is no way to tell that from "4.200"
        // meaning four-point-two without knowing the locale, so it is refused.
        let strings = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="\(Self.spreadsheetNS)">
              <si><t>Impressions</t></si><si><t>Members reached</t></si>
              <si><t>\(raw)</t></si>
            </sst>
            """
        let data = try makeXLSX([
            "xl/sharedStrings.xml": strings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"s\"><v>2</v></c>",
                b3: "<c r=\"B3\"><v>1750</v></c>")
        ])
        let result = try parser.parse(data: data)

        #expect(result.metrics["total_impressions"] == nil, "\(raw) should not be read as a count")
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A decimal in a numeric cell is still accepted")
    func numericCellsKeepTheirLooserParsing() throws {
        // The strictness is for *text* only. A numeric <v> keeps the behaviour
        // it always had, so this must not become collateral damage.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\"><v>4200.0</v></c>",
                b3: "<c r=\"B3\" t=\"n\"><v>1750.6</v></c>")
        ])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_impressions"] == .int(4200))
        #expect(result.metrics["members_reached"] == .int(1750))
    }

    @Test("A phonetic hint in an inline string is not part of the number")
    func inlineStringPhoneticHintsAreExcluded() throws {
        // Japanese workbooks carry <rPh> pronunciation guides that have their
        // own <t>. Concatenating them turns 42 into 4200.
        let data = try makeXLSX([
            "xl/sharedStrings.xml": Self.discoveryStrings,
            "xl/worksheets/sheet1.xml": discoverySheet(
                b2: "<c r=\"B2\" t=\"inlineStr\"><is><t>42</t><rPh><t>00</t></rPh></is></c>",
                b3: "<c r=\"B3\"><v>1750</v></c>")
        ])
        let result = try parser.parse(data: data)
        #expect(result.metrics["total_impressions"] == .int(42))
    }

    // MARK: - Untrusted XML

    /// A shared-strings part wrapping whatever DTD internal subset is given.
    private func partWithDoctype(_ internalSubset: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE sst [\(internalSubset)]>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <si><t>\(body)</t></si>
        </sst>
        """
    }

    @Test("A part carrying a document type declaration is refused")
    func doctypeIsRefused() throws {
        let xml = partWithDoctype("<!ENTITY harmless \"x\">", body: "&harmless;")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.unsafeXML) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    @Test("A benign part still parses, so the refusal is not refusing everything")
    func benignPartsStillParse() throws {
        // The positive control for the test above. Without it, a change that
        // broke extraction entirely would leave every refusal assertion green.
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>Alpha</t></si>
            </sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("The contents of a local file never reach a parsed value")
    func externalEntitiesCannotReadLocalFiles() throws {
        // XXE. Confirmed against this parser before the fix: XMLDocument
        // resolves external entities by default, so a crafted .xlsx names a
        // path in its DTD and the file's contents land in the shared-string
        // table.
        //
        // The fixture is written here with a unique sentinel rather than
        // pointing at /etc/hosts, so the assertion does not depend on the
        // contents of a machine-global file that the test does not control.
        //
        // Deliberately asserts containment rather than mechanism: it fails if
        // the DTD guard and the entity option are *both* removed, which is the
        // property that matters. Network fetches are not tested because they
        // are not reachable — Foundation sets XML_PARSE_NONET and refuses them.
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("xxe-probe-\(UUID().uuidString).txt")
        try Data(sentinel.utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let xml = partWithDoctype(
            "<!ENTITY xxe SYSTEM \"file://\(secret.path)\">", body: "&xxe;")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        // Asserts on the shared-string table, not on parse()'s metrics: the
        // strings are where the entity would land, and metrics never carry
        // them, so asserting on the returned PlatformData passes no matter what
        // the parser does. Whether the file is refused or merely parsed with
        // the entity dropped, the sentinel must not appear here.
        let strings = (try? parser.extractSharedStrings(from: zip)) ?? []
        #expect(!strings.joined().contains(sentinel))
    }

    @Test("A part that expands to a gigabyte is refused instead of expanded")
    func entityExpansionIsRefused() throws {
        // .nodeLoadExternalEntitiesNever does nothing about entities defined
        // inline, and libxml2 applies no expansion limit. Measured against this
        // parser: this ~513-byte part produced 10,000,000 characters with the
        // option in place, taking 43 seconds. Eight levels rather than six is a
        // gigabyte, from a part small enough to sail under the 32 MB ZIP cap —
        // the amplification is against the compressed size, not the stored one.
        var subset = "<!ENTITY a0 \"aaaaaaaaaa\">"
        for i in 1...6 {
            let prev = String(repeating: "&a\(i - 1);", count: 10)
            subset += "<!ENTITY a\(i) \"\(prev)\">"
        }
        let xml = partWithDoctype(subset, body: "&a6;")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.unsafeXML) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    @Test("A part in an encoding a spreadsheet never uses is refused, not scanned")
    func ebcdicIsRefused() throws {
        // The evasion that made the byte scan unsound. libxml2 auto-detects
        // EBCDIC from the first four bytes (4C 6F A7 94 = "<?xm" in cp037), and
        // in EBCDIC the DOCTYPE token is neither ASCII nor null-padded — so a
        // scan looking for "<!DOCTYPE" with a null-stripping pass sees neither.
        // Measured before this fix: a 510-byte cp037 part expanded to ten
        // million characters straight through the guard.
        var subset = "<!ENTITY a0 \"aaaaaaaaaa\">"
        for i in 1...6 {
            subset += "<!ENTITY a\(i) \"\(String(repeating: "&a\(i - 1);", count: 10))\">"
        }
        let xml = partWithDoctype(subset, body: "&a6;")
        // kCFStringEncodingEBCDIC_CP037, which CFStringEncodingExt.h puts at
        // 0x0C02 and Swift does not surface as a named case.
        let cp037 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0C02))
        let ebcdic = try #require(xml.data(using: String.Encoding(rawValue: cp037)))

        #expect(throws: LinkedInXLSXParser.ParseError.unsupportedEncoding) {
            try LinkedInXLSXParser.parseXML(ebcdic)
        }
    }

    @Test("A benign UTF-16 part parses, so the UTF-16 refusal is not refusing all of them")
    func benignUTF16Parses() throws {
        // Positive control for doctypeIsFoundInUTF16, which on its own would
        // pass just as well if UTF-16 were rejected outright.
        let xml = """
            <?xml version="1.0" encoding="UTF-16"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>Alpha</t></si><si><t>Beta</t></si>
            </sst>
            """
        var utf16 = Data([0xFF, 0xFE])  // little-endian BOM
        utf16.append(Data(xml.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))

        let doc = try LinkedInXLSXParser.parseXML(utf16)
        let items = try doc.nodes(forXPath: "//*[local-name()='si']")
        #expect(items.count == 2)
    }

    @Test("A cell whose own text contains the token is not mistaken for a DTD")
    func cdataContainingTheTokenIsNotRefused() throws {
        // CDATA is the one place the token can appear unescaped in legitimate
        // content. Searching the whole part refused this; the prolog is the only
        // place a DTD can actually be, so that is the only place worth looking.
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t><![CDATA[Blogged about <!DOCTYPE html> today]]></t></si>
            </sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(try parser.extractSharedStrings(from: zip)
                == ["Blogged about <!DOCTYPE html> today"])
    }

    @Test("A DTD hiding behind a comment is still found")
    func doctypeAfterACommentIsFound() throws {
        // The prolog walk has to step over comments and processing
        // instructions rather than stopping at the first one.
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- generated by something -->
            <?mso-application progid="Excel.Sheet"?>
            <!DOCTYPE sst [<!ENTITY harmless "x">]>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>&harmless;</t></si>
            </sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.unsafeXML) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    private static let spreadsheetNS =
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    @Test("A UTF-7 part cannot hide the DOCTYPE token behind an escape")
    func utf7IsRefused() throws {
        // The evasion that made sniffing the first bytes insufficient. UTF-7
        // encodes `<` as itself, so byte 0 passes the sniff — and encodes `!`
        // as `+ACE-`, so the walk sees `<` followed by `+`, matches none of the
        // declaration forms, and reads it as the root element. libxml2 honours
        // the declaration via iconv and parses the DTD.
        //
        // Measured before this fix: 436 bytes expanded to ten million
        // characters. Closed twice over — the declared encoding is checked, and
        // the byte after `<` must be a NameStartChar.
        var subset = "<!ENTITY a0 \"aaaaaaaaaa\">"
        for i in 1...6 {
            subset += "<!ENTITY a\(i) \"\(String(repeating: "&a\(i - 1);", count: 10))\">"
        }
        let xml = """
            <?xml version="1.0" encoding="UTF-7"?><+ACE-DOCTYPE sst [\(subset)]>\
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <si><t>&a6;</t></si></sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.unsupportedEncoding) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    @Test("`<` followed by something that cannot start a name is not the document body")
    func nonNameAfterAngleBracketIsRefused() throws {
        // Pins the second half of the UTF-7 fix on its own. The declared-
        // encoding check catches the UTF-7 fixture above, so without this the
        // NameStartChar rule could be deleted and nothing would notice — and
        // it is the half that generalises to any encoding that hides a
        // declaration behind a byte the walk cannot read.
        let xml = "<+ACE-DOCTYPE sst [<!ENTITY harmless \"x\">]><sst><si><t>&harmless;</t></si></sst>"

        #expect(throws: LinkedInXLSXParser.ParseError.malformedProlog) {
            try LinkedInXLSXParser.parseXML(Data(xml.utf8))
        }
    }

    @Test("Whitespace before the declaration does not skip the encoding check")
    func whitespaceBeforeDeclarationStillChecksEncoding() throws {
        // The encoding check was anchored at byte 0, and the encoding sniff
        // allows a part to open with whitespace — so a single leading space
        // meant the declaration was never examined and the part fell through to
        // "no declaration, therefore permitted".
        //
        // Nothing exploited it (libxml2 refuses a declaration that is not at the
        // very start, and a hidden DOCTYPE still trips the NameStartChar rule),
        // but it is the seam a future encoding evasion would use.
        let xml = "  <?xml version=\"1.0\" encoding=\"UTF-7\"?><sst><si><t>x</t></si></sst>"

        #expect(throws: LinkedInXLSXParser.ParseError.unsupportedEncoding) {
            try LinkedInXLSXParser.parseXML(Data(xml.utf8))
        }
    }

    @Test("A DOCTYPE padded onto the scan boundary is not read as a root element")
    func doctypeOnTheScanBoundaryIsRefused() throws {
        // The prolog scan reads a bounded prefix. Pad the prolog with legal
        // whitespace so the `<` of `<!DOCTYPE` lands on the last byte of it:
        // the token test runs off the end, every branch misses, and the
        // fall-through used to read it as the document body. The padding
        // deflates to almost nothing, so the whole .xlsx was 413 bytes.
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        let padding = String(repeating: " ", count: 64 * 1024 - declaration.utf8.count)
        let xml = """
            \(declaration)\(padding)<!DOCTYPE sst [<!ENTITY harmless "x">]>\
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <si><t>&harmless;</t></si></sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.malformedProlog) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    // MARK: - Nesting depth

    @Test("A part that nests deeply enough to kill the process is refused")
    func deepNestingIsRefused() throws {
        // #129. XMLDocument parses this happily and then dies releasing it —
        // the tree is destroyed recursively, so around 50,000 levels the
        // process takes SIGILL in deinit. The parse has already returned by
        // then, so no `try` catches it.
        //
        // Neither existing limit helps: no DTD, so the prolog walk never looks;
        // and `<a>` repeated deflates to almost nothing, so 350 KB of it is a
        // 647-byte .xlsx, three orders of magnitude under the 32 MB entry cap.
        let depth = 60_000
        let xml = "<sst xmlns=\"\(Self.spreadsheetNS)\">"
            + String(repeating: "<a>", count: depth) + "x"
            + String(repeating: "</a>", count: depth) + "</sst>"
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(throws: LinkedInXLSXParser.ParseError.tooDeeplyNested) {
            try parser.extractSharedStrings(from: zip)
        }
    }

    @Test("The depth scan reads UTF-16 too", arguments: [true, false])
    func deepNestingIsRefusedInUTF16(littleEndian: Bool) throws {
        // The scanner strides two bytes at a time for UTF-16, and nothing
        // pinned that: forcing the stride back to one left every parser test
        // green.
        //
        // Plain deep nesting does not pin it either, which is the subtlety. At
        // stride one the `<` of each `<a>` is still found and still counted, so
        // the depth comes out the same and the part is still refused — right
        // answer, broken reason. What breaks is `skipPast`: `-->` in UTF-16 is
        // `2D 00 2D 00 3E 00`, so at stride one it never matches, the comment
        // skip runs to the end of the part, and everything after it — including
        // the nesting — is never seen.
        //
        // Hence a comment first, then the depth.
        let depth = 60_000
        let xml = "<sst xmlns=\"\(Self.spreadsheetNS)\"><!-- a comment -->"
            + String(repeating: "<a>", count: depth) + "x"
            + String(repeating: "</a>", count: depth) + "</sst>"

        var bytes = Data(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
        bytes.append(Data(xml.utf16.flatMap {
            littleEndian ? [UInt8($0 & 0xFF), UInt8($0 >> 8)]
                         : [UInt8($0 >> 8), UInt8($0 & 0xFF)]
        }))

        #expect(throws: LinkedInXLSXParser.ParseError.tooDeeplyNested) {
            try LinkedInXLSXParser.parseXML(bytes)
        }
    }

    @Test("A UTF-16 comment full of tags is still skipped, not counted")
    func utf16CommentContentsAreNotDepth() throws {
        // Pins the two-byte stride, which the deep-nesting tests above do not:
        // at stride one the `<` of each element is still found and still
        // counted, so the depth comes out the same and the part is still
        // refused — right answer, wrong reason.
        //
        // Where the stride actually decides something is `lookingAt`. In
        // UTF-16 `<!--` is `3C 00 21 00 2D 00 2D 00`, so at stride one it never
        // matches and the comment is not recognised as one. Its contents get
        // read as markup instead, and a comment full of tags is then counted as
        // real nesting — refusing a legitimate file.
        let noise = String(repeating: "<a><b><c>", count: 200)
        let xml = """
            <sst xmlns="\(Self.spreadsheetNS)"><!-- \(noise) -->\
            <si><t>Alpha</t></si></sst>
            """
        var bytes = Data([0xFF, 0xFE])
        bytes.append(Data(xml.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))

        let doc = try LinkedInXLSXParser.parseXML(bytes)
        let items = try doc.nodes(forXPath: "//*[local-name()='si']")
        #expect(items.count == 1)
    }

    @Test("Ordinary spreadsheet nesting is nowhere near the limit")
    func realisticNestingIsAccepted() throws {
        // worksheet/sheetData/row/c/v is five deep. The positive control that
        // stops the bound from becoming "refuse everything".
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="\(Self.spreadsheetNS)">
              <si><r><rPr><b/></rPr><t>Alpha</t></r><r><t> Beta</t></r></si>
            </sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha Beta"])
    }

    @Test("Angle brackets inside comments, CDATA and attributes are not counted",
          arguments: [
            "<!-- <a><a><a><a> a comment full of tags -->",
            "<![CDATA[<a><a><a><a> not markup]]>",
            "<?pi <a><a><a><a> ?>",
          ])
    func nonMarkupAngleBracketsAreNotDepth(noise: String) throws {
        // The scan has to understand enough XML not to miscount. If it treated
        // any of these as elements it would drift a few levels per occurrence,
        // and a large real file would eventually be refused as hostile.
        let xml = """
            <sst xmlns="\(Self.spreadsheetNS)">\(String(repeating: noise, count: 400))\
            <si><t>Alpha</t></si></sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("A `>` inside an attribute value does not end the tag early")
    func angleBracketInAttributeIsNotDepth() throws {
        // Self-closing on purpose. With a paired tag this passes either way —
        // ending early at the `>` inside the attribute still leaves the open
        // and its `</si>` balanced, so depth never drifts and the test cannot
        // fail. Ending `<br note="a > b"/>` early instead loses the trailing
        // `/`, so it counts as an open that never closes and drifts one level
        // per element.
        let xml = """
            <sst xmlns="\(Self.spreadsheetNS)">\
            \(String(repeating: "<br note=\"a > b\"/>", count: 400))\
            <si><t>Alpha</t></si></sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("Self-closing tags do not accumulate depth")
    func selfClosingTagsAreNotDepth() throws {
        // <x/> opens and closes in one tag. Counting it as an open would drift
        // one level per element, and a sheet is full of them.
        let xml = """
            <sst xmlns="\(Self.spreadsheetNS)">\(String(repeating: "<br/>", count: 400))\
            <si><t>Alpha</t></si></sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("A part bigger than the prolog scan still parses")
    func largePartsAreNotRefusedForBeingLarge() throws {
        // The positive control for the test above. Refusing at a truncated
        // buffer edge must not become "refuse anything over 64 KB" — a real
        // shared-string table is routinely larger than that.
        let entries = (0..<8000).map { "<si><t>Row \($0) with enough text to pass 64 KB</t></si>" }
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            \(entries.joined())</sst>
            """
        #expect(xml.utf8.count > 64 * 1024)
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        let strings = try parser.extractSharedStrings(from: zip)
        #expect(strings.count == 8000)
        #expect(strings.first == "Row 0 with enough text to pass 64 KB")
    }

    @Test("A part opening with a comment or a processing instruction still parses")
    func benignPrologConstructsStillParse() throws {
        // The positive control for doctypeAfterACommentIsFound, which asserts
        // only that something is refused — so deleting the comment branch
        // entirely, and reporting every comment as a DTD, kept the whole suite
        // green. A regression that refused every part with a leading comment
        // would have shipped.
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- generated by something -->
            <?mso-application progid="Excel.Sheet"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <si><t>Alpha</t></si>
            </sst>
            """
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("A part opening with whitespace instead of a declaration still parses")
    func leadingWhitespaceIsNotAnUnknownEncoding() throws {
        // `prolog ::= XMLDecl? Misc*`, so this is legal and libxml2 reads it.
        // Sniffing byte 0 for `<` refused it as an unknown encoding.
        let xml = "\n  <sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<si><t>Alpha</t></si></sst>"
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))
        #expect(try parser.extractSharedStrings(from: zip) == ["Alpha"])
    }

    @Test("A UTF-16 part cannot smuggle a DTD past the scan")
    func doctypeIsFoundInUTF16() throws {
        // ECMA-376 permits UTF-16, and UTF-16 of ASCII is the same bytes
        // interleaved with nulls — so a scan that only knows UTF-8 looks for
        // "<!DOCTYPE" and walks straight past "<\0!\0D\0O\0…".
        let xml = partWithDoctype("<!ENTITY harmless \"x\">", body: "&harmless;")
        let utf16 = Data(xml.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

        #expect(throws: LinkedInXLSXParser.ParseError.unsafeXML) {
            try LinkedInXLSXParser.parseXML(utf16)
        }
    }
}
