import Foundation

/// Browser-safe project projection for the standalone portal.
public struct PortalProjectSummary: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let name: String
    public let state: ProjectLifecycleState
    public let rootNames: [String]

    public init(projectID: UUID, name: String, state: ProjectLifecycleState, rootNames: [String]) {
        self.projectID = projectID
        self.name = name
        self.state = state
        self.rootNames = rootNames
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case name, state, rootNames
    }
}

/// Compact session projection used by the project/session sidebar.
public struct PortalSessionSummary: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let title: String
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?
    public let state: SessionLifecycleState
    public let revision: Int64
    public let runGeneration: Int64
    public let lastActivityAt: Date?
    public let contextUsage: ContextUsageWireSnapshot?

    public init(
        sessionID: UUID,
        projectID: UUID,
        parentSessionID: UUID?,
        title: String,
        provider: ProviderKind,
        providerSettingsID: ProviderSettingsID? = nil,
        model: String?,
        state: SessionLifecycleState,
        revision: Int64,
        runGeneration: Int64,
        lastActivityAt: Date?,
        contextUsage: ContextUsageWireSnapshot? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.title = title
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.model = model
        self.state = state
        self.revision = revision
        self.runGeneration = runGeneration
        self.lastActivityAt = lastActivityAt
        self.contextUsage = contextUsage
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case title, provider
        case providerSettingsID = "providerSettingsId"
        case model, state, revision, runGeneration, lastActivityAt, contextUsage
    }
}

public struct PortalWorkflowSummary: Codable, Hashable, Sendable {
    public let workflowID: String
    public let name: String
    public let source: ServerWorkflowSource
    public let enabled: Bool
    public let visible: Bool
    public let featuredOrder: Int?
    public let rowRevision: Int64

    public init(
        workflowID: String,
        name: String,
        source: ServerWorkflowSource = .builtin,
        enabled: Bool,
        visible: Bool = true,
        featuredOrder: Int? = nil,
        rowRevision: Int64 = 1
    ) {
        self.workflowID = workflowID
        self.name = name
        self.source = source
        self.enabled = enabled
        self.visible = visible
        self.featuredOrder = featuredOrder
        self.rowRevision = rowRevision
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID, name, source, enabled, visible, featuredOrder, rowRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decode(String.self, forKey: .workflowID)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(ServerWorkflowSource.self, forKey: .source) ?? .builtin
        enabled = try container.decode(Bool.self, forKey: .enabled)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        featuredOrder = try container.decodeIfPresent(Int.self, forKey: .featuredOrder)
        rowRevision = try container.decodeIfPresent(Int64.self, forKey: .rowRevision) ?? 1
    }
}

/// Browser-safe projection of the canonical MCP tool catalog. Availability is
/// service-managed; this DTO deliberately carries no client-side enable toggle.
public struct PortalToolSummary: Codable, Hashable, Sendable {
    public let name: String
    public let scope: String
    public let capability: String
    public let admissionClass: String

    public init(name: String, scope: String, capability: String, admissionClass: String) {
        self.name = name
        self.scope = scope
        self.capability = capability
        self.admissionClass = admissionClass
    }
}

public struct PortalBootstrapResponse: Codable, Sendable {
    public let projects: [PortalProjectSummary]
    public let sessions: [PortalSessionSummary]
    public let workflows: [PortalWorkflowSummary]
    public let tools: [PortalToolSummary]
    public let workflowRepositoryRevision: Int64
    public let includeSessionCleanupGuidance: Bool

    public init(
        projects: [PortalProjectSummary],
        sessions: [PortalSessionSummary],
        workflows: [PortalWorkflowSummary],
        tools: [PortalToolSummary] = [],
        workflowRepositoryRevision: Int64 = 0,
        includeSessionCleanupGuidance: Bool = true
    ) {
        self.projects = projects
        self.sessions = sessions
        self.workflows = workflows
        self.tools = tools
        self.workflowRepositoryRevision = workflowRepositoryRevision
        self.includeSessionCleanupGuidance = includeSessionCleanupGuidance
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, workflows, tools, workflowRepositoryRevision, includeSessionCleanupGuidance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([PortalProjectSummary].self, forKey: .projects)
        sessions = try container.decode([PortalSessionSummary].self, forKey: .sessions)
        workflows = try container.decode([PortalWorkflowSummary].self, forKey: .workflows)
        tools = try container.decodeIfPresent([PortalToolSummary].self, forKey: .tools) ?? []
        workflowRepositoryRevision = try container.decodeIfPresent(Int64.self, forKey: .workflowRepositoryRevision) ?? 0
        includeSessionCleanupGuidance = try container.decodeIfPresent(Bool.self, forKey: .includeSessionCleanupGuidance) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(workflows, forKey: .workflows)
        try container.encode(tools, forKey: .tools)
        try container.encode(workflowRepositoryRevision, forKey: .workflowRepositoryRevision)
        try container.encode(includeSessionCleanupGuidance, forKey: .includeSessionCleanupGuidance)
    }
}

/// Sanitized transcript row. Rich desktop presentation payloads and actor
/// records deliberately remain server-side.
public struct PortalTranscriptEntry: Codable, Hashable, Sendable {
    public let entryID: UUID
    public let sessionSequence: Int64
    public let kind: TranscriptEntry.Kind
    public let content: String
    public let timestamp: Date
    public let truncated: Bool

    public init(entryID: UUID, sessionSequence: Int64, kind: TranscriptEntry.Kind, content: String, timestamp: Date, truncated: Bool) {
        self.entryID = entryID
        self.sessionSequence = sessionSequence
        self.kind = kind
        self.content = content
        self.timestamp = timestamp
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case entryID = "entryId"
        case sessionSequence, kind, content, timestamp, truncated
    }
}

public struct PortalTranscriptPage: Codable, Sendable {
    public let session: PortalSessionSummary
    public let items: [PortalTranscriptEntry]
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool
    public let earliestSequence: Int64?
    public let latestSequence: Int64?

    public init(
        session: PortalSessionSummary,
        items: [PortalTranscriptEntry],
        hasMoreBefore: Bool,
        hasMoreAfter: Bool,
        earliestSequence: Int64?,
        latestSequence: Int64?
    ) {
        self.session = session
        self.items = items
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.earliestSequence = earliestSequence
        self.latestSequence = latestSequence
    }
}

public struct PortalCreateSessionRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let projectID: UUID
    public let providerID: ProviderSettingsID?
    public let routingTarget: AgentRoutingTarget?
    public let model: String?
    public let initialPrompt: String

    public init(
        operationID: UUID,
        projectID: UUID,
        providerID: ProviderSettingsID? = nil,
        routingTarget: AgentRoutingTarget? = nil,
        model: String?,
        initialPrompt: String
    ) {
        self.operationID = operationID
        self.projectID = projectID
        self.providerID = providerID
        self.routingTarget = routingTarget
        self.model = model
        self.initialPrompt = initialPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case projectID = "projectId"
        case providerID = "providerId"
        case routingTarget, model, initialPrompt
    }
}

public struct PortalSendMessageRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64
    public let text: String

    public init(operationID: UUID, expectedRevision: Int64, text: String) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision, text
    }
}
