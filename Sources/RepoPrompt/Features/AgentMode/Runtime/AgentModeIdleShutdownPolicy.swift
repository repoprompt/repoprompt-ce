import Foundation

/// Shared Agent Mode idle-shutdown timing policy.
///
/// Runtime coordinators may retain completed provider sessions briefly for follow-up reuse, but
/// heavyweight provider processes should use this common default TTL before idle teardown.
enum AgentModeIdleShutdownPolicy {
    static let defaultDelay: TimeInterval = 300
    static let minimumDelayNanos: UInt64 = 1_000_000
    static let defaultDelayNanos = UInt64(defaultDelay * 1_000_000_000)

    static func normalizedDelayNanos(_ delayNanos: UInt64) -> UInt64 {
        max(minimumDelayNanos, delayNanos)
    }
}
