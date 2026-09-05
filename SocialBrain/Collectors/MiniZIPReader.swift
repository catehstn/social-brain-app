import Foundation
import zlib

/// Minimal read-only ZIP archive reader.
///
/// Supports stored (method 0) and deflated (method 8) entries.
/// Does not support ZIP64, encrypted archives, split archives, or
/// entries that use data descriptors for compressed-size metadata.
struct MiniZIPReader {

    enum ZIPError: LocalizedError {
        case notAZIPFile
        case corruptedArchive
        case decompressionFailed
        case truncatedStream
        case entryTooLarge(reported: Int, limit: Int)
        case entryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .notAZIPFile:              "The file is not a valid ZIP archive."
            case .corruptedArchive:         "The ZIP archive is corrupted or unsupported."
            case .decompressionFailed:      "Decompression of a ZIP entry failed."
            case .truncatedStream:
                "A ZIP entry ended before it was complete — the file is truncated or corrupt."
            case let .entryTooLarge(reported, limit):
                """
                A ZIP entry claims to be \(reported / 1_048_576) MB, over the \(limit / 1_048_576) MB \
                limit. Either it is not the export this expects, or the file is crafted to \
                exhaust memory.
                """
            case .entryNotFound(let name):  "Entry '\(name)' not found in the archive."
            }
        }
    }

    private struct Entry {
        let compressionMethod: UInt16
        let compressedSize:    UInt32
        let uncompressedSize:  UInt32
        let localHeaderOffset: UInt32
    }

    private let data:    Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        guard data.count > 22,
              data[data.startIndex] == 0x50,
              data[data.startIndex + 1] == 0x4B else { throw ZIPError.notAZIPFile }

        self.data = data

        let eocdOffset = try MiniZIPReader.findEOCD(in: data)
        let cdOffset   = data.readLE32(at: eocdOffset + 16)
        let cdCount    = data.readLE16(at: eocdOffset + 10)

        var entries: [String: Entry] = [:]
        var pos = Int(cdOffset)

        for _ in 0..<cdCount {
            guard pos + 46 <= data.count,
                  data.readLE32(at: pos) == 0x02014B50 else { break }

            let compressionMethod = data.readLE16(at: pos + 10)
            let compressedSize    = data.readLE32(at: pos + 20)
            let uncompressedSize  = data.readLE32(at: pos + 24)
            let nameLen           = Int(data.readLE16(at: pos + 28))
            let extraLen          = Int(data.readLE16(at: pos + 30))
            let commentLen        = Int(data.readLE16(at: pos + 32))
            let localHeaderOffset = data.readLE32(at: pos + 42)

            let nameStart = data.startIndex + pos + 46
            let nameEnd   = nameStart + nameLen
            guard nameEnd <= data.endIndex else { break }

            if let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) {
                entries[name] = Entry(
                    compressionMethod: compressionMethod,
                    compressedSize:    compressedSize,
                    uncompressedSize:  uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            }
            pos = pos + 46 + nameLen + extraLen + commentLen
        }

        self.entries = entries
    }

    /// Returns the uncompressed contents of the named entry.
    func extractEntry(named name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZIPError.entryNotFound(name) }

        let lhBase = Int(entry.localHeaderOffset)
        guard lhBase + 30 <= data.count,
              data.readLE32(at: lhBase) == 0x04034B50 else { throw ZIPError.corruptedArchive }

        let lhNameLen  = Int(data.readLE16(at: lhBase + 26))
        let lhExtraLen = Int(data.readLE16(at: lhBase + 28))
        let dataStart  = data.startIndex + lhBase + 30 + lhNameLen + lhExtraLen
        let dataEnd    = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.endIndex else { throw ZIPError.corruptedArchive }

        let slice = data[dataStart..<dataEnd]

        switch entry.compressionMethod {
        case 0:  return Data(slice)
        case 8:  return try inflateRaw(slice, expectedSize: Int(entry.uncompressedSize))
        default: throw ZIPError.decompressionFailed
        }
    }

    // MARK: - Private

    private static func findEOCD(in data: Data) throws -> Int {
        // Search backward from the end for the EOCD signature PK\x05\x06.
        // Maximum comment length is 65535 bytes, so start at (size - 22).
        let lo = Swift.max(0, data.count - 65558)
        var i  = data.count - 22
        while i >= lo {
            if data.readLE32(at: i) == 0x06054B50 { return i }
            i -= 1
        }
        throw ZIPError.notAZIPFile
    }

    /// Largest entry this will inflate.
    ///
    /// The uncompressed size comes from the archive's own header, which is
    /// attacker-controlled for any file the user drags in — a `UInt32` allows a
    /// claim of up to 4 GiB, and the old code allocated it without question. A
    /// spreadsheet sheet does not approach this; anything that does is either
    /// not the export we expect or is crafted to exhaust memory.
    static let maximumEntrySize = 256 * 1_048_576  // 256 MB

    private func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize <= Self.maximumEntrySize else {
            throw ZIPError.entryTooLarge(reported: expectedSize, limit: Self.maximumEntrySize)
        }

        // A reported size of 0 means the header didn't say (streamed entries do
        // this). Start from a guess and grow, rather than trusting one.
        if expectedSize > 0 {
            return try inflateOnce(compressed, into: expectedSize, sizeKnown: true)
        }
        var attempt = Swift.max(compressed.count * 4, 64 * 1024)
        while attempt <= Self.maximumEntrySize {
            do {
                return try inflateOnce(compressed, into: attempt, sizeKnown: false)
            } catch ZIPError.truncatedStream {
                // Output buffer was too small rather than the stream being short.
                attempt *= 4
            }
        }
        throw ZIPError.entryTooLarge(reported: attempt, limit: Self.maximumEntrySize)
    }

    private func inflateOnce(_ compressed: Data, into outputSize: Int, sizeKnown _: Bool) throws -> Data {
        var output = Data(count: outputSize)
        var producedBytes = 0

        let zlibResult: Int32 = compressed.withUnsafeBytes { srcBuf in
            output.withUnsafeMutableBytes { dstBuf in
                guard let src = srcBuf.baseAddress,
                      let dst = dstBuf.baseAddress else { return Z_MEM_ERROR }

                var strm       = z_stream()
                strm.next_in   = UnsafeMutablePointer(mutating: src.assumingMemoryBound(to: Bytef.self))
                strm.avail_in  = uInt(compressed.count)
                strm.next_out  = dst.assumingMemoryBound(to: Bytef.self)
                strm.avail_out = uInt(outputSize)

                guard inflateInit2_(&strm, -15, ZLIB_VERSION,
                                    Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_MEM_ERROR
                }
                let ret = inflate(&strm, Z_FINISH)
                producedBytes = Int(strm.total_out)
                inflateEnd(&strm)
                return ret
            }
        }

        // Only Z_STREAM_END means the stream finished. The old code also
        // accepted Z_OK, which after Z_FINISH means "ran out of output room" —
        // so a truncated archive parsed as a complete, silently short file.
        if zlibResult != Z_STREAM_END {
            guard zlibResult == Z_OK || zlibResult == Z_BUF_ERROR else {
                throw ZIPError.decompressionFailed
            }
            // Both cases surface as truncatedStream. When the size was guessed
            // rather than declared, the caller catches this and grows the buffer;
            // when the header declared it, a short stream is a real error.
            throw ZIPError.truncatedStream
        }

        // Trim: a header may over-report, and the tail would otherwise be zeros
        // that the caller reads as real content.
        return output.prefix(producedBytes)
    }
}

// MARK: - Little-endian integer helpers

private extension Data {
    func readLE16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
