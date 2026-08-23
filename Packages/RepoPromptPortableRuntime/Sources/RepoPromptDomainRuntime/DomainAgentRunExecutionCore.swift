import Foundation

// MARK: - Shared transient Agent run execution

/// The host-controlled result of one provider operation.
///
/// Cancellation and failure are expressed by thrown errors so every execution
/// host shares the same classification order. Supersession is explicit because
/// it must never be mistaken for a missing terminal result.
public enum DomainAgentRunExecutionOperationResult: Equatable, Sendable {
    case completed(assistantText: String?)
    case superseded
}

/// The presentation-free result returned to an Agent execution host.
///
/// Hosts remain responsible for mapping terminal outcomes into their canonical
/// publication surface. This value owns no session, provider, or settlement
/// state.
public enum DomainAgentRunExecutionResult: Equatable, Sendable {
    case terminal(DomainAgentRunTerminalOutcome)
    case superseded
}

/// Deterministic lifecycle facts produced by one execution-core invocation.
///
/// The trace intentionally excludes provider payloads, display text, IDs, and
/// timestamps so streaming and one-shot hosts can assert lifecycle parity.
public enum DomainAgentRunExecutionTraceEvent: Equatable, Sendable {
    case executionStarted
    case terminalOutcomeProduced(DomainAgentRunTerminalOutcome.Kind)
    case executionSuperseded
}

/// Immutable report from one shared execution-core invocation.
public struct DomainAgentRunExecutionReport: Equatable, Sendable {
    public let result: DomainAgentRunExecutionResult
    public let trace: [DomainAgentRunExecutionTraceEvent]

    public init(
        result: DomainAgentRunExecutionResult,
        trace: [DomainAgentRunExecutionTraceEvent]
    ) {
        self.result = result
        self.trace = trace
    }
}

/// Stateless classifier shared by app-hosted and direct/headless Agent runs.
///
/// This namespace deliberately owns no task, stream, provider, registration,
/// epoch, cancellation handler, teardown, or publication capability. The
/// caller supplies exactly one operation on its own isolation domain, then maps
/// the returned report into its existing host and canonical lifecycle surfaces.
public enum DomainAgentRunExecutionCore {
    public static func execute(
        isolation _: isolated (any Actor)? = #isolation,
        failureReason: DomainAgentRunSnapshot.FailureReason = .agentError,
        failureText: (any Error) -> String = { $0.localizedDescription },
        operation: () async throws -> DomainAgentRunExecutionOperationResult
    ) async -> DomainAgentRunExecutionReport {
        let started: [DomainAgentRunExecutionTraceEvent] = [.executionStarted]
        do {
            switch try await operation() {
            case let .completed(assistantText):
                let outcome = DomainAgentRunTerminalOutcome.completed(assistantText: assistantText)
                return terminalReport(outcome, after: started)
            case .superseded:
                return DomainAgentRunExecutionReport(
                    result: .superseded,
                    trace: started + [.executionSuperseded]
                )
            }
        } catch is CancellationError {
            return terminalReport(.cancelled(), after: started)
        } catch {
            return terminalReport(
                .failed(assistantText: failureText(error), reason: failureReason),
                after: started
            )
        }
    }

    private static func terminalReport(
        _ outcome: DomainAgentRunTerminalOutcome,
        after trace: [DomainAgentRunExecutionTraceEvent]
    ) -> DomainAgentRunExecutionReport {
        DomainAgentRunExecutionReport(
            result: .terminal(outcome),
            trace: trace + [.terminalOutcomeProduced(outcome.kind)]
        )
    }
}
