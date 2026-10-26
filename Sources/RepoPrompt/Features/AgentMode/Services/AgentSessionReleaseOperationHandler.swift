import Foundation
import MCP
import RepoPromptDomainRuntime

/// Read + unlink access to oversight links. Unlink always goes through the bridge's
/// `stopMonitorLink`, so the link authority stays the sole owner of link lifecycle (and the durable
/// intent removal and Auto-wake target cleanup that path performs).
@MainActor
protocol AgentSessionLinkReleasing: AnyObject {
    func oversightInventory() async -> (
        live: [DomainAgentSessionLinkInventoryItem],
        persisted: [AgentSessionOversightIntent]
    )
    func stopLink(_ item: DomainAgentSessionLinkInventoryItem, isStillAuthorized: @escaping @MainActor () -> Bool) async -> AgentMonitorStopOutcome
}

@MainActor
final class BridgeAgentSessionLinkReleaser: AgentSessionLinkReleasing {
    func oversightInventory() async -> (
        live: [DomainAgentSessionLinkInventoryItem],
        persisted: [AgentSessionOversightIntent]
    ) {
        await AgentSessionLinkRuntimeBridge.shared.oversightInventory()
    }

    func stopLink(_ item: DomainAgentSessionLinkInventoryItem, isStillAuthorized: @escaping @MainActor () -> Bool) async -> AgentMonitorStopOutcome {
        await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
            observerSessionID: item.observerSessionID,
            targetSessionID: item.targetSessionID,
            linkID: item.linkID,
            generation: item.generation,
            isStillAuthorized: isStillAuthorized
        )
    }
}

/// `release` (unlink + clear Auto-wake for the targets' links) and `retire` (stop if running and
/// permitted, release, archive).
///
/// Only links whose *other* endpoint is also a scope member are unlinked: a scope restructures links
/// among its members and never reaches past them. Auto-wake for an unlinked pair is cleared by the
/// Stop path itself; the observer's Auto-wake preference is inert once it oversees nothing.
/// Durable intents with no live link are reported, never removed here.
@MainActor
final class AgentSessionReleaseOperationHandler: AgentSessionAdministrationOperationHandler {
    let operations: Set<DomainAgentSessionTargetOperation> = [.adminRelease, .adminRetire]

    private let backend: any AgentSessionOrganizingBackend
    private let links: any AgentSessionLinkReleasing
    private let isLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool
    /// Whether a session is a member of the scope (and every ancestor of an attenuated scope).
    private let isMember: @MainActor (UUID, DomainDelegationScopeRecord) -> Bool
    /// Whether the scope is still live and its whole chain holds `control`.
    private let holdsControl: @MainActor (DomainDelegationScopeRecord) -> Bool

    init(
        backend: any AgentSessionOrganizingBackend,
        links: any AgentSessionLinkReleasing,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        isMember: @escaping @MainActor (UUID, DomainDelegationScopeRecord) -> Bool,
        holdsControl: @escaping @MainActor (DomainDelegationScopeRecord) -> Bool
    ) {
        self.backend = backend
        self.links = links
        self.isLeaseCurrent = isLeaseCurrent
        self.isMember = isMember
        self.holdsControl = holdsControl
    }

    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        let effect = request.operation == .adminRetire
            ? "Stop if running, unlink its oversight links, and archive"
            : "Unlink its oversight links among scope members and clear their Auto-wake"
        return request.targetSessionIDs.map { id in
            BatchConfirmationItem(sessionID: id, title: backend.state(of: id)?.name ?? id.uuidString, effect: effect)
        }
    }

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let leases = Dictionary(batch.leases.map { ($0.targetSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        func isCurrent(_ id: UUID) -> Bool {
            !Task.isCancelled && (leases[id].map(isLeaseCurrent) ?? false) && isMember(id, batch.scope)
        }
        var items: [AgentSessionAdminItemResult] = []
        var released: Set<UUID> = []
        var totalUnlinked = 0
        // Any durable side effect (a stop, an unlink, an archive), even on an item that ends `failed`
        // or `skipped`. The reply then reports `committed_changes`, so the call's receipt is recorded
        // for idempotent replay and a same-key retry never re-runs work that already took effect.
        var committed = false
        let retiring = batch.request.operation == .adminRetire
        let backend = backend
        let holdsControl = holdsControl
        let scope = batch.scope
        /// Retire may act on a target only while it is idle (aggregated across every window) or the
        /// scope chain holds `control`. Re-read after every suspension, before each step.
        func runStateAllows(_ id: UUID) -> Bool {
            !retiring || backend.runState(of: id) == .idle || holdsControl(scope)
        }

        for target in batch.admittedSessionIDs {
            var detail: [String: Value] = [:]
            var targetChanged = false
            if retiring {
                guard backend.state(of: target) != nil else {
                    items.append(.init(sessionID: target, status: .skipped, reason: "workspace_not_loaded"))
                    continue
                }
                if backend.runState(of: target) != .idle {
                    guard isCurrent(target) else {
                        items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current"))
                        continue
                    }
                    // The target may have been idle when it was authorized and started running since.
                    // Stopping it needs `control` now; without it nothing is done to this target.
                    guard holdsControl(batch.scope) else {
                        items.append(.init(sessionID: target, status: .skipped, reason: "requires_control"))
                        continue
                    }
                    let stop = await backend.stopRun(target, isStillAuthorized: {
                        isCurrent(target) && holdsControl(scope)
                    })
                    detail["stopped"] = .bool(stop.stopped)
                    detail["stop_requested"] = .bool(stop.initiatedCancellation)
                    if stop.initiatedCancellation {
                        committed = true
                        targetChanged = true
                    }
                    // The Stop may have committed preparation but lost terminal publication.
                    // Retain that receipt; control permission is not proof that a run settled.
                    guard isCurrent(target) else {
                        items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                        continue
                    }
                    guard backend.state(of: target) != nil else {
                        items.append(.init(sessionID: target, status: .skipped, reason: "workspace_not_loaded", detail: detail))
                        continue
                    }
                    guard backend.runState(of: target) == .idle else {
                        items.append(.init(sessionID: target, status: .failed, reason: "stop_unconfirmed", detail: detail))
                        continue
                    }
                }
            }

            // Fresh inventory per target: an earlier Stop may have retired shared links.
            let inventory = await links.oversightInventory()
            guard isCurrent(target) else {
                items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                continue
            }
            guard runStateAllows(target) else {
                items.append(.init(sessionID: target, status: .skipped, reason: "requires_control", detail: detail))
                continue
            }
            var unlinked = 0
            var outsideScope = 0
            var failures: [String] = []
            var refusedOnAuthority = false
            var refusedOnRunState = false
            for item in inventory.live where item.observerSessionID == target || item.targetSessionID == target {
                guard !released.contains(item.linkID) else { continue }
                // This reference remains unhandled. Check target authority before classifying its
                // counterpart, so an interrupted traversal cannot masquerade as outsider filtering.
                guard isCurrent(target) else {
                    refusedOnAuthority = true
                    break
                }
                let counterpart = item.observerSessionID == target ? item.targetSessionID : item.observerSessionID
                guard isMember(counterpart, batch.scope) else {
                    outsideScope += 1
                    continue
                }
                // Each unlink suspends; a retire target that starts running meanwhile is not unlinked
                // further (nor archived) without `control`.
                guard runStateAllows(target) else {
                    refusedOnRunState = true
                    break
                }
                switch await links.stopLink(item, isStillAuthorized: {
                    isCurrent(target) && self.isMember(counterpart, batch.scope) && runStateAllows(target)
                }) {
                case .stopped:
                    unlinked += 1
                    released.insert(item.linkID)
                case .alreadyStopped:
                    released.insert(item.linkID)
                case let .failed(message):
                    failures.append(message)
                }
            }
            let liveTouching = Set(
                inventory.live.filter { $0.observerSessionID == target || $0.targetSessionID == target }
                    .map { AgentSessionOversightIntent(observerSessionID: $0.observerSessionID, targetSessionID: $0.targetSessionID) }
            )
            let dormant = inventory.persisted.count(where: { $0.touches(sessionID: target) && !liveTouching.contains($0) })
            totalUnlinked += unlinked
            if unlinked > 0 {
                committed = true
                targetChanged = true
            }
            detail["unlinked"] = .int(unlinked)
            if outsideScope > 0 { detail["links_outside_scope"] = .int(outsideScope) }
            if dormant > 0 { detail["dormant_intents"] = .int(dormant) }
            if !failures.isEmpty { detail["unlink_failures"] = .array(failures.map(Value.string)) }
            if refusedOnAuthority {
                items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                continue
            }
            if refusedOnRunState {
                items.append(.init(sessionID: target, status: .skipped, reason: "requires_control", detail: detail))
                continue
            }

            if retiring {
                guard isCurrent(target) else {
                    items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                    continue
                }
                guard runStateAllows(target) else {
                    items.append(.init(sessionID: target, status: .skipped, reason: "requires_control", detail: detail))
                    continue
                }
                guard let beforeArchive = backend.state(of: target) else {
                    items.append(.init(sessionID: target, status: .skipped, reason: "workspace_not_loaded", detail: detail))
                    continue
                }
                // An archived target can still have links to release. Check its archive requirement
                // only after those steps, without counting an existing stash as our own effect.
                let refusals = AgentSessionRunStateRefusals()
                let archiveChanged = if beforeArchive.isArchived {
                    false
                } else {
                    await backend.archive([target], isAuthorized: { id in
                        guard isCurrent(id) else {
                            refusals.clear(id)
                            return false
                        }
                        return refusals.admit(id, runStateAllows(id))
                    }).contains(target)
                }
                detail["archive_changed"] = .bool(archiveChanged)
                if archiveChanged {
                    committed = true
                    targetChanged = true
                } else {
                    // A failed transition may have suspended. Never reinterpret its refusal as an
                    // already-satisfied target after the lease or run-state authority changed.
                    guard isCurrent(target) else {
                        items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                        continue
                    }
                    guard !refusals.refused.contains(target), runStateAllows(target) else {
                        items.append(.init(sessionID: target, status: .skipped, reason: "requires_control", detail: detail))
                        continue
                    }
                }
                let currentState = backend.state(of: target)
                if let currentState { detail["archived"] = .bool(currentState.isArchived) }
                let archiveSatisfied = archiveChanged || currentState?.isArchived == true
                detail["archive_result"] = .string(archiveChanged ? "changed" : (archiveSatisfied ? "already_archived" : "rejected"))
                let reason = !archiveSatisfied ? "archive_rejected" : (failures.isEmpty ? nil : "unlink_failed")
                let status: AgentSessionAdminItemResult.Status = reason == nil
                    ? (targetChanged ? .changed : .unchanged)
                    : .failed
                items.append(.init(sessionID: target, status: status, reason: reason, detail: detail))
            } else {
                let status: AgentSessionAdminItemResult.Status = failures.isEmpty
                    ? (unlinked > 0 ? .changed : .unchanged)
                    : .failed
                items.append(.init(sessionID: target, status: status, reason: failures.isEmpty ? nil : "unlink_failed", detail: detail))
            }
        }
        var extra: [String: Value] = ["unlinked_total": .int(totalUnlinked)]
        if committed { extra[AgentSessionAdminRendering.committedChangesKey] = .bool(true) }
        if items.contains(where: { $0.detail["dormant_intents"] != nil }) {
            extra["dormant_intents_detail"] = .string(
                "Saved links whose sessions are not live were left in place; they are released when the user stops them or deletes a session."
            )
        }
        return AgentSessionAdminRendering.mutationValue(
            operation: batch.request.operation,
            items: items,
            itemsRequiringControl: batch.itemsRequiringControl,
            extra: extra
        )
    }
}
