import Foundation

/// Process-wide, never-persisted authority for cross-window Agent session oversight links.
///
/// This actor is the single execution-time choke point for every oversight operation. It owns link
/// records, link generations, target change sequences, waiters, opaque read cursors, send
/// idempotency reservations, revocation, and two-phase shutdown. It has no app, UI, or feature-layer
/// dependency: each window bridge maps its own live bindings into
/// `DomainAgentSessionLinkEndpointIdentity` values and revalidates them on every operation.
///
/// Invariants enforced here:
/// - UUID knowledge is never authority; only an activated grant authorizes an operation.
/// - At most one active link per `(observer session incarnation, target session incarnation)` pair.
/// - Multiple independent observers may oversee one target; there is no artificial link-count cap.
/// - A revoked link ID/generation never resurrects; re-adding creates a new ID and generation.
/// - Grant capabilities are fixed for v1 and never inferred from role or parentage.
/// - No date-based expiry: only explicit/lifecycle revocation and runtime shutdown end a link.
package actor DomainAgentSessionLinkAuthority {
    // MARK: - Bounds

    /// Bounded opaque read-cursor records per link (LRU). Evicted handles return `cursor_expired`.
    package static let readCursorsPerLinkLimit = 64
    /// Bounded wait-cursor records per link (LRU). Evicted handles return `cursor_expired`.
    package static let waitCursorsPerLinkLimit = 64
    /// Multi-target `poll`/`wait` fan-out cap. This bounds one call, not the number of active links.
    package static let waitFanOutLimit = 32
    /// At most this many uncommitted-or-committed sends may be settling authority-wide.
    package static let inFlightSendLimit = 16
    /// At most this many settled outcomes are retained across active link generations.
    package static let retainedSendOutcomeLimit = 4096
    /// Bounded recent-revocation projection per endpoint incarnation for explanatory UI.
    package static let recentRevocationNoticesPerEndpoint = 5
    /// Bounded number of endpoint incarnations retaining notices, evicted oldest-write-first.
    ///
    /// Notices are keyed by exact incarnation rather than by session UUID, so a long-lived process
    /// accumulates a bucket per dead incarnation that nothing will ever read or dismiss. The bound is
    /// what keeps that key space from growing without limit.
    package static let recentRevocationNoticeEndpointLimit = 64
    /// Maximum observer UUID candidates disclosed when an attention request omits its selector.
    ///
    /// The authority may hold any number of inbound links. Bounding this diagnostic projection keeps
    /// one ambiguous request from turning that authority into an unbounded inventory surface.
    package static let requestAttentionObserverCandidateLimit = 16

    // MARK: - Inverse attention authorization

    /// Capability-free proof that one exact target may enqueue an attention occurrence for one exact
    /// observer link generation.
    ///
    /// This is deliberately not `DomainAgentSessionLinkLease`: that lease represents an
    /// observer-origin monitor operation and carries a monitor capability. An attention request runs in
    /// the inverse direction, and the exact active grant is its whole authority.
    package struct RequestAttentionAuthorization: Hashable, Sendable {
        package let runtimeID: UUID
        package let runtimeGeneration: UInt64
        package let reference: DomainAgentSessionLinkReference
        package let observer: DomainAgentSessionLinkEndpointIdentity
        package let target: DomainAgentSessionLinkEndpointIdentity
        /// The caller's selector, retained so validation can re-prove the same cardinality after a
        /// suspension. `nil` means the chosen grant must still be the sole live inbound grant.
        package let requestedObserverSessionID: UUID?
        /// Revision the observer-local reducer must already be baselined against before it stores the
        /// occurrence.
        package let observerLinkSetRevision: UInt64
        /// Fences changes to the target's inbound grant set between authorization and reducer mutation.
        package let targetLinkSetRevision: UInt64

        fileprivate init(
            runtimeID: UUID,
            runtimeGeneration: UInt64,
            reference: DomainAgentSessionLinkReference,
            observer: DomainAgentSessionLinkEndpointIdentity,
            target: DomainAgentSessionLinkEndpointIdentity,
            requestedObserverSessionID: UUID?,
            observerLinkSetRevision: UInt64,
            targetLinkSetRevision: UInt64
        ) {
            self.runtimeID = runtimeID
            self.runtimeGeneration = runtimeGeneration
            self.reference = reference
            self.observer = observer
            self.target = target
            self.requestedObserverSessionID = requestedObserverSessionID
            self.observerLinkSetRevision = observerLinkSetRevision
            self.targetLinkSetRevision = targetLinkSetRevision
        }
    }

    package enum RequestAttentionAuthorizationError: Error, Equatable, Sendable {
        /// Indistinguishable absence, stale routing, or authorization denial.
        case denied
        /// More than one exact live grant can satisfy the request.
        ///
        /// Candidate UUIDs are returned only for an omitted selector. An explicit UUID ambiguity uses
        /// an empty array so it cannot enumerate any other observer.
        case ambiguousObserver(
            candidateObserverSessionIDs: [UUID],
            omittedCandidateCount: Int
        )
        case runtimeShuttingDown
    }

    // MARK: - Internal records

    private struct LinkRecord {
        var grant: DomainAgentSessionLinkGrant
        /// Authority revision at activation. Used so a stale lifecycle observation cannot revoke a
        /// link that was activated after that observation was taken.
        var activationAuthorityRevision: UInt64
        var readCursors: [String: DomainAgentSessionLinkReadCursorState] = [:]
        var readCursorOrder: [String] = []
        var waitCursors: [String: UInt64] = [:]
        var waitCursorOrder: [String] = []
        /// At most one active waiter per link generation.
        var activeWaiterID: UUID?
    }

    private enum RequestAttentionSelection {
        case selected(LinkRecord)
        case denied
        case ambiguous(candidateObserverSessionIDs: [UUID], omittedCandidateCount: Int)
    }

    private struct TargetRecord {
        var endpoint: DomainAgentSessionLinkEndpointIdentity
        var snapshot: DomainAgentSessionObservationSnapshot
        var changeSequence: UInt64
        /// Only publications strictly newer than this mark are accepted.
        var sourcePublicationHighWater: UInt64
        var inboundLinkIDs: Set<UUID> = []
    }

    private struct WaitRegistration {
        let reference: DomainAgentSessionLinkReference
        let targetSessionID: UUID
        let baselineChangeSequence: UInt64
    }

    private struct Waiter {
        let id: UUID
        let observerSessionID: UUID
        let predicate: DomainAgentSessionLinkWaitPredicate
        let registrations: [WaitRegistration]
        let continuation: CheckedContinuation<DomainAgentSessionLinkWaitResult, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct SendLedgerKey: Hashable {
        let linkID: UUID
        let linkGeneration: UInt64
        let idempotencyKey: String
    }

    private struct SendLedgerEntry {
        let reservation: DomainAgentSessionLinkSendReservation
        var isCommitted: Bool
        var receipt: DomainAgentSessionLinkSendReceipt?
        /// Terminal tombstone: the delivery's durable outcome could not be determined, so this key is
        /// permanently spent and has no receipt to replay.
        var isIndeterminate: Bool = false

        var isSettled: Bool { receipt != nil || isIndeterminate }
    }

    // MARK: - State

    private let runtimeID: UUID
    private let baseLifecycleGeneration: UInt64
    private let now: @Sendable () -> Date

    private var runtimeGenerationOffset: UInt64 = 0
    private var authorityRevision: UInt64 = 0
    private var nextLinkGeneration: UInt64 = 1
    private var isDraining = false
    private var isShutDown = false

    private var links: [UUID: LinkRecord] = [:]
    private var pendingReservations: [UUID: DomainAgentSessionLinkPendingReservation] = [:]
    private var targets: [UUID: TargetRecord] = [:]
    /// Monotonic per-target-session change sequence that survives target record replacement.
    private var nextChangeSequenceBySession: [UUID: UInt64] = [:]
    private var observerLinkSetRevisions: [UUID: UInt64] = [:]
    /// Inbound membership revision per target session. Kept separate from the observer revision so a
    /// target that is also an observer elsewhere cannot have the two counters alias each other.
    private var targetLinkSetRevisions: [UUID: UInt64] = [:]
    /// Keyed by exact endpoint incarnation, never by session UUID: a duplicate live incarnation of
    /// one session UUID was granted nothing and must not be handed another incarnation's notices.
    private var recentRevocationNotices:
        [DomainAgentSessionLinkEndpointIdentity: [DomainAgentSessionLinkRevocationNotice]] = [:]
    /// Write order of `recentRevocationNotices`, oldest first, so the endpoint bound evicts
    /// deterministically.
    private var recentRevocationNoticeOrder: [DomainAgentSessionLinkEndpointIdentity] = []

    private var waiters: [UUID: Waiter] = [:]
    private var sendLedger: [SendLedgerKey: SendLedgerEntry] = [:]
    private var sendLedgerOrder: [SendLedgerKey] = []
    private var subscribers: [UUID: AsyncStream<DomainAgentSessionLinkChangeEvent>.Continuation] = [:]

    package init(
        identity: DomainRuntimeIdentity,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        runtimeID = identity.runtimeID
        baseLifecycleGeneration = identity.lifecycleGeneration
        self.now = now
    }

    /// Runtime generation every lease and cursor is fenced against. Advancing it invalidates all
    /// previously issued tokens.
    package var runtimeGeneration: UInt64 {
        baseLifecycleGeneration &+ runtimeGenerationOffset
    }

    package func snapshot() -> DomainAgentSessionLinkAuthoritySnapshot {
        DomainAgentSessionLinkAuthoritySnapshot(
            runtimeGeneration: runtimeGeneration,
            authorityRevision: authorityRevision,
            isDraining: isDraining,
            isShutDown: isShutDown,
            activeLinkCount: links.count,
            pendingReservationCount: pendingReservations.count,
            observedTargetCount: targets.count,
            parkedWaiterCount: waiters.count,
            readCursorCount: links.values.reduce(0) { $0 + $1.readCursors.count },
            inFlightSendCount: sendLedger.values.filter { !$0.isSettled }.count,
            retainedSendOutcomeCount: sendLedger.values.filter(\.isSettled).count
        )
    }

    // MARK: - Change feed

    /// Identity/revision-only change feed. Consumers refetch an authoritative snapshot.
    package func changeEvents() -> AsyncStream<DomainAgentSessionLinkChangeEvent> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            if isShutDown {
                continuation.finish()
                return
            }
            subscribers[subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func publish(_ event: DomainAgentSessionLinkChangeEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    @discardableResult
    private func advanceAuthorityRevision() -> UInt64 {
        authorityRevision &+= 1
        return authorityRevision
    }

    @discardableResult
    private func advanceObserverLinkSetRevision(_ observerSessionID: UUID) -> UInt64 {
        let next = (observerLinkSetRevisions[observerSessionID] ?? 0) &+ 1
        observerLinkSetRevisions[observerSessionID] = next
        return next
    }

    @discardableResult
    private func advanceTargetLinkSetRevision(_ targetSessionID: UUID) -> UInt64 {
        let next = (targetLinkSetRevisions[targetSessionID] ?? 0) &+ 1
        targetLinkSetRevisions[targetSessionID] = next
        return next
    }

    // MARK: - Reservation and activation

    /// Reserves a pending directed link, or returns the existing active link for the same endpoint
    /// pair. Reservation alone grants nothing: the bridge must activate with a seeded snapshot.
    package func reserveLink(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        capabilities: Set<DomainAgentSessionLinkCapability> = DomainAgentSessionLinkCapability.version1,
        requiresExistingOutboundLink: Bool = false
    ) -> DomainAgentSessionLinkReservationDisposition {
        guard !isDraining, !isShutDown else { return .rejected(.shuttingDown) }
        guard observer.sessionID != target.sessionID, observer != target else {
            return .rejected(.selfMonitor)
        }
        guard observer.hasResolvedPersistentBinding else { return .rejected(.observerBindingUnresolved) }
        guard target.hasResolvedPersistentBinding else { return .rejected(.targetBindingUnresolved) }

        if let existing = activeLink(observer: observer, target: target) {
            return .existing(existing.grant)
        }
        guard !requiresExistingOutboundLink || hasActiveOutboundLink(observerEndpoint: observer) else {
            return .rejected(.observerHasNoActiveOutboundLink)
        }
        if pendingReservations.values.contains(where: { $0.observer == observer && $0.target == target }) {
            return .rejected(.reservationAlreadyPending)
        }

        // A target record bound to a different incarnation is stale by construction. Fail its links
        // closed before admitting a new one rather than mixing incarnations under one session ID.
        //
        // The resulting notices ride out on the disposition: they revoke links belonging to observers
        // that are not party to this call, and the change feed alone can drop the event that would
        // have repaired them.
        var collateralRevocations: [DomainAgentSessionLinkRevocationNotice] = []
        if let existingTarget = targets[target.sessionID], existingTarget.endpoint != target {
            collateralRevocations = revokeLinks(
                withIDs: existingTarget.inboundLinkIDs,
                reason: .targetIdentityDrift
            )
            targets.removeValue(forKey: target.sessionID)
        }

        // A pending reservation already claims the first-inbound role for this target, so a second
        // concurrent observer must not also be told to install an observation/publication chain.
        let hasPendingInboundReservation = pendingReservations.values.contains {
            $0.target.sessionID == target.sessionID
        }
        let reservation = DomainAgentSessionLinkPendingReservation(
            linkID: UUID(),
            generation: nextLinkGeneration,
            observer: observer,
            target: target,
            capabilities: capabilities,
            requiresExistingOutboundLink: requiresExistingOutboundLink,
            provisionallyInstallsTargetObservation: targets[target.sessionID] == nil
                && !hasPendingInboundReservation,
            reservedAtAuthorityRevision: advanceAuthorityRevision()
        )
        nextLinkGeneration &+= 1
        pendingReservations[reservation.linkID] = reservation
        return .reserved(reservation, collateralRevocations: collateralRevocations)
    }

    /// Activates a pending reservation with its synchronously built seed snapshot, so `poll` can
    /// never race an uninitialized active link.
    package func activateLink(
        reservation: DomainAgentSessionLinkPendingReservation,
        initialSnapshot: DomainAgentSessionObservationSnapshot,
        sourcePublicationSequence: UInt64
    ) -> DomainAgentSessionLinkActivationDisposition {
        guard !isDraining, !isShutDown else {
            pendingReservations.removeValue(forKey: reservation.linkID)
            return .rejected(.shuttingDown)
        }
        guard let pending = pendingReservations[reservation.linkID], pending == reservation else {
            return .rejected(.unknownReservation)
        }
        guard initialSnapshot.sessionID == reservation.target.sessionID else {
            pendingReservations.removeValue(forKey: reservation.linkID)
            return .rejected(.snapshotSessionMismatch)
        }
        if let existingTarget = targets[reservation.target.sessionID],
           existingTarget.endpoint != reservation.target
        {
            pendingReservations.removeValue(forKey: reservation.linkID)
            return .rejected(.endpointDrift)
        }
        if activeLink(observer: reservation.observer, target: reservation.target) != nil {
            pendingReservations.removeValue(forKey: reservation.linkID)
            return .rejected(.endpointDrift)
        }
        if reservation.requiresExistingOutboundLink,
           !hasActiveOutboundLink(observerEndpoint: reservation.observer)
        {
            pendingReservations.removeValue(forKey: reservation.linkID)
            return .rejected(.observerHasNoActiveOutboundLink)
        }

        pendingReservations.removeValue(forKey: reservation.linkID)
        let revision = advanceAuthorityRevision()
        let grant = DomainAgentSessionLinkGrant(
            id: reservation.linkID,
            generation: reservation.generation,
            observer: reservation.observer,
            target: reservation.target,
            createdAt: now(),
            capabilities: reservation.capabilities
        )
        links[grant.id] = LinkRecord(grant: grant, activationAuthorityRevision: revision)

        // The installer role belongs to the activation that actually creates the target record, not
        // to whichever reservation was provisionally elected. An elected reservation can be abandoned
        // or lifecycle-invalidated while a sibling survives, and that sibling must then install the
        // observation instead of activating into a target that nobody is publishing for.
        let installsTargetObservation = targets[reservation.target.sessionID] == nil
        if var existingTarget = targets[reservation.target.sessionID] {
            // Joining an existing record: this caller does not own the publication chain, so its
            // `sourcePublicationSequence` is meaningless here and must never move the high-water mark
            // that fences the installing chain.
            existingTarget.inboundLinkIDs.insert(grant.id)
            targets[reservation.target.sessionID] = existingTarget
        } else {
            let sequence = allocateChangeSequence(for: reservation.target.sessionID)
            targets[reservation.target.sessionID] = TargetRecord(
                endpoint: reservation.target,
                snapshot: canonicalSnapshot(initialSnapshot, previous: nil),
                changeSequence: sequence,
                // Seeded only from the chain that is actually installing.
                sourcePublicationHighWater: sourcePublicationSequence,
                inboundLinkIDs: [grant.id]
            )
        }

        let linkSetRevision = advanceObserverLinkSetRevision(grant.observer.sessionID)
        advanceTargetLinkSetRevision(grant.target.sessionID)
        publish(DomainAgentSessionLinkChangeEvent(
            kind: .activated,
            authorityRevision: revision,
            linkID: grant.id,
            linkGeneration: grant.generation,
            observerSessionID: grant.observer.sessionID,
            targetSessionID: grant.target.sessionID,
            observerLinkSetRevision: linkSetRevision
        ))
        return .activated(DomainAgentSessionLinkActivation(
            grant: grant,
            installsTargetObservation: installsTargetObservation,
            // Read here, inside the same actor-isolated body that committed the membership write, so
            // it is exactly the inventory `projectionInputs(forEndpoint:)` would return for this
            // observer at this instant — with none of the window between.
            observerInventory: links(forObserverEndpoint: grant.observer)
        ))
    }

    /// Rolls back a reservation whose seeding failed or whose endpoints drifted before activation.
    package func abandonReservation(_ reservation: DomainAgentSessionLinkPendingReservation) {
        pendingReservations.removeValue(forKey: reservation.linkID)
    }

    private func allocateChangeSequence(for sessionID: UUID) -> UInt64 {
        let sequence = nextChangeSequenceBySession[sessionID] ?? 1
        nextChangeSequenceBySession[sessionID] = sequence &+ 1
        return sequence
    }

    private func activeLink(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) -> LinkRecord? {
        links.values.first { $0.grant.observer == observer && $0.grant.target == target }
    }

    /// Returns the active grant recorded for one exact link generation.
    ///
    /// This is a read-only authority lookup for callers that already hold a generation-qualified
    /// reference. It neither resolves live endpoints nor mints a lease, and a stale generation can
    /// never observe the grant that replaced it.
    package func activeGrant(
        for reference: DomainAgentSessionLinkReference
    ) -> DomainAgentSessionLinkGrant? {
        guard let record = links[reference.linkID],
              record.grant.generation == reference.generation
        else {
            return nil
        }
        return record.grant
    }

    // MARK: - Inventory

    /// Inventory for one exact observer incarnation.
    ///
    /// A session UUID can be live in more than one window at once, and the app models that
    /// explicitly. Scoping by UUID would hand a duplicate incarnation the grants of the incarnation
    /// the user actually authorized, so every authorization-bearing inventory read takes an endpoint.
    package func links(
        forObserverEndpoint observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> DomainAgentSessionLinkInventory {
        inventory(
            forObserver: observerEndpoint.sessionID,
            matching: { $0.grant.observer == observerEndpoint }
        )
    }

    /// Inventory for every incarnation of one observer session UUID.
    ///
    /// Only for UUID-scoped bookkeeping — lifecycle sweeps, pruning, and revocation — never for
    /// authorizing or publishing to a caller.
    package func links(forObserver observerSessionID: UUID) -> DomainAgentSessionLinkInventory {
        inventory(
            forObserver: observerSessionID,
            matching: { $0.grant.observer.sessionID == observerSessionID }
        )
    }

    private func inventory(
        forObserver observerSessionID: UUID,
        matching predicate: (LinkRecord) -> Bool
    ) -> DomainAgentSessionLinkInventory {
        var items: [DomainAgentSessionLinkInventoryItem] = []
        for record in links.values where predicate(record) {
            let targetSessionID: UUID = record.grant.target.sessionID
            items.append(DomainAgentSessionLinkInventoryItem(
                linkID: record.grant.id,
                generation: record.grant.generation,
                observerSessionID: record.grant.observer.sessionID,
                targetSessionID: targetSessionID,
                displayName: targets[targetSessionID]?.snapshot.displayName,
                capabilities: record.grant.capabilities
            ))
        }
        items.sort(by: Self.orderedByTarget)
        return DomainAgentSessionLinkInventory(
            sessionID: observerSessionID,
            linkSetRevision: observerLinkSetRevisions[observerSessionID] ?? 0,
            authorityRevision: authorityRevision,
            items: items
        )
    }

    /// Inbound inventory for one exact target incarnation.
    package func links(
        forTargetEndpoint targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> DomainAgentSessionLinkInventory {
        inventory(
            forTarget: targetEndpoint.sessionID,
            matching: { $0.grant.target == targetEndpoint }
        )
    }

    package func links(forTarget targetSessionID: UUID) -> DomainAgentSessionLinkInventory {
        inventory(
            forTarget: targetSessionID,
            matching: { $0.grant.target.sessionID == targetSessionID }
        )
    }

    private func inventory(
        forTarget targetSessionID: UUID,
        matching predicate: (LinkRecord) -> Bool
    ) -> DomainAgentSessionLinkInventory {
        var items: [DomainAgentSessionLinkInventoryItem] = []
        for record in links.values where predicate(record) {
            items.append(DomainAgentSessionLinkInventoryItem(
                linkID: record.grant.id,
                generation: record.grant.generation,
                observerSessionID: record.grant.observer.sessionID,
                targetSessionID: record.grant.target.sessionID,
                displayName: nil,
                capabilities: record.grant.capabilities
            ))
        }
        items.sort(by: Self.orderedByObserver)
        return DomainAgentSessionLinkInventory(
            sessionID: targetSessionID,
            // Inbound membership, not this session's own outbound revision: a session can be both a
            // target and an observer, and the two counters must never alias.
            linkSetRevision: targetLinkSetRevisions[targetSessionID] ?? 0,
            authorityRevision: authorityRevision,
            items: items
        )
    }

    private static func orderedByTarget(
        _ lhs: DomainAgentSessionLinkInventoryItem,
        _ rhs: DomainAgentSessionLinkInventoryItem
    ) -> Bool {
        let lhsTarget: String = lhs.targetSessionID.uuidString
        let rhsTarget: String = rhs.targetSessionID.uuidString
        if lhsTarget != rhsTarget { return lhsTarget < rhsTarget }
        return lhs.linkID.uuidString < rhs.linkID.uuidString
    }

    private static func orderedByObserver(
        _ lhs: DomainAgentSessionLinkInventoryItem,
        _ rhs: DomainAgentSessionLinkInventoryItem
    ) -> Bool {
        let lhsObserver: String = lhs.observerSessionID.uuidString
        let rhsObserver: String = rhs.observerSessionID.uuidString
        if lhsObserver != rhsObserver { return lhsObserver < rhsObserver }
        return lhs.linkID.uuidString < rhs.linkID.uuidString
    }

    /// Notices recorded for one exact endpoint incarnation.
    package func recentRevocationNotices(
        forEndpoint endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        recentRevocationNotices[endpoint] ?? []
    }

    /// Single-turn projection inputs for one exact endpoint incarnation.
    ///
    /// Membership on both sides, the peer incarnation of every listed grant, and this incarnation's
    /// notices are read together so a host projection can never mix snapshots or resolve a peer by
    /// session UUID.
    package func projectionInputs(
        forEndpoint endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> DomainAgentSessionLinkEndpointProjectionInputs {
        let outbound = links(forObserverEndpoint: endpoint)
        let inbound = links(forTargetEndpoint: endpoint)
        var outboundTargetEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity] = [:]
        for item in outbound.items {
            guard let record = links[item.linkID] else { continue }
            outboundTargetEndpoints[item.linkID] = record.grant.target
        }
        var inboundObserverEndpoints: [UUID: DomainAgentSessionLinkEndpointIdentity] = [:]
        for item in inbound.items {
            guard let record = links[item.linkID] else { continue }
            inboundObserverEndpoints[item.linkID] = record.grant.observer
        }
        return DomainAgentSessionLinkEndpointProjectionInputs(
            outbound: outbound,
            inbound: inbound,
            outboundTargetEndpoints: outboundTargetEndpoints,
            inboundObserverEndpoints: inboundObserverEndpoints,
            activeOutboundObserverEndpoints: Set(links.values.map { $0.grant.observer }),
            notices: recentRevocationNotices[endpoint] ?? []
        )
    }

    package func observerLinkSetRevision(_ observerSessionID: UUID) -> UInt64 {
        observerLinkSetRevisions[observerSessionID] ?? 0
    }

    package func targetLinkSetRevision(_ targetSessionID: UUID) -> UInt64 {
        targetLinkSetRevisions[targetSessionID] ?? 0
    }

    /// Whether one exact observer incarnation currently holds an outbound link.
    ///
    /// This is the live input to outbound readiness and targetless `list` authorization, so it is
    /// endpoint-scoped: a second live incarnation of the same session UUID must not inherit the
    /// outbound inventory of the incarnation the user granted. Catalog visibility uses
    /// `hasActiveLink(endpoint:)` independently.
    ///
    /// There is deliberately **no** session-UUID overload. Every caller of this predicate is deciding
    /// whether a live caller may be granted a capability, and a UUID-scoped answer would say yes to
    /// an incarnation the user never authorized.
    package func hasActiveOutboundLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        links.values.contains { $0.grant.observer == observerEndpoint }
    }

    package func hasActiveLink(endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
        links.values.contains { record in
            record.grant.observer == endpoint || record.grant.target == endpoint
        }
    }

    /// Authorizes the fixed inverse attention signal from one exact target endpoint.
    ///
    /// `liveEndpoints` is the bridge's already-resolved endpoint set. Stale exact observer or target
    /// incarnations are removed before selector cardinality is decided, so a dead grant cannot turn a
    /// sole live observer into a false ambiguity. The grant itself is the authority; this path never
    /// consults the observer-origin operation authorizer and never mints or checks a capability.
    package func authorizeRequestAttention(
        requesterEndpoint: DomainAgentSessionLinkEndpointIdentity,
        observerSessionID: UUID? = nil,
        liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) -> Result<RequestAttentionAuthorization, RequestAttentionAuthorizationError> {
        guard !isDraining, !isShutDown else { return .failure(.runtimeShuttingDown) }

        switch requestAttentionSelection(
            requesterEndpoint: requesterEndpoint,
            observerSessionID: observerSessionID,
            liveEndpoints: liveEndpoints
        ) {
        case let .selected(record):
            let grant = record.grant
            return .success(RequestAttentionAuthorization(
                runtimeID: runtimeID,
                runtimeGeneration: runtimeGeneration,
                reference: DomainAgentSessionLinkReference(
                    linkID: grant.id,
                    generation: grant.generation
                ),
                observer: grant.observer,
                target: grant.target,
                requestedObserverSessionID: observerSessionID,
                observerLinkSetRevision: observerLinkSetRevisions[grant.observer.sessionID] ?? 0,
                targetLinkSetRevision: targetLinkSetRevisions[grant.target.sessionID] ?? 0
            ))
        case .denied:
            return .failure(.denied)
        case let .ambiguous(candidateObserverSessionIDs, omittedCandidateCount):
            return .failure(.ambiguousObserver(
                candidateObserverSessionIDs: candidateObserverSessionIDs,
                omittedCandidateCount: omittedCandidateCount
            ))
        }
    }

    /// Revalidates an inverse attention proof immediately before observer-local reducer mutation.
    ///
    /// Besides runtime and exact generation fencing, this repeats the original selector decision using
    /// the caller's current live endpoint set. That repetition is load-bearing: a previously stale
    /// sibling grant can become live without changing authority membership, and must make a formerly
    /// sole or uniquely selected observer ambiguous before any occurrence is stored.
    package func validateRequestAttentionAuthorization(
        _ authorization: RequestAttentionAuthorization,
        liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) -> RequestAttentionAuthorizationError? {
        guard !isDraining, !isShutDown else { return .runtimeShuttingDown }
        guard authorization.runtimeID == runtimeID,
              authorization.runtimeGeneration == runtimeGeneration,
              authorization.observerLinkSetRevision
              == (observerLinkSetRevisions[authorization.observer.sessionID] ?? 0),
              authorization.targetLinkSetRevision
              == (targetLinkSetRevisions[authorization.target.sessionID] ?? 0)
        else { return .denied }

        switch requestAttentionSelection(
            requesterEndpoint: authorization.target,
            observerSessionID: authorization.requestedObserverSessionID,
            liveEndpoints: liveEndpoints
        ) {
        case let .selected(record):
            let grant = record.grant
            guard grant.id == authorization.reference.linkID,
                  grant.generation == authorization.reference.generation,
                  grant.observer == authorization.observer,
                  grant.target == authorization.target
            else { return .denied }
            return nil
        case .denied:
            return .denied
        case let .ambiguous(candidateObserverSessionIDs, omittedCandidateCount):
            return .ambiguousObserver(
                candidateObserverSessionIDs: candidateObserverSessionIDs,
                omittedCandidateCount: omittedCandidateCount
            )
        }
    }

    /// Selects one exact live inbound grant under request-attention's optional observer selector.
    ///
    /// The exact target inventory read is intentional. A UUID-scoped target inventory would let a
    /// rebound caller inherit the previous incarnation's inbound grants.
    private func requestAttentionSelection(
        requesterEndpoint: DomainAgentSessionLinkEndpointIdentity,
        observerSessionID: UUID?,
        liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) -> RequestAttentionSelection {
        let inbound = links(forTargetEndpoint: requesterEndpoint)
        let liveRecords = inbound.items.compactMap { item -> LinkRecord? in
            guard let record = links[item.linkID],
                  record.grant.generation == item.generation,
                  record.grant.target == requesterEndpoint,
                  liveEndpoints.contains(record.grant.target),
                  liveEndpoints.contains(record.grant.observer)
            else { return nil }
            return record
        }

        if let observerSessionID {
            let matches = liveRecords.filter { $0.grant.observer.sessionID == observerSessionID }
            guard !matches.isEmpty else { return .denied }
            guard matches.count == 1 else {
                // Explicit denials and ambiguities never enumerate observers.
                return .ambiguous(candidateObserverSessionIDs: [], omittedCandidateCount: 0)
            }
            return .selected(matches[0])
        }

        guard !liveRecords.isEmpty else { return .denied }
        guard liveRecords.count == 1 else {
            let allCandidateIDs = Set(liveRecords.map { $0.grant.observer.sessionID })
                .sorted { $0.uuidString < $1.uuidString }
            let candidateIDs = Array(allCandidateIDs.prefix(Self.requestAttentionObserverCandidateLimit))
            return .ambiguous(
                candidateObserverSessionIDs: candidateIDs,
                omittedCandidateCount: allCandidateIDs.count - candidateIDs.count
            )
        }
        return .selected(liveRecords[0])
    }

    // MARK: - Authorization

    /// Issues a short-lived lease for one operation on one target.
    ///
    /// The caller must still revalidate both live endpoint identities before reading or mutating
    /// target state. An absent or mismatched grant returns `noActiveLink` so an unauthorized UUID is
    /// indistinguishable from a nonexistent one.
    ///
    /// The observer is an exact endpoint incarnation resolved from server-owned connection routing,
    /// never a session UUID: duplicate live incarnations of one session UUID are explicitly possible,
    /// and matching on the UUID alone would let the incarnation the user never authorized exercise
    /// the other's grant. The target stays UUID-addressed because that is what the caller names; the
    /// grant supplies its exact incarnation, and the caller revalidates it before use.
    package func authorize(
        operation: DomainAgentSessionTargetOperation,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID
    ) -> Result<DomainAgentSessionLinkLease, DomainAgentSessionLinkError> {
        guard !isDraining, !isShutDown else { return .failure(.runtimeShuttingDown) }
        guard operation.family == .monitor,
              !operation.isObserverScoped,
              let capability = operation.requiredMonitorCapability
        else {
            return .failure(.capabilityDenied)
        }
        guard let record = links.values.first(where: {
            $0.grant.observer == observerEndpoint && $0.grant.target.sessionID == targetSessionID
        }) else {
            return .failure(.noActiveLink)
        }
        guard record.grant.capabilities.contains(capability) else {
            return .failure(.capabilityDenied)
        }
        return .success(DomainAgentSessionLinkLease(
            leaseID: UUID(),
            runtimeID: runtimeID,
            runtimeGeneration: runtimeGeneration,
            linkID: record.grant.id,
            linkGeneration: record.grant.generation,
            capability: capability,
            observer: record.grant.observer,
            target: record.grant.target,
            issuedAt: now()
        ))
    }

    /// Authorizes a targetless oversight operation against the caller's own outbound grant set and
    /// returns its authoritative inventory in one transition.
    ///
    /// `list` names no target, so it cannot present a per-target capability proof. It is available
    /// only while at least one outbound link remains; after the final revocation the caller receives
    /// the same indistinguishable denial as an ungranted caller.
    package func authorizeInventory(
        operation: DomainAgentSessionTargetOperation = .monitorList,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Result<DomainAgentSessionLinkInventory, DomainAgentSessionLinkError> {
        guard !isDraining, !isShutDown else { return .failure(.runtimeShuttingDown) }
        let decision = DomainAgentSessionOperationAuthorizer.authorizeObserverScoped(
            operation: operation,
            caller: .agentSession(observerEndpoint.sessionID),
            hasActiveOutboundLink: hasActiveOutboundLink(observerEndpoint: observerEndpoint)
        )
        guard decision.isAuthorized else { return .failure(.noActiveLink) }
        return .success(links(forObserverEndpoint: observerEndpoint))
    }

    /// Validates a previously issued lease against current authority state.
    package func validate(lease: DomainAgentSessionLinkLease) -> DomainAgentSessionLinkError? {
        guard !isShutDown else { return .runtimeShuttingDown }
        guard lease.runtimeID == runtimeID, lease.runtimeGeneration == runtimeGeneration else {
            return .endpointInvalidated
        }
        guard let record = links[lease.linkID], record.grant.generation == lease.linkGeneration else {
            return .linkRevoked
        }
        guard record.grant.observer == lease.observer, record.grant.target == lease.target else {
            return .endpointInvalidated
        }
        guard record.grant.capabilities.contains(lease.capability) else { return .capabilityDenied }
        return nil
    }

    // MARK: - Target publication

    /// Applies one sanitized target snapshot under high-water semantics so a late task crossing the
    /// actor boundary can never regress status.
    package func publishTargetSnapshot(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        snapshot: DomainAgentSessionObservationSnapshot,
        sourcePublicationSequence: UInt64
    ) -> DomainAgentSessionLinkTargetChangeDisposition {
        guard !isShutDown else { return .shuttingDown }
        guard var record = targets[endpoint.sessionID] else { return .unknownTarget }
        guard record.endpoint == endpoint, snapshot.sessionID == endpoint.sessionID else {
            return .unknownTarget
        }
        guard sourcePublicationSequence > record.sourcePublicationHighWater else {
            return .stale(currentSourcePublicationSequence: record.sourcePublicationHighWater)
        }
        record.sourcePublicationHighWater = sourcePublicationSequence
        let canonical = canonicalSnapshot(snapshot, previous: record.snapshot)
        guard canonical != record.snapshot else {
            targets[endpoint.sessionID] = record
            return .unchanged(changeSequence: record.changeSequence)
        }
        record.snapshot = canonical
        record.changeSequence = allocateChangeSequence(for: endpoint.sessionID)
        targets[endpoint.sessionID] = record

        let revision = advanceAuthorityRevision()
        publish(DomainAgentSessionLinkChangeEvent(
            kind: .targetStateChanged,
            authorityRevision: revision,
            targetSessionID: endpoint.sessionID
        ))
        wakeWaiters(forTargetSession: endpoint.sessionID)
        return .accepted(changeSequence: record.changeSequence)
    }

    private func canonicalSnapshot(
        _ incoming: DomainAgentSessionObservationSnapshot,
        previous: DomainAgentSessionObservationSnapshot?
    ) -> DomainAgentSessionObservationSnapshot {
        let isIdle = incoming.status == .idle && !incoming.hasPendingInteraction
        let idleSince: Date? = if isIdle {
            previous?.status == .idle && previous?.hasPendingInteraction == false
                ? previous?.idleSince ?? now()
                : now()
        } else {
            nil
        }
        return DomainAgentSessionObservationSnapshot(
            sessionID: incoming.sessionID,
            displayName: incoming.displayName,
            providerDisplayName: incoming.providerDisplayName,
            status: incoming.status,
            idleForSend: incoming.idleForSend,
            idleSince: idleSince,
            waitingOn: incoming.waitingOn,
            pendingInteractionKind: incoming.pendingInteractionKind,
            latestVisibleAssistantPreview: incoming.latestVisibleAssistantPreview,
            visibleRowCount: incoming.visibleRowCount,
            lastActivityAt: incoming.lastActivityAt
        )
    }

    package func observationSnapshot(
        forTargetEndpoint endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> DomainAgentSessionObservationSnapshot? {
        guard let record = targets[endpoint.sessionID], record.endpoint == endpoint else { return nil }
        return record.snapshot
    }

    /// Current authorized target state plus a freshly minted successor wait cursor.
    package func targetState(for lease: DomainAgentSessionLinkLease) -> DomainAgentSessionLinkTargetState? {
        guard validate(lease: lease) == nil else { return nil }
        return makeTargetState(linkID: lease.linkID)
    }

    private func makeTargetState(linkID: UUID) -> DomainAgentSessionLinkTargetState? {
        guard var record = links[linkID],
              let target = targets[record.grant.target.sessionID]
        else {
            return nil
        }
        let handle = mintWaitCursor(in: &record, changeSequence: target.changeSequence)
        links[linkID] = record
        return DomainAgentSessionLinkTargetState(
            sessionID: record.grant.target.sessionID,
            linkID: record.grant.id,
            linkGeneration: record.grant.generation,
            snapshot: target.snapshot,
            changeSequence: target.changeSequence,
            waitCursor: handle
        )
    }

    private func mintWaitCursor(in record: inout LinkRecord, changeSequence: UInt64) -> String {
        let handle = Self.makeOpaqueHandle(prefix: "w")
        record.waitCursors[handle] = changeSequence
        record.waitCursorOrder.append(handle)
        while record.waitCursorOrder.count > Self.waitCursorsPerLinkLimit {
            let evicted = record.waitCursorOrder.removeFirst()
            record.waitCursors.removeValue(forKey: evicted)
        }
        return handle
    }

    private static func makeOpaqueHandle(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.lowercased())\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    // MARK: - Wait

    /// Bounded, event-driven waiting. Never busy-polls and never runs a timer between events.
    ///
    /// Collection authorization is all-or-nothing, and the waiter slot on every included link is
    /// reserved atomically: if any slot is occupied, none is taken.
    package func wait(
        requests: [DomainAgentSessionLinkWaitRequest],
        until predicate: DomainAgentSessionLinkWaitPredicate = .change,
        timeoutSeconds: TimeInterval
    ) async -> DomainAgentSessionLinkWaitResult {
        guard !isDraining, !isShutDown else {
            return DomainAgentSessionLinkWaitResult(outcome: .shuttingDown, targets: [])
        }
        guard !requests.isEmpty, requests.count <= Self.waitFanOutLimit else {
            return DomainAgentSessionLinkWaitResult(outcome: .invalidRequest, targets: [])
        }
        var seenLinkIDs: Set<UUID> = []
        for request in requests {
            guard seenLinkIDs.insert(request.lease.linkID).inserted else {
                return DomainAgentSessionLinkWaitResult(outcome: .invalidRequest, targets: [])
            }
        }

        // 1. Authorize every requested target before returning any snapshot.
        for request in requests {
            if validate(lease: request.lease) != nil {
                return DomainAgentSessionLinkWaitResult(
                    outcome: .linkUnavailable(sessionID: request.lease.target.sessionID),
                    targets: []
                )
            }
            guard request.lease.capability == .wait else {
                return DomainAgentSessionLinkWaitResult(
                    outcome: .linkUnavailable(sessionID: request.lease.target.sessionID),
                    targets: []
                )
            }
        }

        // 2. Resolve baselines from caller-supplied cursors. A forged, stale, or evicted cursor is
        //    rejected rather than silently reinterpreted.
        var registrations: [WaitRegistration] = []
        registrations.reserveCapacity(requests.count)
        for request in requests {
            guard let record = links[request.lease.linkID],
                  let target = targets[record.grant.target.sessionID]
            else {
                return DomainAgentSessionLinkWaitResult(
                    outcome: .linkUnavailable(sessionID: request.lease.target.sessionID),
                    targets: []
                )
            }
            let baseline: UInt64
            if let cursor = request.cursor {
                guard let stored = record.waitCursors[cursor] else {
                    return DomainAgentSessionLinkWaitResult(
                        outcome: .cursorExpired(sessionID: record.grant.target.sessionID),
                        targets: []
                    )
                }
                baseline = stored
            } else {
                baseline = target.changeSequence
            }
            registrations.append(WaitRegistration(
                reference: DomainAgentSessionLinkReference(
                    linkID: record.grant.id,
                    generation: record.grant.generation
                ),
                targetSessionID: record.grant.target.sessionID,
                baselineChangeSequence: baseline
            ))
        }

        // 3. Immediate resolution in request order.
        if let outcome = firstSatisfiedOutcome(registrations: registrations, predicate: predicate) {
            return waitResult(outcome: outcome, registrations: registrations)
        }
        if timeoutSeconds <= 0 {
            return waitResult(outcome: .timedOut, registrations: registrations)
        }

        // 4. Atomically reserve the one waiter slot on every included link.
        if let conflict = registrations.first(where: { links[$0.reference.linkID]?.activeWaiterID != nil }) {
            return DomainAgentSessionLinkWaitResult(
                outcome: .waitAlreadyPending(conflictingSessionID: conflict.targetSessionID),
                targets: []
            )
        }

        let waiterID = UUID()
        let observerSessionID = requests[0].lease.observer.sessionID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isDraining, !isShutDown else {
                    continuation.resume(returning: DomainAgentSessionLinkWaitResult(
                        outcome: Task.isCancelled ? .cancelled : .shuttingDown,
                        targets: []
                    ))
                    return
                }
                // Re-check after the continuation hop: state may have advanced.
                for registration in registrations {
                    guard let record = links[registration.reference.linkID],
                          record.grant.generation == registration.reference.generation
                    else {
                        continuation.resume(returning: DomainAgentSessionLinkWaitResult(
                            outcome: .linkUnavailable(sessionID: registration.targetSessionID),
                            targets: []
                        ))
                        return
                    }
                    if record.activeWaiterID != nil {
                        continuation.resume(returning: DomainAgentSessionLinkWaitResult(
                            outcome: .waitAlreadyPending(conflictingSessionID: registration.targetSessionID),
                            targets: []
                        ))
                        return
                    }
                }
                if let outcome = firstSatisfiedOutcome(registrations: registrations, predicate: predicate) {
                    continuation.resume(returning: waitResult(outcome: outcome, registrations: registrations))
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(timeoutSeconds))
                        await self?.timeoutWaiter(waiterID)
                    } catch {}
                }
                for registration in registrations {
                    links[registration.reference.linkID]?.activeWaiterID = waiterID
                }
                waiters[waiterID] = Waiter(
                    id: waiterID,
                    observerSessionID: observerSessionID,
                    predicate: predicate,
                    registrations: registrations,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Converts seconds to nanoseconds, saturating strictly below `UInt64.max`.
    ///
    /// `Double(UInt64.max)` rounds up to exactly 2^64, so clamping the *seconds* against it and then
    /// multiplying produces a Double equal to 2^64, and converting that to `UInt64` traps. Clamping
    /// after the multiplication, against a value that is strictly representable, avoids the trap for
    /// any finite input including `.infinity` and absurdly large caller timeouts.
    static func timeoutNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return 0 }
        let nanoseconds = (timeoutSeconds * 1_000_000_000).rounded(.up)
        // The multiplication itself can overflow to infinity for an absurdly large caller timeout.
        // That means "longer than we can represent", so it must saturate rather than collapse to 0 —
        // a 0 here would fire the timeout task immediately and silently convert a long wait into an
        // instant timeout.
        guard nanoseconds.isFinite else { return UInt64.max }
        guard nanoseconds > 0 else { return 0 }
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }

    private func firstSatisfiedOutcome(
        registrations: [WaitRegistration],
        predicate: DomainAgentSessionLinkWaitPredicate
    ) -> DomainAgentSessionLinkWaitOutcome? {
        for registration in registrations {
            guard let target = targets[registration.targetSessionID] else { continue }
            switch predicate {
            case .change:
                if target.changeSequence > registration.baselineChangeSequence {
                    return .changed(sessionID: registration.targetSessionID)
                }
            case .idle:
                if target.snapshot.status == .idle, !target.snapshot.hasPendingInteraction {
                    return .idle(sessionID: registration.targetSessionID)
                }
            case .sendable:
                // Reports the same `.idle` outcome on purpose: `idleForSend` is only ever published
                // for a target that is already status-idle with no pending interaction, so "idle" is
                // true of every wake this predicate produces. The caller asked for send-readiness and
                // the returned snapshot carries `idle_for_send`, so no separate result name is owed.
                if target.snapshot.idleForSend {
                    return .idle(sessionID: registration.targetSessionID)
                }
            }
        }
        return nil
    }

    /// Successor cursors for every authorized target, in request order.
    ///
    /// A missing row is never compacted away: the response must either carry one entry per originally
    /// authorized target or become an explicit terminal disposition, otherwise a caller holding a
    /// multi-target cursor map would silently lose a target and stop waiting on it.
    private enum SuccessorAssembly {
        case complete([DomainAgentSessionLinkTargetState])
        case missing(sessionID: UUID)
    }

    private func successorTargetStates(for registrations: [WaitRegistration]) -> SuccessorAssembly {
        var states: [DomainAgentSessionLinkTargetState] = []
        states.reserveCapacity(registrations.count)
        for registration in registrations {
            guard let record = links[registration.reference.linkID],
                  record.grant.generation == registration.reference.generation,
                  let state = makeTargetState(linkID: registration.reference.linkID)
            else {
                return .missing(sessionID: registration.targetSessionID)
            }
            states.append(state)
        }
        return .complete(states)
    }

    /// Builds a result that keeps every authorized target, downgrading to a terminal disposition when
    /// the successor set cannot be completed.
    private func waitResult(
        outcome: DomainAgentSessionLinkWaitOutcome,
        registrations: [WaitRegistration]
    ) -> DomainAgentSessionLinkWaitResult {
        switch successorTargetStates(for: registrations) {
        case let .complete(states):
            DomainAgentSessionLinkWaitResult(outcome: outcome, targets: states)
        case let .missing(sessionID):
            DomainAgentSessionLinkWaitResult(outcome: .linkUnavailable(sessionID: sessionID), targets: [])
        }
    }

    private func wakeWaiters(forTargetSession targetSessionID: UUID) {
        let candidates = waiters.values.filter { waiter in
            waiter.registrations.contains { $0.targetSessionID == targetSessionID }
        }
        for waiter in candidates {
            guard let outcome = firstSatisfiedOutcome(
                registrations: waiter.registrations,
                predicate: waiter.predicate
            ) else {
                continue
            }
            resumeWaiter(waiter.id, outcome: outcome, includeTargets: true)
        }
    }

    private func timeoutWaiter(_ waiterID: UUID) {
        resumeWaiter(waiterID, outcome: .timedOut, includeTargets: true)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        resumeWaiter(waiterID, outcome: .cancelled, includeTargets: false)
    }

    /// Removes the aggregate waiter from every sibling link before resuming it exactly once.
    private func resumeWaiter(
        _ waiterID: UUID,
        outcome: DomainAgentSessionLinkWaitOutcome,
        includeTargets: Bool
    ) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        for registration in waiter.registrations
            where links[registration.reference.linkID]?.activeWaiterID == waiterID
        {
            links[registration.reference.linkID]?.activeWaiterID = nil
        }
        waiter.timeoutTask?.cancel()
        let result = includeTargets
            ? waitResult(outcome: outcome, registrations: waiter.registrations)
            : DomainAgentSessionLinkWaitResult(outcome: outcome, targets: [])
        waiter.continuation.resume(returning: result)
    }

    // MARK: - Read cursors

    package func openReadCursor(
        lease: DomainAgentSessionLinkLease,
        anchor: DomainAgentSessionLinkReadAnchor,
        direction: DomainAgentSessionLinkReadDirection
    ) -> Result<DomainAgentSessionLinkReadCursorState, DomainAgentSessionLinkError> {
        guard !isDraining, !isShutDown else { return .failure(.runtimeShuttingDown) }
        if let error = validate(lease: lease) { return .failure(error) }
        guard lease.capability == .read else { return .failure(.capabilityDenied) }
        guard var record = links[lease.linkID] else { return .failure(.linkRevoked) }

        let state = DomainAgentSessionLinkReadCursorState(
            handle: Self.makeOpaqueHandle(prefix: "r"),
            linkID: record.grant.id,
            linkGeneration: record.grant.generation,
            targetSessionID: record.grant.target.sessionID,
            direction: direction,
            anchor: anchor
        )
        record.readCursors[state.handle] = state
        record.readCursorOrder.append(state.handle)
        while record.readCursorOrder.count > Self.readCursorsPerLinkLimit {
            let evicted = record.readCursorOrder.removeFirst()
            record.readCursors.removeValue(forKey: evicted)
        }
        links[lease.linkID] = record
        return .success(state)
    }

    /// Resolves an opaque read cursor. Old runtime generations, revoked/re-linked generations, wrong
    /// targets, forged handles, and LRU-evicted handles all return `expired`.
    package func resolveReadCursor(
        lease: DomainAgentSessionLinkLease,
        opaqueCursor: String
    ) -> DomainAgentSessionLinkReadCursorDisposition {
        guard !isShutDown, validate(lease: lease) == nil, lease.capability == .read else {
            return .expired
        }
        guard var record = links[lease.linkID],
              let state = record.readCursors[opaqueCursor],
              state.linkGeneration == record.grant.generation,
              state.targetSessionID == record.grant.target.sessionID
        else {
            return .expired
        }
        // Touch for LRU recency.
        if let index = record.readCursorOrder.firstIndex(of: opaqueCursor) {
            record.readCursorOrder.remove(at: index)
            record.readCursorOrder.append(opaqueCursor)
            links[lease.linkID] = record
        }
        return .resolved(state)
    }

    // MARK: - Send reservations

    /// Atomically returns a prior receipt, an in-progress marker, a ledger-full rejection, a digest
    /// conflict, or a new reservation bound to `(link generation, idempotency key, message digest)`.
    package func beginSend(
        lease: DomainAgentSessionLinkLease,
        idempotencyKey: String,
        messageDigest: String
    ) -> DomainAgentSessionLinkSendReservationDisposition {
        guard !isDraining, !isShutDown else { return .rejected(.runtimeShuttingDown) }
        if let error = validate(lease: lease) { return .rejected(error) }
        guard lease.capability == .sendWhenIdle else { return .rejected(.capabilityDenied) }
        let trimmedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              trimmedKey.utf8.count <= DomainAgentSessionLinkTextBudget.idempotencyKeyMaxBytes,
              !messageDigest.isEmpty,
              messageDigest.utf8.count <= DomainAgentSessionLinkTextBudget.messageDigestMaxBytes
        else {
            return .rejected(.invalidRequest)
        }

        let key = SendLedgerKey(
            linkID: lease.linkID,
            linkGeneration: lease.linkGeneration,
            idempotencyKey: trimmedKey
        )
        if let existing = sendLedger[key] {
            guard existing.reservation.messageDigest == messageDigest else { return .conflict }
            // Checked before the receipt so a tombstone is never mistaken for an undelivered retry.
            if existing.isIndeterminate { return .indeterminate }
            if let receipt = existing.receipt { return .duplicate(receipt.markedDuplicate()) }
            return .inProgress
        }

        // Reported separately: saturation clears on its own as sends settle, exhaustion does not clear
        // until a link generation is revoked or the runtime restarts. Collapsing them would tell a
        // caller to retry a rejection that can only ever be re-rejected.
        let inFlight = sendLedger.values.filter { !$0.isSettled }.count
        guard inFlight < Self.inFlightSendLimit else { return .inFlightLimitReached }
        let retained = sendLedger.values.filter(\.isSettled).count
        guard retained < Self.retainedSendOutcomeLimit else { return .retainedOutcomeLimitReached }

        let reservation = DomainAgentSessionLinkSendReservation(
            id: UUID(),
            linkID: lease.linkID,
            linkGeneration: lease.linkGeneration,
            observerSessionID: lease.observer.sessionID,
            targetSessionID: lease.target.sessionID,
            idempotencyKey: trimmedKey,
            messageDigest: messageDigest
        )
        sendLedger[key] = SendLedgerEntry(reservation: reservation, isCommitted: false, receipt: nil)
        sendLedgerOrder.append(key)
        return .reserved(reservation)
    }

    /// Non-mutating ledger lookup for one exact lease, key, and digest.
    ///
    /// Reserves nothing, so a queued send can learn that its key is already spent — or already
    /// conflicting — without occupying an in-flight slot for the whole time its message sits waiting
    /// for the target to become sendable. The disposition order deliberately mirrors `beginSend`, so
    /// the two can never disagree about what a stored entry means.
    package func probeSend(
        lease: DomainAgentSessionLinkLease,
        idempotencyKey: String,
        messageDigest: String
    ) -> DomainAgentSessionLinkSendLedgerProbe {
        guard !isDraining, !isShutDown else { return .rejected(.runtimeShuttingDown) }
        if let error = validate(lease: lease) { return .rejected(error) }
        guard lease.capability == .sendWhenIdle else { return .rejected(.capabilityDenied) }
        let trimmedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              trimmedKey.utf8.count <= DomainAgentSessionLinkTextBudget.idempotencyKeyMaxBytes,
              !messageDigest.isEmpty,
              messageDigest.utf8.count <= DomainAgentSessionLinkTextBudget.messageDigestMaxBytes
        else {
            return .rejected(.invalidRequest)
        }
        guard let existing = sendLedger[SendLedgerKey(
            linkID: lease.linkID,
            linkGeneration: lease.linkGeneration,
            idempotencyKey: trimmedKey
        )] else {
            return .unused
        }
        guard existing.reservation.messageDigest == messageDigest else { return .conflict }
        // Checked before the receipt for the same reason `beginSend` does it: a tombstone must never
        // be mistaken for an undelivered retry.
        if existing.isIndeterminate { return .indeterminate }
        if let receipt = existing.receipt { return .duplicate(receipt.markedDuplicate()) }
        return .inProgress
    }

    /// The authorization linearization fence.
    ///
    /// A manual revocation that wins this race cancels the send with no transcript mutation. A commit
    /// that wins first is allowed to settle even if manual Stop follows; lifecycle invalidation may
    /// still abort it later because the endpoint no longer exists.
    package func commitSendAuthorization(
        reservation: DomainAgentSessionLinkSendReservation,
        linkGeneration: UInt64
    ) -> DomainAgentSessionLinkSendCommitDisposition {
        guard !isShutDown else { return .shuttingDown }
        let key = ledgerKey(for: reservation)
        // Link liveness is the fence, checked before the ledger lookup: revocation eagerly drops the
        // uncommitted reservation, so an absent entry on a dead generation still means `linkRevoked`
        // rather than an unknown reservation.
        guard reservation.linkGeneration == linkGeneration,
              let record = links[reservation.linkID],
              record.grant.generation == linkGeneration
        else {
            if let entry = sendLedger[key], entry.reservation.id == reservation.id, !entry.isCommitted {
                sendLedger.removeValue(forKey: key)
                sendLedgerOrder.removeAll { $0 == key }
            }
            return .linkRevoked
        }
        guard var entry = sendLedger[key], entry.reservation.id == reservation.id else {
            return .unknownReservation
        }
        entry.isCommitted = true
        sendLedger[key] = entry
        return .committed
    }

    /// Settles a committed reservation with its stable receipt.
    ///
    /// When the owning link generation is already terminal the receipt is not retained: nothing can
    /// reference it again, and retaining it would leak a ledger slot for the runtime's lifetime.
    package func completeSend(
        reservation: DomainAgentSessionLinkSendReservation,
        receipt: DomainAgentSessionLinkSendReceipt
    ) {
        let key = ledgerKey(for: reservation)
        guard var entry = sendLedger[key], entry.reservation.id == reservation.id else { return }
        entry.receipt = receipt
        guard links[reservation.linkID]?.grant.generation == reservation.linkGeneration else {
            sendLedger.removeValue(forKey: key)
            sendLedgerOrder.removeAll { $0 == key }
            return
        }
        sendLedger[key] = entry
    }

    /// Settles a reservation whose durable outcome could not be determined.
    ///
    /// Persistence failure is not automatically "undelivered": the failed write may already have
    /// committed the row, and the compensating removal can fail too. Abandoning such a reservation
    /// would release the key for a fresh delivery that could duplicate a row already on disk, so the
    /// entry is instead retained as a terminal tombstone. It carries no receipt, so a retry replays
    /// no delivery either.
    ///
    /// Retention follows the same generation rule as `completeSend`: nothing can reference a
    /// terminal generation again, so its tombstone is dropped rather than leaking a ledger slot.
    package func settleIndeterminateSend(reservation: DomainAgentSessionLinkSendReservation) {
        let key = ledgerKey(for: reservation)
        guard var entry = sendLedger[key], entry.reservation.id == reservation.id, !entry.isSettled
        else {
            return
        }
        entry.isIndeterminate = true
        guard links[reservation.linkID]?.grant.generation == reservation.linkGeneration else {
            sendLedger.removeValue(forKey: key)
            sendLedgerOrder.removeAll { $0 == key }
            return
        }
        sendLedger[key] = entry
    }

    /// Releases an uncommitted or failed reservation so a later retry with the same key may proceed.
    /// It never retains an outcome, so no duplicate receipt can be replayed for a delivery that never
    /// happened.
    ///
    /// Only valid when the delivery provably did not commit. A failure that may have written durably
    /// must use `settleIndeterminateSend` instead.
    package func abandonSend(reservation: DomainAgentSessionLinkSendReservation) {
        let key = ledgerKey(for: reservation)
        guard let entry = sendLedger[key], entry.reservation.id == reservation.id, !entry.isSettled else {
            return
        }
        sendLedger.removeValue(forKey: key)
        sendLedgerOrder.removeAll { $0 == key }
    }

    package func storedSendReceipt(
        reservation: DomainAgentSessionLinkSendReservation
    ) -> DomainAgentSessionLinkSendReceipt? {
        sendLedger[ledgerKey(for: reservation)]?.receipt
    }

    private func ledgerKey(for reservation: DomainAgentSessionLinkSendReservation) -> SendLedgerKey {
        SendLedgerKey(
            linkID: reservation.linkID,
            linkGeneration: reservation.linkGeneration,
            idempotencyKey: reservation.idempotencyKey
        )
    }

    // MARK: - Revocation

    package func revoke(
        linkID: UUID,
        generation: UInt64,
        reason: DomainAgentSessionLinkRevocationReason
    ) -> DomainAgentSessionLinkRevocationDisposition {
        guard let record = links[linkID], record.grant.generation == generation else {
            return .notFound
        }
        let notices = revokeLinks(withIDs: [linkID], reason: reason)
        guard let notice = notices.first else { return .notFound }
        return .revoked(notice)
    }

    /// Revokes every link whose observer or target endpoint incarnation exactly matches `endpoint`.
    ///
    /// `notNewerThanAuthorityRevision` makes a stale lifecycle observation unable to remove a link
    /// that was activated after that observation was taken.
    @discardableResult
    package func invalidate(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        reason: DomainAgentSessionLinkRevocationReason,
        notNewerThanAuthorityRevision: UInt64? = nil
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        let affected = links.values
            .filter { $0.grant.observer == endpoint || $0.grant.target == endpoint }
            .filter { isNotNewer($0.activationAuthorityRevision, than: notNewerThanAuthorityRevision) }
            .map(\.grant.id)
        dropPendingReservations(notNewerThan: notNewerThanAuthorityRevision) {
            $0.observer == endpoint || $0.target == endpoint
        }
        return revokeLinks(withIDs: Set(affected), reason: reason)
    }

    private func isNotNewer(_ revision: UInt64, than limit: UInt64?) -> Bool {
        guard let limit else { return true }
        return revision <= limit
    }

    /// Drops matching pending reservations, honouring the same staleness fence used for active links
    /// so a late lifecycle observation cannot cancel a reservation created after it was taken.
    private func dropPendingReservations(
        notNewerThan limit: UInt64?,
        matching predicate: (DomainAgentSessionLinkPendingReservation) -> Bool
    ) {
        pendingReservations = pendingReservations.filter { _, reservation in
            guard predicate(reservation) else { return true }
            return !isNotNewer(reservation.reservedAtAuthorityRevision, than: limit)
        }
    }

    /// Revokes every link touching `sessionID` regardless of incarnation. Used when the session is
    /// known to be gone (delete, tab close) rather than merely rebound.
    @discardableResult
    package func invalidateSession(
        sessionID: UUID,
        reason: DomainAgentSessionLinkRevocationReason,
        notNewerThanAuthorityRevision: UInt64? = nil
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        let affected = links.values
            .filter { $0.grant.observer.sessionID == sessionID || $0.grant.target.sessionID == sessionID }
            .filter { isNotNewer($0.activationAuthorityRevision, than: notNewerThanAuthorityRevision) }
            .map(\.grant.id)
        dropPendingReservations(notNewerThan: notNewerThanAuthorityRevision) {
            $0.observer.sessionID == sessionID || $0.target.sessionID == sessionID
        }
        return revokeLinks(withIDs: Set(affected), reason: reason)
    }

    @discardableResult
    package func invalidateWindow(
        windowID: Int,
        reason: DomainAgentSessionLinkRevocationReason,
        notNewerThanAuthorityRevision: UInt64? = nil
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        let affected = links.values
            .filter { $0.grant.observer.windowID == windowID || $0.grant.target.windowID == windowID }
            .filter { isNotNewer($0.activationAuthorityRevision, than: notNewerThanAuthorityRevision) }
            .map(\.grant.id)
        dropPendingReservations(notNewerThan: notNewerThanAuthorityRevision) {
            $0.observer.windowID == windowID || $0.target.windowID == windowID
        }
        return revokeLinks(withIDs: Set(affected), reason: reason)
    }

    @discardableResult
    package func invalidateWorkspace(
        workspaceID: UUID,
        windowID: Int? = nil,
        reason: DomainAgentSessionLinkRevocationReason,
        notNewerThanAuthorityRevision: UInt64? = nil
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        func matches(_ endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
            guard endpoint.workspaceID == workspaceID else { return false }
            guard let windowID else { return true }
            return endpoint.windowID == windowID
        }
        let affected = links.values
            .filter { matches($0.grant.observer) || matches($0.grant.target) }
            .filter { isNotNewer($0.activationAuthorityRevision, than: notNewerThanAuthorityRevision) }
            .map(\.grant.id)
        dropPendingReservations(notNewerThan: notNewerThanAuthorityRevision) {
            matches($0.observer) || matches($0.target)
        }
        return revokeLinks(withIDs: Set(affected), reason: reason)
    }

    @discardableResult
    private func revokeLinks(
        withIDs linkIDs: Set<UUID>,
        reason: DomainAgentSessionLinkRevocationReason
    ) -> [DomainAgentSessionLinkRevocationNotice] {
        guard !linkIDs.isEmpty else { return [] }
        var notices: [DomainAgentSessionLinkRevocationNotice] = []
        var touchedObservers: Set<UUID> = []
        var touchedTargets: Set<UUID> = []
        let revokedAt = now()

        for linkID in linkIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = links.removeValue(forKey: linkID) else { continue }
            let grant = record.grant
            touchedObservers.insert(grant.observer.sessionID)
            touchedTargets.insert(grant.target.sessionID)
            // Captured before teardown so the last inbound revocation still names its target.
            let targetDisplayName = targets[grant.target.sessionID]?.snapshot.displayName

            // Detach target observation once the last inbound link is gone.
            if var target = targets[grant.target.sessionID] {
                target.inboundLinkIDs.remove(linkID)
                if target.inboundLinkIDs.isEmpty {
                    targets.removeValue(forKey: grant.target.sessionID)
                } else {
                    targets[grant.target.sessionID] = target
                }
            }

            // Read cursors die with the record; uncommitted reservations and retained outcomes for
            // this generation are released here.
            releaseSendLedger(forLinkID: linkID, generation: grant.generation)

            let notice = DomainAgentSessionLinkRevocationNotice(
                linkID: grant.id,
                generation: grant.generation,
                observerSessionID: grant.observer.sessionID,
                targetSessionID: grant.target.sessionID,
                observerEndpoint: grant.observer,
                targetEndpoint: grant.target,
                targetDisplayName: targetDisplayName,
                observerDisplayName: nil,
                reason: reason,
                revokedAt: revokedAt
            )
            notices.append(notice)
            recordRevocationNotice(notice, observer: grant.observer, target: grant.target)

            if let waiterID = record.activeWaiterID {
                resumeWaiter(waiterID, outcome: .revoked(notice), includeTargets: false)
            }
        }

        guard !notices.isEmpty else { return [] }
        let revision = advanceAuthorityRevision()
        // Inbound membership changed for each affected target, so its own revision advances too.
        for targetSessionID in touchedTargets.sorted(by: { $0.uuidString < $1.uuidString }) {
            advanceTargetLinkSetRevision(targetSessionID)
        }
        for observerSessionID in touchedObservers.sorted(by: { $0.uuidString < $1.uuidString }) {
            let linkSetRevision = advanceObserverLinkSetRevision(observerSessionID)
            let notice = notices.first { $0.observerSessionID == observerSessionID }
            publish(DomainAgentSessionLinkChangeEvent(
                kind: .revoked,
                authorityRevision: revision,
                linkID: notice?.linkID,
                linkGeneration: notice?.generation,
                observerSessionID: observerSessionID,
                targetSessionID: notice?.targetSessionID,
                observerLinkSetRevision: linkSetRevision
            ))
        }
        return notices
    }

    /// Revocation releases this generation's retained outcomes and cancels its uncommitted
    /// reservations.
    ///
    /// A committed-but-unsettled reservation is deliberately retained: its authorization commit fence
    /// already won the race against manual revocation, so it must still be allowed to settle exactly
    /// once. `completeSend` drops it immediately afterwards because nothing can replay it.
    private func releaseSendLedger(forLinkID linkID: UUID, generation: UInt64) {
        let doomed = sendLedger.filter { key, entry in
            key.linkID == linkID
                && key.linkGeneration == generation
                && (!entry.isCommitted || entry.isSettled)
        }.map(\.key)
        guard !doomed.isEmpty else { return }
        for key in doomed {
            sendLedger.removeValue(forKey: key)
        }
        let doomedSet = Set(doomed)
        sendLedgerOrder.removeAll { doomedSet.contains($0) }
    }

    /// Records one notice against both exact endpoint incarnations of the revoked grant.
    private func recordRevocationNotice(
        _ notice: DomainAgentSessionLinkRevocationNotice,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) {
        for endpoint in [observer, target] {
            var notices = recentRevocationNotices[endpoint] ?? []
            notices.append(notice)
            if notices.count > Self.recentRevocationNoticesPerEndpoint {
                notices.removeFirst(notices.count - Self.recentRevocationNoticesPerEndpoint)
            }
            if recentRevocationNotices.updateValue(notices, forKey: endpoint) != nil {
                recentRevocationNoticeOrder.removeAll { $0 == endpoint }
            }
            recentRevocationNoticeOrder.append(endpoint)
        }
        while recentRevocationNoticeOrder.count > Self.recentRevocationNoticeEndpointLimit {
            let evicted = recentRevocationNoticeOrder.removeFirst()
            recentRevocationNotices.removeValue(forKey: evicted)
        }
    }

    package func clearRecentRevocationNotices(
        forEndpoint endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard recentRevocationNotices.removeValue(forKey: endpoint) != nil else { return }
        recentRevocationNoticeOrder.removeAll { $0 == endpoint }
    }

    // MARK: - Two-phase shutdown

    /// Phase one, called *before* `domainHost.drain`.
    ///
    /// New work is rejected and every parked wait resumes while its MCP invocation can still settle.
    /// Placing the only waiter wake after the host has cancelled its invocations would strand them.
    package func beginDrain() {
        guard !isDraining, !isShutDown else { return }
        isDraining = true
        pendingReservations.removeAll()
        let revision = advanceAuthorityRevision()
        for waiterID in waiters.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            resumeWaiter(waiterID, outcome: .shuttingDown, includeTargets: false)
        }
        publish(DomainAgentSessionLinkChangeEvent(kind: .draining, authorityRevision: revision))
    }

    /// Phase two, called *after* host drain completes.
    ///
    /// Clears links, cursors, ledger, and subscribers, then advances the runtime generation so no
    /// previously issued lease or cursor can authorize anything.
    package func finishShutdown() {
        guard !isShutDown else { return }
        isDraining = true
        for waiterID in waiters.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            resumeWaiter(waiterID, outcome: .shuttingDown, includeTargets: false)
        }
        isShutDown = true
        links.removeAll()
        pendingReservations.removeAll()
        targets.removeAll()
        nextChangeSequenceBySession.removeAll()
        recentRevocationNotices.removeAll()
        recentRevocationNoticeOrder.removeAll()
        sendLedger.removeAll()
        sendLedgerOrder.removeAll()
        runtimeGenerationOffset &+= 1
        let revision = advanceAuthorityRevision()
        publish(DomainAgentSessionLinkChangeEvent(kind: .shutdown, authorityRevision: revision))
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }
}
