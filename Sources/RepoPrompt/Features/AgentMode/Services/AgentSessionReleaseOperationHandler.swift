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
    func stopLink(_ item: DomainAgentSessionLinkInventoryItem) async -> AgentMonitorStopOutcome
}

@MainActor
final class BridgeAgentSessionLinkReleaser: AgentSessionLinkReleasing {
    func oversightInventory() async -> (
        live: [DomainAgentSessionLinkInventoryItem],
        persisted: [AgentSessionOversightIntent]
    ) {
        await AgentSessionLinkRuntimeBridge.shared.oversightInventory()
    }

    func stopLink(_ item: DomainAgentSessionLinkInventoryItem) async -> AgentMonitorStopOutcome {
        await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
            observerSessionID: item.observerSessionID,
            targetSessionID: item.targetSessionID,
            linkID: item.linkID,
            generation: item.generation
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

    init(
        backend: any AgentSessionOrganizingBackend,
        links: any AgentSessionLinkReleasing,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        isMember: @escaping @MainActor (UUID, DomainDelegationScopeRecord) -> Bool
    ) {
        self.backend = backend
        self.links = links
        self.isLeaseCurrent = isLeaseCurrent
        self.isMember = isMember
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
            leases[id].map(isLeaseCurrent) ?? false
        }
        var items: [AgentSessionAdminItemResult] = []
        var released: Set<UUID> = []
        var totalUnlinked = 0
        let retiring = batch.request.operation == .adminRetire

        for target in batch.admittedSessionIDs {
            var detail: [String: Value] = [:]
            if retiring {
                guard let state = backend.state(of: target) else {
                    items.append(.init(sessionID: target, status: .skipped, reason: "workspace_not_loaded"))
                    continue
                }
                if state.runState != .idle {
                    // Admitted while not idle means the scope holds `control` (otherwise the authority
                    // set this item aside as `requires_control`).
                    guard isCurrent(target) else {
                        items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current"))
                        continue
                    }
                    detail["stopped"] = .bool(await backend.stopRun(target))
                }
            }

            // Fresh inventory per target: an earlier Stop may have retired shared links.
            let inventory = await links.oversightInventory()
            guard isCurrent(target) else {
                items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                continue
            }
            var unlinked = 0
            var outsideScope = 0
            var failures: [String] = []
            for item in inventory.live where item.observerSessionID == target || item.targetSessionID == target {
                guard !released.contains(item.linkID) else { continue }
                let counterpart = item.observerSessionID == target ? item.targetSessionID : item.observerSessionID
                guard isMember(counterpart, batch.scope) else {
                    outsideScope += 1
                    continue
                }
                guard isCurrent(target) else { break }
                switch await links.stopLink(item) {
                case .stopped:
                    unlinked += 1
                    released.insert(item.linkID)
                case .alreadyStopped:
                    released.insert(item.linkID)
                case let .failed(message):
                    failures.append(message)
                }
            }
            let liveTouching = Set(inventory.live.filter { $0.observerSessionID == target || $0.targetSessionID == target }
                .map { AgentSessionOversightIntent(observerSessionID: $0.observerSessionID, targetSessionID: $0.targetSessionID) })
            let dormant = inventory.persisted.filter { $0.touches(sessionID: target) && !liveTouching.contains($0) }.count
            totalUnlinked += unlinked
            detail["unlinked"] = .int(unlinked)
            if outsideScope > 0 { detail["links_outside_scope"] = .int(outsideScope) }
            if dormant > 0 { detail["dormant_intents"] = .int(dormant) }
            if !failures.isEmpty { detail["unlink_failures"] = .array(failures.map(Value.string)) }

            if retiring {
                guard isCurrent(target) else {
                    items.append(.init(sessionID: target, status: .failed, reason: "scope_no_longer_current", detail: detail))
                    continue
                }
                let archived = await backend.archive([target]).contains(target)
                detail["archived"] = .bool(archived)
                let status: AgentSessionAdminItemResult.Status = archived ? .changed : (unlinked > 0 ? .changed : .failed)
                items.append(.init(sessionID: target, status: status, reason: archived ? nil : "archive_rejected", detail: detail))
            } else {
                let status: AgentSessionAdminItemResult.Status = failures.isEmpty
                    ? (unlinked > 0 ? .changed : .unchanged)
                    : .failed
                items.append(.init(sessionID: target, status: status, reason: failures.isEmpty ? nil : "unlink_failed", detail: detail))
            }
        }
        var extra: [String: Value] = ["unlinked_total": .int(totalUnlinked)]
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
