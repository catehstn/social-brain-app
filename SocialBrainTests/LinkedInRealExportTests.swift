import Testing
import Foundation
@testable import SocialBrain

/// Parses a real LinkedIn export, redacted.
///
/// Every other test in this repo builds its `.xlsx` by hand, and that is exactly
/// how the parser shipped unable to read a real file while its suite stayed
/// green (#53, #55): **a real export writes every cell as `t="s"`, a shared
/// string, including the numbers.** A fixture written from reading the parser
/// never has that shape.
///
/// The fixture keeps LinkedIn's structure — sheet names and order, cell types,
/// styles, the `<si>` layout, the dates — and redacts content by whitelist: a
/// string survives only if the parser reads it, or is a date. See
/// `Fixtures/README.md`, which records why it is a whitelist.
@Suite("LinkedIn real export")
struct LinkedInRealExportTests {

    /// Located relative to this source file rather than a bundle resource: the
    /// test target has no Resources build phase, and adding one that silently
    /// fails to copy would produce a test that skips and passes — which is the
    /// failure mode this whole fixture exists to close.
    private func realExport() throws -> Data {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LinkedInAggregateAnalytics-redacted.xlsx")
        return try Data(contentsOf: fixture)
    }

    @Test("A real export parses, where a hand-written one always did")
    func realExportParses() throws {
        let data = try realExport()
        let result = try LinkedInXLSXParser().parse(data: data)

        // Before #135 every one of these was absent and the parse threw
        // "No usable metrics were found in the LinkedIn XLSX file" — verified
        // against nine real exports, and the error a user reported in #53.
        #expect(result.metrics["total_impressions"] != nil)
        #expect(result.metrics["members_reached"] != nil)
        #expect(result.metrics["total_followers"] != nil)
        #expect(result.metrics["total_engagements"] != nil)
        #expect(result.metrics["new_followers"] != nil)
    }

    @Test("Every cell in a real export is a shared string, including the numbers")
    func realExportUsesSharedStringsThroughout() throws {
        // The property that made the fixture necessary. If LinkedIn ever starts
        // writing numeric cells, this test is what says the parser is no longer
        // being exercised against the shape it was written for.
        let zip = try MiniZIPReader(data: try realExport())
        let sheet = try zip.extractEntry(named: "xl/worksheets/sheet1.xml")
        let xml = String(decoding: sheet, as: UTF8.self)

        #expect(xml.contains("t=\"s\""))
        #expect(!xml.contains("<c r=\"B2\"><v>"), "B2 is numeric — the fixture no longer has the real shape")
    }

    @Test("The snapshot is dated from the export, not the import clock")
    func realExportSetsPeriodEnd() throws {
        // #76. The ENGAGEMENT sheet is one row per day, so its newest date is
        // the end of the period the file describes. This export covers
        // 2026-08-22 to 2026-09-04.
        let result = try LinkedInXLSXParser().parse(data: try realExport())

        let periodEnd = try #require(result.periodEnd, "no periodEnd from a dated export")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = calendar.dateComponents([.year, .month, .day], from: periodEnd)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 4)
    }

    @Test("LinkedIn's own date spelling parses")
    func linkedInDateFormat() throws {
        // M/d/yyyy, month first, unpadded. Confirmed against the export's own
        // filename range rather than assumed: the file covering 2026-05-09 to
        // 2026-05-22 has rows running 5/9/2026 to 5/22/2026, so the leading
        // component is the month. Getting that backwards would silently move
        // every LinkedIn snapshot by up to eleven months.
        //
        // Parsed here rather than in ExportDates, which every file importer
        // shares: a slash format there would make LinkedIn's convention the
        // default for Substack and O'Reilly too, and ExportDatesTests pins that
        // it stays out.
        let date = try #require(LinkedInXLSXParser.linkedInDate("5/9/2026"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 5)
        #expect(parts.day == 9)
    }

    @Test("A two-digit year is refused rather than read as year 26",
          arguments: ["12/31/26", "1/1/99", "5/9/26"])
    func twoDigitYearsAreRefused(raw: String) {
        // `M/d/yyyy` accepts a two-digit year and reads it literally, so
        // "12/31/26" becomes 0026-12-31 — two thousand years before any export.
        // The future clamp on periodEnd does not catch it, because the absurd
        // direction is the past. A single four-digit row would win via max(),
        // so this only bites if LinkedIn changed format wholesale — but then it
        // would file every snapshot in the first century rather than falling
        // back to the import clock, which is the wrong way to fail.
        #expect(LinkedInXLSXParser.linkedInDate(raw) == nil)
    }
}
