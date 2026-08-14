import Foundation

enum ACPProviderID: String, Hashable {
    case openCode
    case cursor
    case grokBuild
}

enum ACPSupportResult: Equatable {
    case supported
    case unsupported(reason: String)

    var reason: String? {
        switch self {
        case .supported:
            nil
        case let .unsupported(reason):
            reason
        }
    }
}

struct ACPDiscoveredSessionModels: Equatable {
    let options: [AgentModelOption]
    let currentModelRaw: String?

    var preferredModelRaw: String? {
        option(matching: currentModelRaw)?.rawValue
            ?? Self.normalizedRawModel(currentModelRaw)
            ?? options.first(where: \.isProviderDefault)?.rawValue
            ?? options.first?.rawValue
    }

    func option(matching raw: String?) -> AgentModelOption? {
        guard let normalized = Self.normalizedRawModel(raw) else { return nil }
        return options.first {
            Self.normalizedRawModel($0.rawValue) == normalized
        }
    }

    func contains(rawModel: String?) -> Bool {
        option(matching: rawModel) != nil
    }

    private static func normalizedRawModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed.lowercased()
    }
}

/// Describes whether an ACP session identifier is known to be safe for a future
/// `session/load`.
enum ACPLoadSessionIDConfidence: Equatable {
    case unavailable
    case candidate
    case verified
}

/// Runtime-to-load identity reported by the ACP controller to the runner.
/// ACP providers generally set both IDs to the same verified value when the
/// runtime session can be used for future `session/load` calls.
struct ACPProviderSessionIdentity: Equatable {
    let providerID: ACPProviderID
    let runtimeSessionID: String?
    let loadSessionID: String?
    let loadSessionIDConfidence: ACPLoadSessionIDConfidence

    init(
        providerID: ACPProviderID,
        runtimeSessionID: String? = nil,
        loadSessionID: String? = nil,
        loadSessionIDConfidence: ACPLoadSessionIDConfidence = .unavailable
    ) {
        self.providerID = providerID
        let runtime = runtimeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let load = loadSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimeSessionID = runtime?.isEmpty == false ? runtime : nil
        self.loadSessionID = load?.isEmpty == false ? load : nil
        self.loadSessionIDConfidence = load == nil || load?.isEmpty == true ? .unavailable : loadSessionIDConfidence
    }
}

struct ACPRunRequest {
    let agentKind: AgentProviderKind
    let modelString: String?
    let workspacePath: String?
    let resumeSessionID: String?
    let attachments: [AgentImageAttachment]
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    let sessionModeID: String?
    let autoApproveAllToolPermissions: Bool

    init(
        agentKind: AgentProviderKind,
        modelString: String?,
        workspacePath: String?,
        resumeSessionID: String?,
        attachments: [AgentImageAttachment],
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        sessionModeID: String? = nil,
        autoApproveAllToolPermissions: Bool = false
    ) {
        self.agentKind = agentKind
        self.modelString = modelString
        self.workspacePath = workspacePath
        self.resumeSessionID = resumeSessionID
        self.attachments = attachments
        self.taskLabelKind = taskLabelKind
        self.sessionModeID = sessionModeID
        self.autoApproveAllToolPermissions = autoApproveAllToolPermissions
    }
}

struct ACPAuthenticationContext: Equatable {
    let authMethodIDs: [String]
    let environment: [String: String]
}

struct ACPLaunchCleanupArtifact: Equatable {
    let providerID: ACPProviderID
    let id: UUID
    let kind: String
}

struct ACPLaunchConfiguration: Equatable {
    let providerID: ACPProviderID
    let command: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String?
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let cleanupArtifact: ACPLaunchCleanupArtifact?
    let expectedExecutableIdentity: ExecutableFileIdentity?

    init(
        providerID: ACPProviderID,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        additionalPathHints: [String],
        enableDebugLogging: Bool,
        cleanupArtifact: ACPLaunchCleanupArtifact? = nil,
        expectedExecutableIdentity: ExecutableFileIdentity? = nil
    ) {
        self.providerID = providerID
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.cleanupArtifact = cleanupArtifact
        self.expectedExecutableIdentity = expectedExecutableIdentity
    }
}

struct ACPSessionConfiguration: Equatable {
    enum Mode: Equatable {
        case new
        case load(existingSessionID: String)
    }

    let mode: Mode
    let workingDirectory: String
    let mcpServers: [RepoPromptMCPServerConfiguration]
}

enum NormalizedAgentRuntimeEvent {
    case stream(AIStreamResult)
    case approvalRequested(AgentApprovalRequest)
    case approvalCancelled(AgentApprovalRequestID)
    case terminal(state: AgentSessionRunState, errorText: String?)
}

/// Result of parsing a provider-specific session-open model advertisement.
enum ACPProviderModelSnapshotResult: Equatable {
    /// The provider response carries no usable model metadata.
    case absent
    /// A valid snapshot was parsed.
    case valid(ACPDiscoveredSessionModels)
    /// Metadata was present but malformed; explicit model selection must be
    /// unavailable and the failure recorded/diagnosed. Never persisted.
    case malformed(reason: String)
}

/// A provider-owned direct model-selection RPC (e.g. Grok's `session/set_model`).
/// The controller stays unaware of provider method names and parameter keys.
struct ACPDirectModelSelectionRequest {
    let method: String
    let params: [String: Any]
}

/// Bounded capability for ACP providers that advertise session models outside the
/// modern `configOptions` contract (e.g. Grok's top-level `SessionModelState`) and
/// apply selections through a provider-specific RPC instead of
/// `session/set_config_option`.
///
/// The controller consults this ONLY when modern `configOptions` metadata is
/// absent; a malformed modern selector never falls back to this path.
protocol ACPDirectSessionModelProvider: Sendable {
    func parseDirectSessionModelSnapshot(
        from sessionResponse: [String: Any]
    ) -> ACPProviderModelSnapshotResult

    func makeDirectModelSelectionRequest(
        sessionID: String,
        modelRaw: String
    ) -> ACPDirectModelSelectionRequest
}

protocol ACPAgentProvider: Sendable {
    var providerID: ACPProviderID { get }

    func support(for request: ACPRunRequest) async throws -> ACPSupportResult
    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration
    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration
    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]]
    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent]
    func preferredAuthMethodID(context: ACPAuthenticationContext) -> String?
    func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async
    func normalizeError(_ error: Error) -> Error

    /// Whether a provider's stderr line should be surfaced into the transcript as a system
    /// event. Must be declared here (not only in the extension) so the controller's call
    /// through the existential dispatches to provider overrides.
    func shouldEmitStderrLine(_ line: String) -> Bool
}

extension ACPAgentProvider {
    func preferredAuthMethodID(context _: ACPAuthenticationContext) -> String? {
        nil
    }

    func cleanupLaunchArtifacts(for _: ACPLaunchConfiguration) async {}

    /// Whether a provider's stderr line should be surfaced into the transcript as a system
    /// event. Default surfaces everything; providers with known-noisy background logging
    /// can suppress specific patterns (diagnostics still record every line).
    func shouldEmitStderrLine(_: String) -> Bool {
        true
    }
}
