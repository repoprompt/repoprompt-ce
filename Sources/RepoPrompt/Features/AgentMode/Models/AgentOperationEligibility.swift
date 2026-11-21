import RepoPromptAIContracts

/// Capability and readiness are separate: installing a CLI cannot enable an unsupported operation.
/// The caller supplies readiness from the owning catalog or connection state, not recommendations.
enum AgentOperationEligibility: Equatable {
    case eligible
    case unsupportedOperation
    case unavailableModel

    var isEligible: Bool {
        self == .eligible
    }

    enum AgentOperation {
        case contextBuilder
        case subAgent

        func supports(_ provider: AgentProviderKind) -> Bool {
            switch self {
            case .contextBuilder: provider != .antigravity
            case .subAgent: true
            }
        }

        func eligibility(for provider: AgentProviderKind, available: @autoclosure () -> Bool) -> AgentOperationEligibility {
            guard supports(provider) else { return .unsupportedOperation }
            return available() ? .eligible : .unavailableModel
        }
    }

    enum AIOperation {
        case oracle
        case reprompt

        func supports(_ model: AIModel) -> Bool {
            switch self {
            case .oracle:
                true
            case .reprompt:
                AgentRepromptModelPolicy.supportsSideCall(model) && model.canStream
            }
        }

        func eligibility(for model: AIModel, available: @autoclosure () -> Bool) -> AgentOperationEligibility {
            guard supports(model) else { return .unsupportedOperation }
            return available() ? .eligible : .unavailableModel
        }
    }
}
