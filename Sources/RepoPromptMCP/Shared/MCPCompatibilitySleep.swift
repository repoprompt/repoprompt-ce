//
//  MCPCompatibilitySleep.swift
//  repoprompt-mcp
//

/// Avoids the release-mode `Task.sleep(for:)` specialization crash tracked by
/// https://github.com/swiftlang/swift/issues/86204 while preserving continuous-clock
/// timing and cancellation behavior.
enum MCPCompatibilitySleep {
    static func sleep(_ duration: Duration) async throws {
        let clock = ContinuousClock()
        try await clock.sleep(until: clock.now.advanced(by: duration))
    }
}
