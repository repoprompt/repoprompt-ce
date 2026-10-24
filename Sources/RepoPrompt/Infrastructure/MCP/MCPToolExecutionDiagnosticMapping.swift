import RepoPromptDomainRuntime
import RepoPromptInstrumentation

extension MCPToolExecutionDiagnosticEvent.ContractKind {
    init(_ kind: MCPToolExecutionContract.Kind) {
        self = switch kind {
        case .bounded: .bounded
        case .longSynchronousCancellable: .longSynchronousCancellable
        case .lifecycleManagedCancellable: .lifecycleManagedCancellable
        case .interactiveCancellable: .interactiveCancellable
        case .workspaceLifecycleCancellable: .workspaceLifecycleCancellable
        }
    }
}

extension MCPToolExecutionDiagnosticEvent.CleanupDisposition {
    init(_ disposition: MCPToolExecutionCleanupDisposition) {
        self = switch disposition {
        case .forceDisconnect: .forceDisconnect
        case .detachAndSettle: .detachAndSettle
        }
    }
}

extension MCPToolExecutionDiagnosticEvent.CancellationOrigin {
    init(_ origin: MCPToolExecutionCancellationOrigin) {
        self = switch origin {
        case .watchdogDeadline: .watchdogDeadline
        case .requestCancellation: .requestCancellation
        case .clientDeadline: .clientDeadline
        case .serverExportEnvelope: .serverExportEnvelope
        }
    }
}

extension MCPToolExecutionDiagnosticEvent.Outcome {
    init(_ outcome: MCPToolExecutionSettlement) {
        self = switch outcome {
        case .success: .success
        case .cancellation: .cancellation
        case .error: .error
        }
    }
}
