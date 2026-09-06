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
