import Testing
import Foundation
@testable import SocialBrain

/// Covers the shared-string table, which is addressed by index — so an entry
/// skipped while reading it shifts every subsequent lookup and silently returns
/// the wrong text (#72).
///
/// Fixtures are real ZIP archives built with `/usr/bin/zip` from real OOXML,
/// not bytes shaped to match this implementation. #70 is what happens when a
/// parser is tested against its own assumptions.
@Suite("LinkedIn XLSX parser")
struct LinkedInXLSXParserTests {

    private let parser = LinkedInXLSXParser()

    /// Packages the given part paths into a real `.xlsx`-shaped archive.
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

        #expect(parser.extractSharedStrings(from: zip) == ["Alpha", "Beta"])
    }

    @Test("Rich-text runs are concatenated, not skipped")
    func richTextRunsAreRead() throws {
        // Excel splits a cell into runs whenever part of it is styled
        // differently. The old XPath (si/t) matched none of them.
        let xml = sharedStrings("<si><r><t>Hello </t></r><r><t>world</t></r></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(parser.extractSharedStrings(from: zip) == ["Hello world"])
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

        let strings = parser.extractSharedStrings(from: zip)
        #expect(strings == ["Impressions", "Engagements", "Followers"])
        // Index 2 is the assertion that matters: under the old code it was
        // "Followers" at index 1 and index 2 did not exist.
        #expect(strings[safe: 2] == "Followers")
    }

    @Test("Phonetic hints are excluded rather than concatenated into the value")
    func phoneticHintsAreExcluded() throws {
        // <rPh> carries a pronunciation guide in Japanese workbooks. It has its
        // own <t>, so a naive descendant search would append it to the content.
        let xml = sharedStrings("<si><t>東京</t><rPh sb=\"0\" eb=\"2\"><t>トウキョウ</t></rPh></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        #expect(parser.extractSharedStrings(from: zip) == ["東京"])
    }

    @Test("An empty string entry still occupies its index")
    func emptyEntryKeepsItsSlot() throws {
        let xml = sharedStrings("<si><t></t></si><si><t>After</t></si>")
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/sharedStrings.xml": xml]))

        let strings = parser.extractSharedStrings(from: zip)
        #expect(strings.count == 2)
        #expect(strings[1] == "After")
    }

    @Test("A workbook with no shared strings yields an empty table, not a crash")
    func missingTableIsEmpty() throws {
        let zip = try MiniZIPReader(data: try makeXLSX(["xl/worksheets/sheet1.xml": "<x/>"]))
        #expect(parser.extractSharedStrings(from: zip).isEmpty)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
