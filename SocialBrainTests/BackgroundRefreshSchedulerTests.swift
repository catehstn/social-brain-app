import Testing
import Foundation
@testable import SocialBrain

/// `BackgroundRefreshScheduler` had no tests (#90), because exercising it meant
/// registering a real activity with the system and waiting up to a day.
///
/// What is worth pinning: the handler runs when the system is willing, does
/// **not** run when the system asks for deferral, and the completion result
/// reported back matches — reporting `.finished` on a deferral is what makes
/// the system stop asking, so the daily refresh would quietly stop happening.
@Suite("Background refresh scheduler")
struct BackgroundRefreshSchedulerTests {

    /// An activity that records instead of registering with the system.
    ///
    /// The block is captured rather than run, so a test decides when the
    /// "wake" happens and can await what the handler did.
    private final class StubActivity: BackgroundActivityScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var _block: (@Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void)?
        private var _invalidations = 0
        private var _scheduleCalls = 0
        private var _shouldDefer: Bool
        private var _results: [NSBackgroundActivityScheduler.Result] = []

        init(shouldDefer: Bool = false) {
            self._shouldDefer = shouldDefer
        }

        var shouldDefer: Bool { lock.withLock { _shouldDefer } }
        var invalidations: Int { lock.withLock { _invalidations } }
        var scheduleCalls: Int { lock.withLock { _scheduleCalls } }

        /// Every completion reported, so a second one for the same wake is a
        /// failed assertion rather than a crashed test host.
        var results: [NSBackgroundActivityScheduler.Result] { lock.withLock { _results } }

        func schedule(
            _ block: @escaping @Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void
        ) {
            lock.withLock {
                _block = block
                _scheduleCalls += 1
            }
        }

        func invalidate() { lock.withLock { _invalidations += 1 } }

        /// Fires the scheduled block and waits for its completion result — the
        /// system's side of the contract, which is what the handler runs
        /// inside.
        ///
        /// Records every result and resumes only on the first. The API's
        /// contract is exactly one completion per invocation, and
        /// `withCheckedContinuation` traps on a second resume — which under
        /// this suite's test host means "SocialBrain quit unexpectedly" and an
        /// `.ips` file rather than a red test (CLAUDE.md). `results` is what
        /// tests assert on, so a double completion fails instead.
        func wake() async -> NSBackgroundActivityScheduler.Result? {
            guard let block = lock.withLock({ _block }) else { return nil }
            return await withCheckedContinuation { continuation in
                let resumed = Resumed()
                block { [weak self] result in
                    self?.lock.withLock { self?._results.append(result) }
                    if resumed.claim() { continuation.resume(returning: result) }
                }
            }
        }

        /// One-shot latch, so only the first completion resumes.
        private final class Resumed: @unchecked Sendable {
            private let lock = NSLock()
            private var taken = false
            func claim() -> Bool {
                lock.withLock {
                    guard !taken else { return false }
                    taken = true
                    return true
                }
            }
        }
    }

    /// Records whether the refresh ran, across the task the scheduler spawns.
    private final class RanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func mark() { lock.withLock { _count += 1 } }
        var count: Int { lock.withLock { _count } }
    }

    @Test("Starting schedules exactly one activity, and runs nothing yet")
    func startSchedulesWithoutRunning() {
        let activity = StubActivity()
        let ran = RanFlag()

        BackgroundRefreshScheduler(activity: activity).start { ran.mark() }

        #expect(activity.scheduleCalls == 1)
        // The handler belongs to the system's wake, not to `start`.
        #expect(ran.count == 0)
    }

    @Test("A wake the system is happy with runs the refresh and reports finished")
    func wakeRunsTheRefresh() async {
        let activity = StubActivity(shouldDefer: false)
        let ran = RanFlag()
        let scheduler = BackgroundRefreshScheduler(activity: activity)
        scheduler.start { ran.mark() }

        let result = await activity.wake()

        #expect(ran.count == 1)
        #expect(result == .finished)
        // Exactly one completion per wake, which is the API's contract.
        #expect(activity.results == [.finished])
        // Uses `scheduler` after the wake, deliberately: ARC may release an
        // otherwise-unused local before the `await`, the block holds `self`
        // weakly, and a released scheduler reports `.deferred` — so this test
        // would fail and `deferredWakeDoesNotRun` would pass for the wrong
        // reason. Debug builds hide that; `-O` need not.
        scheduler.stop()
        #expect(activity.invalidations == 1)
    }

    @Test("A repeating activity runs the refresh on every wake")
    func everyWakeRuns() async {
        // `repeats` is true, so the system invokes the block again and again;
        // nothing pinned that the handler is not consumed by the first wake.
        let activity = StubActivity(shouldDefer: false)
        let ran = RanFlag()
        let scheduler = BackgroundRefreshScheduler(activity: activity)
        scheduler.start { ran.mark() }

        _ = await activity.wake()
        _ = await activity.wake()

        #expect(ran.count == 2)
        #expect(activity.results == [.finished, .finished])
        scheduler.stop()   // keeps `scheduler` alive across both wakes
    }

    @Test("A wake the system wants deferred does not run the refresh")
    func deferredWakeDoesNotRun() async {
        // `shouldDefer` is the system saying the machine is busy, hot, or on
        // battery. Collecting anyway would be a network burst at the worst
        // moment, and reporting `.finished` would tell the system the work is
        // done — so it would not ask again, and the daily refresh would stop.
        let activity = StubActivity(shouldDefer: true)
        let ran = RanFlag()
        let scheduler = BackgroundRefreshScheduler(activity: activity)
        scheduler.start { ran.mark() }

        let result = await activity.wake()

        #expect(ran.count == 0)
        #expect(result == .deferred)
        #expect(activity.results == [.deferred])
        scheduler.stop()   // keeps `scheduler` alive across the wake
    }

    @Test("Stopping invalidates the activity")
    func stopInvalidates() {
        let activity = StubActivity()
        let scheduler = BackgroundRefreshScheduler(activity: activity)
        scheduler.start { }

        scheduler.stop()

        #expect(activity.invalidations == 1)
    }

    @Test("The production activity asks for a daily wake")
    func systemActivityIsDaily() {
        // The cadence is a number in a factory: changed from a day to an hour,
        // or to a week, it looks like nothing in a diff and cannot be noticed
        // at runtime for a day at best. Constructing one does not register it
        // with the system — only `schedule` does.
        let activity = BackgroundRefreshScheduler.makeSystemActivity()

        #expect(activity.repeats)
        #expect(activity.interval == 24 * 60 * 60)
        #expect(activity.tolerance == 4 * 60 * 60)
        #expect(activity.qualityOfService == .background)
        #expect(activity.identifier == "com.catehuston.SocialBrain.refresh")
    }
}
