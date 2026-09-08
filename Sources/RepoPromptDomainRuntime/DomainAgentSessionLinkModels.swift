import Foundation

// MARK: - Endpoint identity

/// Exact live endpoint incarnation for one side of an oversight link.
///
/// This mirrors the app-owned `AgentSessionLifecycleAuthority.Identity` without importing any
/// feature-layer or UI type. `persistentBindingGeneration` is deliberately a `UUID?` rather than a
/// counter so an unexpected `nil` fails closed instead of comparing equal to another unbound
/// endpoint.
package struct DomainAgentSessionLinkEndpointIdentity: Hashable, Sendable {
    package let windowID: Int
    package let workspaceID: UUID
    package let tabID: UUID
    package let sessionID: UUID
    package let persistentBindingGeneration: UUID?
    package let bindingTransitionGeneration: UInt64

    package init(
        windowID: Int,
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID,
        persistentBindingGeneration: UUID?,
        bindingTransitionGeneration: UInt64
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
    }

    /// Both endpoints must carry a resolved persistent binding before a link may be reserved.
    package var hasResolvedPersistentBinding: Bool {
        persistentBindingGeneration != nil
    }
}

// MARK: - Capabilities and grants

package enum DomainAgentSessionLinkCapability: String, CaseIterable, Hashable, Sendable {
    case poll
    case wait
    case read
    case sendWhenIdle = "send_when_idle"

    /// V1 capabilities are fixed and never inferred from role or parentage.
    package static let version1: Set<DomainAgentSessionLinkCapability> = [
        .poll,
        .wait,
        .read,
        .sendWhenIdle,
    ]
}

package struct DomainAgentSessionLinkGrant: Identifiable, Hashable, Sendable {
    package let id: UUID
    package let generation: UInt64
    package let observer: DomainAgentSessionLinkEndpointIdentity
    package let target: DomainAgentSessionLinkEndpointIdentity
    package let createdAt: Date
    package let capabilities: Set<DomainAgentSessionLinkCapability>

    package init(
        id: UUID,
        generation: UInt64,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        createdAt: Date,
        capabilities: Set<DomainAgentSessionLinkCapability>
    ) {
        self.id = id
        self.generation = generation
        self.observer = observer
        self.target = target
        self.createdAt = createdAt
        self.capabilities = capabilities
    }
}

/// Stable identity of one link generation. A revoked reference never resurrects.
package struct DomainAgentSessionLinkReference: Hashable, Sendable {
    package let linkID: UUID
    package let generation: UInt64

    package init(linkID: UUID, generation: UInt64) {
        self.linkID = linkID
        self.generation = generation
    }
}

// MARK: - Sanitized observation snapshot

package enum DomainAgentSessionLinkStatus: String, CaseIterable, Hashable, Sendable {
    case idle
    case running
    case awaitingUser = "awaiting_user"
}

package enum DomainAgentSessionLinkPendingInteractionKind: String, CaseIterable, Hashable, Sendable {
    case approval
    case question
    case input
    case permission
    case review
}

/// Byte budgets for every agent-facing textual value the authority accepts or emits.
package enum DomainAgentSessionLinkTextBudget {
    package static let displayNameMaxBytes = 120
    package static let assistantPreviewMaxBytes = 280
    package static let waitingOnSummaryMaxBytes = 280
    package static let idempotencyKeyMaxBytes = 200
    package static let messageDigestMaxBytes = 200
    package static let messageMaxBytes = 16_000

    /// Collapses control characters/whitespace runs and caps the result at `maxBytes` UTF-8 bytes
    /// without ever splitting a Unicode scalar.
    package static func normalized(_ text: String?, maxBytes: Int) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .unicodeScalars
            .map { CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control ? " " : Character($0) }
            .reduce(into: "") { partial, character in
                if character == " ", partial.last == " " { return }
                partial.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return truncatedUTF8(collapsed, maxBytes: maxBytes)
    }

    /// Truncates to at most `maxBytes` UTF-8 bytes on a Character boundary.
    package static func truncatedUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > maxBytes { break }
            result.append(character)
            used += width
        }
        return result
    }

    package static func utf8ByteCount(_ text: String) -> Int {
        text.utf8.count
    }
}

/// The only target state the authority ever publishes to an observer.
///
/// It intentionally carries no interaction identifiers or bodies, no raw provider events, no run
/// identifiers, no filesystem/worktree paths, and no diagnostics.
package struct DomainAgentSessionWaitingOn: Hashable, Sendable {
    package let summary: String
    package let declaredAt: Date

    package init?(summary: String, declaredAt: Date) {
        guard let normalized = DomainAgentSessionLinkTextBudget.normalized(
            summary,
            maxBytes: DomainAgentSessionLinkTextBudget.waitingOnSummaryMaxBytes
        ) else { return nil }
        self.summary = normalized
        self.declaredAt = declaredAt
    }
}

package struct DomainAgentSessionObservationSnapshot: Hashable, Sendable {
    package let sessionID: UUID
    package let displayName: String?
    package let providerDisplayName: String?
    package let status: DomainAgentSessionLinkStatus
    package let idleForSend: Bool
    package let idleSince: Date?
    package let waitingOn: DomainAgentSessionWaitingOn?
    package let pendingInteractionKind: DomainAgentSessionLinkPendingInteractionKind?
    package let latestVisibleAssistantPreview: String?
    package let visibleRowCount: Int
    package let lastActivityAt: Date

    package var hasPendingInteraction: Bool {
        pendingInteractionKind != nil
    }

    /// Normalizes and byte-caps every textual field at construction so a buggy bridge cannot publish
    /// oversized or control-character-bearing agent-facing values.
    package init(
        sessionID: UUID,
        displayName: String?,
        providerDisplayName: String?,
        status: DomainAgentSessionLinkStatus,
        idleForSend: Bool,
        idleSince: Date? = nil,
        waitingOn: DomainAgentSessionWaitingOn? = nil,
        pendingInteractionKind: DomainAgentSessionLinkPendingInteractionKind?,
        latestVisibleAssistantPreview: String?,
        visibleRowCount: Int,
        lastActivityAt: Date
    ) {
        self.sessionID = sessionID
        self.displayName = DomainAgentSessionLinkTextBudget.normalized(
            displayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.providerDisplayName = DomainAgentSessionLinkTextBudget.normalized(
            providerDisplayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.status = status
        // A target that is not idle can never be admitted for send, regardless of what the bridge claims.
        self.idleForSend = idleForSend && status == .idle && pendingInteractionKind == nil
        self.idleSince = status == .idle && pendingInteractionKind == nil ? idleSince : nil
        self.waitingOn = waitingOn
        self.pendingInteractionKind = pendingInteractionKind
        self.latestVisibleAssistantPreview = DomainAgentSessionLinkTextBudget.normalized(
            latestVisibleAssistantPreview,
            maxBytes: DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
        )
        self.visibleRowCount = max(0, visibleRowCount)
        self.lastActivityAt = lastActivityAt
    }
}

/// One authorized target row: sanitized snapshot plus the successor wait cursor.
package struct DomainAgentSessionLinkTargetState: Hashable, Sendable {
    package let sessionID: UUID
    package let linkID: UUID
    package let linkGeneration: UInt64
    package let snapshot: DomainAgentSessionObservationSnapshot
    package let changeSequence: UInt64
    package let waitCursor: String

    package init(
        sessionID: UUID,
        linkID: UUID,
        linkGeneration: UInt64,
        snapshot: DomainAgentSessionObservationSnapshot,
        changeSequence: UInt64,
        waitCursor: String
    ) {
        self.sessionID = sessionID
        self.linkID = linkID
        self.linkGeneration = linkGeneration
        self.snapshot = snapshot
        self.changeSequence = changeSequence
        self.waitCursor = waitCursor
    }
}

// MARK: - Inventory

package struct DomainAgentSessionLinkInventoryItem: Hashable, Sendable {
    package let linkID: UUID
    package let generation: UInt64
    package let observerSessionID: UUID
    package let targetSessionID: UUID
    package let displayName: String?
    package let capabilities: Set<DomainAgentSessionLinkCapability>

    package init(
        linkID: UUID,
        generation: UInt64,
        observerSessionID: UUID,
        targetSessionID: UUID,
        displayName: String?,
        capabilities: Set<DomainAgentSessionLinkCapability>
    ) {
        self.linkID = linkID
        self.generation = generation
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.displayName = DomainAgentSessionLinkTextBudget.normalized(
            displayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.capabilities = capabilities
    }

    package var capabilityNames: [String] {
        capabilities.map(\.rawValue).sorted()
    }
}

/// Deterministically ordered inventory for one endpoint.
package struct DomainAgentSessionLinkInventory: Hashable, Sendable {
    package let sessionID: UUID
    /// Advances only when this observer's grant membership changes.
    package let linkSetRevision: UInt64
    package let authorityRevision: UInt64
    package let items: [DomainAgentSessionLinkInventoryItem]

    package init(
        sessionID: UUID,
        linkSetRevision: UInt64,
        authorityRevision: UInt64,
        items: [DomainAgentSessionLinkInventoryItem]
    ) {
        self.sessionID = sessionID
        self.linkSetRevision = linkSetRevision
        self.authorityRevision = authorityRevision
        self.items = items
    }

    package var isEmpty: Bool { items.isEmpty }
}

// MARK: - Revocation

package enum DomainAgentSessionLinkRevocationReason: String, CaseIterable, Hashable, Sendable {
    case userRequested = "user_requested"
    case observerEndpointInvalidated = "observer_endpoint_invalidated"
    case targetEndpointInvalidated = "target_endpoint_invalidated"
    case observerIdentityDrift = "observer_identity_drift"
    /// The observing session is still the same incarnation but permanently lost the capability to
    /// oversee (external MCP control attached, or role/tool policy now denies it).
    case observerNoLongerEligible = "observer_no_longer_eligible"
    case targetIdentityDrift = "target_identity_drift"
    case tabClosed = "tab_closed"
    case windowClosed = "window_closed"
    case workspaceSwitched = "workspace_switched"
    case bindingChanged = "binding_changed"
    case sessionDeleted = "session_deleted"
    case activationSeedFailed = "activation_seed_failed"
    case runtimeShutdown = "runtime_shutdown"
    case appTerminating = "app_terminating"
}

package struct DomainAgentSessionLinkRevocationNotice: Hashable, Sendable {
    package let linkID: UUID
    package let generation: UInt64
    package let observerSessionID: UUID
    package let targetSessionID: UUID
    /// Exact incarnations the revoked grant joined.
    ///
    /// Carried on the notice because a revoked link has no record left to look them up in, and a
    /// host that fell back to resolving either side by session UUID could label this ending with a
    /// duplicate incarnation's name. These are host-side UI inputs only; no agent-facing payload
    /// serializes them.
    package let observerEndpoint: DomainAgentSessionLinkEndpointIdentity?
    package let targetEndpoint: DomainAgentSessionLinkEndpointIdentity?
    package let targetDisplayName: String?
    package let observerDisplayName: String?
    package let reason: DomainAgentSessionLinkRevocationReason
    package let revokedAt: Date

    package init(
        linkID: UUID,
        generation: UInt64,
        observerSessionID: UUID,
        targetSessionID: UUID,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        targetDisplayName: String?,
        observerDisplayName: String?,
        reason: DomainAgentSessionLinkRevocationReason,
        revokedAt: Date
    ) {
        self.linkID = linkID
        self.generation = generation
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.observerEndpoint = observerEndpoint
        self.targetEndpoint = targetEndpoint
        self.targetDisplayName = DomainAgentSessionLinkTextBudget.normalized(
            targetDisplayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.observerDisplayName = DomainAgentSessionLinkTextBudget.normalized(
            observerDisplayName,
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
        self.reason = reason
        self.revokedAt = revokedAt
    }
}

// MARK: - Endpoint projection inputs

/// Everything one exact endpoint incarnation's host-side projection needs, read in a single
/// authority turn.
///
/// Three separate reads (outbound inventory, inbound inventory, notices) could interleave with a
/// membership change and render rows, agent-facing inventory, and notices from different snapshots.
/// The peer maps exist because an inventory item carries only session UUIDs: a session UUID can be
/// live in more than one window at once, so a host that resolved the other side of a link by UUID
/// would render — and attribute — the wrong incarnation. Available target-menu choices also need
/// the authority's exact current outbound observers from that same membership snapshot.
package struct DomainAgentSessionLinkEndpointProjectionInputs: Equatable, Sendable {
    /// Grants where this exact incarnation is the observer.
    package let outbound: DomainAgentSessionLinkInventory
    /// Grants where this exact incarnation is the target.
    package let inbound: DomainAgentSessionLinkInventory
    /// Exact target incarnation of every `outbound` grant, keyed by link ID.
    package let outboundTargetEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity]
    /// Exact observer incarnation of every `inbound` grant, keyed by link ID.
    package let inboundObserverEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity]
    /// Exact endpoint incarnations that currently hold at least one outbound grant.
    package let activeOutboundObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    /// Revocation notices recorded for this exact incarnation. A different incarnation of the same
    /// session UUID never sees them.
    package let notices: [DomainAgentSessionLinkRevocationNotice]

    package init(
        outbound: DomainAgentSessionLinkInventory,
        inbound: DomainAgentSessionLinkInventory,
        outboundTargetEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity],
        inboundObserverEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity],
        activeOutboundObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>,
        notices: [DomainAgentSessionLinkRevocationNotice]
    ) {
        self.outbound = outbound
        self.inbound = inbound
        self.outboundTargetEndpoints = outboundTargetEndpoints
        self.inboundObserverEndpoints = inboundObserverEndpoints
        self.activeOutboundObserverEndpoints = activeOutboundObserverEndpoints
        self.notices = notices
    }
}

// MARK: - Errors

package enum DomainAgentSessionLinkError: String, Error, Equatable, Sendable {
    case noActiveLink = "no_active_link"
    case capabilityDenied = "capability_denied"
    case linkRevoked = "link_revoked"
    case endpointInvalidated = "endpoint_invalidated"
    case runtimeShuttingDown = "runtime_shutting_down"
    case waitAlreadyPending = "wait_already_pending"
    case cursorExpired = "cursor_expired"
    case idempotencyConflict = "idempotency_conflict"
    case deliveryLedgerFull = "delivery_ledger_full"
    case sendAlreadyInProgress = "send_already_in_progress"
    case unknownReservation = "unknown_reservation"
    case invalidRequest = "invalid_request"
}

// MARK: - Reservation and activation

/// A reserved-but-not-yet-active link. The app bridge must seed an initial snapshot before the link
/// becomes visible to any tool operation, so `poll` can never race an uninitialized active link.
package struct DomainAgentSessionLinkPendingReservation: Hashable, Sendable {
    package let linkID: UUID
    package let generation: UInt64
    package let observer: DomainAgentSessionLinkEndpointIdentity
    package let target: DomainAgentSessionLinkEndpointIdentity
    package let capabilities: Set<DomainAgentSessionLinkCapability>
    /// Whether activation must preserve an already-active outbound relationship for this observer.
    ///
    /// Sidebar target-management uses this to prevent a stale available-choice projection from
    /// creating an observer's first link after that exact endpoint stopped being an overseer. The
    /// authority rechecks the predicate at activation, in the same actor turn that would insert the
    /// new grant, so revoking the previous final link cannot race this precondition.
    package let requiresExistingOutboundLink: Bool
    /// Advisory hint that this reservation is currently expected to install target observation.
    ///
    /// This is **not** authoritative. A reservation elected here can still be abandoned or
    /// lifecycle-invalidated before it activates, in which case a sibling reservation becomes the
    /// real installer. Only `DomainAgentSessionLinkActivation.installsTargetObservation`, decided at
    /// the activation that actually creates the target record, determines ownership of the
    /// observation and its serial publication chain.
    package let provisionallyInstallsTargetObservation: Bool
    /// Authority revision at reservation time, so a stale lifecycle observation cannot invalidate a
    /// reservation created after that observation was taken.
    package let reservedAtAuthorityRevision: UInt64

    package init(
        linkID: UUID,
        generation: UInt64,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        capabilities: Set<DomainAgentSessionLinkCapability>,
        requiresExistingOutboundLink: Bool,
        provisionallyInstallsTargetObservation: Bool,
        reservedAtAuthorityRevision: UInt64
    ) {
        self.linkID = linkID
        self.generation = generation
        self.observer = observer
        self.target = target
        self.capabilities = capabilities
        self.requiresExistingOutboundLink = requiresExistingOutboundLink
        self.provisionallyInstallsTargetObservation = provisionallyInstallsTargetObservation
        self.reservedAtAuthorityRevision = reservedAtAuthorityRevision
    }
}

/// Authoritative outcome of a successful activation.
///
/// `installsTargetObservation` is decided by the activation that actually creates the target record,
/// so the role survives abandonment or lifecycle invalidation of an earlier elected reservation. The
/// app bridge must own the target observation and its serial publication chain if and only if this
/// flag is true.
package struct DomainAgentSessionLinkActivation: Hashable, Sendable {
    package let grant: DomainAgentSessionLinkGrant
    package let installsTargetObservation: Bool
    /// The observer's complete outbound inventory *as of this activation*, for that exact
    /// incarnation.
    ///
    /// Returned rather than left for the caller to re-read, for the same reason
    /// `reserved`'s `collateralRevocations` is: the mutation is the only place that knows the answer
    /// without a race. Activation makes the grant live and callable while the caller is still
    /// suspended on the actor hop, so any inventory the caller fetches afterwards is fetched *after*
    /// a window in which its published projection already disagreed with authoritative membership.
    /// Handing back the post-mutation value lets the caller republish without re-deriving it.
    package let observerInventory: DomainAgentSessionLinkInventory

    package init(
        grant: DomainAgentSessionLinkGrant,
        installsTargetObservation: Bool,
        observerInventory: DomainAgentSessionLinkInventory
    ) {
        self.grant = grant
        self.installsTargetObservation = installsTargetObservation
        self.observerInventory = observerInventory
    }
}

package enum DomainAgentSessionLinkReservationDisposition: Equatable, Sendable {
    /// `collateralRevocations` carries links the reservation itself revoked — today, a stale target
    /// incarnation's inbound links. They are returned rather than left to the change feed alone
    /// because that feed is lossy by design (`bufferingNewest`), and these revocations belong to
    /// *other* observers whose UI rows and advertised tool set the caller must still repair.
    case reserved(
        DomainAgentSessionLinkPendingReservation,
        collateralRevocations: [DomainAgentSessionLinkRevocationNotice]
    )
    /// The exact endpoint pair already has an active link; the caller must not create a second one.
    case existing(DomainAgentSessionLinkGrant)
    case rejected(DomainAgentSessionLinkReservationRejection)
}

package enum DomainAgentSessionLinkReservationRejection: String, Equatable, Sendable {
    case shuttingDown = "shutting_down"
    case selfMonitor = "self_monitor"
    case observerBindingUnresolved = "observer_binding_unresolved"
    case targetBindingUnresolved = "target_binding_unresolved"
    case reservationAlreadyPending = "reservation_already_pending"
    case observerHasNoActiveOutboundLink = "observer_has_no_active_outbound_link"
}

package enum DomainAgentSessionLinkActivationDisposition: Equatable, Sendable {
    case activated(DomainAgentSessionLinkActivation)
    case rejected(DomainAgentSessionLinkActivationRejection)

    package var grant: DomainAgentSessionLinkGrant? {
        guard case let .activated(activation) = self else { return nil }
        return activation.grant
    }

    package var installsTargetObservation: Bool {
        guard case let .activated(activation) = self else { return false }
        return activation.installsTargetObservation
    }
}

package enum DomainAgentSessionLinkActivationRejection: String, Equatable, Sendable {
    case shuttingDown = "shutting_down"
    case unknownReservation = "unknown_reservation"
    case endpointDrift = "endpoint_drift"
    case snapshotSessionMismatch = "snapshot_session_mismatch"
    case observerHasNoActiveOutboundLink = "observer_has_no_active_outbound_link"
}

package enum DomainAgentSessionLinkRevocationDisposition: Equatable, Sendable {
    case revoked(DomainAgentSessionLinkRevocationNotice)
    /// The exact link generation was already terminal, or a newer generation now owns the pair.
    case notFound
}

// MARK: - Target publication

package enum DomainAgentSessionLinkTargetChangeDisposition: Equatable, Sendable {
    case accepted(changeSequence: UInt64)
    case unchanged(changeSequence: UInt64)
    /// A late or out-of-order publication that must never regress the high-water mark.
    case stale(currentSourcePublicationSequence: UInt64)
    case unknownTarget
    case shuttingDown
}

// MARK: - Leases

/// Short-lived authorization proof for one operation on one target.
///
/// A lease is not durable authority: the caller must still revalidate both live endpoint identities
/// before it reads or mutates target state.
package struct DomainAgentSessionLinkLease: Hashable, Sendable {
    package let leaseID: UUID
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let linkID: UUID
    package let linkGeneration: UInt64
    package let capability: DomainAgentSessionLinkCapability
    package let observer: DomainAgentSessionLinkEndpointIdentity
    package let target: DomainAgentSessionLinkEndpointIdentity
    package let issuedAt: Date

    package init(
        leaseID: UUID,
        runtimeID: UUID,
        runtimeGeneration: UInt64,
        linkID: UUID,
        linkGeneration: UInt64,
        capability: DomainAgentSessionLinkCapability,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        issuedAt: Date
    ) {
        self.leaseID = leaseID
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.linkID = linkID
        self.linkGeneration = linkGeneration
        self.capability = capability
        self.observer = observer
        self.target = target
        self.issuedAt = issuedAt
    }

    package var reference: DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: linkID, generation: linkGeneration)
    }
}

// MARK: - Wait

package enum DomainAgentSessionLinkWaitPredicate: String, CaseIterable, Hashable, Sendable {
    case change
    /// Mirrors the published `status`/`pending_interaction_kind` pair: the target stopped and is not
    /// holding an interaction. It does **not** promise the target will accept a send.
    case idle
    /// Mirrors the published `idleForSend`. Strictly stronger than `idle`, because a snapshot only
    /// reports `idleForSend` while it is also status-idle with no pending interaction.
    ///
    /// This exists because `idle` alone is not the send precondition: a target can be status-idle
    /// with a terminal commit, follow-up run, composer submission, or queued instruction still in
    /// flight, so "send, get `target_not_idle`, wait for idle, send again" is a tight loop rather
    /// than a wait.
    case sendable
}

package struct DomainAgentSessionLinkWaitRequest: Hashable, Sendable {
    package let lease: DomainAgentSessionLinkLease
    /// Omitting a cursor snapshots current state and waits for the next qualifying event.
    package let cursor: String?

    package init(lease: DomainAgentSessionLinkLease, cursor: String?) {
        self.lease = lease
        self.cursor = cursor
    }
}

package enum DomainAgentSessionLinkWaitOutcome: Equatable, Sendable {
    case changed(sessionID: UUID)
    case idle(sessionID: UUID)
    case revoked(DomainAgentSessionLinkRevocationNotice)
    case timedOut
    case cancelled
    case shuttingDown
    case waitAlreadyPending(conflictingSessionID: UUID)
    case linkUnavailable(sessionID: UUID)
    case cursorExpired(sessionID: UUID)
    case invalidRequest

    package var triggeredSessionID: UUID? {
        switch self {
        case let .changed(sessionID), let .idle(sessionID):
            sessionID
        case let .revoked(notice):
            notice.targetSessionID
        case .timedOut, .cancelled, .shuttingDown, .waitAlreadyPending,
             .linkUnavailable, .cursorExpired, .invalidRequest:
            nil
        }
    }
}

package struct DomainAgentSessionLinkWaitResult: Equatable, Sendable {
    package let outcome: DomainAgentSessionLinkWaitOutcome
    /// Successor cursors for every authorized target, in request order.
    package let targets: [DomainAgentSessionLinkTargetState]

    package init(outcome: DomainAgentSessionLinkWaitOutcome, targets: [DomainAgentSessionLinkTargetState]) {
        self.outcome = outcome
        self.targets = targets
    }
}

// MARK: - Read cursors

package enum DomainAgentSessionLinkReadDirection: String, CaseIterable, Hashable, Sendable {
    case tail
    case start
}

/// A stable transcript anchor. `sourceItemsRevision` is a non-authoritative diagnostic hint only; it
/// never determines cursor validity.
package struct DomainAgentSessionLinkReadAnchor: Hashable, Sendable {
    package let itemID: String
    package let sequenceIndex: Int
    package let sourceItemsRevision: UInt64?

    package init(itemID: String, sequenceIndex: Int, sourceItemsRevision: UInt64?) {
        self.itemID = itemID
        self.sequenceIndex = sequenceIndex
        self.sourceItemsRevision = sourceItemsRevision
    }
}

package struct DomainAgentSessionLinkReadCursorState: Hashable, Sendable {
    package let handle: String
    package let linkID: UUID
    package let linkGeneration: UInt64
    package let targetSessionID: UUID
    package let direction: DomainAgentSessionLinkReadDirection
    package let anchor: DomainAgentSessionLinkReadAnchor

    package init(
        handle: String,
        linkID: UUID,
        linkGeneration: UInt64,
        targetSessionID: UUID,
        direction: DomainAgentSessionLinkReadDirection,
        anchor: DomainAgentSessionLinkReadAnchor
    ) {
        self.handle = handle
        self.linkID = linkID
        self.linkGeneration = linkGeneration
        self.targetSessionID = targetSessionID
        self.direction = direction
        self.anchor = anchor
    }
}

package enum DomainAgentSessionLinkReadCursorDisposition: Equatable, Sendable {
    case resolved(DomainAgentSessionLinkReadCursorState)
    /// Invalid runtime/link/endpoint generation, or an evicted handle. Never attaches to a re-link.
    case expired
}

// MARK: - Send reservations

package struct DomainAgentSessionLinkSendReservation: Hashable, Sendable {
    package let id: UUID
    package let linkID: UUID
    package let linkGeneration: UInt64
    package let observerSessionID: UUID
    package let targetSessionID: UUID
    package let idempotencyKey: String
    package let messageDigest: String

    package init(
        id: UUID,
        linkID: UUID,
        linkGeneration: UInt64,
        observerSessionID: UUID,
        targetSessionID: UUID,
        idempotencyKey: String,
        messageDigest: String
    ) {
        self.id = id
        self.linkID = linkID
        self.linkGeneration = linkGeneration
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.idempotencyKey = idempotencyKey
        self.messageDigest = messageDigest
    }
}

package enum DomainAgentSessionLinkDeliveryState: String, CaseIterable, Hashable, Sendable {
    case persisted
    case runStarted = "run_started"
    case runStartFailed = "run_start_failed"
}

package struct DomainAgentSessionLinkSendReceipt: Hashable, Sendable {
    package let targetSessionID: UUID
    package let targetItemID: String
    package let acceptedAt: Date
    package let deliveryState: DomainAgentSessionLinkDeliveryState
    package let resultingRunState: String
    /// Set by the authority when an identical key/digest pair replays a stored outcome.
    package let duplicate: Bool

    package init(
        targetSessionID: UUID,
        targetItemID: String,
        acceptedAt: Date,
        deliveryState: DomainAgentSessionLinkDeliveryState,
        resultingRunState: String,
        duplicate: Bool = false
    ) {
        self.targetSessionID = targetSessionID
        self.targetItemID = targetItemID
        self.acceptedAt = acceptedAt
        self.deliveryState = deliveryState
        self.resultingRunState = resultingRunState
        self.duplicate = duplicate
    }

    package func markedDuplicate() -> DomainAgentSessionLinkSendReceipt {
        DomainAgentSessionLinkSendReceipt(
            targetSessionID: targetSessionID,
            targetItemID: targetItemID,
            acceptedAt: acceptedAt,
            deliveryState: deliveryState,
            resultingRunState: resultingRunState,
            duplicate: true
        )
    }
}

package enum DomainAgentSessionLinkSendReservationDisposition: Equatable, Sendable {
    case reserved(DomainAgentSessionLinkSendReservation)
    /// Same key, same digest, already settled: replay the exact stored receipt.
    case duplicate(DomainAgentSessionLinkSendReceipt)
    /// Same key, same digest, still settling.
    case inProgress
    /// Same key, same digest, settled with an undetermined durable outcome.
    ///
    /// The delivery may or may not have committed, so this key can never be reused for a fresh
    /// delivery and has no receipt to replay. The caller must verify the target and, if the message
    /// did not arrive, send again under a new key.
    case indeterminate
    /// Same key, different digest: never replays and never delivers either payload.
    case conflict
    /// Too many sends are settling at once. Transient by construction: every in-flight send either
    /// commits or is abandoned, so a slot frees on its own and the same key may be retried.
    case inFlightLimitReached
    /// The retained settled-outcome ceiling is reached. **Not** transient: retained outcomes are only
    /// released when a link generation is revoked (`releaseSendLedger`) or the runtime restarts, so
    /// waiting does not clear it and retrying only re-rejects.
    case retainedOutcomeLimitReached
    case rejected(DomainAgentSessionLinkError)
}

/// Non-mutating view of what the send ledger already holds for one exact
/// `(link generation, idempotency key)` pair.
///
/// It exists for queued admission, which has to consult the ledger *before* it resolves a workflow:
/// an already-settled duplicate must replay its stored outcome even when the workflow it originally
/// named has since been renamed or deleted. `beginSend` cannot answer that question without also
/// reserving, and a reservation held for a message that will not be delivered until the target next
/// becomes sendable would occupy the in-flight ceiling for that entire time.
///
/// Nothing here is a promise about a *future* call: `unused` only means the ledger held no outcome
/// at the instant it was read, and admission is still decided by `beginSend` at delivery time.
package enum DomainAgentSessionLinkSendLedgerProbe: Equatable, Sendable {
    case unused
    /// Same key, same digest, already settled with a receipt.
    case duplicate(DomainAgentSessionLinkSendReceipt)
    /// Same key, same digest, still settling.
    case inProgress
    /// Same key, same digest, settled with an undetermined durable outcome.
    case indeterminate
    /// Same key, different digest.
    case conflict
    case rejected(DomainAgentSessionLinkError)
}

package enum DomainAgentSessionLinkSendCommitDisposition: Equatable, Sendable {
    /// The authorization linearization fence was won before manual revocation.
    case committed
    case linkRevoked
    case unknownReservation
    case shuttingDown
}

// MARK: - Change events

/// Identity/revision-only change feed. Consumers refetch an authoritative snapshot.
package struct DomainAgentSessionLinkChangeEvent: Hashable, Sendable {
    package enum Kind: String, CaseIterable, Hashable, Sendable {
        case activated
        case revoked
        case targetStateChanged = "target_state_changed"
        case draining
        case shutdown
    }

    package let kind: Kind
    package let authorityRevision: UInt64
    package let linkID: UUID?
    package let linkGeneration: UInt64?
    package let observerSessionID: UUID?
    package let targetSessionID: UUID?
    /// Present only when this observer's grant membership changed.
    package let observerLinkSetRevision: UInt64?

    package init(
        kind: Kind,
        authorityRevision: UInt64,
        linkID: UUID? = nil,
        linkGeneration: UInt64? = nil,
        observerSessionID: UUID? = nil,
        targetSessionID: UUID? = nil,
        observerLinkSetRevision: UInt64? = nil
    ) {
        self.kind = kind
        self.authorityRevision = authorityRevision
        self.linkID = linkID
        self.linkGeneration = linkGeneration
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.observerLinkSetRevision = observerLinkSetRevision
    }
}

// MARK: - Diagnostics

package struct DomainAgentSessionLinkAuthoritySnapshot: Equatable, Sendable {
    package let runtimeGeneration: UInt64
    package let authorityRevision: UInt64
    package let isDraining: Bool
    package let isShutDown: Bool
    package let activeLinkCount: Int
    package let pendingReservationCount: Int
    package let observedTargetCount: Int
    package let parkedWaiterCount: Int
    package let readCursorCount: Int
    package let inFlightSendCount: Int
    package let retainedSendOutcomeCount: Int

    package init(
        runtimeGeneration: UInt64,
        authorityRevision: UInt64,
        isDraining: Bool,
        isShutDown: Bool,
        activeLinkCount: Int,
        pendingReservationCount: Int,
        observedTargetCount: Int,
        parkedWaiterCount: Int,
        readCursorCount: Int,
        inFlightSendCount: Int,
        retainedSendOutcomeCount: Int
    ) {
        self.runtimeGeneration = runtimeGeneration
        self.authorityRevision = authorityRevision
        self.isDraining = isDraining
        self.isShutDown = isShutDown
        self.activeLinkCount = activeLinkCount
        self.pendingReservationCount = pendingReservationCount
        self.observedTargetCount = observedTargetCount
        self.parkedWaiterCount = parkedWaiterCount
        self.readCursorCount = readCursorCount
        self.inFlightSendCount = inFlightSendCount
        self.retainedSendOutcomeCount = retainedSendOutcomeCount
    }
}
