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
        case entryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .notAZIPFile:              "The file is not a valid ZIP archive."
            case .corruptedArchive:         "The ZIP archive is corrupted or unsupported."
            case .decompressionFailed:      "Decompression of a ZIP entry failed."
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

    private func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        // Guard against files that report 0 uncompressed size.
        let outputSize = expectedSize > 0 ? expectedSize : compressed.count * 4
        var output = Data(count: outputSize)

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
                inflateEnd(&strm)
                return ret
            }
        }

        guard zlibResult == Z_STREAM_END || zlibResult == Z_OK else {
            throw ZIPError.decompressionFailed
        }
        return output
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
