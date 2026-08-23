import Foundation

public enum WorkflowRepositoryDefaults {
    /// Desktop `AgentWorkflowStore.hiddenBuiltInIDs` default `{build}`.
    public static let hiddenBuiltInID = "rp-build"
}

public enum ServerWorkflowSource: String, Codable, CaseIterable, Sendable {
    case builtin
    case custom
}

public struct ServerWorkflowDefinition: Codable, Hashable, Sendable {
    public let workflowID: String
    public let source: ServerWorkflowSource
    public let name: String
    public let definition: String
    public let contentDigest: String
    public let enabled: Bool
    public let visible: Bool
    public let featuredOrder: Int?
    public let rowRevision: Int64

    public init(
        workflowID: String,
        source: ServerWorkflowSource,
        name: String,
        definition: String,
        contentDigest: String,
        enabled: Bool = true,
        visible: Bool = true,
        featuredOrder: Int? = nil,
        rowRevision: Int64 = 1
    ) {
        self.workflowID = workflowID
        self.source = source
        self.name = name
        self.definition = definition
        self.contentDigest = contentDigest
        self.enabled = enabled
        self.visible = visible
        self.featuredOrder = featuredOrder
        self.rowRevision = rowRevision
    }
}

public struct ServerWorkflowRepositorySnapshot: Codable, Hashable, Sendable {
    public let workflows: [ServerWorkflowDefinition]
    public let includeSessionCleanupGuidance: Bool
    public let revision: Int64
    public let updatedAt: Date

    public init(
        workflows: [ServerWorkflowDefinition],
        includeSessionCleanupGuidance: Bool,
        revision: Int64,
        updatedAt: Date
    ) {
        self.workflows = workflows
        self.includeSessionCleanupGuidance = includeSessionCleanupGuidance
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct CreateServerWorkflowRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let name: String
    public let definition: String
    public let enabled: Bool
    public let visible: Bool
    public let featured: Bool

    public init(expectedRevision: Int64, name: String, definition: String, enabled: Bool = true, visible: Bool = true, featured: Bool = false) {
        self.expectedRevision = expectedRevision
        self.name = name
        self.definition = definition
        self.enabled = enabled
        self.visible = visible
        self.featured = featured
    }
}

public struct UpdateServerWorkflowRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let expectedRowRevision: Int64
    public let name: String
    public let definition: String
    public let enabled: Bool
    public let visible: Bool
    public let featured: Bool

    public init(expectedRevision: Int64, expectedRowRevision: Int64, name: String, definition: String, enabled: Bool, visible: Bool, featured: Bool) {
        self.expectedRevision = expectedRevision
        self.expectedRowRevision = expectedRowRevision
        self.name = name
        self.definition = definition
        self.enabled = enabled
        self.visible = visible
        self.featured = featured
    }
}

public struct CloneServerWorkflowRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let expectedSourceRowRevision: Int64
    public let name: String

    public init(expectedRevision: Int64, expectedSourceRowRevision: Int64, name: String) {
        self.expectedRevision = expectedRevision
        self.expectedSourceRowRevision = expectedSourceRowRevision
        self.name = name
    }
}

public struct DeleteServerWorkflowRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let expectedRowRevision: Int64

    public init(expectedRevision: Int64, expectedRowRevision: Int64) {
        self.expectedRevision = expectedRevision
        self.expectedRowRevision = expectedRowRevision
    }
}

public struct SetServerWorkflowVisibilityRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let expectedRowRevision: Int64
    public let visible: Bool

    public init(expectedRevision: Int64, expectedRowRevision: Int64, visible: Bool) {
        self.expectedRevision = expectedRevision
        self.expectedRowRevision = expectedRowRevision
        self.visible = visible
    }
}

public struct ReorderServerWorkflowsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let featuredWorkflowIDs: [String]

    public init(expectedRevision: Int64, featuredWorkflowIDs: [String]) {
        self.expectedRevision = expectedRevision
        self.featuredWorkflowIDs = featuredWorkflowIDs
    }
}

public struct UpdateServerWorkflowPreferencesRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let includeSessionCleanupGuidance: Bool

    public init(expectedRevision: Int64, includeSessionCleanupGuidance: Bool) {
        self.expectedRevision = expectedRevision
        self.includeSessionCleanupGuidance = includeSessionCleanupGuidance
    }
}

public struct ReloadServerWorkflowsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64

    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }
}
