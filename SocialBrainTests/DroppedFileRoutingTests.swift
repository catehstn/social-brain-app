import Testing
import Foundation
@testable import SocialBrain

/// Covers which error a dropped file surfaces.
///
/// The routing loop tries several parsers for one file extension, so a parser
/// that fails has to be indistinguishable from "not my format" — except when it
/// refused a file it *did* recognise, which is a different thing to tell the
/// user about.
@Suite("Dropped File Routing")
struct DroppedFileRoutingTests {

    private func data(_ platform: Platform) -> PlatformData {
        PlatformData(platform: platform, metrics: ["x": .int(1)])
    }

    @Test("The first parser that succeeds wins")
    func firstSuccessWins() throws {
        let (platform, result) = try PlatformsViewModel.firstParseThatWorks([
            (.linkedin, { throw LinkedInXLSXParser.ParseError.notXLSX }),
            (.substack, { self.data(.substack) }),
        ])
        #expect(platform == .substack)
        #expect(result.platform == .substack)
    }

    @Test("A parser saying 'not my format' lets the next one try")
    func nonRefusalsFallThrough() throws {
        // notXLSX and noUsableData both mean the file was not ours. Neither
        // should stop a later parser from claiming it.
        for error in [LinkedInXLSXParser.ParseError.notXLSX, .noUsableData] {
            let (platform, _) = try PlatformsViewModel.firstParseThatWorks([
                (.linkedin, { throw error }),
                (.substack, { self.data(.substack) }),
            ])
            #expect(platform == .substack)
        }
    }

    @Test("A refusal stops the loop and reaches the user",
          arguments: [LinkedInXLSXParser.ParseError.unsafeXML,
                      .unsupportedEncoding,
                      .malformedProlog])
    func refusalsPropagate(refusal: LinkedInXLSXParser.ParseError) {
        // Without this the user is told "the file format wasn't recognised" and
        // goes to check their export, when what actually happened is that the
        // file declared a DTD and was rejected on purpose.
        #expect(throws: refusal) {
            _ = try PlatformsViewModel.firstParseThatWorks([
                (.linkedin, { throw refusal }),
                (.substack, { self.data(.substack) }),
            ])
        }
    }

    @Test("Nothing matching is still an unrecognised format")
    func noneMatching() {
        #expect(throws: ImportError.unrecognisedFormat) {
            _ = try PlatformsViewModel.firstParseThatWorks([
                (.linkedin, { throw LinkedInXLSXParser.ParseError.notXLSX }),
            ])
        }
    }
}
