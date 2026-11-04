import Foundation

/// Admission and dispatch for activation-triggered passive appcast checks (#110).
///
/// Admission is reserved synchronously, before any check work is enqueued: the throttle anchor is
/// written in the same main-actor turn that admits the request. Two activations delivered in one
/// turn (or before the first check's task starts) therefore enqueue exactly one check, instead of
/// both passing the throttle and racing two appcast requests.
@MainActor
final class SparkleActivationCheckCoordinator {
    /// Facts the owner reads at activation time. Kept as a value so the coordinator holds no
    /// reference back to the updater and stays constructible in tests.
    struct Eligibility: Equatable {
        /// Discovery is enabled, the Sparkle configuration is valid, and passive checks are on.
        var passiveChecksEnabled: Bool
        /// A passive or user-initiated check is already running.
        var checkInFlight: Bool
        /// Persisted `SparkleLastUpdateCheck` value; 0 when never checked successfully.
        var lastSuccessfulCheckTimestamp: TimeInterval
    }

    private let minimumInterval: TimeInterval
    private let enqueueCheck: @MainActor () -> Void
    /// In-memory anchor shared by every passive attempt (launch, initial, timer, activation),
    /// successful or not, so a failing feed is not hammered on every focus change.
    private(set) var lastAttempt: Date?

    init(
        minimumInterval: TimeInterval = SparkleUpdaterManager.activationCheckMinimumInterval,
        enqueueCheck: @escaping @MainActor () -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.enqueueCheck = enqueueCheck
    }

    /// Anchors the throttle for a passive attempt that did not come through activation admission.
    func recordPassiveAttempt(at now: Date) {
        lastAttempt = now
    }

    /// Reserves and dispatches one activation check when admitted. Returns whether a check was
    /// enqueued. A refused request (disabled, in flight, or throttled) leaves the anchor untouched.
    @discardableResult
    func activationDidOccur(now: Date, eligibility: Eligibility) -> Bool {
        guard eligibility.passiveChecksEnabled, !eligibility.checkInFlight else { return false }
        guard SparkleUpdaterManager.shouldPerformActivationCheck(
            lastSuccessfulCheckTimestamp: eligibility.lastSuccessfulCheckTimestamp,
            lastAttempt: lastAttempt,
            now: now,
            minimumInterval: minimumInterval
        ) else { return false }
        // Reserve before dispatch: the enqueued check runs in a later turn.
        lastAttempt = now
        enqueueCheck()
        return true
    }
}
