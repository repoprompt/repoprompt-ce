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
    /// A committed session deletion fences later legacy imports, including currently unloaded scopes.
    case deletedSession(String)
    /// Explicit link assertion or ownership transition; expected revision is a compare-and-swap.
    case put(OverseerContinuityRow, expectedRevision: Int64?)
    case remove(kind: OverseerContinuityKind, id: String, expectedRevision: Int64)
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
