import Testing
import Foundation
@testable import SocialBrain

/// A hand-rolled binary parser reading files the user drags in, with no tests
/// until now (#49, #71).
///
/// Fixtures are built with the system `zip`, so they are real archives rather
/// than bytes reverse-engineered from this implementation — which is the trap
/// the rest of this suite's file-format fixtures fell into.
@Suite("MiniZIPReader")
struct MiniZIPReaderTests {

    /// Builds a real ZIP containing the given entries and returns its bytes.
    private func makeZIP(_ entries: [String: String], compressed: Bool = true) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, contents) in entries {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        let archive = dir.appendingPathComponent("out.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = [compressed ? "-r" : "-r0", archive.path] + entries.keys.sorted()
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        return try Data(contentsOf: archive)
    }

    // MARK: - Happy path

    @Test("Reads a deflated entry back exactly")
    func readsDeflatedEntry() throws {
        // Long and repetitive so zip actually deflates it rather than storing.
        let body = String(repeating: "social brain analytics,", count: 500)
        let data = try makeZIP(["sheet.xml": body])

        let reader = try MiniZIPReader(data: data)
        let extracted = try reader.extractEntry(named: "sheet.xml")

        #expect(String(decoding: extracted, as: UTF8.self) == body)
    }

    @Test("Reads a stored (uncompressed) entry back exactly")
    func readsStoredEntry() throws {
        let body = "short"
        let data = try makeZIP(["a.txt": body], compressed: false)

        let reader = try MiniZIPReader(data: data)
        #expect(String(decoding: try reader.extractEntry(named: "a.txt"), as: UTF8.self) == body)
    }

    @Test("Finds the right entry among several")
    func findsCorrectEntry() throws {
        let data = try makeZIP([
            "one.xml": String(repeating: "one,", count: 300),
            "two.xml": String(repeating: "two,", count: 300)
        ])
        let reader = try MiniZIPReader(data: data)

        #expect(String(decoding: try reader.extractEntry(named: "two.xml"), as: UTF8.self)
                == String(repeating: "two,", count: 300))
    }

    @Test("An over-reporting header does not pad the output with zeros")
    func outputIsTrimmed() throws {
        // Only discriminating when the header over-reports: with an accurate
        // size the allocated buffer is already exactly right, so an untrimmed
        // return looks identical. Inflate the claim and check the caller still
        // gets 1000 bytes rather than 1000 bytes plus a tail of zeros.
        let body = String(repeating: "x", count: 1000)
        var data = try makeZIP(["a.txt": body])

        let start = try #require(Self.centralDirectoryOffset(in: data))
        data.replaceSubrange((start + 24)..<(start + 28),
                             with: UInt32(4000).littleEndianBytes)

        let extracted = try MiniZIPReader(data: data).extractEntry(named: "a.txt")

        #expect(extracted.count == 1000)
        #expect(!extracted.contains(0))
        #expect(String(decoding: extracted, as: UTF8.self) == body)
    }

    // MARK: - Malformed input

    @Test("A file that is not a ZIP is rejected")
    func rejectsNonZIP() {
        #expect(throws: MiniZIPReader.ZIPError.self) {
            _ = try MiniZIPReader(data: Data("this is plainly not a zip".utf8))
        }
    }

    @Test("An empty file is rejected")
    func rejectsEmpty() {
        #expect(throws: MiniZIPReader.ZIPError.self) {
            _ = try MiniZIPReader(data: Data())
        }
    }

    @Test("Corrupted compressed bytes are rejected")
    func rejectsCorruptedStream() throws {
        let body = String(repeating: "social brain,", count: 2000)
        var data = try makeZIP(["sheet.xml": body])

        // Overwrite inside the deflate payload, which starts after the local
        // header. Computed rather than hard-coded: a fixed byte range only lands
        // in the payload by accident of the entry name's length.
        let payloadStart = try #require(Self.firstPayloadOffset(in: data))
        data.replaceSubrange(payloadStart..<(payloadStart + 40),
                             with: Data(repeating: 0xFF, count: 40))

        #expect(throws: (any Error).self) {
            _ = try MiniZIPReader(data: data).extractEntry(named: "sheet.xml")
        }
    }

    @Test("A genuinely truncated entry is rejected, not returned short")
    func rejectsTruncatedEntry() throws {
        // Halve the declared compressed size so zlib runs out of input with the
        // output buffer still roomy — measured to give Z_BUF_ERROR with
        // total_out below capacity, which is the real truncation signature.
        let body = String(repeating: "social brain,", count: 2000)
        var data = try makeZIP(["sheet.xml": body])

        let cd = try #require(Self.centralDirectoryOffset(in: data))
        let declared = Self.readLE32(data, at: cd + 20)
        data.replaceSubrange((cd + 20)..<(cd + 24),
                             with: UInt32(declared / 2).littleEndianBytes)

        #expect(throws: (any Error).self) {
            _ = try MiniZIPReader(data: data).extractEntry(named: "sheet.xml")
        }
    }

    @Test("A missing entry is named in the error")
    func missingEntryIsNamed() throws {
        let data = try makeZIP(["a.txt": "hello"])
        let reader = try MiniZIPReader(data: data)

        let error = #expect(throws: MiniZIPReader.ZIPError.self) {
            _ = try reader.extractEntry(named: "absent.xml")
        }
        #expect(error?.localizedDescription.contains("absent.xml") == true)
    }

    @Test("An entry claiming to be larger than the limit is refused, not allocated")
    func refusesOversizedEntry() throws {
        // The uncompressed size is attacker-controlled — a UInt32 allows a 4 GiB
        // claim, which the old code allocated without question.
        let body = String(repeating: "y", count: 5000)
        var data = try makeZIP(["a.txt": body])

        // Rewrite the *central directory* entry's uncompressed-size field, which
        // is what the reader parses — not the local header. Central directory
        // file header: signature 0x02014B50, uncompressed size at offset 24.
        let start = try #require(Self.centralDirectoryOffset(in: data))
        data.replaceSubrange((start + 24)..<(start + 28),
                             with: UInt32(2_000_000_000).littleEndianBytes)

        #expect(throws: (any Error).self) {
            let reader = try MiniZIPReader(data: data)
            _ = try reader.extractEntry(named: "a.txt")
        }
    }

    @Test("The size limit stays close to the use case")
    func limitIsReasonable() {
        // A LinkedIn analytics sheet is single-digit KB. The upper bound matters
        // most: each extracted entry is handed to XMLDocument, whose DOM is
        // several times the source size, so a generous cap is not protective.
        // An earlier version of this test asserted >= 64 MB, which would have
        // blocked tightening it — the bound it enshrined was the loose one.
        #expect(MiniZIPReader.maximumEntrySize >= 4 * 1_048_576)
        #expect(MiniZIPReader.maximumEntrySize <= 64 * 1_048_576)
    }

    @Test("A stored entry over the limit is refused too")
    func refusesOversizedStoredEntry() throws {
        // The cap previously applied only to deflated entries, so a stored one
        // walked straight past it.
        var data = try makeZIP(["a.txt": "small"], compressed: false)
        let cd = try #require(Self.centralDirectoryOffset(in: data))
        // compressedSize at +20, uncompressedSize at +24; stored means equal.
        let huge = UInt32(100_000_000).littleEndianBytes
        data.replaceSubrange((cd + 20)..<(cd + 24), with: huge)
        data.replaceSubrange((cd + 24)..<(cd + 28), with: huge)

        #expect(throws: (any Error).self) {
            _ = try MiniZIPReader(data: data).extractEntry(named: "a.txt")
        }
    }

    // MARK: - Locating structures

    /// Offset of the first central-directory header, found via the end-of-central
    /// -directory record rather than by scanning — a scan from zero can match
    /// the signature inside compressed data.
    static func centralDirectoryOffset(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { return nil }
        for i in stride(from: bytes.count - 22, through: 0, by: -1)
        where Array(bytes[i..<(i + 4)]) == signature {
            return Int(readLE32(data, at: i + 16))
        }
        return nil
    }

    /// Offset of the first entry's compressed payload, past its local header.
    static func firstPayloadOffset(in data: Data) -> Int? {
        guard data.count > 30 else { return nil }
        let nameLength = Int(readLE16(data, at: 26))
        let extraLength = Int(readLE16(data, at: 28))
        return 30 + nameLength + extraLength
    }

    static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        Data([UInt8(self & 0xFF),
              UInt8((self >> 8) & 0xFF),
              UInt8((self >> 16) & 0xFF),
              UInt8((self >> 24) & 0xFF)])
    }
}
