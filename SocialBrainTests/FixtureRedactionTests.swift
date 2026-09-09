import Testing
import Foundation

/// Guards every checked-in fixture against carrying real data.
///
/// This exists because a fixture in this directory shipped to a public repo
/// holding 49 LinkedIn post URLs, two demographics tables naming employers, job
/// titles, seniority and locations, and the account name in `docProps`. It had
/// been "redacted" by a blacklist: replace digits, replace dates, replace the
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

    private func isAllowed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.allowedText.contains(trimmed) { return true }
        if trimmed.wholeMatch(of: /\d{1,2}\/\d{1,2}\/\d{4}/) != nil { return true }
        if trimmed.wholeMatch(of: /\d+(\.\d+)?/) != nil { return true }
        if trimmed.wholeMatch(of: /Total followers on \d{1,2}\/\d{1,2}\/\d{4}/) != nil { return true }
        return false
    }

    @Test("Every string in every .xlsx fixture is one we deliberately kept")
    func fixturesCarryNoRealText() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xlsx" }

        // Fails rather than skips when the directory is empty: a guard that
        // quietly checks nothing is how the original problem got through.
        #expect(!files.isEmpty, "no .xlsx fixtures found — is the path still right?")

        for file in files {
            let parts = try Self.zipEntries(in: try Data(contentsOf: file))

            // Not just sharedStrings. docProps/core.xml is where the account
            // name survived, and it was never looked at.
            for (name, contents) in parts where name.hasSuffix(".xml") {
                let text = String(decoding: contents, as: UTF8.self)
                for value in Self.textNodes(in: text) where !isAllowed(value) {
                    Issue.record("""
                        Unredacted text in \(file.lastPathComponent) → \(name):
                          \(value.prefix(120))
                        Fixtures are redacted by whitelist. If this string is one a
                        parser genuinely reads, add it to `allowedText` on purpose.
                        """)
                }
            }
        }
    }

    @Test("No fixture contains anything shaped like a link or an address")
    func fixturesCarryNoIdentifiers() throws {
        // A second, blunter net. The whitelist above is the real guard; this
        // catches a URL or email smuggled inside something that passes it, and
        // says so in terms a reader recognises immediately.
        let files = try FileManager.default
            .contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xlsx" }

        for file in files {
            for (name, contents) in try Self.zipEntries(in: try Data(contentsOf: file)) {
                let text = String(decoding: contents, as: UTF8.self)
                // Schema URLs are unavoidable in OOXML and are not identifiers.
                let stripped = text.replacingOccurrences(
                    of: "http://schemas.openxmlformats.org", with: "")
                    .replacingOccurrences(of: "http://purl.org", with: "")
                    .replacingOccurrences(of: "http://www.w3.org", with: "")
                for needle in ["http://", "https://", "@", "linkedin.com"] {
                    #expect(!stripped.contains(needle),
                            "\(file.lastPathComponent) → \(name) contains \(needle)")
                }
            }
        }
    }

    // MARK: - Minimal reading of the archive

    private static func textNodes(in xml: String) -> [String] {
        var values: [String] = []
        for tag in ["t", "dc:title", "dc:creator", "dc:subject", "dc:description", "cp:keywords"] {
            var search = xml[...]
            while let open = search.range(of: "<\(tag)"),
                  let gt = search[open.upperBound...].firstIndex(of: ">") {
                // A self-closing `<t/>` has no closing tag. Skipping the check
                // here would make the scan run to the *next* element's `</t>`
                // and report a span across two entries as one unredacted
                // string — which is exactly what it did on first run.
                guard search[search.index(before: gt)] != "/" else {
                    search = search[search.index(after: gt)...]
                    continue
                }
                guard let close = search.range(of: "</\(tag)>", range: gt..<search.endIndex) else { break }
                values.append(String(search[search.index(after: gt)..<close.lowerBound]))
                search = search[close.upperBound...]
            }
        }
        return values
    }

    /// Reads the archive with `unzip`, so this test needs no ZIP implementation
    /// of its own and cannot inherit a bug from the one under test.
    private static func zipEntries(in data: Data) throws -> [(String, Data)] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).xlsx")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let listing = try run(["/usr/bin/unzip", "-Z1", temp.path])
        var entries: [(String, Data)] = []
        for name in String(decoding: listing, as: UTF8.self)
            .split(separator: "\n").map(String.init) where !name.hasSuffix("/") {
            entries.append((name, try run(["/usr/bin/unzip", "-p", temp.path, name])))
        }
        return entries
    }

    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return out
    }
}
