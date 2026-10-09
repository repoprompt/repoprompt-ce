import Foundation
import MCP
import RepoPromptDomainRuntime

/// `link`, `unlink`, `reparent`, `adopt`, and `attenuate` under a delegation scope.
///
/// - Links are created and removed only through the link bridge, so link authority stays their sole
///   owner. A new link may carry no capability the scope does not hold (S8 ceiling), and an existing
///   link is reported as-is and never upgraded. Management never chains: both endpoints must
///   themselves be members of the caller's scope.
/// - Placement changes write only the mutable `organizationalParentID`; spawn provenance is
///   untouched. `reparent` needs both endpoints in scope, and neither `reparent` nor `adopt` may
///   change the membership of any live scope outside the caller's own chain (S9).
/// - `attenuate` creates a nested sub-scope for a member without a prompt, via the scope runtime.
@MainActor
final class SessionAdminRestructureHandler: AgentSessionAdministrationOperationHandler {
    let operations: Set<DomainAgentSessionTargetOperation> = [
        .adminLink, .adminUnlink, .adminReparent, .adminAdopt, .adminAttenuate
    ]

    private let context: SessionAdminHandlerContext
    private let host: any SessionAdminStructureHost
    private let now: () -> Date

    init(context: SessionAdminHandlerContext, host: any SessionAdminStructureHost, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.host = host
        self.now = now
    }

    // MARK: - Cards

    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        guard request.operation == .adminAdopt else {
            return request.targetSessionIDs.map {
                BatchConfirmationItem(sessionID: $0, title: title(of: $0), effect: request.operation.rawValue)
            }
        }
        let destination = (try? SessionAdminArguments.uuid(request.arguments, "parent_session_id", op: "adopt"))
            ?? request.caller.agentSessionID
        let destinationName = destination.map(title(of:)) ?? "the overseer"
        // Every session that moves is listed: each adoptee and every organizational descendant, so the
        // user sees the whole subtree the scope will gain.
        var items: [BatchConfirmationItem] = []
        var listed: Set<UUID> = []
        var adoptees: [UUID] = []
        var descendantsByAdoptee: [UUID: [UUID]] = [:]
        for adoptee in request.targetSessionIDs {
            if listed.contains(adoptee) {
                // Named by the caller but already listed under an earlier adoptee: it stays visible
                // to the agent as a named adoptee, not as that adoptee's descendant.
                adoptees.append(adoptee)
                for key in descendantsByAdoptee.keys {
                    descendantsByAdoptee[key]?.removeAll { $0 == adoptee }
                }
                continue
            }
            let nodes = context.projector.organizationalSubtree(of: adoptee)
                ?? [DomainDelegationSubtreeNode(sessionID: adoptee, depth: 0)]
            for node in nodes where listed.insert(node.sessionID).inserted {
                let isAdoptee = node.sessionID == adoptee
                let effect = isAdoptee
                    ? "Bring into this delegation scope under \(destinationName)"
                    : "Moves with \(title(of: adoptee)) (descendant)"
                items.append(BatchConfirmationItem(sessionID: node.sessionID, title: title(of: node.sessionID), effect: effect))
                if isAdoptee {
                    adoptees.append(adoptee)
                } else {
                    descendantsByAdoptee[adoptee, default: []].append(node.sessionID)
                }
            }
        }
        // The agent-facing replies render this card through the projection: adoptee IDs and counts
        // only, never the ID or title of a descendant outside the scope (one already in the scope is
        // shown normally).
        if let grantee = request.caller.agentSessionID {
            SessionAdminAdoptCardProjection.record(
                SessionAdminAdoptCardProjection.Layout(
                    adoptees: adoptees,
                    descendantsByAdoptee: descendantsByAdoptee,
                    runningSessionIDs: Set(items.map(\.sessionID).filter { context.projector.targetState(for: $0) == .running }),
                    memberDescendants: Set(descendantsByAdoptee.values.joined().filter {
                        context.isMember($0, ofChainFrom: scope)
                    })
                ),
                granteeSessionID: grantee,
                idempotencyKey: request.idempotencyKey,
                itemSessionIDs: Set(items.map(\.sessionID))
            )
        }
        return items
    }

    /// Display title with run state, for cards.
    private func title(of sessionID: UUID) -> String {
        let name = context.displayName(sessionID) ?? sessionID.uuidString
        return switch context.projector.targetState(for: sessionID) {
        case .running: "\(name) (running)"
        case .unknown: "\(name) (state unknown)"
        case .idle: name
        }
    }

    // MARK: - Preflight

    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value? {
        let args = batch.request.arguments
        switch batch.request.operation {
        case .adminLink:
            try SessionAdminArguments.requireOnly(["observer_session_id"], in: args, op: "link")
            // A scope only mints links its own grantee observes; links between two other members are
            // the user's to create (links are durable and outlive the scope).
            if let caller = batch.request.caller.agentSessionID, try observer(of: batch) != caller {
                return SessionAdminReply.refused(
                    code: "observer_must_be_caller",
                    detail: "Under a delegation scope you can only create links you observe yourself; omit observer_session_id."
                )
            }
            try context.requireMember(observer(of: batch), of: batch)
            let minted = host.mintedLinkCapabilities
            for record in context.scopeChain(of: batch.scope) {
                if let missing = DomainDelegationScopeLinkPolicy.missingCapability(linkCapabilities: minted, grant: record.grant) {
                    return try SessionAdminMCPToolService.deniedValue(.capabilityMissing(missing), sessionID: nil)
                }
            }
            return nil
        case .adminUnlink:
            try SessionAdminArguments.requireOnly(["observer_session_id"], in: args, op: "unlink")
            try context.requireMember(observer(of: batch), of: batch)
            return nil
        case .adminReparent:
            try SessionAdminArguments.requireOnly(["parent_session_id"], in: args, op: "reparent")
            let destination = try destination(of: batch, required: true)
            try context.requireMember(destination, of: batch)
            return try reparentRefusal(batch, destination: destination)
        case .adminAdopt:
            try SessionAdminArguments.requireOnly(["parent_session_id"], in: args, op: "adopt")
            let destination = try destination(of: batch, required: false)
            try context.requireMember(destination, of: batch)
            return try adoptRefusal(batch, destination: destination)
        case .adminAttenuate:
            try SessionAdminArguments.requireOnly(["capabilities", "guardrails"], in: args, op: "attenuate")
            guard batch.admittedSessionIDs.count == 1 else {
                throw MCPError.invalidParams("session_admin attenuate takes exactly one session_id (the nested overseer).")
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Perform

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        switch batch.request.operation {
        case .adminLink:
            try await link(batch)
        case .adminUnlink:
            try await unlink(batch)
        case .adminReparent:
            try await reparent(batch)
        case .adminAdopt:
            try await adopt(batch)
        case .adminAttenuate:
            try attenuate(batch)
        default:
            throw SessionAdminMCPToolService.notImplemented(batch.request.operation.rawValue)
        }
    }

    // MARK: - Links

    private func observer(of batch: AgentSessionAdministrationAuthorizedBatch) throws -> UUID {
        if let explicit = try SessionAdminArguments.uuid(batch.request.arguments, "observer_session_id", op: "link") {
            return explicit
        }
        guard let caller = batch.request.caller.agentSessionID else { throw SessionAdminMCPToolService.unavailableError }
        return caller
    }

    private func link(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let observer = try observer(of: batch)
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            let target = lease.targetSessionID
            guard !authorityLost, context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(target))
                continue
            }
            guard target != observer else {
                items.append(SessionAdminItemResult(sessionID: target, result: "not_applied", code: "self_link"))
                continue
            }
            if batch.request.preview {
                items.append(SessionAdminItemResult(sessionID: target, result: "would_link"))
                continue
            }
            let existing = await host.activeLinkCapabilities(observer: observer, target: target)
            if let existing {
                // Never upgraded: the existing grant is reported exactly as it is.
                items.append(SessionAdminItemResult(
                    sessionID: target, result: "already_linked",
                    fields: ["capabilities": Self.capabilitiesValue(existing)]
                ))
                continue
            }
            guard context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(target))
                continue
            }
            await items.append(Self.linkItem(target, host.addLink(observer: observer, target: target)))
        }
        return SessionAdminReply.batch(
            op: "link", items: items, requiresControl: batch.itemsRequiringControl, preview: batch.request.preview,
            extra: ["observer_session_id": .string(observer.uuidString)]
        )
    }

    private func unlink(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let observer = try observer(of: batch)
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            let target = lease.targetSessionID
            guard !authorityLost, context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(target))
                continue
            }
            if batch.request.preview {
                let linked = await host.activeLinkCapabilities(observer: observer, target: target) != nil
                items.append(SessionAdminItemResult(sessionID: target, result: linked ? "would_unlink" : "not_linked"))
                continue
            }
            // Re-checked after the link lookup and right before the Stop: the lease is current and both
            // endpoints are still members of the whole chain (management never chains).
            let context = context
            let scope = batch.scope
            let outcome = await host.stopLink(observer: observer, target: target) {
                context.isStillAuthorized(lease, scope: scope) && context.isMember(observer, ofChainFrom: scope)
            }
            items.append(Self.linkItem(target, outcome))
        }
        return SessionAdminReply.batch(
            op: "unlink", items: items, requiresControl: batch.itemsRequiringControl, preview: batch.request.preview,
            extra: ["observer_session_id": .string(observer.uuidString)]
        )
    }

    private static func linkItem(_ target: UUID, _ outcome: SessionAdminLinkOutcome) -> SessionAdminItemResult {
        switch outcome {
        case .linked: SessionAdminItemResult(sessionID: target, result: "linked")
        case .alreadyLinked: SessionAdminItemResult(sessionID: target, result: "already_linked")
        case .stopped: SessionAdminItemResult(sessionID: target, result: "unlinked")
        case .notLinked: SessionAdminItemResult(sessionID: target, result: "not_linked")
        case let .failed(message):
            SessionAdminItemResult(sessionID: target, result: "not_applied", code: "link_failed", fields: ["detail": .string(message)])
        }
    }

    private static func capabilitiesValue(_ capabilities: Set<DomainAgentSessionLinkCapability>) -> Value {
        .array(DomainAgentSessionLinkCapability.allCases.filter(capabilities.contains).map { .string($0.rawValue) })
    }

    // MARK: - Placement

    private func destination(of batch: AgentSessionAdministrationAuthorizedBatch, required: Bool) throws -> UUID {
        let op = batch.request.operation == .adminAdopt ? "adopt" : "reparent"
        if let explicit = try SessionAdminArguments.uuid(batch.request.arguments, "parent_session_id", op: op) {
            return explicit
        }
        guard !required, let caller = batch.request.caller.agentSessionID else {
            throw MCPError.invalidParams("session_admin \(op) requires parent_session_id.")
        }
        return caller
    }

    /// `maxDepth` of every tree scope on the caller's chain that sets one.
    private func depthLimits(_ batch: AgentSessionAdministrationAuthorizedBatch) -> [DomainDelegationTreeDepthLimit] {
        context.scopeChain(of: batch.scope).compactMap { record in
            guard case let .tree(root) = record.grant.kind, let maxDepth = record.grant.guardrails.maxDepth else { return nil }
            return DomainDelegationTreeDepthLimit(rootSessionID: root, maxDepth: maxDepth)
        }
    }

    /// Depth after moving `sessionID`'s subtree under `destination`; `nil` when within every limit.
    private func depthRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        moving sessionID: UUID,
        destinationAncestry: DomainDelegationOrganizationalAncestry?
    ) throws -> Value? {
        let limits = depthLimits(batch)
        guard !limits.isEmpty else { return nil }
        guard let destinationAncestry,
              let height = context.projector.organizationalSubtree(of: sessionID)?.map(\.depth).max()
        else { return SessionAdminReply.placementRefusal(.unresolved, sessionID: sessionID) }
        guard let denial = DomainDelegationScopePlacementPolicy.depthViolation(
            destinationAncestry: destinationAncestry, movedSubtreeHeight: height, limits: limits
        ) else { return nil }
        return try SessionAdminMCPToolService.deniedValue(denial, sessionID: sessionID)
    }

    private func reparentRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        sources: [UUID]? = nil
    ) throws -> Value? {
        let roots = context.scopes.liveTreeScopeRoots()
        let chain = Set(context.scopeChain(of: batch.scope).map(\.id))
        let destinationAncestry = context.projector.organizationalAncestry(of: destination)
        for source in sources ?? batch.admittedSessionIDs {
            if let denial = DomainDelegationScopePlacementPolicy.validateReparent(
                source: source,
                destination: destination,
                sourceAncestry: context.projector.organizationalAncestry(of: source),
                destinationAncestry: destinationAncestry,
                liveTreeScopes: roots,
                callerScopeChain: chain
            ) {
                return SessionAdminReply.placementRefusal(denial, sessionID: source)
            }
            if let refusal = try depthRefusal(batch, moving: source, destinationAncestry: destinationAncestry) {
                return refusal
            }
        }
        return nil
    }

    private func adoptRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        adoptees: [UUID]? = nil
    ) throws -> Value? {
        let roots = context.scopes.liveTreeScopeRoots()
        // Grantees and tree roots of every live scope: never adoptable.
        let anchors = context.scopes.liveScopeAnchors()
        let destinationAncestry = context.projector.organizationalAncestry(of: destination)
        var moved: Set<UUID> = []
        for adoptee in adoptees ?? batch.admittedSessionIDs {
            if context.isMember(adoptee, ofChainFrom: batch.scope) {
                return SessionAdminReply.refused(
                    code: "already_member",
                    detail: "This session is already in the scope; use reparent to move it.",
                    fields: ["session_id": .string(adoptee.uuidString)]
                )
            }
            let subtree = context.projector.organizationalSubtree(of: adoptee).map { Set($0.map(\.sessionID)) }
            if let denial = DomainDelegationScopePlacementPolicy.validateAdopt(
                adoptee: adoptee,
                destination: destination,
                adopteeAncestry: context.projector.organizationalAncestry(of: adoptee),
                destinationAncestry: destinationAncestry,
                adopteeSubtree: subtree,
                scopeAnchors: anchors,
                liveTreeScopes: roots,
                callerScope: batch.scope.grant
            ) {
                return SessionAdminReply.placementRefusal(denial, sessionID: adoptee)
            }
            if let refusal = try depthRefusal(batch, moving: adoptee, destinationAncestry: destinationAncestry) {
                return refusal
            }
            moved.formUnion(subtree ?? [adoptee])
        }
        return try adoptionGuardrailRefusal(batch, moved: moved)
    }

    /// `maxLiveSessions` / `maxWorktrees` against post-adopt membership: the scope's current usage
    /// (with in-flight reservations) plus every session that would join. Unknown liveness counts as
    /// live so the check only gets stricter.
    private func adoptionGuardrailRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        moved: Set<UUID>
    ) throws -> Value? {
        let joining = moved.filter { !context.isMember($0, ofChainFrom: batch.scope) }
        let addedLive = joining.count { context.projector.knownProvenance(for: $0)?.isLive ?? true }
        let addedWorktrees = joining.reduce(into: Set<String>()) {
            $0.formUnion(context.projector.knownProvenance(for: $1)?.boundWorktreeIDs ?? [])
        }.count
        for record in context.scopeChain(of: batch.scope) {
            let usage = context.scopes.usageIncludingReservations(
                context.projector.usage(of: record.grant, spawnParentSessionID: nil)
            )
            if let denial = DomainDelegationScopePlacementPolicy.adoptionGuardrailViolation(
                guardrails: record.grant.guardrails, usage: usage,
                addedLiveSessions: addedLive, addedWorktrees: addedWorktrees
            ) {
                return try SessionAdminMCPToolService.deniedValue(denial, sessionID: nil)
            }
        }
        return nil
    }

    private func reparent(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let destination = try destination(of: batch, required: true)
        return try await applyPlacement(batch, destination: destination, stampScope: nil, op: "reparent") { source in
            try self.reparentRefusal(batch, destination: destination, sources: [source])
        }
    }

    private func adopt(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let destination = try destination(of: batch, required: false)
        return try await applyPlacement(
            batch, destination: destination, stampScope: batch.scope.id, op: "adopt",
            reserve: { adoptee in self.adoptionReservation(batch, adoptee: adoptee) }
        ) { adoptee in
            // The card was approved against this state; anything that changed since is re-decided,
            // one item at a time (an earlier item of this batch is a member by now), including the
            // guardrails against the membership the earlier items already produced.
            if let approved = batch.confirmation?.approvedSessionIDs,
               let subtree = self.context.projector.organizationalSubtree(of: adoptee),
               !Set(subtree.map(\.sessionID)).isSubset(of: approved)
            {
                // A descendant the user unticked would still move with its parent: refuse the item.
                return SessionAdminReply.refused(code: "subtree_not_approved", detail: "A descendant that moves with this session was not approved.")
            }
            return try self.adoptRefusal(batch, destination: destination, adoptees: [adoptee])
        }
    }

    /// Counts an adoptee's joining subtree against the caller's chain from its final check until its
    /// placement is visible to the projector (the in-memory write), like spawn and fork. Held any
    /// longer it would count the subtree twice (as members and as reserved).
    private func adoptionReservation(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        adoptee: UUID
    ) -> DelegationScopeReservation {
        let moved = context.projector.organizationalSubtree(of: adoptee).map { $0.map(\.sessionID) } ?? [adoptee]
        let joining = moved.filter { !context.isMember($0, ofChainFrom: batch.scope) }
        return context.scopes.reserve(
            scopeIDs: context.scopeChain(of: batch.scope).map(\.id),
            sessions: joining.count { context.projector.knownProvenance(for: $0)?.isLive ?? true },
            worktrees: joining.reduce(into: Set<String>()) {
                $0.formUnion(context.projector.knownProvenance(for: $1)?.boundWorktreeIDs ?? [])
            }.count
        )
    }

    /// Each item's final re-validation, its reservation, and its in-memory placement write run in one
    /// synchronous region (no suspension), so concurrent placement changes are decided one after the
    /// other: a cross re-parent is refused as a cycle and a second adopt at a limit is refused. Only
    /// the durable write is awaited afterwards.
    private func applyPlacement(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        stampScope: UUID?,
        op: String,
        reserve: (UUID) -> DelegationScopeReservation? = { _ in nil },
        revalidate: (UUID) throws -> Value?
    ) async throws -> Value {
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            let source = lease.targetSessionID
            guard !authorityLost, context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(source))
                continue
            }
            if batch.request.preview {
                items.append(SessionAdminItemResult(
                    sessionID: source, result: "would_move",
                    fields: ["parent_session_id": .string(destination.uuidString)]
                ))
                continue
            }
            // Placement and membership may have moved since preflight (earlier items, other
            // callers); every write is decided against current state.
            guard context.isMember(destination, ofChainFrom: batch.scope) else {
                items.append(SessionAdminItemResult(sessionID: source, result: "not_applied", code: "destination_unavailable"))
                continue
            }
            // A re-parent source must still be a member at the write (an adoptee is not one yet).
            if stampScope == nil, !context.isMember(source, ofChainFrom: batch.scope) {
                items.append(SessionAdminItemResult(sessionID: source, result: "not_applied", code: "source_unavailable"))
                continue
            }
            if let refusal = try revalidate(source), let code = refusal.objectValue?["code"]?.stringValue {
                items.append(SessionAdminItemResult(sessionID: source, result: "not_applied", code: code))
                continue
            }
            let reservation = reserve(source)
            let commit: DelegationPlacementCommit?
            do {
                defer { context.scopes.release(reservation) }
                commit = try host.commitOrganizationalPlacement(
                    sessionID: source, parentID: destination, delegationScopeID: stampScope
                )
            }
            guard let commit else {
                items.append(SessionAdminItemResult(
                    sessionID: source, result: "not_applied", code: "session_not_loaded",
                    fields: ["parent_session_id": .string(destination.uuidString)]
                ))
                continue
            }
            var fields: [String: Value] = ["parent_session_id": .string(destination.uuidString)]
            do {
                try await commit.persisted()
            } catch {
                // Applied in memory (membership already changed); only the session file rewrite
                // failed. Reported per item so the rest of the batch and its results are kept.
                fields["persist_failed"] = .bool(true)
                fields["detail"] = .string(error.localizedDescription)
            }
            items.append(SessionAdminItemResult(sessionID: source, result: "moved", fields: fields))
        }
        return SessionAdminReply.batch(op: op, items: items, preview: batch.request.preview)
    }

    // MARK: - Attenuate

    private func attenuate(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value {
        guard let lease = batch.leases.first, batch.leases.count == 1 else {
            throw MCPError.invalidParams("session_admin attenuate takes exactly one session_id (the nested overseer).")
        }
        let parent = batch.scope.grant
        let grantee = lease.targetSessionID
        let capabilities: Set<DomainDelegationScopeCapability> = if batch.request.arguments["capabilities"] == nil {
            parent.capabilities
        } else {
            try SessionAdminMCPToolService.parseCapabilities(
                batch.request.arguments["capabilities"], kind: .tree(rootSessionID: grantee)
            )
        }
        let guardrails = try Self.attenuatedGuardrails(batch.request.arguments["guardrails"], parent: parent.guardrails, now: now())
        if batch.request.preview {
            return .object([
                "result": .string("preview"),
                "op": .string("attenuate"),
                "session_id": .string(grantee.uuidString),
                "capabilities": .array(DomainDelegationScopeCapability.allCases.filter(capabilities.contains).map { .string($0.rawValue) })
            ])
        }
        switch context.scopes.attenuate(
            parentScopeID: batch.scope.id,
            presentedGeneration: lease.generation,
            caller: batch.request.caller,
            newGranteeSessionID: grantee,
            newGranteeMemberships: context.memberships(of: grantee, inChainFrom: batch.scope),
            capabilities: capabilities,
            guardrails: guardrails
        ) {
        case let .success(record):
            return .object([
                "result": .string("attenuated"),
                "scope": SessionAdminMCPToolService.scopeValue(record, now: now()),
                "changed_count": .int(1)
            ])
        case let .failure(denial) where denial.publicCode != nil:
            return try SessionAdminMCPToolService.deniedValue(denial, sessionID: grantee)
        case let .failure(denial):
            switch denial {
            case .attenuationWidensCapabilities, .attenuationLoosensGuardrails, .capabilitiesEmpty,
                 .capabilityNotPermittedForKind, .guardrailsMalformed, .expiryInPast:
                return .object(["result": .string("invalid_request"), "code": .string(denial.diagnosticLabel)])
            default:
                throw AgentSessionTargetOperationGuard.denialError(sessionID: grantee)
            }
        }
    }

    /// Requested guardrails, with every omitted limit inherited from the parent so a nested scope is
    /// never looser by omission. A relative lifetime starts now and may not outlive the parent.
    static func attenuatedGuardrails(
        _ raw: Value?,
        parent: DomainDelegationScopeGuardrails,
        now: Date
    ) throws -> DomainDelegationScopeGuardrails {
        let (requested, expiresInSeconds) = try SessionAdminMCPToolService.parseGuardrails(raw)
        let provided = Set(raw?.objectValue?.keys.map(\.self) ?? [])
        var result = parent
        if provided.contains("max_live_sessions") { result.maxLiveSessions = requested.maxLiveSessions }
        if provided.contains("max_depth") { result.maxDepth = requested.maxDepth }
        if provided.contains("max_worktrees") { result.maxWorktrees = requested.maxWorktrees }
        if provided.contains("bulk_confirmation_threshold") {
            result.bulkConfirmationThreshold = requested.bulkConfirmationThreshold
        }
        if let expiresInSeconds {
            result.expiresAt = now.addingTimeInterval(TimeInterval(expiresInSeconds))
        }
        return result
    }
}
