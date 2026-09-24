import Foundation
import UserNotifications
@testable import SocialBrain

/// A `NotificationScheduling` that records instead of posting.
///
/// `NotificationManager` had no tests because every method reached
/// `UNUserNotificationCenter.current()` (#90): exercising it meant posting real
/// notifications to whoever ran the suite, which is the same class of hazard as
/// a test writing real preferences or real Keychain items.
final class RecordingNotificationCenter: NotificationScheduling, @unchecked Sendable {

    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private var _removed: [String] = []
    private var _authorizationRequests = 0
    private var _status: UNAuthorizationStatus

    /// Defaults to authorised, so a test that cares about the refusal path has
    /// to say so — the other way round, every test would pass by doing nothing.
    init(status: UNAuthorizationStatus = .authorized) {
        self._status = status
    }

    var added: [UNNotificationRequest] { lock.withLock { _added } }
    var removed: [String] { lock.withLock { _removed } }
    var authorizationRequests: Int { lock.withLock { _authorizationRequests } }

    /// The one request, when exactly one was scheduled.
    var onlyRequest: UNNotificationRequest? {
        let requests = added
        return requests.count == 1 ? requests.first : nil
    }

    // MARK: - NotificationScheduling

    func authorizationStatus() async -> UNAuthorizationStatus { lock.withLock { _status } }

    func requestAuthorization() async { lock.withLock { _authorizationRequests += 1 } }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _added.append(request) }
    }

    func removePending(withIdentifiers identifiers: [String]) {
        lock.withLock { _removed.append(contentsOf: identifiers) }
    }
}
