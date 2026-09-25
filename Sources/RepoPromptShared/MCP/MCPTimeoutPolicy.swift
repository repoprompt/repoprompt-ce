import Foundation

public struct MCPToolCallDeadlineEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ordinaryPromptExportV1 = "ordinary_prompt_export_v1"
    }

    public enum TimeoutMode: String, Codable, Sendable {
        case ordinaryDefault = "default"
        case explicitFinite = "explicit_finite"
        case explicitUnbounded = "explicit_unbounded"
    }

    public let kind: Kind
    public let expiresAtUnixMilliseconds: Int64?
    public let timeoutMode: TimeoutMode

    private enum CodingKeys: String, CodingKey {
        case kind
        case expiresAtUnixMilliseconds = "expires_at_unix_milliseconds"
        case timeoutMode = "timeout_mode"
    }

    public init(
        kind: Kind,
        expiresAtUnixMilliseconds: Int64? = nil,
        timeoutMode: TimeoutMode = .ordinaryDefault
    ) {
        self.kind = kind
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.timeoutMode = timeoutMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        expiresAtUnixMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .expiresAtUnixMilliseconds
        )
        timeoutMode = try container.decodeIfPresent(TimeoutMode.self, forKey: .timeoutMode)
            ?? .ordinaryDefault
        if timeoutMode == .ordinaryDefault, expiresAtUnixMilliseconds == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.expiresAtUnixMilliseconds,
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Default export metadata requires an expiration"
                )
            )
        }
    }
}

/// RepoPrompt CE-owned timeout policy for MCP execution, delivery, and caller-driven defaults.
/// Caller-supplied timeout values remain dynamic; these constants only define CE defaults and guards.
public enum MCPTimeoutPolicy {
    public static let boundedToolExecutionDeadlineSeconds = 30
    public static let boundedToolExecutionDeadline: Duration = .seconds(boundedToolExecutionDeadlineSeconds)

    public static let promptExportAdmissionHeadroomSeconds = 25
    public static let promptExportExecutionDeadlineSeconds = 240
    public static let promptExportExecutionDeadline: Duration = .seconds(
        promptExportExecutionDeadlineSeconds
    )

    /// macOS Finder Trash can legitimately retain synchronous post-move work after the source
    /// path disappears. Keep destructive file_actions bounded, but allow that system tail to
    /// settle as an applied mutation instead of reporting a false cancellation.
    public static let fileActionTrashExecutionDeadlineSeconds = 60
    public static let fileActionTrashExecutionDeadline: Duration = .seconds(
        fileActionTrashExecutionDeadlineSeconds
    )

    public static let workspaceFreshnessWaitTimeoutSeconds = 30
    public static let workspaceFreshnessWaitTimeout: Duration = .seconds(workspaceFreshnessWaitTimeoutSeconds)

    /// Mutation preflight must settle before the ordinary bounded tool watchdog so a blocked
    /// workspace barrier can return a retryable result instead of racing connection teardown.
    public static let mutationPreflightFreshnessWaitTimeoutSeconds = 20
    public static let mutationPreflightFreshnessWaitTimeout: Duration = .seconds(
        mutationPreflightFreshnessWaitTimeoutSeconds
    )

    public static let workspaceReadinessWaitTimeoutSeconds = 30
    public static let workspaceReadinessWaitTimeout: Duration = .seconds(workspaceReadinessWaitTimeoutSeconds)

    /// Root-catalog authority fence for a single MCP file-tool call. Shorter than
    /// `workspaceReadinessWaitTimeout` because catalog admissibility excludes search-index
    /// construction: this window covers only the filesystem crawl. It stays well inside
    /// `boundedToolExecutionDeadline` so a crawl that overruns surfaces as an explicit
    /// retryable readiness error rather than racing the tool watchdog.
    public static let fileToolAuthorityReadinessWaitTimeoutSeconds = 5
    public static let fileToolAuthorityReadinessWaitTimeout: Duration = .seconds(
        fileToolAuthorityReadinessWaitTimeoutSeconds
    )

    /// Context Builder freezes roots once for an entire discovery run, so paying a longer
    /// wait once is cheaper than failing a run that would have resolved.
    public static let contextBuilderAuthorityReadinessWaitTimeoutSeconds = 10
    public static let contextBuilderAuthorityReadinessWaitTimeout: Duration = .seconds(
        contextBuilderAuthorityReadinessWaitTimeoutSeconds
    )

    public static let workspaceSwitchToolExecutionDeadlineSeconds = 120
    public static let workspaceSwitchToolExecutionDeadline: Duration = .seconds(
        workspaceSwitchToolExecutionDeadlineSeconds
    )

    /// Allows the 120-second workspace-switch window, 5-second cleanup grace, and 25 seconds of transport margin.
    public static let postStdinHalfCloseBridgeDrainDeadlineSeconds = 150

    public static let boundedToolCancellationCleanupGraceSeconds = 5
    public static let boundedToolCancellationCleanupGrace: Duration = .seconds(boundedToolCancellationCleanupGraceSeconds)

    public static let bootstrapReplacementPredecessorStopGraceSeconds = 5
    public static let bootstrapReplacementPredecessorStopGrace: Duration = .seconds(
        bootstrapReplacementPredecessorStopGraceSeconds
    )

    public static let promptExportResponseDeliveryAllowanceSeconds = 30
    public static let promptExportResponseDeliveryAllowance: Duration = .seconds(
        promptExportResponseDeliveryAllowanceSeconds
    )
    public static let promptExportReservedEnvelopeArgumentKey = "_repoprompt_execution_envelope"
    public static let promptExportReservedProviderAndCleanupSeconds =
        promptExportExecutionDeadlineSeconds
            + boundedToolCancellationCleanupGraceSeconds
            + promptExportResponseDeliveryAllowanceSeconds
    public static let promptExportTotalEnvelopeSeconds =
        promptExportAdmissionHeadroomSeconds + promptExportReservedProviderAndCleanupSeconds

    public static let responseSendDeadlineSeconds = promptExportResponseDeliveryAllowanceSeconds
    public static let responseSendDeadline: Duration = .seconds(responseSendDeadlineSeconds)
    public static let transportWriteStallTimeoutSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    public static let codexServerActiveTimeoutSeconds = 10000

    /// Default CLI-side deadline for ordinary tool responses.
    public static let cliDefaultToolCallTimeoutSeconds: TimeInterval = 300
    /// Long-running tools whose provider/run cancellation contract is authoritative.
    public static let cliDefaultUnboundedToolNames: Set<String> = [
        "ask_oracle",
        "context_builder"
    ]
    /// Extra time after a caller-requested server-side wait for response encoding
    /// and transport delivery before the CLI cancels the request.
    public static let cliSemanticWaitResponseMarginSeconds: TimeInterval = .init(responseSendDeadlineSeconds)

    /// Factory default for otherwise-quiet RP-managed subagent lifecycle waits
    /// (start post-launch, wait, steer-and-wait). Not a startup, execution, or notification interval.
    public static let agentLifecycleDefaultWaitSeconds: TimeInterval = 120

    /// Session setup (worktree binding, provider startup, steer reactivation) runs before a
    /// lifecycle wait begins, and the server starts the caller's full wait only afterwards.
    /// Client deadlines add this allowance so setup cannot consume the requested wait.
    public static let agentLifecycleSetupAllowanceSeconds: TimeInterval = 180

    /// Discovery/help phrase for an omitted agent-control wait timeout.
    public static let configuredSubagentWaitDiscoveryPhrase =
        "configured subagent wait (factory default: two minutes)"

    public static let agentControlTimeoutPropertyDescription =
        "[start, wait] Max wait seconds. 0 = poll. Omitted timeout uses the \(configuredSubagentWaitDiscoveryPhrase)."

    public static let agentControlSteerTimeoutPropertyDescription =
        "[steer] Max wait seconds when wait=true. 0 = immediate post-steer snapshot. Omitted timeout uses the \(configuredSubagentWaitDiscoveryPhrase)."

    /// App-wide subagent wait choices exposed in Settings and `app_settings`.
    public static let supportedSubagentDefaultWaitSeconds: [Int] = [120, 300, 600, 1200, 1800, 3600]

    /// Upper bound of `supportedSubagentDefaultWaitSeconds` for compatibility guards.
    public static var maximumSupportedSubagentDefaultWaitSeconds: Int {
        supportedSubagentDefaultWaitSeconds.max() ?? Int(agentLifecycleDefaultWaitSeconds)
    }

    /// `app_settings` key for the app-wide subagent wait preference.
    public static let subagentDefaultWaitSettingsKey = "agent_mode.subagent_default_wait_seconds"

    /// Budget for the CLI implicit-wait settings preflight, covering registration, send, and the
    /// response. Cancellation delivery may add its usual drain grace on top before the caller's
    /// lifecycle request proceeds under the compatibility guard.
    public static let subagentDefaultWaitSettingsReadBudgetSeconds: TimeInterval = 5

    /// CLI-side guard when implicit lifecycle preflight cannot pin a supported preference.
    public static var cliImplicitLifecycleCompatibilityGuardSeconds: TimeInterval {
        max(
            cliDefaultToolCallTimeoutSeconds,
            TimeInterval(maximumSupportedSubagentDefaultWaitSeconds) + cliSemanticWaitResponseMarginSeconds
        )
    }

    public static func isSupportedSubagentDefaultWaitSeconds(_ seconds: Int) -> Bool {
        supportedSubagentDefaultWaitSeconds.contains(seconds)
    }

    public static func resolvedSubagentDefaultWaitSeconds(_ stored: Int?) -> Int {
        guard let stored, isSupportedSubagentDefaultWaitSeconds(stored) else {
            return Int(agentLifecycleDefaultWaitSeconds)
        }
        return stored
    }

    public static let askUserDefaultTimeoutSeconds: TimeInterval = 300
    public static let nextUserInstructionDefaultWaitSeconds: TimeInterval = 600
    public static let applyEditsApprovalTimeoutSeconds: TimeInterval = 300
    public static let worktreeMergeApprovalTimeoutSeconds: TimeInterval = 600
}
