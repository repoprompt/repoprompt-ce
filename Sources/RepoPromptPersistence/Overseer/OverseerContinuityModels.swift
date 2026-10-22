import Foundation

/// Continuity facts, never permission to dispatch an action. The app's exact live decision owner
/// authorizes; this repository records those decisions without replacing unrelated rows.
package enum OverseerContinuityKind: String, Codable {
    case scope, link, worktree
}

package struct OverseerContinuityRow: Codable, Equatable {
    package var kind: OverseerContinuityKind
    package var id: String
    package var parentID: String?
    package var ownerID: String?
    package var anchorID: String?
    package var workspaceID: String?
    package var capabilities: [String]
    package var expiresAt: Date?
    package var payload: Data
    package var terminal: Bool
    package var revision: Int64

    package init(
        kind: OverseerContinuityKind,
        id: String,
        parentID: String? = nil,
        ownerID: String? = nil,
        anchorID: String? = nil,
        workspaceID: String? = nil,
        capabilities: [String] = [],
        expiresAt: Date? = nil,
        payload: Data,
        terminal: Bool = false,
        revision: Int64 = 0
    ) {
        self.kind = kind
        self.id = id
        self.parentID = parentID
        self.ownerID = ownerID
        self.anchorID = anchorID
        self.workspaceID = workspaceID
        self.capabilities = capabilities.sorted()
        self.expiresAt = expiresAt
        self.payload = payload
        self.terminal = terminal
        self.revision = revision
    }
}

package enum OverseerContinuityMutation: Codable, Equatable {
    /// Immutable scope identity; a terminal ID can never be reused, including by an importer.
    case grant(OverseerContinuityRow)
    /// All descendants become terminal in the same transaction, including concurrent children.
    case revokeScope(String)
    /// Terminal evidence shares the revocation transaction; it never confers authority.
    case endScope(String, OverseerScopeEnding, original: OverseerContinuityRow?)
    /// A committed session deletion fences later legacy imports, including currently unloaded scopes.
    case deletedSession(String)
    case deletedSessionWithEvidence(String, OverseerScopeEnding)
    /// Explicit link assertion or ownership transition; expected revision is a compare-and-swap.
    case put(OverseerContinuityRow, expectedRevision: Int64?)
    case remove(kind: OverseerContinuityKind, id: String, expectedRevision: Int64)
}

/// Bounded, app-owned evidence. Unknown historical tombstones deliberately have no invented time.
package struct OverseerScopeEnding: Codable, Equatable {
    package enum Reason: String, Codable {
        case userRevoked = "user_revoked"
        case granteeReleased = "grantee_released"
        case sessionDeleted = "session_deleted"
        case expired
        case fullAccessDisabled = "full_access_disabled"
        case historicalUnknown = "historical_unknown"
        case fullAccessReconciled = "full_access_reconciled"

        package init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .historicalUnknown
        }
    }

    package enum DeletionOrigin: String, Codable {
        case unknown
        case mcpClient = "mcp_client"
        case userUI = "user_ui"
        case agentCleanup = "agent_cleanup"
        case automaticDiscard = "automatic_discard"
        case composeTabBatch = "compose_tab_batch"
    }

    package let deletionOrigin: DeletionOrigin?
    package let fileRemoved: Bool?
    package var initiator: String {
        if reason == .historicalUnknown { return "unknown" }
        if reason == .sessionDeleted {
            switch deletionOrigin {
            case .userUI: return "user"
            case .mcpClient: return actorSessionID == nil ? "mcp_client" : "agent"
            case .unknown, .composeTabBatch: return "unknown"
            case .agentCleanup: return "agent"
            case .automaticDiscard: return "system"
            case nil: return "unknown"
            }
        }
        if reason == .userRevoked || reason == .fullAccessDisabled { return "user" }
        return reason == .granteeReleased ? "grantee" : "system"
    }

    package let reason: Reason
    package let at: Date?
    package let actorSessionID: UUID?
    package let originatingScopeID: UUID?
    package let originatingSessionID: UUID?

    package init(reason: Reason, at: Date? = nil, actorSessionID: UUID? = nil, originatingScopeID: UUID? = nil, originatingSessionID: UUID? = nil, deletionOrigin: DeletionOrigin? = nil, fileRemoved: Bool? = nil) {
        self.deletionOrigin = deletionOrigin
        self.fileRemoved = fileRemoved
        self.reason = reason
        self.at = at
        self.actorSessionID = actorSessionID
        self.originatingScopeID = originatingScopeID
        self.originatingSessionID = originatingSessionID
    }
}

/// Only terminal scope rows use this envelope. Live grant bytes and the database schema stay unchanged.
package struct OverseerEndedScope: Codable, Equatable {
    package let ending: OverseerScopeEnding
    package let originalPayload: Data
    package init(ending: OverseerScopeEnding, originalPayload: Data) {
        self.ending = ending
        self.originalPayload = originalPayload
    }
}

package struct OverseerContinuityReceipt: Codable, Equatable {
    package let operationID: UUID
    package let revision: Int64
    package let affectedIDs: [String]
    package var replayed: Bool
}

package struct OverseerLegacySource: Equatable {
    package let id: String
    package let path: String
    package let digest: String
    package let bytes: Data
    package let reason: String
    package init(id: String, path: String, digest: String, bytes: Data, reason: String) {
        self.id = id
        self.path = path
        self.digest = digest
        self.bytes = bytes
        self.reason = reason
    }
}

package struct OverseerLegacyRow {
    package let ordinal: Int
    package let raw: Data
    package let mutation: OverseerContinuityMutation?
    package let outcome: String
    package init(ordinal: Int, raw: Data, mutation: OverseerContinuityMutation?, outcome: String) {
        self.ordinal = ordinal
        self.raw = raw
        self.mutation = mutation
        self.outcome = outcome
    }
}

package enum OverseerContinuityError: Error, Equatable {
    case incompatibleSchema(Int)
    case profileMismatch
    case invalidRecord
    case invalidTransition
    case operationConflict
    case revisionConflict
    case terminalIdentity
    case parentUnavailable
    case unsafeLocation
    case unsupportedEngineSettings
    case writerBusy

    /// Replaying these exact bytes can never repair this operation. Keep its failed outcome,
    /// but let unrelated later decisions reach the store rather than poisoning the queue head.
    package var isPermanentTransitionFailure: Bool {
        switch self {
        case .operationConflict, .revisionConflict, .terminalIdentity, .parentUnavailable, .invalidTransition: true
        default: false
        }
    }
}
