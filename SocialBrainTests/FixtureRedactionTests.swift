import Testing
import Foundation

/// Guards every checked-in fixture against carrying real data.
///
/// This exists because a fixture in this directory shipped to a public repo
/// holding 49 LinkedIn post URLs, two demographics tables naming employers, job
/// titles, seniority and locations, and the account name in `docProps`. It had
/// been "redacted" by a denylist: replace digits, replace dates, replace the
/// one name I thought of. Everything I had not thought of went through.
///
/// So the rule is inverted here, and enforced rather than remembered. A string
/// in a fixture survives only if it is one the parser reads, a date, a number,
/// or the literal `redacted`. Anything else fails this test — including, by
/// construction, whatever the next person forgets to think of.
@Suite("Fixture redaction")
struct FixtureRedactionTests {

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    /// The only free text any fixture may contain: header labels the parsers
    /// match on. Adding to this list is a deliberate act, which is the point.
    private static let allowedText: Set<String> = [
        "", "redacted",
        "Overall Performance", "Impressions", "Members reached",
        "Date", "Engagements", "New followers",
        "Discovery", "Engagement", "Followers"
    ]

    /// Attribute values that are structure rather than content: relationship
    /// ids, cell references, MIME types, schema URLs, the sheet names LinkedIn
    /// writes, and the handful of literals OOXML requires.
    ///
    /// Enumerated rather than skipped, because `<sheet name="…">` is an
    /// attribute and a perfectly good place to hide a name — a mutant that did
    /// exactly that passed the previous version of this test.
    private static func isStructural(_ value: String, partNames: Set<String>) -> Bool {
        // Relationship targets name other parts of this same archive. Checked
        // against the parts actually present rather than a path pattern, so a
        // file *named* after a person would still be caught.
        // Targets are relative to the referring part's directory, so
        // `worksheets/sheet1.xml` names `xl/worksheets/sheet1.xml`.
        let bare = String(value.drop(while: { $0 == "/" }))
        if partNames.contains(bare) { return true }
        if !bare.isEmpty, partNames.contains(where: { $0.hasSuffix("/" + bare) || $0 == bare }) {
            return true
        }
        let structuralSheets: Set<String> = [
            "DISCOVERY", "ENGAGEMENT", "TOP POSTS", "FOLLOWERS",
            "AUDIENCE DEMOGRAPHICS", "CONTENT DEMOGRAPHICS", "DEMOGRAPHICS"
        ]
        if structuralSheets.contains(value) { return true }
        if value.hasPrefix("http://schemas.") || value.hasPrefix("http://purl.org")
            || value.hasPrefix("http://www.w3.org") { return true }
        if value.hasPrefix("application/") || value.hasPrefix("/xl/") || value.hasPrefix("/docProps/") {
            return true
        }
        // rId3, A1, B2:C99, "1", "0", "true", "Calibri", "s", "n", …
        if value.wholeMatch(of: /rId\d+/) != nil { return true }
        if value.wholeMatch(of: /[A-Z]{1,3}\d{1,7}(:[A-Z]{1,3}\d{1,7})?/) != nil { return true }
        if value.wholeMatch(of: /[-\d.]+/) != nil { return true }
        if ["true", "false", "s", "n", "str", "inlineStr", "b", "e", "d",
            "Calibri", "none", "1.0", "UTF-8", "yes",
            // Extensions declared in [Content_Types].xml, and the library
            // LinkedIn writes the file with. Named here rather than skipped,
            // so that part is inspected rather than exempt — reading it at all
            // is new: `unzip -p` treated the bracketed name as a glob and
            // matched nothing.
            "rels", "xml", "Apache POI",
            // The whole non-numeric vocabulary of styles.xml, enumerated rather
            // than exempting the part. Six values, and if a seventh appears
            // this test says so — which is the behaviour wanted from a file
            // that should never carry content.
            "darkGray", "left", "minor", "major"].contains(value) { return true }
        return false
    }

    private func isAllowed(_ text: String, partNames: Set<String>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.allowedText.contains(trimmed) { return true }
        if Self.isStructural(trimmed, partNames: partNames) { return true }
        if trimmed.wholeMatch(of: /\d{1,2}\/\d{1,2}\/\d{4}/) != nil { return true }
        if trimmed.wholeMatch(of: /Total followers on \d{1,2}\/\d{1,2}\/\d{4}/) != nil { return true }
        return false
    }

    @Test("Every string in every .xlsx fixture is one we deliberately kept")
    func fixturesCarryNoRealText() throws {
        let files = try xlsxFixtures()
        for file in files {
            let parts = try Self.unpack(file)
            let partNames = Set(parts.map(\.name))
            for (name, contents) in parts {
                guard name.hasSuffix(".xml") || name.hasSuffix(".rels") else {
                    Issue.record("\(file.lastPathComponent) contains a non-XML part: \(name)")
                    continue
                }
                for value in try Self.textAndAttributes(in: contents)
                where !isAllowed(value, partNames: partNames) {
                    Issue.record("""
                        Unredacted text in \(file.lastPathComponent) → \(name):
                          \(value.prefix(120))
                        Fixtures are redacted by allowlist. If this string is one a
                        parser genuinely reads, add it to `allowedText` on purpose.
                        """)
                }
            }
        }
    }

    @Test("No fixture contains anything shaped like a link or an address")
    func fixturesCarryNoIdentifiers() throws {
        // A second, blunter net. The allowlist above is the real guard; this
        // catches an identifier smuggled inside something that passes it, and
        // names it in terms a reader recognises at once.
        for file in try xlsxFixtures() {
            for (name, contents) in try Self.unpack(file) {
                let text = String(decoding: contents, as: UTF8.self)
                    .replacingOccurrences(of: "http://schemas.openxmlformats.org", with: "")
                    .replacingOccurrences(of: "http://purl.org", with: "")
                    .replacingOccurrences(of: "http://www.w3.org", with: "")
                for needle in ["http://", "https://", "@", "linkedin.com"] {
                    #expect(!text.contains(needle),
                            "\(file.lastPathComponent) → \(name) contains \(needle)")
                }
            }
        }
    }

    /// Fails rather than skips when there is nothing to check: a guard that
    /// quietly inspects nothing is how the original problem got through.
    private func xlsxFixtures() throws -> [URL] {
        let files = try FileManager.default
            .contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xlsx" }
        try #require(!files.isEmpty, "no .xlsx fixtures found — is the path still right?")
        return files
    }

    // MARK: - Reading the archive

    /// Every text node and every attribute value in the document.
    ///
    /// Parsed with `XMLDocument` rather than scanned by hand. The first version
    /// of this walked the markup with string ranges against a fixed list of six
    /// tag names, and a review found it silently green for a name in
    /// `cp:lastModifiedBy`, in `<Company>`, in `<Manager>`, in an XML comment,
    /// and in a `<sheet name=…>` attribute — because those were not on the list
    /// and attributes were never read at all. A guard that inspects only what
    /// its author enumerated is the same mistake as redacting by denylist, one
    /// level up.
    ///
    /// `XMLDocument` is Foundation, not the ZIP or spreadsheet code under test,
    /// so this cannot inherit a bug from what it is guarding.
    private static func textAndAttributes(in xml: Data) throws -> [String] {
        let document = try XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever])
        var found: [String] = []

        func walk(_ node: XMLNode) {
            if let element = node as? XMLElement {
                for attribute in element.attributes ?? [] {
                    if let value = attribute.stringValue { found.append(value) }
                }
            }
            // Comments and processing instructions carry text too, and a name
            // in a comment is a name.
            if node.kind == .text || node.kind == .comment || node.kind == .processingInstruction,
               let value = node.stringValue {
                found.append(value)
            }
            for child in node.children ?? [] { walk(child) }
        }
        // From the document, not its root element: a comment before `<sst` is a
        // top-level child and would otherwise never be visited. A name in a
        // comment is a name.
        walk(document)
        return found
    }

    /// Unpacks the archive to a directory and returns every file in it.
    ///
    /// `unzip -d`, not `unzip -p <name>`: entry names are treated as *glob
    /// patterns* by the latter, so `[Content_Types].xml` reads as a character
    /// class and matches nothing. That part was never inspected at all.
    ///
    /// The exit status is checked, which it previously was not — a file that is
    /// not a zip produced no entries, both loops iterated zero times, and the
    /// suite went green. A guard that quietly checks nothing is worse than none.
    private static func unpack(_ file: URL) throws -> [(name: String, contents: Data)] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let status = try run(["/usr/bin/unzip", "-q", "-o", file.path, "-d", directory.path])
        guard status == 0 else {
            throw FixtureError.notReadable(file.lastPathComponent, status: status)
        }

        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { throw FixtureError.notReadable(file.lastPathComponent, status: -1) }

        var entries: [(String, Data)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let name = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            entries.append((name, try Data(contentsOf: url)))
        }
        guard !entries.isEmpty else {
            throw FixtureError.notReadable(file.lastPathComponent, status: 0)
        }
        return entries
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notReadable(String, status: Int32)
        var description: String {
            switch self {
            case let .notReadable(name, status):
                "\(name) could not be unpacked (unzip exit \(status)). A fixture that "
                + "cannot be read must fail, not silently pass an empty check."
            }
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
