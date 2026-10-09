import Combine
import Foundation
import RepoPromptDomainRuntime

/// One row on a batch confirmation card.
struct BatchConfirmationItem: Identifiable, Hashable {
    let sessionID: UUID
    let title: String
    /// Human-readable per-item effect, for example "Unbind worktree and mark stale".
    let effect: String

    var id: UUID {
        sessionID
    }
}

/// One batch confirmation card (design §2.5).
///
/// It is bound to the exact scope generation, operation, idempotency key, and item set it was
/// created for. The user may untick individual items; approval authorizes only the ticked subset.
/// Cards never pass through the oversight transport: they are presentation plus an authority input.
struct PendingBatchConfirmation: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case approved
        /// The approval is being applied right now. It authorizes nothing further, so a concurrent
        /// replay cannot double-apply; a failed application returns the card to `approved`.
        case applying
        /// The approval was applied successfully and cannot be replayed.
        case consumed
        case denied(reason: String?)
        /// The bound scope was revoked, expired, or re-generated before a decision.
        case invalidated
    }

    let id: UUID
    let scopeID: UUID
    let scopeGeneration: UInt64
    let operation: DomainAgentSessionTargetOperation
    let idempotencyKey: String
    let granteeSessionID: UUID
    /// The tab whose Agent Mode view shows the card.
    let granteeTabID: UUID?
    let reason: DomainDelegationScopeConfirmationReason
    let items: [BatchConfirmationItem]
    /// `DomainDelegationScopeArgumentsDigest` of the arguments the card was raised for.
    let argumentsDigest: String
    let createdAt: Date
    var untickedSessionIDs: Set<UUID> = []
    var state: State = .pending

    var itemSessionIDs: Set<UUID> {
        Set(items.map(\.sessionID))
    }

    var approvedSessionIDs: Set<UUID> {
        itemSessionIDs.subtracting(untickedSessionIDs)
    }

    /// The domain authority input, available only once the user approved.
    var domainConfirmation: DomainDelegationScopeConfirmation? {
        guard state == .approved else { return nil }
        return DomainDelegationScopeConfirmation(
            confirmationID: id,
            scopeID: scopeID,
            scopeGeneration: scopeGeneration,
            operation: operation,
            idempotencyKey: idempotencyKey,
            approvedSessionIDs: approvedSessionIDs,
            argumentsDigest: argumentsDigest
        )
    }
}

enum BatchConfirmationRequestResult: Equatable {
    case created(PendingBatchConfirmation)
    /// An identical retry under the same key: same scope generation, operation, item set, and
    /// arguments.
    case existing(PendingBatchConfirmation)
    /// The key is already bound to a different request.
    case idempotencyConflict
    /// The grantee already has the maximum number of undecided cards.
    case tooManyPending
}

/// Owns pending batch confirmation cards. Process-local; cards do not survive relaunch.
@MainActor
final class BatchConfirmationCoordinator: ObservableObject {
    private struct Key: Hashable {
        let granteeSessionID: UUID
        let idempotencyKey: String
    }

    /// Bounded retention of decided cards so `confirmation_status` can report outcomes.
    static let maxRetainedConfirmations = 256
    /// Undecided cards per grantee. Keeps an agent minting new keys from flooding the user.
    static let maxPendingPerGrantee = 8

    @Published private(set) var confirmations: [UUID: PendingBatchConfirmation] = [:]
    private var confirmationIDByKey: [Key: UUID] = [:]
    private var order: [UUID] = []
    private let now: () -> Date
    private let makeUUID: () -> UUID

    init(now: @escaping () -> Date = Date.init, makeUUID: @escaping () -> UUID = UUID.init) {
        self.now = now
        self.makeUUID = makeUUID
    }

    func request(
        scope: DomainDelegationScopeRecord,
        operation: DomainAgentSessionTargetOperation,
        idempotencyKey: String,
        granteeTabID: UUID?,
        reason: DomainDelegationScopeConfirmationReason,
        items: [BatchConfirmationItem],
        argumentsDigest: String = ""
    ) -> BatchConfirmationRequestResult {
        let key = Key(granteeSessionID: scope.grant.granteeSessionID, idempotencyKey: idempotencyKey)
        if let existingID = confirmationIDByKey[key], let existing = confirmations[existingID] {
            // Same key with different arguments is a conflict, never the earlier card.
            let sameRequest = existing.scopeID == scope.id
                && existing.scopeGeneration == scope.generation
                && existing.operation == operation
                && existing.argumentsDigest == argumentsDigest
                && existing.itemSessionIDs == Set(items.map(\.sessionID))
            return sameRequest ? .existing(existing) : .idempotencyConflict
        }
        let pendingForGrantee = confirmations.values.filter {
            $0.granteeSessionID == scope.grant.granteeSessionID && $0.state == .pending
        }.count
        guard pendingForGrantee < Self.maxPendingPerGrantee else { return .tooManyPending }
        let confirmation = PendingBatchConfirmation(
            id: makeUUID(),
            scopeID: scope.id,
            scopeGeneration: scope.generation,
            operation: operation,
            idempotencyKey: idempotencyKey,
            granteeSessionID: scope.grant.granteeSessionID,
            granteeTabID: granteeTabID,
            reason: reason,
            items: items,
            argumentsDigest: argumentsDigest,
            createdAt: now()
        )
        confirmations[confirmation.id] = confirmation
        confirmationIDByKey[key] = confirmation.id
        order.append(confirmation.id)
        trimRetention()
        return .created(confirmation)
    }

    /// Ticks or unticks one item on a pending card. Ignored once decided.
    func setItem(_ sessionID: UUID, ticked: Bool, confirmationID: UUID) {
        guard var confirmation = confirmations[confirmationID],
              confirmation.state == .pending,
              confirmation.itemSessionIDs.contains(sessionID)
        else { return }
        if ticked {
            confirmation.untickedSessionIDs.remove(sessionID)
        } else {
            confirmation.untickedSessionIDs.insert(sessionID)
        }
        confirmations[confirmationID] = confirmation
    }

    /// Approves the ticked subset. An approval with every item unticked is a denial.
    @discardableResult
    func approve(confirmationID: UUID) -> DomainDelegationScopeConfirmation? {
        guard var confirmation = confirmations[confirmationID], confirmation.state == .pending else { return nil }
        guard !confirmation.approvedSessionIDs.isEmpty else {
            confirmation.state = .denied(reason: "No items were selected.")
            confirmations[confirmationID] = confirmation
            return nil
        }
        confirmation.state = .approved
        confirmations[confirmationID] = confirmation
        return confirmation.domainConfirmation
    }

    /// Claims an approved card for one application before the handler runs. Returns `false` if the
    /// card is not (or no longer) approved, so a concurrent replay cannot apply it twice.
    @discardableResult
    func beginApplying(confirmationID: UUID) -> Bool {
        guard var confirmation = confirmations[confirmationID], confirmation.state == .approved else { return false }
        confirmation.state = .applying
        confirmations[confirmationID] = confirmation
        return true
    }

    /// Settles a claimed card: `consumed` only after the handler succeeded; a failure returns it to
    /// `approved` so the same approval can be retried.
    func finishApplying(confirmationID: UUID, succeeded: Bool) {
        guard var confirmation = confirmations[confirmationID], confirmation.state == .applying else { return }
        confirmation.state = succeeded ? .consumed : .approved
        confirmations[confirmationID] = confirmation
    }

    func deny(confirmationID: UUID, reason: String? = nil) {
        guard var confirmation = confirmations[confirmationID], confirmation.state == .pending else { return }
        confirmation.state = .denied(reason: reason)
        confirmations[confirmationID] = confirmation
    }

    /// Invalidates every undecided or approved-but-unused card bound to the scope (revocation,
    /// expiry, re-generation). An approval for a generation that no longer exists authorizes nothing.
    func invalidate(scopeID: UUID) {
        for (id, confirmation) in confirmations
            where confirmation.scopeID == scopeID && (confirmation.state == .pending || confirmation.state == .approved)
        {
            var updated = confirmation
            updated.state = .invalidated
            confirmations[id] = updated
        }
    }

    /// The card, but only for the session it was created for.
    func confirmation(id: UUID, granteeSessionID: UUID) -> PendingBatchConfirmation? {
        guard let confirmation = confirmations[id], confirmation.granteeSessionID == granteeSessionID else {
            return nil
        }
        return confirmation
    }

    func pendingConfirmations(forTab tabID: UUID) -> [PendingBatchConfirmation] {
        order.compactMap { confirmations[$0] }
            .filter { $0.granteeTabID == tabID && $0.state == .pending }
    }

    private func trimRetention() {
        while order.count > Self.maxRetainedConfirmations {
            // Never evict an undecided card; drop the oldest decided one instead.
            guard let index = order.firstIndex(where: { confirmations[$0]?.state != .pending }) else { return }
            let id = order.remove(at: index)
            if let removed = confirmations.removeValue(forKey: id) {
                confirmationIDByKey.removeValue(forKey: Key(
                    granteeSessionID: removed.granteeSessionID,
                    idempotencyKey: removed.idempotencyKey
                ))
            }
        }
    }
}
