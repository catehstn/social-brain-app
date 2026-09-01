import Foundation

extension JSONDecoder.DateDecodingStrategy {

    /// Decodes ISO 8601 timestamps with or without fractional seconds.
    ///
    /// The built-in `.iso8601` strategy uses `ISO8601DateFormatter` with its
    /// default options, which reject a fractional-seconds component. Mastodon,
    /// Bluesky and Calendly all emit timestamps like `2026-03-24T08:00:00.000Z`,
    /// so `.iso8601` fails against their real responses on any Foundation that
    /// implements the format strictly.
    ///
    /// Newer swift-foundation happens to accept fractional seconds, which is why
    /// this only showed up on an older toolchain — the bug was always present,
    /// just masked by whichever Foundation was doing the parsing.
    static let iso8601Flexible = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let string = try decoder.singleValueContainer().decode(String.self)

        if let date = ISO8601Parsers.withFractionalSeconds.date(from: string) {
            return date
        }
        if let date = ISO8601Parsers.plain.date(from: string) {
            return date
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an ISO 8601 date, got \"\(string)\""
            )
        )
    }
}

/// `ISO8601DateFormatter` is expensive to build, so both variants are created
/// once and shared.
///
/// `nonisolated(unsafe)` is required because the type is not `Sendable`. It is
/// safe here: both instances are fully configured at initialisation and only
/// ever read from afterwards, and date formatters are documented as thread-safe
/// for parsing once configured.
private enum ISO8601Parsers {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
