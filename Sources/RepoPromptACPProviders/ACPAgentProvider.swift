import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess

/// Describes whether an ACP session identifier is known to be safe for a future
/// `session/load`.
package enum ACPLoadSessionIDConfidence: Equatable {
    case unavailable
    case candidate
    case verified
}

/// Runtime-to-load identity reported by the ACP controller to the runner.
/// ACP providers generally set both IDs to the same verified value when the
/// runtime session can be used for future `session/load` calls.
package struct ACPProviderSessionIdentity: Equatable {
    package let providerID: ACPProviderID
    package let runtimeSessionID: String?
    package let loadSessionID: String?
    package let loadSessionIDConfidence: ACPLoadSessionIDConfidence

    package init(
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

package struct ACPRunRequest {
    package let agentKind: AgentProviderKind
    package let modelString: String?
    package let workspacePath: String?
    package let resumeSessionID: String?
    package let attachments: [AgentFileAttachment]
    package let taskLabelKind: AgentTaskLabelKind?
    package let sessionModeID: String?
    package let autoApproveAllToolPermissions: Bool
    /// Provider-native CLI permission mode applied by the provider at PROCESS LAUNCH
    /// (Devin `--permission-mode`). Never sent over ACP and never passed to
    /// `setSessionMode`; `nil` means "pass no flag".
    package let launchPermissionMode: String?
    package let modelParameterSelections: [ACPModelParameterSelection]

    package init(
        agentKind: AgentProviderKind,
        modelString: String?,
        workspacePath: String?,
        resumeSessionID: String?,
        attachments: [AgentFileAttachment],
        taskLabelKind: AgentTaskLabelKind?,
        sessionModeID: String? = nil,
        autoApproveAllToolPermissions: Bool = false,
        launchPermissionMode: String? = nil,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) {
        self.agentKind = agentKind
        self.modelString = modelString
        self.workspacePath = workspacePath
        self.resumeSessionID = resumeSessionID
        self.attachments = attachments
        self.taskLabelKind = taskLabelKind
        self.sessionModeID = sessionModeID
        self.autoApproveAllToolPermissions = autoApproveAllToolPermissions
        self.launchPermissionMode = launchPermissionMode
        self.modelParameterSelections = modelParameterSelections
    }
}

package struct ACPAuthenticationContext: Equatable {
    package let authMethodIDs: [String]
    package let environment: [String: String]

    package init(authMethodIDs: [String], environment: [String: String]) {
        self.authMethodIDs = authMethodIDs
        self.environment = environment
    }
}

package struct ACPLaunchCleanupArtifact: Equatable {
    package let providerID: ACPProviderID
    package let id: UUID
    package let kind: String

    package init(providerID: ACPProviderID, id: UUID, kind: String) {
        self.providerID = providerID
        self.id = id
        self.kind = kind
    }
}

package struct ACPLaunchConfiguration: Equatable {
    package let providerID: ACPProviderID
    package let command: String
    package let arguments: [String]
    package let environment: [String: String]
    package let workingDirectory: String?
    package let additionalPathHints: [String]
    package let enableDebugLogging: Bool
    package let cleanupArtifact: ACPLaunchCleanupArtifact?
    package let expectedExecutableIdentity: ExecutableFileIdentity?
    /// Names of intentional launch additions, excluding any copied ambient snapshot.
    package let explicitEnvironmentKeys: Set<String>

    package init(
        providerID: ACPProviderID,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        additionalPathHints: [String],
        enableDebugLogging: Bool,
        cleanupArtifact: ACPLaunchCleanupArtifact? = nil,
        expectedExecutableIdentity: ExecutableFileIdentity? = nil,
        explicitEnvironmentKeys: Set<String>? = nil
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
        self.explicitEnvironmentKeys = explicitEnvironmentKeys ?? []
    }
}

package struct ACPSessionConfiguration: Equatable {
    package enum Mode: Equatable {
        case new
        case load(existingSessionID: String)
    }

    package struct PostOpenNotification: Equatable {
        package let method: String
        package let params: [String: AgentJSONValue]

        package init(method: String, params: [String: AgentJSONValue]) {
            self.method = method
            self.params = params
        }
    }

    package let mode: Mode
    package let workingDirectory: String
    package let mcpServers: [RepoPromptMCPServerConfiguration]
    /// Provider-owned `_meta` on every session-open attempt; empty means omit the key.
    package let metadata: [String: AgentJSONValue]
    /// Sent once after successful opening (including fallback), before the first prompt.
    package let postOpenNotification: PostOpenNotification?

    package init(
        mode: Mode,
        workingDirectory: String,
        mcpServers: [RepoPromptMCPServerConfiguration],
        metadata: [String: AgentJSONValue] = [:],
        postOpenNotification: PostOpenNotification? = nil
    ) {
        self.mode = mode
        self.workingDirectory = workingDirectory
        self.mcpServers = mcpServers
        self.metadata = metadata
        self.postOpenNotification = postOpenNotification
    }
}

/// Result of parsing a provider-specific session-open model advertisement.
package enum ACPProviderModelSnapshotResult: Equatable {
    /// The provider response carries no usable model metadata.
    case absent
    /// A valid snapshot was parsed.
    case valid(ACPDiscoveredSessionModels)
    /// Metadata was present but malformed; explicit model selection must be
    /// unavailable and the failure recorded/diagnosed. Never persisted.
    case malformed(reason: String)
}

package struct ACPModelParameterClassificationInput {
    package let configID: String
    package let category: String?
    package let displayName: String
    package let choices: [ACPModelParameterChoice]

    package init(configID: String, category: String?, displayName: String, choices: [ACPModelParameterChoice]) {
        self.configID = configID
        self.category = category
        self.displayName = displayName
        self.choices = choices
    }
}

package struct ACPModelParameterApplicationReport: Equatable {
    package let applied: [ACPModelParameterSelection]
    package let alreadyCurrent: [ACPModelParameterSelection]
    package let skipped: [ACPModelParameterSelection]

    package init(
        applied: [ACPModelParameterSelection],
        alreadyCurrent: [ACPModelParameterSelection] = [],
        skipped: [ACPModelParameterSelection]
    ) {
        self.applied = applied
        self.alreadyCurrent = alreadyCurrent
        self.skipped = skipped
    }

    /// A skipped selection means a requested model parameter could not be honoured. Callers
    /// fail loudly before prompting rather than silently running at another value. This lives on
    /// the report type because the check depends only on the report — it is the shared owner for
    /// both the Agent Mode runner and the Context Builder headless provider.
    package func validateNoSkippedSelections() throws {
        guard skipped.isEmpty else {
            throw ACPModelParameterSelectionError.skipped(selections: skipped)
        }
    }
}

/// A requested ACP model parameter that could not be applied to the session.
package enum ACPModelParameterSelectionError: LocalizedError, Equatable {
    case skipped(selections: [ACPModelParameterSelection])

    package var errorDescription: String? {
        switch self {
        case let .skipped(selections):
            let values = selections.map { "\($0.configID)=\($0.valueRaw)" }.joined(separator: ", ")
            return "The selected model settings are stale or unsupported for this ACP session: \(values). Refresh the model settings and try again."
        }
    }
}

/// A provider-owned direct model-selection RPC (e.g. Grok's `session/set_model`).
/// The controller stays unaware of provider method names and parameter keys.
package struct ACPDirectModelSelectionRequest {
    package let method: String
    package let params: [String: Any]
    /// The model id the provider's acknowledgement must echo before the controller updates
    /// local model authority. For effort-compound selections this is the BASE model id —
    /// the wire confirms the model, not the effort suffix.
    package var expectedConfirmationModelRaw: String

    package init(method: String, params: [String: Any], expectedConfirmationModelRaw: String) {
        self.method = method
        self.params = params
        self.expectedConfirmationModelRaw = expectedConfirmationModelRaw
    }
}

/// A report applies to the advertised base named in the same update. A nil effort means
/// the report was applicable but unresolvable; a nil report means no applicable update.
package struct ACPDirectSessionEffortReport {
    package let baseModelRaw: String
    package let effortRaw: String?

    package init(baseModelRaw: String, effortRaw: String?) {
        self.baseModelRaw = baseModelRaw
        self.effortRaw = effortRaw
    }
}

/// Bounded capability for ACP providers that advertise session models outside the
/// modern `configOptions` contract (e.g. Grok's top-level `SessionModelState`) and
/// apply selections through a provider-specific RPC instead of
/// `session/set_config_option`.
///
/// The controller consults this ONLY when modern `configOptions` metadata is
/// absent; a malformed modern selector never falls back to this path.
package protocol ACPDirectSessionModelProvider: Sendable {
    func parseDirectSessionModelSnapshot(
        from sessionResponse: [String: Any]
    ) -> ACPProviderModelSnapshotResult

    func parseDirectSessionEffortReport(
        from configOptions: [[String: Any]],
        sessionID: String,
        options: [AgentModelOption]
    ) -> ACPDirectSessionEffortReport?

    /// Builds the provider's selection RPC from STRUCTURED parts. The controller
    /// decomposes and validates the selection against the advertised snapshot; the
    /// provider owns wire names (`session/set_model`, `_meta.reasoningEffort`, …)
    /// and never re-parses compound strings.
    func makeDirectModelSelectionRequest(
        sessionID: String,
        baseModelRaw: String,
        reasoningEffortRaw: String?
    ) -> ACPDirectModelSelectionRequest
}

package protocol ACPAgentProvider: Sendable {
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

    /// Recognizes a provider-owned response ID only. After ordinary request correlation fails,
    /// the controller requires only a string `id` and no `method` before consulting this hook.
    /// Keep this synchronous and side-effect-free.
    /// This must be a protocol requirement so calls through an existential reach overrides.
    func recognizesUnmatchedResponseID(_ id: String) -> Bool

    /// Opts a provider into ACP's parameterized model picker capability and classifies
    /// provider-owned select options without changing their exact wire identity.
    var supportsParameterizedModelPicker: Bool { get }
    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind?

    /// Whether a provider's stderr line should be surfaced into the transcript as a system
    /// event. Must be declared here (not only in the extension) so the controller's call
    /// through the existential dispatches to provider overrides.
    func shouldEmitStderrLine(_ line: String) -> Bool
}

package extension ACPAgentProvider {
    func recognizesUnmatchedResponseID(_: String) -> Bool {
        false
    }

    var supportsParameterizedModelPicker: Bool {
        false
    }

    func modelParameterKind(for _: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        nil
    }

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
