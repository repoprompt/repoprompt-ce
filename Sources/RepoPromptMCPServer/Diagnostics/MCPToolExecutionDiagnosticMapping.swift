import RepoPromptDomainRuntime
import RepoPromptInstrumentation

package extension MCPToolExecutionDiagnosticEvent.ContractKind {
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

package extension MCPToolExecutionDiagnosticEvent.CleanupDisposition {
    init(_ disposition: MCPToolExecutionCleanupDisposition) {
        self = switch disposition {
        case .forceDisconnect: .forceDisconnect
        case .detachAndSettle: .detachAndSettle
        }
    }
}

package extension MCPToolExecutionDiagnosticEvent.CancellationOrigin {
    init(_ origin: MCPToolExecutionCancellationOrigin) {
        self = switch origin {
        case .watchdogDeadline: .watchdogDeadline
        case .requestCancellation: .requestCancellation
        case .clientDeadline: .clientDeadline
        case .serverExportEnvelope: .serverExportEnvelope
        }
    }
}

package extension MCPToolExecutionDiagnosticEvent.Outcome {
    init(_ outcome: MCPToolExecutionSettlement) {
        self = switch outcome {
        case .success: .success
        case .cancellation: .cancellation
        case .error: .error
        }
    }
}
