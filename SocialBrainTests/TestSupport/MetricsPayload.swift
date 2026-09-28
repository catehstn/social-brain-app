import Foundation
@testable import SocialBrain

/// A snapshot's stored metrics, in the shape the collectors write.
///
/// The Feed suites used to seed typed structs — `MastodonData`,
/// `ButtondownData` and friends — which **only tests ever built**.
/// `FeedCardBuilder` decoded those first and fell back to the dictionary, so
/// the tests exercised a branch production never took, and the cards they
/// asserted on could not appear in the app (#90).
///
/// Keys are spelled as literals on purpose. `MetricKey` is the producer's end;
/// written through the same constants, these tests would agree with a changed
/// value instead of catching it (CLAUDE.md).
func metricsPayload(_ metrics: [String: MetricValue]) throws -> Data {
    try JSONEncoder().encode(metrics)
}
