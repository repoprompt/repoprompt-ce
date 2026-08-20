import Foundation

public struct Page<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextPageToken: String?
    public let cursor: ServiceCursor

    public init(items: [Item], nextPageToken: String?, cursor: ServiceCursor) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case items, nextPageToken, cursor
    }
}

public struct ProjectRootWireSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalName: String
    public let writable: Bool
    public let revision: Int64

    public init(_ value: ProjectRootSnapshot) {
        rootID = value.rootID
        logicalName = value.logicalName
        writable = value.writable
        revision = value.revision
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalName, writable, revision
    }
}

public struct ProjectWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let name: String
    public let creator: ExternalActor
    public let state: ProjectLifecycleState
    public let roots: [ProjectRootWireSnapshot]
    public let revision: Int64
    public let cursor: ServiceCursor

    public init(_ value: ProjectSnapshot) {
        schemaVersion = value.schemaVersion
        projectID = value.projectID
        name = value.name
        creator = value.creator
        state = value.state
        roots = value.roots.map(ProjectRootWireSnapshot.init)
        revision = value.revision
        cursor = value.cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID = "projectId"
        case name, creator, state, roots, revision, cursor
    }
}

/// Bounded project event payload consumed by chat-host projections. Physical
/// roots remain in RepoPrompt persistence and never enter the event stream.
public struct ProjectEventWirePayload: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let name: String
    public let state: ProjectLifecycleState
    public let revision: Int64
    public let rootCount: Int

    public init(_ value: ProjectSnapshot) {
        schemaVersion = 1
        projectID = value.projectID
        name = value.name
        state = value.state
        revision = value.revision
        rootCount = value.roots.count
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID = "projectId"
        case name, state, revision, rootCount
    }
}

public enum ProjectSourceOperationState: String, Codable, Hashable, Sendable {
    case validating
    case cloning
    case promoting
    case completed
    case failed
}

/// Safe progress/result payload. It deliberately excludes the submitted
/// remote, configured physical path, staging path, and credential profile.
public struct ProjectSourceOperationWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let operationID: UUID
    public let projectID: UUID
    public let state: ProjectSourceOperationState
    public let progressRevision: Int64
    public let messageCode: String
    public let project: ProjectWireSnapshot?
    public let errorCode: ServiceErrorCode?

    public init(
        schemaVersion: Int = 1,
        operationID: UUID,
        projectID: UUID,
        state: ProjectSourceOperationState,
        progressRevision: Int64,
        messageCode: String,
        project: ProjectWireSnapshot? = nil,
        errorCode: ServiceErrorCode? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.projectID = projectID
        self.state = state
        self.progressRevision = progressRevision
        self.messageCode = messageCode
        self.project = project
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID = "operationId"
        case projectID = "projectId"
        case state, progressRevision, messageCode, project, errorCode
    }
}

public struct ProjectSourceCapabilities: Codable, Hashable, Sendable {
    public struct GitRemoteRule: Codable, Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let pathPrefix: String

        public init(scheme: String, host: String, pathPrefix: String) {
            self.scheme = scheme
            self.host = host
            self.pathPrefix = pathPrefix
        }

        private enum CodingKeys: String, CodingKey {
            case scheme, host, pathPrefix
        }
    }

    public let schemaVersion: Int
    public let gitRemoteRules: [GitRemoteRule]
    public let gitCloneEnabled: Bool

    public init(
        schemaVersion: Int = 1,
        gitRemoteRules: [GitRemoteRule],
        gitCloneEnabled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.gitRemoteRules = gitRemoteRules
        self.gitCloneEnabled = gitCloneEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gitRemoteRules, gitCloneEnabled
    }
}

public struct WorktreeWireSnapshot: Codable, Hashable, Sendable {
    public let bindingID: UUID
    public let projectID: UUID
    public let rootID: UUID
    public let sessionID: UUID?
    public let baseRef: String
    public let branch: String
    public let ownershipState: WorktreeBindingSnapshot.OwnershipState
    public let mergeState: WorktreeBindingSnapshot.MergeState
    public let revision: Int64

    public init(_ value: WorktreeBindingSnapshot) {
        bindingID = value.bindingID
        projectID = value.projectID
        rootID = value.rootID
        sessionID = value.sessionID
        baseRef = value.baseRef
        branch = value.branch
        ownershipState = value.ownershipState
        mergeState = value.mergeState
        revision = value.revision
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case projectID = "projectId"
        case rootID = "rootId"
        case sessionID = "sessionId"
        case baseRef, branch, ownershipState, mergeState, revision
    }
}

public struct AuthoritativeWireSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let storeID: UUID
    public let projects: [ProjectWireSnapshot]
    public let sessions: [SessionSnapshot]
    public let sessionTitles: [String: String]?
    public let cursor: ServiceCursor

    public init(_ value: AuthoritativeSnapshot, sessionTitles: [String: String]? = nil) {
        schemaVersion = value.schemaVersion
        storeID = value.storeID
        projects = value.projects.map(ProjectWireSnapshot.init)
        sessions = value.sessions
        self.sessionTitles = sessionTitles
        cursor = value.cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID = "storeId"
        case projects, sessions, sessionTitles, cursor
    }
}

public struct ProtocolVersionRange: Codable, Hashable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey { case minimum, maximum }
}

public struct ProviderCatalogItem: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let enabled: Bool
    public let version: String?
    public let protocolVersion: String?
    public let supportsResume: Bool
    public let supportsSteering: Bool
    public let reasonUnavailable: String?

    public init(kind: ProviderKind, enabled: Bool, version: String?, protocolVersion: String?, supportsResume: Bool, supportsSteering: Bool, reasonUnavailable: String?) {
        self.kind = kind
        self.enabled = enabled
        self.version = version
        self.protocolVersion = protocolVersion
        self.supportsResume = supportsResume
        self.supportsSteering = supportsSteering
        self.reasonUnavailable = reasonUnavailable
    }

    private enum CodingKeys: String, CodingKey {
        case kind, enabled, version, protocolVersion, supportsResume, supportsSteering, reasonUnavailable
    }
}

public struct ModelCatalogItem: Codable, Hashable, Sendable {
    public let id: String
    public let provider: ProviderKind
    public let providerID: ProviderSettingsID?
    public let displayName: String
    public let enabled: Bool
    public let description: String?
    public let supportedEffortIDs: [String]?
    public let defaultEffortID: String?

    public init(
        id: String,
        provider: ProviderKind,
        providerID: ProviderSettingsID? = nil,
        displayName: String,
        enabled: Bool,
        description: String? = nil,
        supportedEffortIDs: [String]? = nil,
        defaultEffortID: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.providerID = providerID
        self.displayName = displayName
        self.enabled = enabled
        self.description = description
        self.supportedEffortIDs = supportedEffortIDs
        self.defaultEffortID = defaultEffortID
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider
        case providerID = "providerId"
        case displayName, enabled, description
        case supportedEffortIDs = "supportedEffortIds"
        case defaultEffortID = "defaultEffortId"
    }
}

public struct ExecutionModeCatalogItem: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let allowsWorkspaceWrites: Bool
    public let allowsUnrestrictedHostAccess: Bool
    public let providers: [ProviderKind]

    public init(id: String, displayName: String, allowsWorkspaceWrites: Bool, allowsUnrestrictedHostAccess: Bool, providers: [ProviderKind]) {
        self.id = id
        self.displayName = displayName
        self.allowsWorkspaceWrites = allowsWorkspaceWrites
        self.allowsUnrestrictedHostAccess = allowsUnrestrictedHostAccess
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, allowsWorkspaceWrites, allowsUnrestrictedHostAccess, providers
    }
}

public struct ServiceCapabilitiesResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let protocolRange: ProtocolVersionRange
    public let schemaVersion: Int
    public let storeID: UUID
    public let replayFloor: Int64
    public let providers: [ProviderCatalogItem]
    public let models: [ModelCatalogItem]
    public let workflows: [WorkflowSnapshot]
    public let executionModes: [ExecutionModeCatalogItem]
    public let eventTypes: [EventType]
    public let projectSources: ProjectSourceCapabilities?

    public init(protocolVersion: Int = 1, protocolRange: ProtocolVersionRange, schemaVersion: Int, storeID: UUID, replayFloor: Int64, providers: [ProviderCatalogItem], models: [ModelCatalogItem], workflows: [WorkflowSnapshot], executionModes: [ExecutionModeCatalogItem], eventTypes: [EventType], projectSources: ProjectSourceCapabilities? = nil) {
        self.protocolVersion = protocolVersion
        self.protocolRange = protocolRange
        self.schemaVersion = schemaVersion
        self.storeID = storeID
        self.replayFloor = replayFloor
        self.providers = providers
        self.models = models
        self.workflows = workflows
        self.executionModes = executionModes
        self.eventTypes = eventTypes
        self.projectSources = projectSources
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case protocolRange = "protocol"
        case schemaVersion
        case storeID = "storeId"
        case replayFloor, providers, models, workflows, executionModes, eventTypes, projectSources
    }
}
