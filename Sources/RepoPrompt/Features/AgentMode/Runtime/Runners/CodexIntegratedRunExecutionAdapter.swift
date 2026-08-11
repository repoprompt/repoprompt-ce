import Foundation
import RepoPromptDomainRuntime

/// Maps Codex's dispatch-specific result vocabulary onto the shared transient
/// execution classifier without transferring any Codex lifecycle authority.
///
/// A completed report means only that the provider accepted or durably queued
/// the dispatch operation. The report must never be published as a terminal
/// Agent run result; Codex events and `AgentRunTerminalCommitBarrier` remain the
/// sole terminal settlement path.
@MainActor
enum CodexIntegratedRunExecutionAdapter {
    struct Result {
        let nativeOutcome: CodexAgentModeCoordinator.NativeSendOutcome
        let executionReport: DomainAgentRunExecutionReport

        var didStartProviderRun: Bool {
            if case .sent = nativeOutcome {
                return true
            }
            return false
        }

        var shouldReleaseCreatedOwnership: Bool {
            switch executionReport.result {
            case .superseded:
                true
            case let .terminal(outcome):
                outcome.kind != .completed
            }
        }
    }

    static func execute(
        operation: () async -> CodexAgentModeCoordinator.NativeSendOutcome
    ) async -> Result {
        var nativeOutcome: CodexAgentModeCoordinator.NativeSendOutcome?
        let executionReport = await DomainAgentRunExecutionCore.execute {
            let outcome = await operation()
            nativeOutcome = outcome
            return try operationResult(for: outcome)
        }
        guard let nativeOutcome else {
            preconditionFailure("Codex transient execution completed without a native outcome")
        }
        return Result(nativeOutcome: nativeOutcome, executionReport: executionReport)
    }

    private static func operationResult(
        for outcome: CodexAgentModeCoordinator.NativeSendOutcome
    ) throws -> DomainAgentRunExecutionOperationResult {
        switch outcome {
        case .sent, .queuedFallback:
            .completed(assistantText: nil)
        case .stale:
            .superseded
        case .cancelled:
            throw CancellationError()
        case let .preDispatchRejected(message), let .failed(message):
            throw DispatchFailure(message: message)
        }
    }

    private struct DispatchFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }
}
