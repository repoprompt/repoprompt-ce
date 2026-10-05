import Foundation
import RepoPromptSettingsCore

extension ContextBuilderDefaults {
    /// Report-only watchdog for a live run that has not yet opened its owned MCP connection.
    static let mcpRoutingWatchdogSeconds: TimeInterval = 30

    /// Maximum buffered text while routing is pending. Control events are always preserved.
    static let mcpPreRouteBufferedTextCharacterLimit = 64000

    /// Maximum early provider events retained while routing is pending. Redundant progress and
    /// retry notifications are coalesced or dropped before ordered terminal/error/tool events.
    static let mcpPreRouteBufferedEventLimit = 256

    /// Diagnostic age recorded on the policy. Context Builder policies are settlement-scoped and
    /// are never revoked because this interval elapsed.
    static let mcpBootstrapConnectionTTL: TimeInterval = 35

    /// Bounded handoff after response-drain failure while orderly peer-EOF teardown publishes final context ownership.
    static let peerEOFDetachmentHandoffTimeoutSeconds: TimeInterval = 10
}
