import Testing
import Foundation
@testable import SocialBrain

/// `since` used to be optional, and `nil` meant five different windows
/// depending on the collector — 30 days, 28 days, one page, or no filter at all
/// — so "All time" produced numbers the prompt then presented side by side as
/// comparable (#96). These pin the shared pieces that replaced it.
@Suite("Collection window")
struct CollectionWindowTests {

    private let end = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 UTC

    // MARK: - resolve

    @Test("A window inside the cap is returned untouched")
    func withinCapIsUnchanged() {
        let since = CollectionWindow.utc.date(byAdding: .day, value: -30, to: end)!
        let window = CollectionWindow.resolve(since: since, end: end, maximumDays: 90)

        #expect(window.start == since)
        #expect(window.requested == 30)
        #expect(window.covered == 30)
    }

    @Test("A window exactly at the cap is not clamped")
    func exactlyAtCapIsUnchanged() {
        // The boundary is the easiest place to put an off-by-one, and clamping
        // here would move the start by a day for no reason.
        let since = CollectionWindow.utc.date(byAdding: .day, value: -90, to: end)!
        let window = CollectionWindow.resolve(since: since, end: end, maximumDays: 90)

        #expect(window.start == since)
        #expect(window.requested == 90)
        #expect(window.covered == 90)
    }

    @Test("A window past the cap is clamped, and says what it asked for")
    func pastCapIsClamped() {
        let since = CollectionWindow.utc.date(byAdding: .day, value: -365, to: end)!
        let window = CollectionWindow.resolve(since: since, end: end, maximumDays: 90)

        #expect(window.requested == 365)
        #expect(window.covered == 90)
        #expect(window.start == CollectionWindow.utc.date(byAdding: .day, value: -90, to: end)!)
    }

    @Test("All time is clamped to the cap rather than reaching the year 1")
    func distantPastIsClamped() {
        let window = CollectionWindow.resolve(since: .distantPast, end: end, maximumDays: 90)

        #expect(window.covered == 90)
        #expect(window.start == CollectionWindow.utc.date(byAdding: .day, value: -90, to: end)!)
        // Roughly two thousand years, so any "is this all time?" threshold a
        // caller applies has an enormous margin.
        #expect(window.requested > 700_000)
    }

    // MARK: - days

    @Test("The shared calendar is UTC")
    func sharedCalendarIsUTC() {
        // Asserted on the calendar itself, because no arithmetic fixture can
        // stand in for it. An earlier version of this test used two instants
        // exactly 24 hours apart and claimed a local calendar "would agree only
        // by luck" — but dateComponents returns 1 for that pair in *every*
        // fixed-offset zone, so repointing this calendar at +13:00 left the
        // whole suite green. Zone only changes a day count across a DST
        // transition, which is the one thing UTC does not have.
        #expect(CollectionWindow.utc.timeZone.secondsFromGMT() == 0)
        #expect(CollectionWindow.utc.identifier == .gregorian)
    }

    @Test("A span across a DST transition counts elapsed days, not wall-clock ones")
    func dstTransitionCountsElapsedDays() {
        // 2026-03-28T12:00Z to 47 hours later. Europe/Berlin springs forward in
        // between, so its wall clock reads exactly two days while only 1 day and
        // 23 hours have elapsed. UTC says 1, which is what a cap should compare
        // against — a clamp is about how much data exists, not what a calendar
        // on a wall says.
        let start = Date(timeIntervalSince1970: 1_774_699_200)
        let end   = start.addingTimeInterval(47 * 3600)

        #expect(CollectionWindow.days(from: start, to: end) == 1)

        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(berlin.dateComponents([.day], from: start, to: end).day == 2,
                "fixture no longer straddles the transition it was chosen for")
    }

    @Test("A backwards range is zero days, not negative")
    func backwardsRangeIsZero() {
        let later = end.addingTimeInterval(86_400)
        #expect(CollectionWindow.days(from: later, to: end) == 0)
    }

    // MARK: - The label the prompt header carries

    @Test("All time is labelled All time, not a day count")
    func allTimeIsLabelled() {
        // The nil branch that used to produce this went dead when `since`
        // became non-optional, and the header read "Last 739879 days" — a
        // user-visible regression in the very artifact #96 is about.
        #expect(RunViewModel.periodLabel(since: .distantPast) == "All time")
    }

    @Test("Ordinary windows keep their labels",
          arguments: [(0, "Last 24 hours"), (7, "Last 7 days"),
                      (30, "Last 30 days"), (90, "Last 90 days")])
    func ordinaryWindowsAreLabelled(daysAgo: Int, expected: String) {
        let since = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        #expect(RunViewModel.periodLabel(since: since) == expected)
    }

    // MARK: - lowerBound

    @Test("A real date is a lower bound; all time is not")
    func lowerBoundDistinguishesAllTime() {
        // Collectors whose API lets the date filter be omitted use this: for
        // them, omitting it *is* the encoding of "no lower bound", and it keeps
        // 0001-01-01 off the wire — the untested extreme that made GoatCounter
        // fail outright in #154.
        #expect(CollectionWindow.lowerBound(end) == end)
        #expect(CollectionWindow.lowerBound(.distantPast) == nil)
    }
}
