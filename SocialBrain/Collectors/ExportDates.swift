import Foundation

/// Reads dates out of file exports.
///
/// File-export importers previously stamped every snapshot with `.now`,
/// discarding the dates the file itself carried. Importing last quarter's export
/// today therefore filed it as *today's* snapshot, which corrupts the series the
/// Dashboard charts and the comparison `SpikeDetector` makes against the
/// previous snapshot — a backfill registers as a sudden change, and the history
/// is plotted at the wrong point on the axis. The real date was discarded rather
/// than merely unused, so the damage could not be repaired afterwards.
enum ExportDates {

    /// Formats seen in export files, tried in order.
    ///
    /// `en_US_POSIX` throughout: a user with a Thai or Persian locale would
    /// otherwise parse a Gregorian date against a different calendar, which is
    /// the bug found in `GoogleSearchConsoleCollector` (#68).
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd"
    ]

    private static let parsers: [DateFormatter] = formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// Parses a single cell, or `nil` when it is empty or in no known format.
    static func date(from raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        for parser in parsers {
            if let date = parser.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The most recent parseable date across `rows` at `column`.
    ///
    /// The latest row date, not the earliest: an export covers a period, and the
    /// snapshot it produces describes the state at the end of that period.
    /// Returns `nil` when the column is absent or nothing parses, so callers can
    /// fall back rather than silently record an epoch date.
    static func latest(in rows: [[String]], column: Int?) -> Date? {
        guard let column else { return nil }
        return rows.compactMap { date(from: $0[safe: column]) }.max()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
