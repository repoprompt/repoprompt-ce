import Foundation

public enum ServerSettingsDomain: String, Codable, CaseIterable, Sendable {
    case agentModels
    case subagentPermissions
    case directAgentPermissions
    case workspaceApprovals
    case mcpDisabledTools
    case mcpShowModelPresets
    case contextBuilder
    case mcpModelPresets
    case advanced
    case selectionPresets
    case workflowRepository
}

public struct SettingsMutationAttribution: Codable, Hashable, Sendable {
    public let actorID: String
    public let actorLabel: String
    public let channel: String

    public init(actorID: String, actorLabel: String, channel: String) {
        self.actorID = actorID
        self.actorLabel = actorLabel
        self.channel = channel
    }
}

public struct ServerSettingsAuditMutation: Codable, Hashable, Sendable {
    public let operation: String
    public let attribution: SettingsMutationAttribution
    public let payloadDigest: String

    public init(operation: String, attribution: SettingsMutationAttribution, payloadDigest: String) {
        self.operation = operation
        self.attribution = attribution
        self.payloadDigest = payloadDigest
    }
}

public struct ServerSettingsAuditRecord: Codable, Hashable, Sendable {
    public let auditID: UUID
    public let domain: ServerSettingsDomain
    public let scopeID: String
    public let priorRevision: Int64
    public let newRevision: Int64
    public let operation: String
    public let actorID: String
    public let actorLabel: String
    public let channel: String
    public let payloadDigest: String
    public let createdAt: Date

    public init(
        auditID: UUID,
        domain: ServerSettingsDomain,
        scopeID: String,
        priorRevision: Int64,
        newRevision: Int64,
        operation: String,
        actorID: String,
        actorLabel: String,
        channel: String,
        payloadDigest: String,
        createdAt: Date
    ) {
        self.auditID = auditID
        self.domain = domain
        self.scopeID = scopeID
        self.priorRevision = priorRevision
        self.newRevision = newRevision
        self.operation = operation
        self.actorID = actorID
        self.actorLabel = actorLabel
        self.channel = channel
        self.payloadDigest = payloadDigest
        self.createdAt = createdAt
    }
}
