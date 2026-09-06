import Foundation

/// Parses rate columns from file exports into a 0–1 fraction.
///
/// Shared because LinkedIn and Substack had separate copies of the same
/// heuristic, and therefore the same bug in both.
///
/// `value > 1 ? value / 100 : value` guesses from magnitude, and cannot tell a
/// genuine 0.72 fraction from 0.72 meaning 0.72%. That guess is **still here**,
/// as the fallback below — this type narrows when it is reached rather than
/// removing it.
///
/// What is new is honouring a literal `%` in the cell, which is unambiguous
/// wherever it appears. That is a real correction for Substack, where `"0.5%"`
/// previously parsed as `0.5` — 50% — rather than `0.005`.
///
/// An earlier version of this file claimed the magnitude guess was actively
/// corrupting LinkedIn CTR, on the basis of a `CTR (%)` header. That header has
/// never been observed in a real export; it comes from this repo's own doc
/// comment, written in the same commit as the importer. Real Page exports head
/// the column `Click through rate (CTR)` and store a **fraction**, so magnitude
/// was already giving the right answer there. See the note above `ctrColumn`
/// in `LinkedInImporter`, and #70, which is still open for want of a real
/// export to check against.
enum RateParsing {

    /// Converts a rate cell to a 0–1 fraction.
    ///
    /// - Parameters:
    ///   - raw: the cell contents, e.g. `"2.72"`, `"2.72%"`, `"0.0272"`.
    ///   - isPercentColumn: whether the column header declares a percentage. A
    ///     header that says so is a reliable signal where one exists — but no
    ///     caller currently passes `true` against a header seen in a real file.
    ///     `ctrColumn` is its only `true` producer, and it matches `CTR (%)`,
    ///     which is so far only a fixture. Kept as a hedge, not a fix.
    static func rate(from raw: String?, isPercentColumn: Bool) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let hasPercentSign = trimmed.hasSuffix("%")
        let number = trimmed
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value.isFinite else { return nil }

        // A literal % in the cell, or a header that says so, settles it.
        if hasPercentSign || isPercentColumn {
            return value / 100
        }

        // No signal either way. Fall back to magnitude: a genuine 0–1 fraction
        // cannot exceed 1, so a larger value is percentage-shaped. This remains a
        // guess, and is wrong for a sub-1% value in an undeclared percentage
        // column — which is why the header is consulted first wherever one exists.
        return value > 1 ? value / 100 : value
    }
}
