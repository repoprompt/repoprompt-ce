import Foundation

/// The version of the RepoPrompt-specific mobile remote protocol.
///
/// This is intentionally separate from the MCP protocol version. A remote client
/// is a first-class RepoPrompt control surface, not a generic MCP client.
public enum RemoteProtocol {
    public static let minimumSupportedVersion = 1
    public static let currentVersion = 1
    public static let irohALPN = "repoprompt-remote/1"

    public static func supports(_ version: Int) -> Bool {
        (minimumSupportedVersion ... currentVersion).contains(version)
    }
}

public struct RemotePairingResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktop: RemoteDesktopSummary
    public let deviceID: String
    public let credential: String
    public let credentialExpiresAt: Date?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktop: RemoteDesktopSummary,
        deviceID: String,
        credential: String,
        credentialExpiresAt: Date? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.desktop = desktop
        self.deviceID = deviceID
        self.credential = credential
        self.credentialExpiresAt = credentialExpiresAt
    }
}

public struct RemoteUnpairResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let unpaired: Bool

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        unpaired: Bool = true
    ) {
        self.protocolVersion = protocolVersion
        self.unpaired = unpaired
    }
}

public struct RemoteErrorResponse: Codable, Sendable, Equatable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum RemoteAuthorityLevel: Int, Codable, Comparable, Sendable {
    case observe = 0
    case respond = 1
    case control = 2
    case danger = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RemoteAuthorizationState: Codable, Sendable, Equatable {
    public let defaultLevel: RemoteAuthorityLevel

    public init(defaultLevel: RemoteAuthorityLevel = .observe) {
        self.defaultLevel = defaultLevel
    }

    public func effectiveLevel() -> RemoteAuthorityLevel {
        defaultLevel
    }

    public func allows(_ requiredLevel: RemoteAuthorityLevel) -> Bool {
        defaultLevel >= requiredLevel
    }
}

public enum RemoteRunState: String, Codable, Sendable {
    case idle
    case opening
    case working
    case waitingForInput = "waiting_for_input"
    case blocked
    case completed
    case failed
    case cancelled
}

public enum RemoteAttentionKind: String, Codable, Sendable {
    case agentNeedsInput = "agent_needs_input"
    case approvalRequired = "approval_required"
    case completed
    case failed
}

public enum RemoteInteractionKind: String, Codable, Sendable {
    case question
    case approval
    case secretInput = "secret_input"
}

public struct RemoteQuestionnaire: Codable, Sendable, Equatable {
    public let context: String?
    public let questions: [RemoteQuestionField]

    public init(context: String? = nil, questions: [RemoteQuestionField]) {
        self.context = context
        self.questions = questions
    }
}

public struct RemoteQuestionField: Codable, Sendable, Equatable, Identifiable {
    public struct Option: Codable, Sendable, Equatable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let id: String
    public let header: String?
    public let prompt: String
    public let context: String?
    public let options: [Option]
    public let isSecret: Bool
    public let allowsMultiple: Bool
    public let allowsCustom: Bool
    public let allowsNote: Bool
    public let allowsSkip: Bool

    public init(
        id: String, header: String? = nil, prompt: String, context: String? = nil,
        options: [Option] = [], isSecret: Bool = false, allowsMultiple: Bool = false,
        allowsCustom: Bool = false, allowsNote: Bool = false, allowsSkip: Bool = false
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.context = context
        self.options = options
        self.isSecret = isSecret
        self.allowsMultiple = allowsMultiple
        self.allowsCustom = allowsCustom
        self.allowsNote = allowsNote
        self.allowsSkip = allowsSkip
    }

    public func accepts(_ answer: RemoteQuestionAnswer) -> Bool {
        let indices = answer.selectedOptionIndices
        let hasText = answer.normalizedText != nil
        if answer.skipped {
            return allowsSkip && indices.isEmpty && !hasText
        }
        return Set(indices).count == indices.count
            && indices.allSatisfy(options.indices.contains)
            && (allowsMultiple || indices.count <= 1)
            && (!hasText || allowsCustom)
            && (indices.isEmpty || !hasText || allowsMultiple || allowsNote)
            && (!indices.isEmpty || hasText)
    }
}

/// Transient response data, including masked entries when the pending field is secret.
/// These values belong only to the respond command and must never be recorded.
public struct RemoteQuestionAnswer: Codable, Sendable, Equatable {
    public let selectedOptionIndices: [Int]
    public let text: String?
    public let skipped: Bool

    public init(selectedOptionIndices: [Int] = [], text: String? = nil, skipped: Bool = false) {
        self.selectedOptionIndices = selectedOptionIndices
        self.text = text
        self.skipped = skipped
    }

    public var normalizedText: String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A pending interaction deliberately contains no answer value. Secret answers are
/// submitted as one-shot commands and are never part of snapshots, history, or events.
public struct RemoteInteractionSummary: Codable, Sendable, Equatable {
    private static let legacyMultipartReason = "Answer this multi-part request on your Mac."

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, prompt, requiresSecureEntry, createdAt, questionnaire
        case wireResponseUnavailableReason = "responseUnavailableReason"
    }

    public let id: String
    public let kind: RemoteInteractionKind
    public let title: String?
    public let prompt: String?
    public let requiresSecureEntry: Bool
    private let wireResponseUnavailableReason: String?
    public let createdAt: Date
    public let questionnaire: RemoteQuestionnaire?

    public var responseUnavailableReason: String? {
        // Questionnaire-aware clients can respond to multipart prompts. Older clients
        // read the wire reason and keep their single-answer form disabled.
        if (questionnaire?.questions.count ?? 0) > 1, wireResponseUnavailableReason == Self.legacyMultipartReason {
            return nil
        }
        return wireResponseUnavailableReason
    }

    public init(
        id: String,
        kind: RemoteInteractionKind,
        title: String? = nil,
        prompt: String? = nil,
        requiresSecureEntry: Bool = false,
        responseUnavailableReason: String? = nil,
        createdAt: Date = Date(),
        questionnaire: RemoteQuestionnaire? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.requiresSecureEntry = requiresSecureEntry
        self.wireResponseUnavailableReason = responseUnavailableReason
            ?? ((questionnaire?.questions.count ?? 0) > 1 ? Self.legacyMultipartReason : nil)
        self.createdAt = createdAt
        self.questionnaire = questionnaire
    }
}

public struct RemoteDesktopSummary: Codable, Sendable, Equatable {
    public let instanceID: String
    public let displayName: String
    public let appVersion: String
    public let isAvailable: Bool
    public let lastSeenAt: Date?

    public init(
        instanceID: String,
        displayName: String,
        appVersion: String,
        isAvailable: Bool,
        lastSeenAt: Date? = nil
    ) {
        self.instanceID = instanceID
        self.displayName = displayName
        self.appVersion = appVersion
        self.isAvailable = isAvailable
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteConnectionSummary: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case disconnected
        case discovering
        case connecting
        case connected
        case reconnecting
    }

    public let state: State
    public let transport: String
    public let lastConnectedAt: Date?

    public init(state: State, transport: String = "iroh", lastConnectedAt: Date? = nil) {
        self.state = state
        self.transport = transport
        self.lastConnectedAt = lastConnectedAt
    }
}

public struct RemoteDiagnostics: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let gatewayState: String
    public let lastRequestAt: Date?
    public let lastSuccessfulRequestAt: Date?
    public let lastSnapshotAt: Date?
    public let lastEventCursor: UInt64
    public let pairedDevice: Bool
    public let notificationRegistration: Bool
    public let notificationRelayConfigured: Bool
    public let notificationLastAttemptAt: Date?
    public let notificationLastError: String?
    public let irohState: String?
    public let irohEndpointID: String?
    public let irohPath: RemoteIrohPathKind?
    public let irohActivePeerCount: Int?
    public let irohLastTransitionAt: Date?
    public let irohLastError: String?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        gatewayState: String,
        lastRequestAt: Date? = nil,
        lastSuccessfulRequestAt: Date? = nil,
        lastSnapshotAt: Date? = nil,
        lastEventCursor: UInt64 = 0,
        pairedDevice: Bool,
        notificationRegistration: Bool = false,
        notificationRelayConfigured: Bool = false,
        notificationLastAttemptAt: Date? = nil,
        notificationLastError: String? = nil,
        irohState: String? = nil,
        irohEndpointID: String? = nil,
        irohPath: RemoteIrohPathKind? = nil,
        irohActivePeerCount: Int? = nil,
        irohLastTransitionAt: Date? = nil,
        irohLastError: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.gatewayState = gatewayState
        self.lastRequestAt = lastRequestAt
        self.lastSuccessfulRequestAt = lastSuccessfulRequestAt
        self.lastSnapshotAt = lastSnapshotAt
        self.lastEventCursor = lastEventCursor
        self.pairedDevice = pairedDevice
        self.notificationRegistration = notificationRegistration
        self.notificationRelayConfigured = notificationRelayConfigured
        self.notificationLastAttemptAt = notificationLastAttemptAt
        self.notificationLastError = notificationLastError
        self.irohState = irohState
        self.irohEndpointID = irohEndpointID
        self.irohPath = irohPath
        self.irohActivePeerCount = irohActivePeerCount
        self.irohLastTransitionAt = irohLastTransitionAt
        self.irohLastError = irohLastError
    }
}

public struct RemoteWorkspaceSummary: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let name: String
    public let repositoryRootSummary: String?
    public let isOpen: Bool
    public let activeSessionIDs: [UUID]
    public let lastActivityAt: Date?

    public init(
        workspaceID: String,
        name: String,
        repositoryRootSummary: String? = nil,
        isOpen: Bool,
        activeSessionIDs: [UUID] = [],
        lastActivityAt: Date? = nil
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.repositoryRootSummary = repositoryRootSummary
        self.isOpen = isOpen
        self.activeSessionIDs = activeSessionIDs
        self.lastActivityAt = lastActivityAt
    }
}

public struct RemoteReasoningEffortDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct RemoteModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let isAvailable: Bool
    public let reasoningEfforts: [RemoteReasoningEffortDescriptor]
    public let defaultReasoningEffortID: String?

    public init(
        id: String,
        displayName: String,
        isAvailable: Bool = true,
        reasoningEfforts: [RemoteReasoningEffortDescriptor] = [],
        defaultReasoningEffortID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffortID = defaultReasoningEffortID
    }
}

public struct RemoteToolSettingDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let category: String
    public let isEnabled: Bool
    public let isMutable: Bool
    public let isRequired: Bool

    public init(id: String, displayName: String, category: String, isEnabled: Bool, isMutable: Bool = true, isRequired: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.isEnabled = isEnabled
        self.isMutable = isMutable
        self.isRequired = isRequired
    }
}

public struct RemoteToolCatalog: Codable, Sendable, Equatable {
    public let providerID: String
    public let revision: Int
    public let settings: [RemoteToolSettingDescriptor]
    public let isMutable: Bool
    public let unavailableReason: String?

    public init(providerID: String, revision: Int, settings: [RemoteToolSettingDescriptor], isMutable: Bool, unavailableReason: String? = nil) {
        self.providerID = providerID
        self.revision = revision
        self.settings = settings
        self.isMutable = isMutable
        self.unavailableReason = unavailableReason
    }
}

public struct RemoteToolMutation: Codable, Sendable, Equatable {
    public let settingID: String
    public let enabled: Bool
    public let expectedRevision: Int

    public init(settingID: String, enabled: Bool, expectedRevision: Int) {
        self.settingID = settingID
        self.enabled = enabled
        self.expectedRevision = expectedRevision
    }
}

public struct RemoteCatalogMetadata: Codable, Sendable, Equatable {
    public let defaultAgentID: String?
    public let defaultSelection: RemoteAgentSelection?
    public let toolCatalog: RemoteToolCatalog?
    public let supportsStartSelection: Bool
    public let supportsSessionConfiguration: Bool
    public let supportsAttachments: Bool?
    public let supportsWorkspaceVoice: Bool?

    public init(
        defaultAgentID: String? = nil,
        defaultSelection: RemoteAgentSelection? = nil,
        toolCatalog: RemoteToolCatalog? = nil,
        supportsStartSelection: Bool = false,
        supportsSessionConfiguration: Bool = false,
        supportsAttachments: Bool? = nil,
        supportsWorkspaceVoice: Bool? = nil
    ) {
        self.defaultAgentID = defaultAgentID
        self.defaultSelection = defaultSelection
        self.toolCatalog = toolCatalog
        self.supportsStartSelection = supportsStartSelection
        self.supportsSessionConfiguration = supportsSessionConfiguration
        self.supportsAttachments = supportsAttachments
        self.supportsWorkspaceVoice = supportsWorkspaceVoice
    }
}

public struct RemoteSelectionControl: Codable, Sendable, Equatable {
    public let isMutable: Bool
    public let allowedValueIDs: [String]
    public let unavailableReason: String?

    public init(
        isMutable: Bool,
        allowedValueIDs: [String] = [],
        unavailableReason: String? = nil
    ) {
        self.isMutable = isMutable
        self.allowedValueIDs = allowedValueIDs
        self.unavailableReason = unavailableReason
    }
}

public struct RemoteSessionConfigurationControls: Codable, Sendable, Equatable {
    public let agent: RemoteSelectionControl
    public let model: RemoteSelectionControl
    public let reasoningEffort: RemoteSelectionControl

    public init(
        agent: RemoteSelectionControl,
        model: RemoteSelectionControl,
        reasoningEffort: RemoteSelectionControl
    ) {
        self.agent = agent
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct RemoteAgentSelection: Codable, Sendable, Equatable {
    public let agentID: String
    public let modelID: String
    public let reasoningEffort: String?

    public init(agentID: String, modelID: String, reasoningEffort: String? = nil) {
        self.agentID = agentID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }
}

public struct RemoteSessionSummary: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let workspaceID: String
    public let composeTabID: UUID?
    public let parentSessionID: UUID?
    public let sessionName: String?
    public let workflow: String?
    public let workflowID: String?
    public let runStartedAt: Date?
    public let transcriptRevision: UInt64?
    public let agent: String?
    public let model: String?
    public let reasoningEffort: String?
    public let configurationControls: RemoteSessionConfigurationControls?
    public let runState: RemoteRunState
    public let lifecycleStage: String?
    public let latestMeaningfulActivity: String?
    public let pendingInteraction: RemoteInteractionSummary?
    public let childSessionIDs: [UUID]
    public let worktreeSummary: String?
    public let mergeAttention: String?
    public let failureSummary: String?
    public let lastUpdatedAt: Date
    public let isLive: Bool

    public init(
        sessionID: UUID,
        workspaceID: String,
        composeTabID: UUID? = nil,
        parentSessionID: UUID? = nil,
        sessionName: String? = nil,
        workflow: String? = nil,
        workflowID: String? = nil,
        runStartedAt: Date? = nil,
        transcriptRevision: UInt64? = nil,
        agent: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        configurationControls: RemoteSessionConfigurationControls? = nil,
        runState: RemoteRunState,
        lifecycleStage: String? = nil,
        latestMeaningfulActivity: String? = nil,
        pendingInteraction: RemoteInteractionSummary? = nil,
        childSessionIDs: [UUID] = [],
        worktreeSummary: String? = nil,
        mergeAttention: String? = nil,
        failureSummary: String? = nil,
        lastUpdatedAt: Date = Date(),
        isLive: Bool
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.parentSessionID = parentSessionID
        self.sessionName = sessionName
        self.workflow = workflow
        self.workflowID = workflowID
        self.runStartedAt = runStartedAt
        self.transcriptRevision = transcriptRevision
        self.agent = agent
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.configurationControls = configurationControls
        self.runState = runState
        self.lifecycleStage = lifecycleStage
        self.latestMeaningfulActivity = latestMeaningfulActivity
        self.pendingInteraction = pendingInteraction
        self.childSessionIDs = childSessionIDs
        self.worktreeSummary = worktreeSummary
        self.mergeAttention = mergeAttention
        self.failureSummary = failureSummary
        self.lastUpdatedAt = lastUpdatedAt
        self.isLive = isLive
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case workspaceID
        case composeTabID
        case parentSessionID
        case sessionName
        case workflow
        case workflowID
        case runStartedAt
        case transcriptRevision
        case agent
        case model
        case reasoningEffort
        case configurationControls
        case runState
        case lifecycleStage
        case latestMeaningfulActivity
        case pendingInteraction
        case childSessionIDs
        case worktreeSummary
        case mergeAttention
        case failureSummary
        case lastUpdatedAt
        case isLive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            workspaceID: try container.decode(String.self, forKey: .workspaceID),
            composeTabID: try container.decodeIfPresent(UUID.self, forKey: .composeTabID),
            parentSessionID: try container.decodeIfPresent(UUID.self, forKey: .parentSessionID),
            sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName),
            workflow: try container.decodeIfPresent(String.self, forKey: .workflow),
            workflowID: try container.decodeIfPresent(String.self, forKey: .workflowID),
            runStartedAt: try container.decodeIfPresent(Date.self, forKey: .runStartedAt),
            transcriptRevision: try container.decodeIfPresent(UInt64.self, forKey: .transcriptRevision),
            agent: try container.decodeIfPresent(String.self, forKey: .agent),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
            configurationControls: try container.decodeIfPresent(RemoteSessionConfigurationControls.self, forKey: .configurationControls),
            runState: try container.decode(RemoteRunState.self, forKey: .runState),
            lifecycleStage: try container.decodeIfPresent(String.self, forKey: .lifecycleStage),
            latestMeaningfulActivity: try container.decodeIfPresent(String.self, forKey: .latestMeaningfulActivity),
            pendingInteraction: try container.decodeIfPresent(RemoteInteractionSummary.self, forKey: .pendingInteraction),
            childSessionIDs: try container.decode([UUID].self, forKey: .childSessionIDs),
            worktreeSummary: try container.decodeIfPresent(String.self, forKey: .worktreeSummary),
            mergeAttention: try container.decodeIfPresent(String.self, forKey: .mergeAttention),
            failureSummary: try container.decodeIfPresent(String.self, forKey: .failureSummary),
            lastUpdatedAt: try container.decode(Date.self, forKey: .lastUpdatedAt),
            isLive: try container.decode(Bool.self, forKey: .isLive)
        )
    }
}

public struct RemoteAttentionItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: RemoteAttentionKind
    public let sessionID: UUID
    public let title: String
    public let sanitizedPreview: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: RemoteAttentionKind,
        sessionID: UUID,
        title: String,
        sanitizedPreview: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.sanitizedPreview = sanitizedPreview
        self.createdAt = createdAt
    }
}

public struct RemoteWorkflowDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isBuiltIn: Bool
    public let requiredAuthority: RemoteAuthorityLevel
    public let iconName: String?
    public let accentColorHex: String?
    public let descriptionText: String?
    public let featuredRank: Int?

    public init(
        id: String,
        displayName: String,
        isBuiltIn: Bool,
        requiredAuthority: RemoteAuthorityLevel = .control,
        iconName: String? = nil,
        accentColorHex: String? = nil,
        descriptionText: String? = nil,
        featuredRank: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isBuiltIn = isBuiltIn
        self.requiredAuthority = requiredAuthority
        self.iconName = iconName
        self.accentColorHex = accentColorHex
        self.descriptionText = descriptionText
        self.featuredRank = featuredRank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case isBuiltIn
        case requiredAuthority
        case iconName
        case accentColorHex
        case descriptionText
        case featuredRank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            isBuiltIn: try container.decode(Bool.self, forKey: .isBuiltIn),
            requiredAuthority: try container.decode(RemoteAuthorityLevel.self, forKey: .requiredAuthority),
            iconName: try container.decodeIfPresent(String.self, forKey: .iconName),
            accentColorHex: try container.decodeIfPresent(String.self, forKey: .accentColorHex),
            descriptionText: try container.decodeIfPresent(String.self, forKey: .descriptionText),
            featuredRank: try container.decodeIfPresent(Int.self, forKey: .featuredRank)
        )
    }
}

public struct RemoteAgentDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// Legacy raw model identifiers retained for protocol-v1 clients.
    public let models: [String]
    public let isAvailable: Bool
    /// Typed, display-ready model metadata. Absent when connected to an older Mac.
    public let modelDescriptors: [RemoteModelDescriptor]?
    public let defaultModelID: String?

    public init(
        id: String,
        displayName: String,
        models: [String] = [],
        isAvailable: Bool,
        modelDescriptors: [RemoteModelDescriptor]? = nil,
        defaultModelID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.isAvailable = isAvailable
        self.modelDescriptors = modelDescriptors
        self.defaultModelID = defaultModelID
    }
}

public struct RemoteCatalogPayload: Codable, Sendable, Equatable {
    public let workflows: [RemoteWorkflowDescriptor]
    public let agents: [RemoteAgentDescriptor]
    public let metadata: RemoteCatalogMetadata?

    public init(
        workflows: [RemoteWorkflowDescriptor] = [],
        agents: [RemoteAgentDescriptor] = [],
        metadata: RemoteCatalogMetadata? = nil
    ) {
        self.workflows = workflows
        self.agents = agents
        self.metadata = metadata
    }
}

public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktop: RemoteDesktopSummary
    public let connection: RemoteConnectionSummary
    public let authorization: RemoteAuthorizationState
    public let workspaces: [RemoteWorkspaceSummary]
    public let sessions: [RemoteSessionSummary]
    public let attentionItems: [RemoteAttentionItem]
    public let workflowCatalog: [RemoteWorkflowDescriptor]
    public let agentCatalog: [RemoteAgentDescriptor]
    public let agentCatalogMetadata: RemoteCatalogMetadata?
    public let eventCursor: UInt64
    /// Identifies the process-lifetime epoch in which transcript revisions are
    /// monotonic. Absent when connected to an older CE build.
    public let transcriptRevisionEpoch: UUID?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary,
        authorization: RemoteAuthorizationState,
        workspaces: [RemoteWorkspaceSummary] = [],
        sessions: [RemoteSessionSummary] = [],
        attentionItems: [RemoteAttentionItem] = [],
        workflowCatalog: [RemoteWorkflowDescriptor] = [],
        agentCatalog: [RemoteAgentDescriptor] = [],
        agentCatalogMetadata: RemoteCatalogMetadata? = nil,
        eventCursor: UInt64 = 0,
        transcriptRevisionEpoch: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.desktop = desktop
        self.connection = connection
        self.authorization = authorization
        self.workspaces = workspaces
        self.sessions = sessions
        self.attentionItems = attentionItems
        self.workflowCatalog = workflowCatalog
        self.agentCatalog = agentCatalog
        self.agentCatalogMetadata = agentCatalogMetadata
        self.eventCursor = eventCursor
        self.transcriptRevisionEpoch = transcriptRevisionEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case desktop
        case connection
        case authorization
        case workspaces
        case sessions
        case attentionItems
        case workflowCatalog
        case agentCatalog
        case agentCatalogMetadata
        case eventCursor
        case transcriptRevisionEpoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            desktop: try container.decode(RemoteDesktopSummary.self, forKey: .desktop),
            connection: try container.decode(RemoteConnectionSummary.self, forKey: .connection),
            authorization: try container.decode(RemoteAuthorizationState.self, forKey: .authorization),
            workspaces: try container.decode([RemoteWorkspaceSummary].self, forKey: .workspaces),
            sessions: try container.decode([RemoteSessionSummary].self, forKey: .sessions),
            attentionItems: try container.decode([RemoteAttentionItem].self, forKey: .attentionItems),
            workflowCatalog: try container.decode([RemoteWorkflowDescriptor].self, forKey: .workflowCatalog),
            agentCatalog: try container.decode([RemoteAgentDescriptor].self, forKey: .agentCatalog),
            agentCatalogMetadata: try container.decodeIfPresent(RemoteCatalogMetadata.self, forKey: .agentCatalogMetadata),
            eventCursor: try container.decode(UInt64.self, forKey: .eventCursor),
            transcriptRevisionEpoch: try container.decodeIfPresent(UUID.self, forKey: .transcriptRevisionEpoch)
        )
    }
}

public enum RemoteTranscriptItemKind: String, Codable, Sendable {
    case request
    case activity
    case conclusion
    case summary
}

/// Additive semantic classification for narrative-first transcript presentation.
/// `RemoteTranscriptItemKind` remains unchanged for protocol v1 clients.
public enum RemoteTranscriptSemanticKind: String, Codable, Sendable {
    case userRequest = "user_request"
    case assistantPreamble = "assistant_preamble"
    case assistantAnswer = "assistant_answer"
    case compactActivity = "compact_activity"
    case error
    case permission
    case question
    case approval
    case summary
}

/// A sanitized transcript row. Tool arguments/results and reasoning are not
/// included in the default projection; a later explicit detail request can
/// add those fields without changing the fleet snapshot contract.
public struct RemoteTranscriptItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let turnID: UUID
    public let timestamp: Date
    public let sequenceIndex: Int
    public let kind: RemoteTranscriptItemKind
    public let semanticKind: RemoteTranscriptSemanticKind?
    public let role: String
    public let text: String?
    public let toolName: String?
    public let toolStatus: String?
    public let summaryOnly: Bool
    public let detailAvailable: Bool
    public let detailText: String?
    public let detail: RemoteTranscriptDetail?
    public let attachments: [RemoteTranscriptAttachment]?
    public let diffSummary: RemoteTranscriptDiffSummary?

    public init(
        id: UUID,
        turnID: UUID,
        timestamp: Date,
        sequenceIndex: Int,
        kind: RemoteTranscriptItemKind,
        semanticKind: RemoteTranscriptSemanticKind? = nil,
        role: String,
        text: String? = nil,
        toolName: String? = nil,
        toolStatus: String? = nil,
        summaryOnly: Bool = false,
        detailAvailable: Bool = false,
        detailText: String? = nil,
        detail: RemoteTranscriptDetail? = nil,
        attachments: [RemoteTranscriptAttachment]? = nil,
        diffSummary: RemoteTranscriptDiffSummary? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.timestamp = timestamp
        self.sequenceIndex = sequenceIndex
        self.kind = kind
        self.semanticKind = semanticKind
        self.role = role
        self.text = text
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.summaryOnly = summaryOnly
        self.detailAvailable = detailAvailable
        self.detailText = detailText
        self.detail = detail
        self.attachments = attachments
        self.diffSummary = diffSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID
        case timestamp
        case sequenceIndex
        case kind
        case semanticKind
        case role
        case text
        case toolName
        case toolStatus
        case summaryOnly
        case detailAvailable
        case detailText
        case detail
        case attachments
        case diffSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            turnID: container.decode(UUID.self, forKey: .turnID),
            timestamp: container.decode(Date.self, forKey: .timestamp),
            sequenceIndex: container.decode(Int.self, forKey: .sequenceIndex),
            kind: container.decode(RemoteTranscriptItemKind.self, forKey: .kind),
            semanticKind: container.decodeIfPresent(RemoteTranscriptSemanticKind.self, forKey: .semanticKind),
            role: container.decode(String.self, forKey: .role),
            text: container.decodeIfPresent(String.self, forKey: .text),
            toolName: container.decodeIfPresent(String.self, forKey: .toolName),
            toolStatus: container.decodeIfPresent(String.self, forKey: .toolStatus),
            summaryOnly: container.decode(Bool.self, forKey: .summaryOnly),
            detailAvailable: container.decode(Bool.self, forKey: .detailAvailable),
            detailText: container.decodeIfPresent(String.self, forKey: .detailText),
            detail: container.decodeIfPresent(RemoteTranscriptDetail.self, forKey: .detail),
            attachments: container.decodeIfPresent([RemoteTranscriptAttachment].self, forKey: .attachments),
            diffSummary: container.decodeIfPresent(RemoteTranscriptDiffSummary.self, forKey: .diffSummary)
        )
    }
}

public struct RemoteRecordedQuestionExchange: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case answered
        case skipped
        case timedOut = "timed_out"
    }

    public struct Question: Codable, Sendable, Equatable {
        public let header: String?
        public let prompt: String
        public let answer: String?
        public let skipped: Bool

        public init(header: String? = nil, prompt: String, answer: String? = nil, skipped: Bool = false) {
            self.header = header
            self.prompt = prompt
            self.answer = answer
            self.skipped = skipped
        }
    }

    public let title: String?
    public let questions: [Question]
    public let outcome: Outcome

    public init(title: String? = nil, questions: [Question], outcome: Outcome) {
        self.title = title
        self.questions = questions
        self.outcome = outcome
    }
}

public struct RemoteTranscriptDiffSummary: Codable, Sendable, Equatable {
    public let fileCount: Int
    public let singleFilePath: String?
    public let additions: Int?
    public let deletions: Int?
    public let isTruncated: Bool

    public init(
        fileCount: Int,
        singleFilePath: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        isTruncated: Bool = false
    ) {
        self.fileCount = fileCount
        self.singleFilePath = singleFilePath
        self.additions = additions
        self.deletions = deletions
        self.isTruncated = isTruncated
    }
}

public struct RemoteTranscriptDiffPreview: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let additions: Int?
        public let deletions: Int?
        public let patch: String?

        public init(path: String, additions: Int? = nil, deletions: Int? = nil, patch: String? = nil) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
            self.patch = patch
        }
    }

    public let files: [File]
    public let isTruncated: Bool

    public init(files: [File], isTruncated: Bool = false) {
        self.files = files
        self.isTruncated = isTruncated
    }
}

public struct RemoteTranscriptDetail: Codable, Sendable, Equatable {
    public let argumentsJSON: String?
    public let resultJSON: String?
    public let reasoning: String?
    public let keyPaths: [String]
    public let processID: String?
    public let exitCode: Int?
    public let summaryText: String?
    public let toolIsError: Bool?
    public let questionExchange: RemoteRecordedQuestionExchange?
    public let diffPreview: RemoteTranscriptDiffPreview?

    public init(
        argumentsJSON: String? = nil,
        resultJSON: String? = nil,
        reasoning: String? = nil,
        keyPaths: [String] = [],
        processID: String? = nil,
        exitCode: Int? = nil,
        summaryText: String? = nil,
        toolIsError: Bool? = nil,
        questionExchange: RemoteRecordedQuestionExchange? = nil,
        diffPreview: RemoteTranscriptDiffPreview? = nil
    ) {
        self.argumentsJSON = argumentsJSON
        self.resultJSON = resultJSON
        self.reasoning = reasoning
        self.keyPaths = keyPaths
        self.processID = processID
        self.exitCode = exitCode
        self.summaryText = summaryText
        self.toolIsError = toolIsError
        self.questionExchange = questionExchange
        self.diffPreview = diffPreview
    }
}

/// Stable total-order position used by opt-in recent-first transcript paging.
public struct RemoteTranscriptCursor: Codable, Sendable, Equatable, Hashable, Comparable {
    public let sequenceIndex: Int
    public let timestamp: Date
    public let itemID: UUID

    public init(sequenceIndex: Int, timestamp: Date, itemID: UUID) {
        self.sequenceIndex = sequenceIndex
        self.timestamp = timestamp
        self.itemID = itemID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }
}

public enum RemoteTranscriptPagingMode: String, Codable, Sendable {
    case legacyForward = "legacy_forward"
    case recentBackward = "recent_backward"
}

public struct RemoteChatConfiguration: Codable, Sendable, Equatable {
    public let selection: RemoteAgentSelection
    public let controls: RemoteSessionConfigurationControls?

    public init(selection: RemoteAgentSelection, controls: RemoteSessionConfigurationControls? = nil) {
        self.selection = selection
        self.controls = controls
    }
}

public struct RemoteTranscriptPage: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let items: [RemoteTranscriptItem]
    public let nextSequenceIndex: Int?
    public let hasMore: Bool
    public let eventCursor: UInt64
    public let pagingMode: RemoteTranscriptPagingMode?
    public let olderCursor: RemoteTranscriptCursor?
    public let hasOlder: Bool?
    public let transcriptRevision: UInt64?
    /// Matches the snapshot epoch for `transcriptRevision`. Absent on legacy CE.
    public let transcriptRevisionEpoch: UUID?
    public let chatConfiguration: RemoteChatConfiguration?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        sessionID: UUID,
        items: [RemoteTranscriptItem],
        nextSequenceIndex: Int? = nil,
        hasMore: Bool = false,
        eventCursor: UInt64 = 0,
        pagingMode: RemoteTranscriptPagingMode? = nil,
        olderCursor: RemoteTranscriptCursor? = nil,
        hasOlder: Bool? = nil,
        transcriptRevision: UInt64? = nil,
        transcriptRevisionEpoch: UUID? = nil,
        chatConfiguration: RemoteChatConfiguration? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.items = items
        self.nextSequenceIndex = nextSequenceIndex
        self.hasMore = hasMore
        self.eventCursor = eventCursor
        self.pagingMode = pagingMode
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
        self.transcriptRevision = transcriptRevision
        self.transcriptRevisionEpoch = transcriptRevisionEpoch
        self.chatConfiguration = chatConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case sessionID
        case items
        case nextSequenceIndex
        case hasMore
        case eventCursor
        case pagingMode
        case olderCursor
        case hasOlder
        case transcriptRevision
        case transcriptRevisionEpoch
        case chatConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            items: try container.decode([RemoteTranscriptItem].self, forKey: .items),
            nextSequenceIndex: try container.decodeIfPresent(Int.self, forKey: .nextSequenceIndex),
            hasMore: try container.decode(Bool.self, forKey: .hasMore),
            eventCursor: try container.decode(UInt64.self, forKey: .eventCursor),
            pagingMode: try container.decodeIfPresent(RemoteTranscriptPagingMode.self, forKey: .pagingMode),
            olderCursor: try container.decodeIfPresent(RemoteTranscriptCursor.self, forKey: .olderCursor),
            hasOlder: try container.decodeIfPresent(Bool.self, forKey: .hasOlder),
            transcriptRevision: try container.decodeIfPresent(UInt64.self, forKey: .transcriptRevision),
            transcriptRevisionEpoch: try container.decodeIfPresent(UUID.self, forKey: .transcriptRevisionEpoch),
            chatConfiguration: try container.decodeIfPresent(RemoteChatConfiguration.self, forKey: .chatConfiguration)
        )
    }
}

public struct RemoteHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspaceID: String
    public let sessionName: String
    public let lastActivityAt: Date
    public let preview: String?
    public let turnCount: Int
    public let runState: RemoteRunState

    public init(
        id: UUID,
        workspaceID: String,
        sessionName: String,
        lastActivityAt: Date,
        preview: String? = nil,
        turnCount: Int = 0,
        runState: RemoteRunState = .idle
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionName = sessionName
        self.lastActivityAt = lastActivityAt
        self.preview = preview
        self.turnCount = turnCount
        self.runState = runState
    }
}

/// Stable position in workspace history, ordered by activity time with a UUID tie-breaker.
public struct RemoteHistoryCursor: Codable, Sendable, Equatable, Comparable {
    public let lastActivityAt: Date
    public let sessionID: UUID

    public init(lastActivityAt: Date, sessionID: UUID) {
        self.lastActivityAt = lastActivityAt
        self.sessionID = sessionID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt < rhs.lastActivityAt }
        return lhs.sessionID.uuidString < rhs.sessionID.uuidString
    }
}

public struct RemoteHistoryPage: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let entries: [RemoteHistoryEntry]
    public let hasMore: Bool
    /// Echoed by a desktop that applied the requested workspace scope.
    public let workspaceID: UUID?
    public let olderCursor: RemoteHistoryCursor?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        entries: [RemoteHistoryEntry],
        hasMore: Bool = false,
        workspaceID: UUID? = nil,
        olderCursor: RemoteHistoryCursor? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.entries = entries
        self.hasMore = hasMore
        self.workspaceID = workspaceID
        self.olderCursor = olderCursor
    }
}

public enum RemoteCommandOperation: String, Codable, Sendable {
    case startRun = "start_run"
    case configureSession = "configure_session"
    case configureTools = "configure_tools"
    case followUp = "follow_up"
    case steer
    case uploadAttachment = "upload_attachment"
    case respond
    case cancel
    case resume
    case contextBuilder = "context_builder"
    case registerNotifications = "register_notifications"
}

public enum RemoteNotificationPlatform: String, Codable, Sendable {
    case apns
    case fcm
}

public struct RemoteNotificationRegistration: Codable, Sendable, Equatable {
    public let platform: RemoteNotificationPlatform
    public let deviceToken: String
    public let relayURL: String?

    public init(platform: RemoteNotificationPlatform, deviceToken: String, relayURL: String? = nil) {
        self.platform = platform
        self.deviceToken = deviceToken
        self.relayURL = relayURL
    }
}

public enum RemoteNotificationCategory: String, Codable, Sendable {
    case agentNeedsInput = "agent_needs_input"
    case approvalRequired = "approval_required"
    case completed
    case failed
}

public struct RemoteNotificationPayload: Codable, Sendable, Equatable {
    public let category: RemoteNotificationCategory
    public let desktopInstanceID: String
    public let sessionID: UUID?
    public let createdAt: Date
    public let title: String
    public let body: String

    public init(
        category: RemoteNotificationCategory,
        desktopInstanceID: String,
        sessionID: UUID? = nil,
        createdAt: Date = Date(),
        title: String,
        body: String
    ) {
        self.category = category
        self.desktopInstanceID = desktopInstanceID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.title = title
        self.body = body
    }
}

public struct RemoteNotificationEnvelope: Codable, Sendable, Equatable {
    public let version: Int
    public let envelopeID: UUID
    public let desktopInstanceID: String
    public let deviceID: String
    public let category: RemoteNotificationCategory
    public let sessionID: UUID?
    public let createdAt: Date
    public let nonce: String
    public let ciphertext: String
    public let authenticationTag: String

    public init(
        version: Int = 1,
        envelopeID: UUID = UUID(),
        desktopInstanceID: String,
        deviceID: String,
        category: RemoteNotificationCategory,
        sessionID: UUID? = nil,
        createdAt: Date = Date(),
        nonce: String,
        ciphertext: String,
        authenticationTag: String
    ) {
        self.version = version
        self.envelopeID = envelopeID
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.category = category
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct RemoteContextBuilderResult: Codable, Sendable, Equatable {
    public let tabID: String
    public let status: String
    public let prompt: String
    public let fileCount: Int
    public let totalTokens: Int
    public let responseType: String?
    public let plan: String?
    public let review: String?
    public let followUpHint: String?

    public init(
        tabID: String,
        status: String,
        prompt: String,
        fileCount: Int,
        totalTokens: Int,
        responseType: String? = nil,
        plan: String? = nil,
        review: String? = nil,
        followUpHint: String? = nil
    ) {
        self.tabID = tabID
        self.status = status
        self.prompt = prompt
        self.fileCount = fileCount
        self.totalTokens = totalTokens
        self.responseType = responseType
        self.plan = plan
        self.review = review
        self.followUpHint = followUpHint
    }
}

/// A desktop command. `secret` is intentionally accepted only as a transient
/// request field; it is never copied into a response, snapshot, event, or
/// persisted credential.
public enum RemoteAttachmentLimits {
    public static let maxCount = 10
    public static let maxFileBytes = 20 * 1024 * 1024
    public static let maxTotalBytes = 50 * 1024 * 1024
    // Iroh wraps the command in two additional JSON envelopes. Leave room for
    // each base64 expansion and JSON escaping, including slash-heavy input.
    public static let maxChunkBytes = 192 * 1024
}

public struct RemoteAttachmentChunk: Codable, Sendable, Equatable {
    public let submissionID: UUID
    public let attachmentID: UUID
    public let fileName: String
    public let fileSize: Int
    public let offset: Int
    public let bytes: Data

    public init(submissionID: UUID, attachmentID: UUID, fileName: String, fileSize: Int, offset: Int, bytes: Data) {
        self.submissionID = submissionID
        self.attachmentID = attachmentID
        self.fileName = fileName
        self.fileSize = fileSize
        self.offset = offset
        self.bytes = bytes
    }
}

public struct RemoteTranscriptAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let isImage: Bool
    public init(id: UUID, name: String, isImage: Bool) {
        self.id = id
        self.name = name
        self.isImage = isImage
    }
}

public struct RemoteCommandRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let commandID: UUID
    public let operation: RemoteCommandOperation
    public let workspaceID: String?
    public let sessionID: UUID?
    public let interactionID: UUID?
    public let message: String?
    public let decision: String?
    public let answers: [String: [String]]
    public let secret: String?
    public let questionAnswers: [String: RemoteQuestionAnswer]?
    public let agentID: String?
    public let modelID: String?
    public let reasoningEffort: String?
    public let workflowID: String?
    public let interviewFirst: Bool?
    public let contextBuilderResponseType: String?
    public let contextBuilderExportResponse: Bool?
    public let notificationRegistration: RemoteNotificationRegistration?
    public let toolMutation: RemoteToolMutation?
    public let attachmentIDs: [UUID]?
    public let attachmentChunk: RemoteAttachmentChunk?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        commandID: UUID = UUID(),
        operation: RemoteCommandOperation,
        workspaceID: String? = nil,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        message: String? = nil,
        decision: String? = nil,
        answers: [String: [String]] = [:],
        secret: String? = nil,
        questionAnswers: [String: RemoteQuestionAnswer]? = nil,
        agentID: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        workflowID: String? = nil,
        interviewFirst: Bool? = nil,
        contextBuilderResponseType: String? = nil,
        contextBuilderExportResponse: Bool? = nil,
        notificationRegistration: RemoteNotificationRegistration? = nil,
        toolMutation: RemoteToolMutation? = nil,
        attachmentIDs: [UUID]? = nil,
        attachmentChunk: RemoteAttachmentChunk? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.commandID = commandID
        self.operation = operation
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.message = message
        self.decision = decision
        self.answers = answers
        self.secret = secret
        self.questionAnswers = questionAnswers
        self.agentID = agentID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.workflowID = workflowID
        self.interviewFirst = interviewFirst
        self.contextBuilderResponseType = contextBuilderResponseType
        self.contextBuilderExportResponse = contextBuilderExportResponse
        self.notificationRegistration = notificationRegistration
        self.toolMutation = toolMutation
        self.attachmentIDs = attachmentIDs
        self.attachmentChunk = attachmentChunk
    }
}

public struct RemoteCommandResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let commandID: UUID
    public let accepted: Bool
    public let workspaceID: String?
    public let sessionID: UUID?
    public let runState: RemoteRunState?
    public let message: String?
    public let eventCursor: UInt64?
    public let contextBuilderResult: RemoteContextBuilderResult?
    public let resolvedSelection: RemoteAgentSelection?
    public let resolvedToolCatalog: RemoteToolCatalog?

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        commandID: UUID,
        accepted: Bool,
        workspaceID: String? = nil,
        sessionID: UUID? = nil,
        runState: RemoteRunState? = nil,
        message: String? = nil,
        eventCursor: UInt64? = nil,
        contextBuilderResult: RemoteContextBuilderResult? = nil,
        resolvedSelection: RemoteAgentSelection? = nil,
        resolvedToolCatalog: RemoteToolCatalog? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.commandID = commandID
        self.accepted = accepted
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.runState = runState
        self.message = message
        self.eventCursor = eventCursor
        self.contextBuilderResult = contextBuilderResult
        self.resolvedSelection = resolvedSelection
        self.resolvedToolCatalog = resolvedToolCatalog
    }
}

public enum RemoteEventType: String, Codable, Sendable {
    case workspaceOpening = "workspace_opening"
    case workspaceReady = "workspace_ready"
    case sessionCreated = "session_created"
    case sessionUpdated = "session_updated"
    case runStarted = "run_started"
    case runProgressed = "run_progressed"
    case runWaitingForInput = "run_waiting_for_input"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runCancelled = "run_cancelled"
    case transcriptItemsAppended = "transcript_items_appended"
    case interactionCreated = "interaction_created"
    case interactionResolved = "interaction_resolved"
    case childSessionCreated = "child_session_created"
    case catalogChanged = "catalog_changed"
    case authorizationChanged = "authorization_changed"
}

public enum RemoteEventPayload: Codable, Sendable, Equatable {
    case empty
    case workspace(RemoteWorkspaceSummary)
    case session(RemoteSessionSummary)
    case attention(RemoteAttentionItem)
    case attentionRemoved(UUID)
    case authorization(RemoteAuthorizationState)
    case catalog(RemoteCatalogPayload)
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspace
        case session
        case attention
        case attentionID
        case authorization
        case catalog
        case text
    }

    private enum Kind: String, Codable {
        case empty
        case workspace
        case session
        case attention
        case attentionRemoved
        case authorization
        case catalog
        case text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode(Kind.empty, forKey: .kind)
        case let .workspace(value):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(value, forKey: .workspace)
        case let .session(value):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(value, forKey: .session)
        case let .attention(value):
            try container.encode(Kind.attention, forKey: .kind)
            try container.encode(value, forKey: .attention)
        case let .attentionRemoved(id):
            try container.encode(Kind.attentionRemoved, forKey: .kind)
            try container.encode(id, forKey: .attentionID)
        case let .authorization(value):
            try container.encode(Kind.authorization, forKey: .kind)
            try container.encode(value, forKey: .authorization)
        case let .catalog(value):
            try container.encode(Kind.catalog, forKey: .kind)
            try container.encode(value, forKey: .catalog)
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .empty:
            self = .empty
        case .workspace:
            self = .workspace(try container.decode(RemoteWorkspaceSummary.self, forKey: .workspace))
        case .session:
            self = .session(try container.decode(RemoteSessionSummary.self, forKey: .session))
        case .attention:
            self = .attention(try container.decode(RemoteAttentionItem.self, forKey: .attention))
        case .attentionRemoved:
            self = .attentionRemoved(try container.decode(UUID.self, forKey: .attentionID))
        case .authorization:
            self = .authorization(try container.decode(RemoteAuthorizationState.self, forKey: .authorization))
        case .catalog:
            self = .catalog(try container.decode(RemoteCatalogPayload.self, forKey: .catalog))
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }
}

public struct RemoteEvent: Codable, Sendable, Equatable {
    public let desktopInstanceID: String
    public let sequence: UInt64
    public let eventID: UUID
    public let timestamp: Date
    public let type: RemoteEventType
    public let payloadVersion: Int
    public let workspaceID: String?
    public let sessionID: UUID?
    public let payload: RemoteEventPayload

    public init(
        desktopInstanceID: String,
        sequence: UInt64 = 0,
        eventID: UUID = UUID(),
        timestamp: Date = Date(),
        type: RemoteEventType,
        payloadVersion: Int = 1,
        workspaceID: String? = nil,
        sessionID: UUID? = nil,
        payload: RemoteEventPayload = .empty
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.sequence = sequence
        self.eventID = eventID
        self.timestamp = timestamp
        self.type = type
        self.payloadVersion = payloadVersion
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.payload = payload
    }

    public func assigning(sequence: UInt64) -> Self {
        Self(
            desktopInstanceID: desktopInstanceID,
            sequence: sequence,
            eventID: eventID,
            timestamp: timestamp,
            type: type,
            payloadVersion: payloadVersion,
            workspaceID: workspaceID,
            sessionID: sessionID,
            payload: payload
        )
    }
}
