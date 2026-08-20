import Foundation

public enum ComposerControlValueWire: Codable, Hashable, Sendable {
    case boolean(Bool)
    case choice(String)
    case choices([String])

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case boolean, choice, choices }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .boolean: self = try .boolean(values.decode(Bool.self, forKey: .value))
        case .choice: self = try .choice(values.decode(String.self, forKey: .value))
        case .choices: self = try .choices(values.decode([String].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value): try values.encode(Kind.boolean, forKey: .type)
            try values.encode(value, forKey: .value)
        case let .choice(value): try values.encode(Kind.choice, forKey: .type)
            try values.encode(value, forKey: .value)
        case let .choices(value): try values.encode(Kind.choices, forKey: .type)
            try values.encode(value, forKey: .value)
        }
    }
}

public struct ComposerContextWire: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case project, session }
    public let kind: Kind
    public let projectID: UUID
    public let sessionID: UUID?

    public init(kind: Kind, projectID: UUID, sessionID: UUID? = nil) {
        self.kind = kind
        self.projectID = projectID
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey { case kind
        case projectID = "projectId"
        case sessionID = "sessionId"
    }
}

public struct ComposerModelCapabilitiesWire: Codable, Hashable, Sendable {
    public let nativeImages: Bool
    public let steering: Bool

    public init(nativeImages: Bool = false, steering: Bool = false) {
        self.nativeImages = nativeImages
        self.steering = steering
    }
}

public struct ComposerModelOptionWire: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let enabled: Bool
    public let supportedEffortIDs: [String]
    public let defaultEffortID: String?
    public let capabilities: ComposerModelCapabilitiesWire

    public init(id: String, displayName: String, description: String? = nil, enabled: Bool = true, supportedEffortIDs: [String] = [], defaultEffortID: String? = nil, capabilities: ComposerModelCapabilitiesWire = .init()) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.enabled = enabled
        self.supportedEffortIDs = supportedEffortIDs
        self.defaultEffortID = defaultEffortID
        self.capabilities = capabilities
    }
}

public struct ComposerControlChoiceWire: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detailText: String?
    public let enabled: Bool
    public let warning: Bool

    public init(id: String, displayName: String, detailText: String? = nil, enabled: Bool = true, warning: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.detailText = detailText
        self.enabled = enabled
        self.warning = warning
    }
}

public struct ComposerControlCommonWire: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detailText: String?
    public let required: Bool
    public let mutable: Bool
    public let warning: Bool
    public let lockReasonCode: String?

    public init(id: String, displayName: String, detailText: String? = nil, required: Bool = false, mutable: Bool = true, warning: Bool = false, lockReasonCode: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.detailText = detailText
        self.required = required
        self.mutable = mutable
        self.warning = warning
        self.lockReasonCode = lockReasonCode
    }
}

public enum ComposerControlWire: Codable, Hashable, Sendable {
    case toggle(common: ComposerControlCommonWire, value: Bool)
    case singleChoice(common: ComposerControlCommonWire, selectedID: String, choices: [ComposerControlChoiceWire])
    case multiChoice(common: ComposerControlCommonWire, selectedIDs: [String], choices: [ComposerControlChoiceWire])

    private enum CodingKeys: String, CodingKey { case type, common, value, selectedID, selectedIDs, choices }
    private enum Kind: String, Codable { case toggle, singleChoice, multiChoice }

    public var common: ComposerControlCommonWire {
        switch self {
        case let .toggle(common, _), let .singleChoice(common, _, _), let .multiChoice(common, _, _): common
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .toggle:
            self = try .toggle(common: values.decode(ComposerControlCommonWire.self, forKey: .common), value: values.decode(Bool.self, forKey: .value))
        case .singleChoice:
            self = try .singleChoice(common: values.decode(ComposerControlCommonWire.self, forKey: .common), selectedID: values.decode(String.self, forKey: .selectedID), choices: values.decode([ComposerControlChoiceWire].self, forKey: .choices))
        case .multiChoice:
            self = try .multiChoice(common: values.decode(ComposerControlCommonWire.self, forKey: .common), selectedIDs: values.decode([String].self, forKey: .selectedIDs), choices: values.decode([ComposerControlChoiceWire].self, forKey: .choices))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .toggle(common, value):
            try values.encode(Kind.toggle, forKey: .type)
            try values.encode(common, forKey: .common)
            try values.encode(value, forKey: .value)
        case let .singleChoice(common, selectedID, choices):
            try values.encode(Kind.singleChoice, forKey: .type)
            try values.encode(common, forKey: .common)
            try values.encode(selectedID, forKey: .selectedID)
            try values.encode(choices, forKey: .choices)
        case let .multiChoice(common, selectedIDs, choices):
            try values.encode(Kind.multiChoice, forKey: .type)
            try values.encode(common, forKey: .common)
            try values.encode(selectedIDs, forKey: .selectedIDs)
            try values.encode(choices, forKey: .choices)
        }
    }
}

public struct ComposerPermissionControlWire: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let selectedID: String
    public let choices: [ComposerControlChoiceWire]
    public let externallyManaged: Bool
    public let mutable: Bool
    public let lockReasonCode: String?

    public init(id: String, displayName: String, selectedID: String, choices: [ComposerControlChoiceWire], externallyManaged: Bool = false, mutable: Bool = true, lockReasonCode: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.selectedID = selectedID
        self.choices = choices
        self.externallyManaged = externallyManaged
        self.mutable = mutable
        self.lockReasonCode = lockReasonCode
    }
}

public struct ComposerProviderGroupWire: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let models: [ComposerModelOptionWire]
    public let toolControls: [ComposerControlWire]
    public let permissionControl: ComposerPermissionControlWire?

    public init(providerID: ProviderSettingsID, displayName: String, models: [ComposerModelOptionWire], toolControls: [ComposerControlWire] = [], permissionControl: ComposerPermissionControlWire? = nil) {
        self.providerID = providerID
        self.displayName = displayName
        self.models = models
        self.toolControls = toolControls
        self.permissionControl = permissionControl
    }

    private enum CodingKeys: String, CodingKey { case providerID = "providerId", displayName, models, toolControls, permissionControl }
}

public struct ComposerWorkflowOptionWire: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let guidance: String?
    public let providerIDs: [ProviderSettingsID]
    public let enabled: Bool
    public let visible: Bool
    public let featuredOrder: Int?

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        guidance: String? = nil,
        providerIDs: [ProviderSettingsID] = [],
        enabled: Bool = true,
        visible: Bool = true,
        featuredOrder: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.guidance = guidance
        self.providerIDs = providerIDs
        self.enabled = enabled
        self.visible = visible
        self.featuredOrder = featuredOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, description, guidance, providerIDs, enabled, visible, featuredOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        guidance = try container.decodeIfPresent(String.self, forKey: .guidance)
        providerIDs = try container.decodeIfPresent([ProviderSettingsID].self, forKey: .providerIDs) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        featuredOrder = try container.decodeIfPresent(Int.self, forKey: .featuredOrder)
    }
}

public struct ComposerSelectedUnavailableWire: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let displayName: String
    public let reasonCode: String

    public init(providerID: ProviderSettingsID, modelID: String, displayName: String = "Model unavailable", reasonCode: String = "provider_unavailable") {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.reasonCode = reasonCode
    }

    private enum CodingKeys: String, CodingKey { case providerID = "providerId", modelID = "modelId", displayName, reasonCode }
}

public struct ComposerSelectionWire: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let effortID: String?
    public let workflowID: String?
    public let permissionID: String?
    public let toolValues: [String: ComposerControlValueWire]
    public let unavailable: ComposerSelectedUnavailableWire?

    public init(providerID: ProviderSettingsID, modelID: String, effortID: String? = nil, workflowID: String? = nil, permissionID: String? = nil, toolValues: [String: ComposerControlValueWire] = [:], unavailable: ComposerSelectedUnavailableWire? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.effortID = effortID
        self.workflowID = workflowID
        self.permissionID = permissionID
        self.toolValues = toolValues
        self.unavailable = unavailable
    }

    private enum CodingKeys: String, CodingKey { case providerID = "providerId", modelID = "modelId", effortID = "effortId", workflowID = "workflowId", permissionID = "permissionId", toolValues, unavailable }
}

public struct ComposerLockWire: Codable, Hashable, Sendable {
    public let locked: Bool
    public let reasonCode: String?
    public let reasonText: String?

    public init(locked: Bool = false, reasonCode: String? = nil, reasonText: String? = nil) {
        self.locked = locked
        self.reasonCode = reasonCode
        self.reasonText = reasonText
    }
}

public struct ComposerLockSnapshotWire: Codable, Hashable, Sendable {
    public let model: ComposerLockWire
    public let effort: ComposerLockWire
    public let workflow: ComposerLockWire
    public let tools: ComposerLockWire
    public let permissions: ComposerLockWire
    public let attachments: ComposerLockWire
    public let send: ComposerLockWire

    public init(model: ComposerLockWire = .init(), effort: ComposerLockWire = .init(), workflow: ComposerLockWire = .init(), tools: ComposerLockWire = .init(), permissions: ComposerLockWire = .init(), attachments: ComposerLockWire = .init(), send: ComposerLockWire = .init()) {
        self.model = model
        self.effort = effort
        self.workflow = workflow
        self.tools = tools
        self.permissions = permissions
        self.attachments = attachments
        self.send = send
    }
}

public struct ComposerCapabilitiesWire: Codable, Hashable, Sendable {
    public let attachments: Bool
    public let taggedFiles: Bool
    public let suggestions: Bool
    public let steering: Bool

    public init(attachments: Bool, taggedFiles: Bool = true, suggestions: Bool = true, steering: Bool = false) {
        self.attachments = attachments
        self.taggedFiles = taggedFiles
        self.suggestions = suggestions
        self.steering = steering
    }
}

public struct AgentEmptyStateTipWire: Codable, Hashable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct AgentEmptyStateWire: Codable, Hashable, Sendable {
    public let heading: String
    public let featuredWorkflowIDs: [String]
    public let tips: [AgentEmptyStateTipWire]

    public init(heading: String = "What are we building?", featuredWorkflowIDs: [String], tips: [AgentEmptyStateTipWire]) {
        self.heading = heading
        self.featuredWorkflowIDs = featuredWorkflowIDs
        self.tips = tips
    }

    private enum CodingKeys: String, CodingKey { case heading
        case featuredWorkflowIDs = "featuredWorkflowIds"
        case tips
    }
}

public struct ComposerCatalogWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let context: ComposerContextWire
    public let providerGroups: [ComposerProviderGroupWire]
    public let workflows: [ComposerWorkflowOptionWire]
    public let selected: ComposerSelectionWire?
    public let locks: ComposerLockSnapshotWire
    public let capabilities: ComposerCapabilitiesWire
    public let emptyState: AgentEmptyStateWire
    public let mcpControlled: Bool

    public init(schemaVersion: Int = 1, revision: String, context: ComposerContextWire, providerGroups: [ComposerProviderGroupWire], workflows: [ComposerWorkflowOptionWire], selected: ComposerSelectionWire?, locks: ComposerLockSnapshotWire, capabilities: ComposerCapabilitiesWire, emptyState: AgentEmptyStateWire, mcpControlled: Bool) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.context = context
        self.providerGroups = providerGroups
        self.workflows = workflows
        self.selected = selected
        self.locks = locks
        self.capabilities = capabilities
        self.emptyState = emptyState
        self.mcpControlled = mcpControlled
    }
}

public struct ComposerSuggestionWire: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case nativeCommand, skill, file }
    public let kind: Kind
    public let id: String
    public let insertionText: String
    public let displayName: String
    public let detailText: String?
    public let providerIDs: [ProviderSettingsID]
    public let available: Bool

    public init(kind: Kind, id: String, insertionText: String, displayName: String, detailText: String? = nil, providerIDs: [ProviderSettingsID] = [], available: Bool = true) {
        self.kind = kind
        self.id = id
        self.insertionText = insertionText
        self.displayName = displayName
        self.detailText = detailText
        self.providerIDs = providerIDs
        self.available = available
    }

    private enum CodingKeys: String, CodingKey { case kind, id, insertionText, displayName, detailText
        case providerIDs = "providerIds"
        case available
    }
}

public struct ComposerSuggestionPageWire: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let items: [ComposerSuggestionWire]

    public init(schemaVersion: Int = 1, catalogRevision: String, items: [ComposerSuggestionWire]) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.items = items
    }
}

public struct AgentTurnConfigurationWire: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let catalogRevision: String
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let effortID: String?
    public let workflowID: String?
    public let permissionID: String?
    public let toolValues: [String: ComposerControlValueWire]

    public init(schemaVersion: Int = 1, catalogRevision: String, providerID: ProviderSettingsID, modelID: String, effortID: String? = nil, workflowID: String? = nil, permissionID: String? = nil, toolValues: [String: ComposerControlValueWire] = [:]) {
        self.schemaVersion = schemaVersion
        self.catalogRevision = catalogRevision
        self.providerID = providerID
        self.modelID = modelID
        self.effortID = effortID
        self.workflowID = workflowID
        self.permissionID = permissionID
        self.toolValues = toolValues
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, catalogRevision
        case providerID = "providerId", modelID = "modelId", effortID = "effortId", workflowID = "workflowId", permissionID = "permissionId"
        case toolValues
    }
}

public struct ComposerTaggedFileReferenceWire: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let worktreeBindingID: UUID?
    public let displayName: String

    public init(rootID: UUID, logicalPath: String, worktreeBindingID: UUID? = nil, displayName: String) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.worktreeBindingID = worktreeBindingID
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case rootID = "rootId", logicalPath, worktreeBindingID = "worktreeBindingId", displayName }
}

public struct ComposerResolvedSuggestionTokenWire: Codable, Hashable, Sendable {
    public let kind: ComposerSuggestionWire.Kind
    public let id: String
    public let insertionText: String

    public init(kind: ComposerSuggestionWire.Kind, id: String, insertionText: String) {
        self.kind = kind
        self.id = id
        self.insertionText = insertionText
    }
}

public struct AgentTurnContentWire: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let text: String
    public let attachmentIDs: [UUID]
    public let taggedFiles: [ComposerTaggedFileReferenceWire]
    public let resolvedSuggestionTokens: [ComposerResolvedSuggestionTokenWire]

    public init(schemaVersion: Int = 1, text: String, attachmentIDs: [UUID] = [], taggedFiles: [ComposerTaggedFileReferenceWire] = [], resolvedSuggestionTokens: [ComposerResolvedSuggestionTokenWire] = []) {
        self.schemaVersion = schemaVersion
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.taggedFiles = taggedFiles
        self.resolvedSuggestionTokens = resolvedSuggestionTokens
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, text
        case attachmentIDs = "attachmentIds"
        case taggedFiles, resolvedSuggestionTokens
    }
}

public struct AgentTurnSubmissionWire: Codable, Hashable, Sendable {
    public let content: AgentTurnContentWire
    public let configuration: AgentTurnConfigurationWire
    public let expectedSessionRevision: Int64?

    public init(content: AgentTurnContentWire, configuration: AgentTurnConfigurationWire, expectedSessionRevision: Int64? = nil) {
        self.content = content
        self.configuration = configuration
        self.expectedSessionRevision = expectedSessionRevision
    }
}

public struct AgentStartSessionWire: Codable, Sendable {
    public let projectID: UUID
    public let visibility: Visibility
    public let turn: AgentTurnSubmissionWire
    public let selectedMessageContext: SelectedMessageContext?

    public init(projectID: UUID, visibility: Visibility, turn: AgentTurnSubmissionWire, selectedMessageContext: SelectedMessageContext? = nil) {
        self.projectID = projectID
        self.visibility = visibility
        self.turn = turn
        self.selectedMessageContext = selectedMessageContext
    }

    private enum CodingKeys: String, CodingKey { case projectID = "projectId", visibility, turn, selectedMessageContext }
}

public struct EffectiveTurnConfigurationWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let configuration: AgentTurnConfigurationWire
    public let capabilityDigest: String
    public let actorID: String
    public let acceptedAt: Date

    public init(schemaVersion: Int = 1, configuration: AgentTurnConfigurationWire, capabilityDigest: String, actorID: String, acceptedAt: Date) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.capabilityDigest = capabilityDigest
        self.actorID = actorID
        self.acceptedAt = acceptedAt
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, configuration, capabilityDigest
        case actorID = "actorId", acceptedAt
    }
}

public struct SessionNextTurnDefaultsWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let revision: Int64
    public let configuration: EffectiveTurnConfigurationWireSnapshot
    public let updatedAt: Date

    public init(schemaVersion: Int = 1, sessionID: UUID, revision: Int64, configuration: EffectiveTurnConfigurationWireSnapshot, updatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.configuration = configuration
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion
        case sessionID = "sessionId"
        case revision, configuration, updatedAt
    }
}

public enum RunPresentationPhaseWire: String, Codable, Hashable, Sendable {
    case preparing, thinking, working, waiting, cancelling
}

public struct RunPresentationWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let runID: UUID
    public let generation: Int64
    public let turnEpoch: Int64
    public let phase: RunPresentationPhaseWire?
    public let phaseRevision: Int64
    public let runningStatusCode: String?
    public let runningStatusText: String?
    public let runStartedAt: Date
    public let priorActivePhase: RunPresentationPhaseWire?
    public let terminalSettlementCode: String?
    public let terminalSettledAt: Date?

    public init(schemaVersion: Int = 1, sessionID: UUID, runID: UUID, generation: Int64, turnEpoch: Int64, phase: RunPresentationPhaseWire?, phaseRevision: Int64, runningStatusCode: String? = nil, runningStatusText: String? = nil, runStartedAt: Date, priorActivePhase: RunPresentationPhaseWire? = nil, terminalSettlementCode: String? = nil, terminalSettledAt: Date? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.phase = phase
        self.phaseRevision = phaseRevision
        self.runningStatusCode = runningStatusCode
        self.runningStatusText = runningStatusText
        self.runStartedAt = runStartedAt
        self.priorActivePhase = priorActivePhase
        self.terminalSettlementCode = terminalSettlementCode
        self.terminalSettledAt = terminalSettledAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID = "sessionId"
        case runID = "runId"
        case generation, turnEpoch, phase, phaseRevision, runningStatusCode, runningStatusText, runStartedAt, priorActivePhase, terminalSettlementCode, terminalSettledAt
    }
}

public enum ComposerAttachmentLifecycle: String, Codable, Hashable, Sendable { case staged, accepted, expired, failed }

public struct ComposerAttachmentWire: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let attachmentID: UUID
    public let displayName: String
    public let mediaType: String
    public let byteSize: Int
    public let digest: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let lifecycle: ComposerAttachmentLifecycle
    public let expiresAt: Date?
    public let selectedProviderSupportsAttachment: Bool

    public init(schemaVersion: Int = 1, attachmentID: UUID, displayName: String, mediaType: String, byteSize: Int, digest: String, pixelWidth: Int, pixelHeight: Int, lifecycle: ComposerAttachmentLifecycle, expiresAt: Date? = nil, selectedProviderSupportsAttachment: Bool = true) {
        self.schemaVersion = schemaVersion
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.digest = digest
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.lifecycle = lifecycle
        self.expiresAt = expiresAt
        self.selectedProviderSupportsAttachment = selectedProviderSupportsAttachment
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion
        case attachmentID = "attachmentId"
        case displayName, mediaType, byteSize, digest, pixelWidth, pixelHeight, lifecycle, expiresAt, selectedProviderSupportsAttachment
    }
}

public struct ComposerAttachmentResolveRequest: Codable, Hashable, Sendable {
    public let attachmentIDs: [UUID]
    public init(attachmentIDs: [UUID]) {
        self.attachmentIDs = attachmentIDs
    }

    private enum CodingKeys: String, CodingKey { case attachmentIDs = "attachmentIds" }
}

public struct ComposerAttachmentResolveResult: Codable, Hashable, Sendable {
    public let attachmentID: UUID
    public let attachment: ComposerAttachmentWire?
    public let errorCode: String?

    public init(attachmentID: UUID, attachment: ComposerAttachmentWire? = nil, errorCode: String? = nil) {
        self.attachmentID = attachmentID
        self.attachment = attachment
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey { case attachmentID = "attachmentId", attachment, errorCode }
}

public struct SubmissionReceipt: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let submissionID: UUID
    public let acceptedAt: Date
    public let operation: String
    public let sessionID: UUID
    public let sessionRevision: Int64
    public let requestAnchorID: UUID
    public let runID: UUID?
    public let generation: Int64?
    public let turnEpoch: Int64?
    public let runPhase: String?
    public let runStartedAt: Date?
    public let consumedAttachmentIDs: [UUID]
    public let consumedTaggedFiles: [ComposerTaggedFileReferenceWire]
    public let selectedConfiguration: AgentTurnConfigurationWire
    public let session: SessionSnapshot?

    public init(schemaVersion: Int = 1, submissionID: UUID, acceptedAt: Date, operation: String, sessionID: UUID, sessionRevision: Int64, requestAnchorID: UUID, runID: UUID? = nil, generation: Int64? = nil, turnEpoch: Int64? = nil, runPhase: String? = nil, runStartedAt: Date? = nil, consumedAttachmentIDs: [UUID] = [], consumedTaggedFiles: [ComposerTaggedFileReferenceWire] = [], selectedConfiguration: AgentTurnConfigurationWire, session: SessionSnapshot? = nil) {
        self.schemaVersion = schemaVersion
        self.submissionID = submissionID
        self.acceptedAt = acceptedAt
        self.operation = operation
        self.sessionID = sessionID
        self.sessionRevision = sessionRevision
        self.requestAnchorID = requestAnchorID
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.runPhase = runPhase
        self.runStartedAt = runStartedAt
        self.consumedAttachmentIDs = consumedAttachmentIDs
        self.consumedTaggedFiles = consumedTaggedFiles
        self.selectedConfiguration = selectedConfiguration
        self.session = session
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion
        case submissionID = "submissionId", acceptedAt, operation, sessionID = "sessionId", sessionRevision, requestAnchorID = "requestAnchorId", runID = "runId", generation, turnEpoch, runPhase, runStartedAt, consumedAttachmentIDs = "consumedAttachmentIds", consumedTaggedFiles, selectedConfiguration, session
    }
}
