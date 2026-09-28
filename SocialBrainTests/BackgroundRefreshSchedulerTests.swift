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

        init(shouldDefer: Bool = false) {
            self._shouldDefer = shouldDefer
        }

        var shouldDefer: Bool { lock.withLock { _shouldDefer } }
        var invalidations: Int { lock.withLock { _invalidations } }
        var scheduleCalls: Int { lock.withLock { _scheduleCalls } }

        func scheduleActivity(
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
        func wake() async -> NSBackgroundActivityScheduler.Result? {
            guard let block = lock.withLock({ _block }) else { return nil }
            return await withCheckedContinuation { continuation in
                block { result in continuation.resume(returning: result) }
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
