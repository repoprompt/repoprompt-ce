import Foundation
import RepoPromptDomainRuntime
import RepoPromptProviderQuota

package enum NativeAgentRuntimeTurnStatus {
    case completed
    case cancelled
    case failed
}

package struct NativeAgentRuntimeRuntimeInitStatus: Equatable {
    package struct InitializeResponseSnapshot: Equatable {
        package struct Command: Equatable {
            package let name: String
            package let description: String
            package let argumentHint: String
            package let builtin: Bool

            package init(name: String, description: String, argumentHint: String, builtin: Bool = false) {
                self.name = name
                self.description = description
                self.argumentHint = argumentHint
                self.builtin = builtin
            }
        }

        package struct Agent: Equatable {
            package let name: String
            package let description: String
            package let model: String?

            package init(name: String, description: String, model: String?) {
                self.name = name
                self.description = description
                self.model = model
            }
        }

        package struct Account: Equatable {
            package let email: String?
            package let organization: String?
            package let subscriptionType: String?
            package let tokenSource: String?
            package let apiKeySource: String?
            package let apiProvider: String?

            package init(email: String?, organization: String?, subscriptionType: String?, tokenSource: String?, apiKeySource: String?, apiProvider: String?) {
                self.email = email
                self.organization = organization
                self.subscriptionType = subscriptionType
                self.tokenSource = tokenSource
                self.apiKeySource = apiKeySource
                self.apiProvider = apiProvider
            }
        }

        package let commands: [Command]
        package let agents: [Agent]
        package let outputStyle: String?
        package let availableOutputStyles: [String]
        package let account: Account?
        package let pid: Int?
        package let modelsJSON: String?
        package let fastModeStateJSON: String?

        package init(commands: [Command], agents: [Agent], outputStyle: String?, availableOutputStyles: [String], account: Account?, pid: Int?, modelsJSON: String?, fastModeStateJSON: String?) {
            self.commands = commands
            self.agents = agents
            self.outputStyle = outputStyle
            self.availableOutputStyles = availableOutputStyles
            self.account = account
            self.pid = pid
            self.modelsJSON = modelsJSON
            self.fastModeStateJSON = fastModeStateJSON
        }
    }

    package let sessionID: String?
    package let tools: [String]
    package let mcpServerStatuses: [String: String]
    package let initializeResponse: InitializeResponseSnapshot?
    /// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the running process's final launch environment.
    package var autoCompactWindowTokens: Int?

    package init(
        sessionID: String?,
        tools: [String],
        mcpServerStatuses: [String: String],
        initializeResponse: InitializeResponseSnapshot?,
        autoCompactWindowTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.tools = tools
        self.mcpServerStatuses = mcpServerStatuses
        self.initializeResponse = initializeResponse
        self.autoCompactWindowTokens = autoCompactWindowTokens
    }
}

package enum NativeAgentRuntimeEvent {
    case stream(RepoPromptDomainRuntime.AIStreamResult)
    case rateLimit(ClaudeProviderQuotaObservation)
    case runtimeInit(NativeAgentRuntimeRuntimeInitStatus)
    case approvalRequest(AgentApprovalRequest)
    case approvalCancelled(requestID: String)
    case providerTurnStarted(turnID: UUID)
    case turnCompleted(turnID: UUID, status: NativeAgentRuntimeTurnStatus)
    /// Keyed answer group, including singleton groups. Legacy positional answers use turnCompleted.
    case turnsCompleted(turnIDs: [UUID], status: NativeAgentRuntimeTurnStatus)
    case error(String)
}

package struct NativeAgentRuntimeSessionRef {
    package var sessionID: String?

    package init(sessionID: String?) {
        self.sessionID = sessionID
    }
}

/// Outcome of an interrupt control request, used by the coordinator to decide
/// whether it is safe to proceed with a superseding user turn.
package enum NativeAgentRuntimeInterruptOutcome: Equatable {
    /// Claude acknowledged the interrupt via control_response success.
    case acknowledged
    /// No turn was in flight; the turn likely completed naturally before the interrupt.
    case noTurnInFlight
    /// The interrupt control request timed out without an acknowledgement.
    case timedOut
    /// The interrupt request failed (e.g. process not running or write error).
    case failed
}

package enum NativeAgentRuntimeControllerError: Error, LocalizedError {
    case processNotRunning
    case initializationFailed(String)
    case invalidControlResponse(String)
    case inputWriteFailed(String)
    case controlRequestTimedOut(requestID: String)
    case liveModelSwitchRequiresRestart
    case configurationNotCurrent
    /// Cancellation observed at the proof-bearing send entry, before any user-message write.
    case cancelledBeforeWrite

    package var errorDescription: String? {
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

package typealias NativeAgentRuntimeSlashCommand = NativeAgentRuntimeRuntimeInitStatus.InitializeResponseSnapshot.Command
