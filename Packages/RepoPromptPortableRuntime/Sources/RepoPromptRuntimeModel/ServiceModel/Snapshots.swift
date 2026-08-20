import Foundation

public struct ProjectRootSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalName: String
    public let canonicalPath: String
    public let writable: Bool
    public let revision: Int64

    public init(rootID: UUID, logicalName: String, canonicalPath: String, writable: Bool, revision: Int64 = 1) {
        self.rootID = rootID
        self.logicalName = logicalName
        self.canonicalPath = canonicalPath
        self.writable = writable
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalName
        case canonicalPath
        case writable
        case revision
    }
}

public struct ProjectSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let name: String
    public let creator: ExternalActor
    public let state: ProjectLifecycleState
    public let roots: [ProjectRootSnapshot]
    public let revision: Int64
    public let cursor: ServiceCursor

    public init(projectID: UUID, name: String, creator: ExternalActor, state: ProjectLifecycleState, roots: [ProjectRootSnapshot], revision: Int64, cursor: ServiceCursor) {
        schemaVersion = 1
        self.projectID = projectID
        self.name = name
        self.creator = creator
        self.state = state
        self.roots = roots
        self.revision = revision
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID = "projectId"
        case name
        case creator
        case state
        case roots
        case revision
        case cursor
    }
}

public struct InteractionSnapshot: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case question, approval }
    public enum State: String, Codable, Sendable { case pending, deliveryIntent, resolved, expired, interrupted }
    public let interactionID: UUID
    public let runID: UUID?
    public let agentID: UUID?
    public let kind: Kind
    public let state: State
    public let payload: Data
    public let revision: Int64
    public let expiresAt: Date?

    public init(interactionID: UUID, runID: UUID? = nil, agentID: UUID? = nil, kind: Kind, state: State, payload: Data, revision: Int64, expiresAt: Date?) {
        self.interactionID = interactionID
        self.runID = runID
        self.agentID = agentID
        self.kind = kind
        self.state = state
        self.payload = payload
        self.revision = revision
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case interactionID = "interactionId"
        case runID = "runId"
        case agentID = "agentId"
        case kind
        case state
        case payload
        case revision
        case expiresAt
    }
}

public struct TranscriptEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case human, assistant, system, reasoning, progress, tool }
    public let entryID: UUID
    public let sessionSequence: Int64
    public let kind: Kind
    public let content: String
    public let actor: ExternalActor?
    public let timestamp: Date
    /// Optional adapter-owned rendering payload. The provider-neutral fields above
    /// remain the canonical transcript contract; macOS uses this to round-trip its
    /// richer chat row without creating a second transcript authority.
    public let presentationPayload: Data?

    public init(entryID: UUID, sessionSequence: Int64, kind: Kind, content: String, actor: ExternalActor?, timestamp: Date, presentationPayload: Data? = nil) {
        self.entryID = entryID
        self.sessionSequence = sessionSequence
        self.kind = kind
        self.content = content
        self.actor = actor
        self.timestamp = timestamp
        self.presentationPayload = presentationPayload
    }

    private enum CodingKeys: String, CodingKey {
        case entryID = "entryId"
        case sessionSequence
        case kind
        case content
        case actor
        case timestamp
        case presentationPayload
    }
}

public struct AgentSnapshot: Codable, Hashable, Sendable {
    public let agentID: UUID
    public let sessionID: UUID
    public let rootSessionID: UUID
    public let parentAgentID: UUID?
    public let providerNativeIdentity: String?
    public let role: String
    public let label: String?
    public let state: SessionLifecycleState
    public let revision: Int64

    public init(agentID: UUID, sessionID: UUID, rootSessionID: UUID, parentAgentID: UUID?, providerNativeIdentity: String? = nil, role: String, label: String? = nil, state: SessionLifecycleState, revision: Int64) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.rootSessionID = rootSessionID
        self.parentAgentID = parentAgentID
        self.providerNativeIdentity = providerNativeIdentity
        self.role = role
        self.label = label
        self.state = state
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case agentID = "agentId"
        case sessionID = "sessionId"
        case rootSessionID = "rootSessionId"
        case parentAgentID = "parentAgentId"
        case providerNativeIdentity
        case role
        case label
        case state
        case revision
    }
}

public struct ProviderRunSnapshot: Codable, Hashable, Sendable {
    public let runID: UUID
    public let sessionID: UUID
    public let provider: ProviderKind
    public let providerSessionID: String?
    public let state: String
    public let generation: Int64
    public let turnEpoch: Int64
    public let startReason: String
    public let endReason: String?
    public let startedAt: Date
    public let endedAt: Date?

    public init(runID: UUID, sessionID: UUID, provider: ProviderKind, providerSessionID: String? = nil, state: String, generation: Int64, turnEpoch: Int64, startReason: String, endReason: String? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.runID = runID
        self.sessionID = sessionID
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.state = state
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.startReason = startReason
        self.endReason = endReason
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case sessionID = "sessionId"
        case provider
        case providerSessionID = "providerSessionId"
        case state
        case generation
        case turnEpoch
        case startReason
        case endReason
        case startedAt
        case endedAt
    }
}

/// Desktop `AgentContextUsage` fields for the composer context-window meter.
public struct ContextUsageWireSnapshot: Codable, Hashable, Sendable {
    public let modelContextWindow: Int?
    public let lastTotalTokens: Int?
    public let totalTotalTokens: Int?

    public init(modelContextWindow: Int? = nil, lastTotalTokens: Int? = nil, totalTotalTokens: Int? = nil) {
        self.modelContextWindow = modelContextWindow
        self.lastTotalTokens = lastTotalTokens
        self.totalTotalTokens = totalTotalTokens
    }

    public func merging(onto existing: ContextUsageWireSnapshot?) -> ContextUsageWireSnapshot {
        ContextUsageWireSnapshot(
            modelContextWindow: modelContextWindow ?? existing?.modelContextWindow,
            lastTotalTokens: lastTotalTokens ?? existing?.lastTotalTokens,
            totalTotalTokens: totalTotalTokens ?? existing?.totalTotalTokens
        )
    }
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let rootSessionID: UUID
    public let creator: ExternalActor
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?
    public let visibility: Visibility
    public let state: SessionLifecycleState
    public let runGeneration: Int64
    public let turnEpoch: Int64
    public let revision: Int64
    public let transcript: [TranscriptEntry]
    public let interactions: [InteractionSnapshot]
    public let cursor: ServiceCursor
    public let effectiveTurnConfiguration: EffectiveTurnConfigurationWireSnapshot?
    public let nextTurnDefaults: SessionNextTurnDefaultsWireSnapshot?
    public let runPresentation: RunPresentationWireSnapshot?
    public let contextUsage: ContextUsageWireSnapshot?

    public init(sessionID: UUID, projectID: UUID, parentSessionID: UUID?, rootSessionID: UUID, creator: ExternalActor, provider: ProviderKind, providerSettingsID: ProviderSettingsID? = nil, model: String?, visibility: Visibility, state: SessionLifecycleState, runGeneration: Int64, turnEpoch: Int64, revision: Int64, transcript: [TranscriptEntry], interactions: [InteractionSnapshot], cursor: ServiceCursor, effectiveTurnConfiguration: EffectiveTurnConfigurationWireSnapshot? = nil, nextTurnDefaults: SessionNextTurnDefaultsWireSnapshot? = nil, runPresentation: RunPresentationWireSnapshot? = nil, contextUsage: ContextUsageWireSnapshot? = nil) {
        schemaVersion = 1
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.rootSessionID = rootSessionID
        self.creator = creator
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.model = model
        self.visibility = visibility
        self.state = state
        self.runGeneration = runGeneration
        self.turnEpoch = turnEpoch
        self.revision = revision
        self.transcript = transcript
        self.interactions = interactions
        self.cursor = cursor
        self.effectiveTurnConfiguration = effectiveTurnConfiguration
        self.nextTurnDefaults = nextTurnDefaults
        self.runPresentation = runPresentation
        self.contextUsage = contextUsage
    }

    public func replacing(
        visibility: Visibility? = nil,
        state: SessionLifecycleState? = nil,
        runGeneration: Int64? = nil,
        turnEpoch: Int64? = nil,
        revision: Int64? = nil,
        transcript: [TranscriptEntry]? = nil,
        interactions: [InteractionSnapshot]? = nil,
        cursor: ServiceCursor? = nil,
        effectiveTurnConfiguration: EffectiveTurnConfigurationWireSnapshot? = nil,
        nextTurnDefaults: SessionNextTurnDefaultsWireSnapshot? = nil,
        runPresentation: RunPresentationWireSnapshot? = nil,
        contextUsage: ContextUsageWireSnapshot? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            sessionID: sessionID,
            projectID: projectID,
            parentSessionID: parentSessionID,
            rootSessionID: rootSessionID,
            creator: creator,
            provider: provider,
            providerSettingsID: providerSettingsID,
            model: model,
            visibility: visibility ?? self.visibility,
            state: state ?? self.state,
            runGeneration: runGeneration ?? self.runGeneration,
            turnEpoch: turnEpoch ?? self.turnEpoch,
            revision: revision ?? self.revision,
            transcript: transcript ?? self.transcript,
            interactions: interactions ?? self.interactions,
            cursor: cursor ?? self.cursor,
            effectiveTurnConfiguration: effectiveTurnConfiguration ?? self.effectiveTurnConfiguration,
            nextTurnDefaults: nextTurnDefaults ?? self.nextTurnDefaults,
            runPresentation: runPresentation ?? self.runPresentation,
            contextUsage: contextUsage ?? self.contextUsage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID = "sessionId"
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case rootSessionID = "rootSessionId"
        case creator
        case provider
        case providerSettingsID = "providerSettingsId"
        case model
        case visibility
        case state
        case runGeneration
        case turnEpoch
        case revision
        case transcript
        case interactions
        case cursor
        case effectiveTurnConfiguration
        case nextTurnDefaults
        case runPresentation
        case contextUsage
    }
}

public struct AuthoritativeSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let storeID: UUID
    public let projects: [ProjectSnapshot]
    public let sessions: [SessionSnapshot]
    public let cursor: ServiceCursor

    public init(storeID: UUID, projects: [ProjectSnapshot], sessions: [SessionSnapshot], cursor: ServiceCursor) {
        schemaVersion = 1
        self.storeID = storeID
        self.projects = projects
        self.sessions = sessions
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID = "storeId"
        case projects
        case sessions
        case cursor
    }
}

/// Complete session projection returned to every authority adapter. Keeping
/// policy, interactions, worktree ownership and the live run binding together
/// prevents UI and direct-MCP compositions from assembling competing views.
public struct AuthoritySessionSnapshot: Codable, Hashable, Sendable {
    public let session: SessionSnapshot
    public let activeRun: ProviderRunSnapshot?
    public let activeBinding: RunBindingSnapshot?
    public let permissions: ExecutionPermissionSnapshot
    public let interactions: [InteractionSnapshot]
    public let worktrees: [WorktreeBindingSnapshot]

    public init(
        session: SessionSnapshot,
        activeRun: ProviderRunSnapshot?,
        activeBinding: RunBindingSnapshot?,
        permissions: ExecutionPermissionSnapshot,
        interactions: [InteractionSnapshot],
        worktrees: [WorktreeBindingSnapshot]
    ) {
        self.session = session
        self.activeRun = activeRun
        self.activeBinding = activeBinding
        self.permissions = permissions
        self.interactions = interactions
        self.worktrees = worktrees
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case activeRun
        case activeBinding
        case permissions
        case interactions
        case worktrees
    }
}

/// Codable service representation of the runtime-core binding identity. This
/// lives in the protocol target so UI, HTTP and MCP adapters share one shape
/// without introducing a reverse dependency on AgentRuntimeCore.
public struct RunBindingSnapshot: Codable, Hashable, Sendable {
    public let runID: UUID
    public let generation: Int64
    public let turnEpoch: Int64
    public let connectionGeneration: Int64

    public init(runID: UUID, generation: Int64, turnEpoch: Int64, connectionGeneration: Int64) {
        self.runID = runID
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.connectionGeneration = connectionGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case generation
        case turnEpoch
        case connectionGeneration
    }
}

/// Exact-identity import used by an embedded host while it migrates its legacy
/// JSON documents. It is an authority admission operation, not an alternate
/// persistence path: once installed, every mutation uses the durable store.
public struct EmbeddedSessionSeed: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let roots: [ProjectRootSnapshot]
    public let sessionID: UUID
    public let parentSessionID: UUID?
    public let rootSessionID: UUID
    public let creator: ExternalActor
    public let provider: ProviderKind
    public let model: String?
    public let visibility: Visibility
    public let transcript: [TranscriptEntry]
    public let permissionMode: String
    public let providerSettings: [String: String]
    public let worktrees: [WorktreeBindingSnapshot]

    public init(
        projectID: UUID,
        projectName: String,
        roots: [ProjectRootSnapshot],
        sessionID: UUID,
        parentSessionID: UUID? = nil,
        rootSessionID: UUID,
        creator: ExternalActor,
        provider: ProviderKind,
        model: String? = nil,
        visibility: Visibility = .privateSession,
        transcript: [TranscriptEntry] = [],
        permissionMode: String = "workspaceWrite",
        providerSettings: [String: String] = [:],
        worktrees: [WorktreeBindingSnapshot] = []
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.roots = roots
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.rootSessionID = rootSessionID
        self.creator = creator
        self.provider = provider
        self.model = model
        self.visibility = visibility
        self.transcript = transcript
        self.permissionMode = permissionMode
        self.providerSettings = providerSettings
        self.worktrees = worktrees
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case projectName
        case roots
        case sessionID = "sessionId"
        case parentSessionID = "parentSessionId"
        case rootSessionID = "rootSessionId"
        case creator
        case provider
        case model
        case visibility
        case transcript
        case permissionMode
        case providerSettings
        case worktrees
    }
}
