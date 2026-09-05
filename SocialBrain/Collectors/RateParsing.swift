import Foundation

/// Parses rate columns from file exports into a 0–1 fraction.
///
/// Shared because LinkedIn and Substack had separate copies of the same
/// heuristic, and therefore the same bug in both.
///
/// The bug: `value > 1 ? value / 100 : value` guesses from magnitude. For a
/// column that genuinely holds percentages, every value at or below 1% is
/// silently left as a fraction — so LinkedIn's `CTR (%)` column turned `0.72`,
/// meaning 0.72%, into `0.72`, meaning 72%. Post and newsletter click rates are
/// usually below 1%, so this was the common case rather than the edge case, and
/// the wrong number went into the prompt that Claude analyses.
enum RateParsing {

    /// Converts a rate cell to a 0–1 fraction.
    ///
    /// - Parameters:
    ///   - raw: the cell contents, e.g. `"2.72"`, `"2.72%"`, `"0.0272"`.
    ///   - isPercentColumn: whether the column header declares a percentage,
    ///     e.g. LinkedIn's `CTR (%)`. This is the reliable signal; magnitude is
    ///     not.
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
