import Foundation
import RepoPromptDomainRuntime
import RepoPromptProviderQuota

enum NativeAgentRuntimeTurnStatus {
    case completed
    case cancelled
    case failed
}

struct NativeAgentRuntimeRuntimeInitStatus: Equatable {
    struct InitializeResponseSnapshot: Equatable {
        struct Command: Equatable {
            let name: String
            let description: String
            let argumentHint: String
            let builtin: Bool

            init(name: String, description: String, argumentHint: String, builtin: Bool = false) {
                self.name = name
                self.description = description
                self.argumentHint = argumentHint
                self.builtin = builtin
            }
        }

        struct Agent: Equatable {
            let name: String
            let description: String
            let model: String?
        }

        struct Account: Equatable {
            let email: String?
            let organization: String?
            let subscriptionType: String?
            let tokenSource: String?
            let apiKeySource: String?
            let apiProvider: String?
        }

        let commands: [Command]
        let agents: [Agent]
        let outputStyle: String?
        let availableOutputStyles: [String]
        let account: Account?
        let pid: Int?
        let modelsJSON: String?
        let fastModeStateJSON: String?
    }

    let sessionID: String?
    let tools: [String]
    let mcpServerStatuses: [String: String]
    let initializeResponse: InitializeResponseSnapshot?
}

enum NativeAgentRuntimeEvent {
    case stream(AIStreamResult)
    case rateLimit(ClaudeProviderQuotaObservation)
    case runtimeInit(NativeAgentRuntimeRuntimeInitStatus)
    case approvalRequest(AgentApprovalRequest)
    case approvalCancelled(requestID: String)
    case turnCompleted(turnID: UUID, status: NativeAgentRuntimeTurnStatus)
    /// Keyed answer group, including singleton groups. Legacy positional answers use turnCompleted.
    case turnsCompleted(turnIDs: [UUID], status: NativeAgentRuntimeTurnStatus)
    case error(String)
}

struct NativeAgentRuntimeSessionRef {
    var sessionID: String?
}

/// Outcome of an interrupt control request, used by the coordinator to decide
/// whether it is safe to proceed with a superseding user turn.
enum NativeAgentRuntimeInterruptOutcome: Equatable {
    /// Claude acknowledged the interrupt via control_response success.
    case acknowledged
    /// No turn was in flight; the turn likely completed naturally before the interrupt.
    case noTurnInFlight
    /// The interrupt control request timed out without an acknowledgement.
    case timedOut
    /// The interrupt request failed (e.g. process not running or write error).
    case failed
}

enum NativeAgentRuntimeControllerError: Error, LocalizedError {
    case processNotRunning
    case initializationFailed(String)
    case invalidControlResponse(String)
    case inputWriteFailed(String)
    case controlRequestTimedOut(requestID: String)
    case liveModelSwitchRequiresRestart
    case configurationNotCurrent
    /// Cancellation observed at the proof-bearing send entry, before any user-message write.
    case cancelledBeforeWrite

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            "Claude process is not running."
        case let .initializationFailed(message):
            "Claude initialization failed: \(message)"
        case let .invalidControlResponse(message):
            "Claude control response failed: \(message)"
        case let .inputWriteFailed(message):
            "Failed writing to Claude process stdin: \(message)"
        case let .controlRequestTimedOut(requestID):
            "Claude control request timed out: \(requestID)"
        case .cancelledBeforeWrite:
            "Claude dispatch was cancelled before writing. No message was sent."
        case .configurationNotCurrent:
            "Claude model configuration is not current. No message was sent; retry the turn."
        case .liveModelSwitchRequiresRestart:
            "Changing to the selected model requires restarting Claude because its launch environment changes."
        }
    }
}

typealias NativeAgentRuntimeSlashCommand = NativeAgentRuntimeRuntimeInitStatus.InitializeResponseSnapshot.Command
