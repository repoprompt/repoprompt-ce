import Foundation
import RepoPromptSettingsCore

/// Complete executable identity used for candidate deduplication and commit/rollback.
/// It deliberately retains effort and normalized ACP parameters; provider/model alone is not executable identity.
struct AgentRoutingExecutableTarget: Hashable {
    let agentRaw: String
    let modelRaw: String
    let reasoningEffortRaw: String?
    let modelParameters: [ACPModelParameterSelection]

    init(
        agentRaw: String,
        modelRaw: String,
        reasoningEffortRaw: String?,
        modelParameters: [ACPModelParameterSelection]
    ) {
        self.agentRaw = agentRaw
        self.modelRaw = modelRaw
        self.reasoningEffortRaw = reasoningEffortRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modelParameters = Self.canonicalParameters(modelParameters)
    }

    private static func canonicalParameters(_ parameters: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.normalized(parameters).sorted {
            let lhs = ($0.providerID.rawValue, $0.baseModelRaw, $0.kind.rawValue, $0.configID, $0.valueRaw)
            let rhs = ($1.providerID.rawValue, $1.baseModelRaw, $1.kind.rawValue, $1.configID, $1.valueRaw)
            return lhs < rhs
        }
    }
}

struct AgentTaskRoutingCandidateDescriptor: Codable, Equatable {
    let opaqueKey: String
    let roleLabels: [String]
    let targetDescription: String
    let rubricVersion: String
    let rubric: String
}

enum AgentTaskRoutingScope: String, Codable, Equatable {
    case primarySession
    case subagent
}

enum AgentTaskRoutingDecisionStage: String, Codable, Equatable {
    case model
    case effort
}

struct AgentTaskRouterConfiguration: Equatable {
    enum Validity: Equatable {
        case valid
        case disabled
        case backendMissing
        case fewerThanTwoRoles
        case noAllowedProviders
    }

    let enabled: Bool
    let selectedBackendID: DecisionServiceID?
    let selectedBackendRawValue: String?
    let candidateRoles: [AgentModelCatalog.TaskLabelKind]
    let allowedProviders: Set<AgentProviderKind>
    let candidateRolesMaterialized: Bool
    let allowedProvidersMaterialized: Bool
    let unknownRoleRawValues: [String]
    let unknownProviderRawValues: [String]
    let primaryProvider: AgentProviderKind?
    let subagentProvider: AgentProviderKind?
    let customInstructions: String
    let validity: Validity
    let revision: UInt64
    var usageBalancing = AgentUsageBalancingConfiguration()
    var allowPaidFastRouting = false
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
