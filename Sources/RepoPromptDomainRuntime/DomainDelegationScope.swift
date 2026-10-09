import Foundation

// Delegation scopes: durable, user-granted authority for one overseer Agent session to act on many
// sessions without per-item prompts.
//
// A scope sits **beside** oversight links rather than replacing them. Links stay a per-pair transport
// (cursors, passive notices, Auto-wake); a scope is the authority to act across its members. Scope
// authority is an *input* to the existing owners (link authority, passive reducer, claim/receipt,
// wake coordinator); it never takes their ownership. See
// `docs/architecture/agent-session-oversight-auto-wake.md`, "Delegation scopes".
//
// Everything in this file is AppKit-free value vocabulary. Decisions live in
// `DomainDelegationScopeAuthority` and `DomainAgentSessionOperationAuthorizer`.

// MARK: - Capabilities

/// One delegable capability. The set is closed: anything not representable here is human-only.
package enum DomainDelegationScopeCapability: String, CaseIterable, Codable, Hashable, Sendable {
    /// Inventory, search, poll/wait/read across members.
    case observe
    /// Rename, pin/unpin/reorder, group, archive/unarchive.
    case organize
    /// Send, steer, respond, stop, compact, set model/effort.
    case control
    /// Link/unlink among members, re-parent within scope, release.
    case restructure
    /// Start sessions and lanes, fork, and create nested overseers with attenuated sub-scopes.
    case spawn
    /// Create/bind/unbind worktrees for members and merge preview.
    case worktree
    /// Bulk retire and worktree release. Always routed through a batch confirmation card.
    case destructive

    /// The only capabilities an `.allSessions` scope may hold (design §6 default 2).
    package static let allSessionsPermitted: Set<Self> = [.observe, .organize, .restructure]

    /// "Manage this tree": everything except `destructive`.
    package static let manageTreePreset: Set<Self> = Set(allCases).subtracting([.destructive])
    /// "Organize everything" (`.allSessions`).
    package static let organizeEverythingPreset: Set<Self> = allSessionsPermitted
    /// "Full".
    package static let fullPreset: Set<Self> = Set(allCases)
}

/// Actions that are never grantable through any scope, preset, or attenuation.
///
/// None of these maps to a `DomainDelegationScopeCapability`, so no scope can carry them. The
/// operation authorizer additionally refuses the scope basis for the existing operations that
/// perform them (for example `agent_manage.cleanup_sessions`, which deletes sessions).
package enum DomainDelegationScopeHumanOnlyAction: String, CaseIterable, Hashable, Sendable {
    case deleteSession = "delete_session"
    case removeWorktree = "remove_worktree"
    case pruneWorktree = "prune_worktree"
    case apiKeysAndProviders = "api_keys_and_providers"
    case providerPermissionModes = "provider_permission_modes"
    case mcpClientApprovals = "mcp_client_approvals"
    case mcpServerControl = "mcp_server_control"
    case appSettingsWrites = "app_settings_writes"
    case appQuitOrUpdate = "app_quit_or_update"
    /// The Agent Mode handoff-instructions *setting*. Reading a session's handoff transcript
    /// (`agent_manage.extract_handoff`) is an ordinary `observe` read, not this action.
    case handoffInstructions = "handoff_instructions"

    /// Always false. Present so call sites and tests state the rule rather than imply it.
    package var isGrantable: Bool {
        false
    }
}

// MARK: - Kind

/// What a scope covers. Membership is never taken from tool arguments; the app presents a
/// `DomainDelegationScopeMembershipProof` computed from persisted provenance.
package enum DomainDelegationScopeKind: Hashable, Sendable {
    /// The root plus every session whose organizational parent chain reaches it.
    case tree(rootSessionID: UUID)
    /// Every session in one workspace.
    case workspace(workspaceID: UUID)
    /// Every session the user owns. Restricted to `allSessionsPermitted` capabilities.
    case allSessions

    package var label: String {
        switch self {
        case .tree: "tree"
        case .workspace: "workspace"
        case .allSessions: "all_sessions"
        }
    }
}

extension DomainDelegationScopeKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case rootSessionID = "root_session_id"
        case workspaceID = "workspace_id"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "tree":
            self = try .tree(rootSessionID: container.decode(UUID.self, forKey: .rootSessionID))
        case "workspace":
            self = try .workspace(workspaceID: container.decode(UUID.self, forKey: .workspaceID))
        case "all_sessions":
            self = .allSessions
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delegation scope kind '\(other)'"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .type)
        switch self {
        case let .tree(rootSessionID):
            try container.encode(rootSessionID, forKey: .rootSessionID)
        case let .workspace(workspaceID):
            try container.encode(workspaceID, forKey: .workspaceID)
        case .allSessions:
            break
        }
    }
}

// MARK: - Guardrails

/// User-chosen limits. `nil` means unlimited for that guardrail.
///
/// Limits count the **whole** subtree: a parent's `maxLiveSessions` includes every live member of
/// every nested overseer's sub-scope.
package struct DomainDelegationScopeGuardrails: Codable, Hashable, Sendable {
    package static let defaultBulkConfirmationThreshold = 25

    package var maxLiveSessions: Int?
    package var maxDepth: Int?
    package var maxWorktrees: Int?
    package var expiresAt: Date?
    /// Reversible bulk operations affecting more items than this require a batch card.
    package var bulkConfirmationThreshold: Int

    package init(
        maxLiveSessions: Int? = nil,
        maxDepth: Int? = nil,
        maxWorktrees: Int? = nil,
        expiresAt: Date? = nil,
        bulkConfirmationThreshold: Int = DomainDelegationScopeGuardrails.defaultBulkConfirmationThreshold
    ) {
        self.maxLiveSessions = maxLiveSessions
        self.maxDepth = maxDepth
        self.maxWorktrees = maxWorktrees
        self.expiresAt = expiresAt
        self.bulkConfirmationThreshold = bulkConfirmationThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case maxLiveSessions = "max_live_sessions"
        case maxDepth = "max_depth"
        case maxWorktrees = "max_worktrees"
        case expiresAt = "expires_at"
        case bulkConfirmationThreshold = "bulk_confirmation_threshold"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxLiveSessions = try container.decodeIfPresent(Int.self, forKey: .maxLiveSessions)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        maxWorktrees = try container.decodeIfPresent(Int.self, forKey: .maxWorktrees)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        bulkConfirmationThreshold = try container.decodeIfPresent(Int.self, forKey: .bulkConfirmationThreshold)
            ?? Self.defaultBulkConfirmationThreshold
    }

    /// Structurally valid: every limit is non-negative and the card threshold is at least one.
    package var isWellFormed: Bool {
        [maxLiveSessions, maxDepth, maxWorktrees].allSatisfy { ($0 ?? 0) >= 0 }
            && bulkConfirmationThreshold >= 1
    }

    /// True when every limit is at least as strict as `parent`'s, and expiry is no later.
    ///
    /// An unlimited (`nil`) child limit is looser than any finite parent limit; an absent child
    /// expiry is later than any parent expiry.
    package func isNoLooserThan(_ parent: Self) -> Bool {
        func noLooser(_ child: Int?, _ parent: Int?) -> Bool {
            guard let parent else { return true }
            guard let child else { return false }
            return child <= parent
        }
        let expiryOK: Bool = {
            guard let parentExpiry = parent.expiresAt else { return true }
            guard let expiresAt else { return false }
            return expiresAt <= parentExpiry
        }()
        return noLooser(maxLiveSessions, parent.maxLiveSessions)
            && noLooser(maxDepth, parent.maxDepth)
            && noLooser(maxWorktrees, parent.maxWorktrees)
            && bulkConfirmationThreshold <= parent.bulkConfirmationThreshold
            && expiryOK
    }

    package func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Which guardrail a spawn or worktree operation exceeded.
package enum DomainDelegationScopeGuardrail: String, Codable, Hashable, Sendable {
    case maxLiveSessions = "max_live_sessions"
    case maxDepth = "max_depth"
    case maxWorktrees = "max_worktrees"
}

// MARK: - Durable grant and live record

/// How a scope came to exist. Scopes are created only by the user or by attenuation.
package enum DomainDelegationScopeOrigin: Hashable, Sendable {
    case user
    case attenuatedFrom(scopeID: UUID)

    package var parentScopeID: UUID? {
        guard case let .attenuatedFrom(scopeID) = self else { return nil }
        return scopeID
    }
}

extension DomainDelegationScopeOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case scopeID = "scope_id"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "user":
            self = .user
        case "attenuated":
            self = try .attenuatedFrom(scopeID: container.decode(UUID.self, forKey: .scopeID))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delegation scope origin '\(other)'"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .type)
        case let .attenuatedFrom(scopeID):
            try container.encode("attenuated", forKey: .type)
            try container.encode(scopeID, forKey: .scopeID)
        }
    }
}

/// The durable intent of one scope. Carries no generation: generations are process-local and a
/// launch reactivates every persisted grant under a fresh one.
package struct DomainDelegationScopeGrant: Codable, Hashable, Sendable {
    package let id: UUID
    package let granteeSessionID: UUID
    package let kind: DomainDelegationScopeKind
    package let capabilities: Set<DomainDelegationScopeCapability>
    package let guardrails: DomainDelegationScopeGuardrails
    package let origin: DomainDelegationScopeOrigin
    package let grantedAt: Date

    package init(
        id: UUID,
        granteeSessionID: UUID,
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails,
        origin: DomainDelegationScopeOrigin,
        grantedAt: Date
    ) {
        self.id = id
        self.granteeSessionID = granteeSessionID
        self.kind = kind
        self.capabilities = capabilities
        self.guardrails = guardrails
        self.origin = origin
        self.grantedAt = grantedAt
    }

    package var parentScopeID: UUID? {
        origin.parentScopeID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case granteeSessionID = "grantee_session_id"
        case kind
        case capabilities
        case guardrails
        case origin
        case grantedAt = "granted_at"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        granteeSessionID = try container.decode(UUID.self, forKey: .granteeSessionID)
        kind = try container.decode(DomainDelegationScopeKind.self, forKey: .kind)
        // Unknown capability strings fail the whole row rather than silently narrowing it, so a
        // newer file can never be half-understood into a different grant.
        capabilities = try Set(container.decode([DomainDelegationScopeCapability].self, forKey: .capabilities))
        guardrails = try container.decode(DomainDelegationScopeGuardrails.self, forKey: .guardrails)
        origin = try container.decode(DomainDelegationScopeOrigin.self, forKey: .origin)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(granteeSessionID, forKey: .granteeSessionID)
        try container.encode(kind, forKey: .kind)
        try container.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try container.encode(guardrails, forKey: .guardrails)
        try container.encode(origin, forKey: .origin)
        try container.encode(grantedAt, forKey: .grantedAt)
    }
}

/// Lifecycle of a live scope record.
package enum DomainDelegationScopeState: String, Hashable, Sendable {
    case active
    /// Revoked by the user, released by its grantee, or cascaded from a revoked ancestor.
    case revoked
    case expired
}

/// One scope as the authority currently holds it.
package struct DomainDelegationScopeRecord: Hashable, Sendable {
    package let grant: DomainDelegationScopeGrant
    /// Bumped on every state change. A presented generation that differs is stale.
    package let generation: UInt64
    package let state: DomainDelegationScopeState

    package init(grant: DomainDelegationScopeGrant, generation: UInt64, state: DomainDelegationScopeState) {
        self.grant = grant
        self.generation = generation
        self.state = state
    }

    package var id: UUID {
        grant.id
    }

    package var isActive: Bool {
        state == .active
    }
}

// MARK: - Membership and usage proofs

/// App-presented evidence that one target belongs to one scope.
///
/// The app projects it from persisted provenance (`parentSessionID`, `createdByOverseerSessionID`,
/// and later `organizationalParentID`) exactly as link leases are presented today. It is never
/// constructed from tool arguments.
package struct DomainDelegationScopeMembershipProof: Hashable, Sendable {
    package enum Basis: Hashable, Sendable {
        /// Organizational chain from the target (first) up to the tree root (last), inclusive.
        case treePath([UUID])
        /// The workspace the target currently belongs to.
        case workspace(UUID)
        /// The target is a session the user owns.
        case allSessions
    }

    package let scopeID: UUID
    package let targetSessionID: UUID
    package let basis: Basis

    package init(scopeID: UUID, targetSessionID: UUID, basis: Basis) {
        self.scopeID = scopeID
        self.targetSessionID = targetSessionID
        self.basis = basis
    }

    /// Depth below the tree root (root = 0). `nil` for non-tree bases.
    package var treeDepth: Int? {
        guard case let .treePath(path) = basis, !path.isEmpty else { return nil }
        return path.count - 1
    }
}

/// App-measured usage of one scope (whole subtree), presented for spawn/worktree guardrails.
package struct DomainDelegationScopeUsage: Hashable, Sendable {
    package let scopeID: UUID
    package let liveSessionCount: Int
    package let worktreeCount: Int
    /// For session-creating operations: the depth of the new session's organizational parent within
    /// this scope's tree (root = 0). `nil` when the scope is not a tree or the op creates no session.
    package let spawnParentDepth: Int?

    package init(scopeID: UUID, liveSessionCount: Int, worktreeCount: Int, spawnParentDepth: Int? = nil) {
        self.scopeID = scopeID
        self.liveSessionCount = liveSessionCount
        self.worktreeCount = worktreeCount
        self.spawnParentDepth = spawnParentDepth
    }
}

/// A user-approved batch card, bound to the exact scope generation, operation, item set, and key.
package struct DomainDelegationScopeConfirmation: Hashable, Sendable {
    package let confirmationID: UUID
    package let scopeID: UUID
    package let scopeGeneration: UInt64
    package let operation: DomainAgentSessionTargetOperation
    package let idempotencyKey: String
    /// The items the user left ticked. A real call may act on these and nothing else.
    package let approvedSessionIDs: Set<UUID>

    package init(
        confirmationID: UUID,
        scopeID: UUID,
        scopeGeneration: UInt64,
        operation: DomainAgentSessionTargetOperation,
        idempotencyKey: String,
        approvedSessionIDs: Set<UUID>
    ) {
        self.confirmationID = confirmationID
        self.scopeID = scopeID
        self.scopeGeneration = scopeGeneration
        self.operation = operation
        self.idempotencyKey = idempotencyKey
        self.approvedSessionIDs = approvedSessionIDs
    }
}

// MARK: - Lease

/// Proof issued by `DomainDelegationScopeAuthority` that one caller may exercise one capability on
/// one target under one live scope generation. Consumed by `DomainAgentSessionOperationAuthorizer`.
package struct DomainDelegationScopeLease: Hashable, Sendable {
    package let scopeID: UUID
    package let generation: UInt64
    package let capability: DomainDelegationScopeCapability
    package let granteeSessionID: UUID
    package let targetSessionID: UUID

    package init(
        scopeID: UUID,
        generation: UInt64,
        capability: DomainDelegationScopeCapability,
        granteeSessionID: UUID,
        targetSessionID: UUID
    ) {
        self.scopeID = scopeID
        self.generation = generation
        self.capability = capability
        self.granteeSessionID = granteeSessionID
        self.targetSessionID = targetSessionID
    }
}

// MARK: - Denials

/// Why a scope request or authorization failed.
///
/// Four cases carry stable, caller-visible codes (design §2.7). Every other case is diagnostic only:
/// callers must render it with the uniform "not found / not available" text so an Agent caller
/// cannot probe whether an unrelated session or scope exists.
package enum DomainDelegationScopeDenial: Error, Hashable, Sendable {
    // Caller-visible, recoverable.
    case capabilityMissing(DomainDelegationScopeCapability)
    case guardrailExceeded(guardrail: DomainDelegationScopeGuardrail, limit: Int, current: Int)
    case expired
    case confirmationRequired(reason: DomainDelegationScopeConfirmationReason)

    // Uniform (diagnostic only).
    case callerNotAgentSession
    case unknownScope
    case granteeMismatch
    case generationStale
    case membershipProofMissing
    case membershipProofInvalid
    case usageProofMissing
    case selfTarget
    case operationNotScopeAuthorizable
    case confirmationMismatch

    // Grant-time validation (user or attenuation requests).
    case capabilitiesEmpty
    case capabilityNotPermittedForKind(DomainDelegationScopeCapability)
    case guardrailsMalformed
    case expiryInPast
    case attenuationWidensCapabilities
    case attenuationLoosensGuardrails
    case attenuationRequiresTreeRootedAtGrantee
    case attenuationParentInactive

    /// Stable public code for the recoverable cases; `nil` means "render the uniform denial".
    package var publicCode: String? {
        switch self {
        case .capabilityMissing: "scope_capability_missing"
        case .guardrailExceeded: "scope_guardrail_exceeded"
        case .expired: "scope_expired"
        case .confirmationRequired: "confirmation_required"
        default: nil
        }
    }

    /// Diagnostic label. Never shown to an Agent caller for uniform cases.
    package var diagnosticLabel: String {
        switch self {
        case .capabilityMissing: "capability_missing"
        case .guardrailExceeded: "guardrail_exceeded"
        case .expired: "expired"
        case .confirmationRequired: "confirmation_required"
        case .callerNotAgentSession: "caller_not_agent_session"
        case .unknownScope: "unknown_scope"
        case .granteeMismatch: "grantee_mismatch"
        case .generationStale: "generation_stale"
        case .membershipProofMissing: "membership_proof_missing"
        case .membershipProofInvalid: "membership_proof_invalid"
        case .usageProofMissing: "usage_proof_missing"
        case .selfTarget: "self_target"
        case .operationNotScopeAuthorizable: "operation_not_scope_authorizable"
        case .confirmationMismatch: "confirmation_mismatch"
        case .capabilitiesEmpty: "capabilities_empty"
        case .capabilityNotPermittedForKind: "capability_not_permitted_for_kind"
        case .guardrailsMalformed: "guardrails_malformed"
        case .expiryInPast: "expiry_in_past"
        case .attenuationWidensCapabilities: "attenuation_widens_capabilities"
        case .attenuationLoosensGuardrails: "attenuation_loosens_guardrails"
        case .attenuationRequiresTreeRootedAtGrantee: "attenuation_requires_tree_rooted_at_grantee"
        case .attenuationParentInactive: "attenuation_parent_inactive"
        }
    }
}

/// Why an operation needs a batch confirmation card.
package enum DomainDelegationScopeConfirmationReason: String, Hashable, Sendable {
    /// Every `destructive` operation.
    case destructive
    /// Bringing sessions from outside the scope into it always needs the user's consent.
    case adoption
    /// A reversible operation affecting more items than the scope's threshold.
    case bulkThreshold = "bulk_threshold"
}
