import Foundation

/// Stable identity for a bundled routing backend. Router selection is exact and never falls back.
struct AgentTaskRouterBackendID: RawRepresentable, Codable, Hashable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static let jev = AgentTaskRouterBackendID(rawValue: "jev")
}

enum AgentTaskRouterBackendReadiness: Equatable {
    case ready(generation: UInt64, policyVersion: String)
    case needsConfiguration(generation: UInt64, reason: String)
    case validating(generation: UInt64)
    case policyUnavailable(generation: UInt64, reason: String)
    case temporarilyUnavailable(generation: UInt64, reason: String)

    var generation: UInt64 {
        switch self {
        case let .ready(generation, _),
             let .needsConfiguration(generation, _),
             let .validating(generation),
             let .policyUnavailable(generation, _),
             let .temporarilyUnavailable(generation, _):
            generation
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

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

struct AgentTaskRoutingRequest: Equatable {
    static let currentContractVersion = "rpce.agent-session-router.v3"

    let requestID: UUID
    let contractVersion: String
    let task: String
    let scope: AgentTaskRoutingScope
    let decisionStage: AgentTaskRoutingDecisionStage
    let customInstructions: String?
    let candidates: [AgentTaskRoutingCandidateDescriptor]

    init(
        requestID: UUID,
        contractVersion: String,
        task: String,
        scope: AgentTaskRoutingScope,
        decisionStage: AgentTaskRoutingDecisionStage = .model,
        customInstructions: String?,
        candidates: [AgentTaskRoutingCandidateDescriptor]
    ) {
        self.requestID = requestID
        self.contractVersion = contractVersion
        self.task = task
        self.scope = scope
        self.decisionStage = decisionStage
        self.customInstructions = customInstructions
        self.candidates = candidates
    }
}

struct AgentTaskRoutingDecisionEvidence: Equatable {
    let policyVersion: String?
    let confidence: Double?
    let scores: [String: Double]?
    let inputTokens: Int?
    let outputTokens: Int?
    let reasonCode: String?
}

enum AgentTaskRoutingBackendFailureCategory: String, Equatable {
    case authentication
    case invalidRequest
    case rateLimited
    case overloaded
    case transport
    case timeout
    case invalidResponse
    case policyUnavailable
}

enum AgentTaskRoutingBackendOutcome: Equatable {
    case selected(opaqueKey: String, evidence: AgentTaskRoutingDecisionEvidence?)
    case abstained(reason: String, evidence: AgentTaskRoutingDecisionEvidence?)
    case failed(category: AgentTaskRoutingBackendFailureCategory, retryable: Bool, evidence: AgentTaskRoutingDecisionEvidence?)
    case cancelled
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
    let selectedBackendID: AgentTaskRouterBackendID?
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
