import Testing
import Foundation

/// `docs/index.html` and the bundled setup guide must not drift apart.
///
/// They had, by four hunks (#93): stale Buttondown and GoatCounter instructions
/// and a vaguer LinkedIn export route survived in `docs/` while the app showed
/// the newer bundled copy. The app reads
/// `SocialBrain/Resources/setup-guide.html` (`SetupGuideSheet.swift`), so the
/// bundled file is canonical and nobody was reading the fork — GitHub Pages is
/// off (#28), so `docs/index.html` is currently published nowhere at all.
///
/// A test rather than a build step, because the failure mode is silent: a fork
/// looks fine in both files and only shows up when someone follows the wrong
/// one and the instructions don't match the vendor's UI.
@Suite("Setup guide copies")
struct SetupGuideCopyTests {

    /// The repository root, found from this file's own path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/SocialBrainTests/SetupGuideCopyTests.swift
            .deletingLastPathComponent()          // …/SocialBrainTests
            .deletingLastPathComponent()          // …/
    }

    @Test("docs/index.html is byte-identical to the bundled setup guide")
    func copiesAreIdentical() throws {
        let bundled = Self.repoRoot
            .appendingPathComponent("SocialBrain/Resources/setup-guide.html")
        let published = Self.repoRoot.appendingPathComponent("docs/index.html")

        let bundledData = try Data(contentsOf: bundled)
        let publishedData = try Data(contentsOf: published)

        let message: Comment = """
            docs/index.html has drifted from SocialBrain/Resources/setup-guide.html. \
            Copy the bundled one over it — the app reads the bundled file.
            """
        #expect(bundledData == publishedData, message)
    }

    @Test("Both copies are non-empty, so identical cannot mean empty")
    func copiesAreNotEmpty() throws {
        let bundled = Self.repoRoot
            .appendingPathComponent("SocialBrain/Resources/setup-guide.html")
        let data = try Data(contentsOf: bundled)

        #expect(data.count > 1_000)
    }
}
