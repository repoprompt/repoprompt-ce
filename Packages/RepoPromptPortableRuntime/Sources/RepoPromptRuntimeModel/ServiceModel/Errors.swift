import Foundation

public enum ServiceErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request", internalAuthFailed = "internal_auth_failed", authorizationDecisionRejected = "authorization_decision_rejected", notFound = "not_found", staleRevision = "stale_revision", controllerChanged = "controller_changed", interactionSettled = "interaction_settled", idempotencyConflict = "idempotency_conflict", runAlreadyActive = "run_already_active", cursorExpired = "cursor_expired", resourceDeleted = "resource_deleted", resourceOwnerMismatch = "resource_owner_mismatch", resourceContextMismatch = "resource_context_mismatch", expiredResource = "expired_resource", providerUnavailable = "provider_unavailable", capabilityMissing = "capability_missing", rootUnauthorized = "root_unauthorized", resumeUnsupported = "resume_unsupported", worktreeConflict = "worktree_conflict", rateLimited = "rate_limited", dependencyUnavailable = "dependency_unavailable", internalFailure = "internal_failure", quiescing, persistenceUnavailable = "persistence_unavailable", migrationRequired = "migration_required", forwardSchemaUnsupported = "forward_schema_unsupported", authorityHostConflict = "authority_host_conflict", authorityPurposeMismatch = "authority_purpose_mismatch", namespacePurposeMismatch = "namespace_purpose_mismatch", serviceDraining = "service_draining", staleCapability = "stale_capability", operationReconciling = "operation_reconciling", backupRequired = "backup_required", idempotencyRequired = "idempotency_required"
}

public struct ServiceAPIError: Error, Codable, Sendable {
    public let schemaVersion: Int
    public let code: ServiceErrorCode
    public let message: String
    public let requestID: UUID
    public let retryable: Bool
    public let currentRevision: Int64?
    public let cursor: ServiceCursor?

    public init(code: ServiceErrorCode, message: String, requestID: UUID = UUID(), retryable: Bool = false, currentRevision: Int64? = nil, cursor: ServiceCursor? = nil) {
        schemaVersion = 1
        self.code = code
        self.message = message
        self.requestID = requestID
        self.retryable = retryable
        self.currentRevision = currentRevision
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case code
        case message
        case requestID = "requestId"
        case retryable
        case currentRevision
        case cursor
    }
}

public struct ServiceCapabilities: Codable, Sendable {
    public let protocolMinimum: Int
    public let protocolMaximum: Int
    public let schemaVersion: Int
    public let storeID: UUID
    public let replayFloor: Int64
    public let providers: [ProviderKind]
    public let eventTypes: [EventType]
    public init(protocolMinimum: Int, protocolMaximum: Int, schemaVersion: Int, storeID: UUID, replayFloor: Int64, providers: [ProviderKind], eventTypes: [EventType]) {
        self.protocolMinimum = protocolMinimum
        self.protocolMaximum = protocolMaximum
        self.schemaVersion = schemaVersion
        self.storeID = storeID
        self.replayFloor = replayFloor
        self.providers = providers
        self.eventTypes = eventTypes
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMinimum
        case protocolMaximum
        case schemaVersion
        case storeID = "storeId"
        case replayFloor
        case providers
        case eventTypes
    }
}
