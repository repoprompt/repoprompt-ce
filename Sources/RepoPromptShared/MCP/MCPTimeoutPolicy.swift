import Foundation

/// RepoPrompt CE-owned timeout policy for MCP execution, delivery, and caller-driven defaults.
/// Caller-supplied timeout values remain dynamic; these constants only define CE defaults and guards.
public enum MCPTimeoutPolicy {
    public static let boundedToolExecutionDeadlineSeconds = 30
    public static let boundedToolExecutionDeadline: Duration = .seconds(boundedToolExecutionDeadlineSeconds)

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

    public static let responseSendDeadlineSeconds = 30
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

    public static let agentLifecycleDefaultWaitSeconds: TimeInterval = 120
    public static let askUserDefaultTimeoutSeconds: TimeInterval = 300
    public static let nextUserInstructionDefaultWaitSeconds: TimeInterval = 600
    public static let applyEditsApprovalTimeoutSeconds: TimeInterval = 300
    public static let worktreeMergeApprovalTimeoutSeconds: TimeInterval = 600
}
