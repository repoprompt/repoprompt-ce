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
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        let destination = (try? SessionAdminArguments.uuid(request.arguments, "parent_session_id", op: "adopt"))
            ?? request.caller.agentSessionID
        let effect = switch request.operation {
        case .adminAdopt:
            "Bring into this delegation scope under \(destination?.uuidString ?? "the overseer")"
        default:
            request.operation.rawValue
        }
        return request.targetSessionIDs.map {
            BatchConfirmationItem(sessionID: $0, title: $0.uuidString, effect: effect)
        }
    }

    // MARK: - Preflight

    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value? {
        let args = batch.request.arguments
        switch batch.request.operation {
        case .adminLink:
            try SessionAdminArguments.requireOnly(["observer_session_id"], in: args, op: "link")
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
            return reparentRefusal(batch, destination: destination)
        case .adminAdopt:
            try SessionAdminArguments.requireOnly(["parent_session_id"], in: args, op: "adopt")
            let destination = try destination(of: batch, required: false)
            try context.requireMember(destination, of: batch)
            return adoptRefusal(batch, destination: destination)
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
            await items.append(Self.linkItem(target, host.stopLink(observer: observer, target: target)))
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

    private func reparentRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        sources: [UUID]? = nil
    ) -> Value? {
        let roots = context.scopes.liveTreeScopeRoots()
        let chain = Set(context.scopeChain(of: batch.scope).map(\.id))
        for source in sources ?? batch.admittedSessionIDs {
            if let denial = DomainDelegationScopePlacementPolicy.validateReparent(
                source: source,
                destination: destination,
                sourceAncestry: context.projector.organizationalAncestry(of: source),
                destinationAncestry: context.projector.organizationalAncestry(of: destination),
                liveTreeScopes: roots,
                callerScopeChain: chain
            ) {
                return SessionAdminReply.placementRefusal(denial, sessionID: source)
            }
        }
        return nil
    }

    private func adoptRefusal(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        adoptees: [UUID]? = nil
    ) -> Value? {
        let roots = context.scopes.liveTreeScopeRoots()
        for adoptee in adoptees ?? batch.admittedSessionIDs {
            if context.isMember(adoptee, ofChainFrom: batch.scope) {
                return SessionAdminReply.refused(
                    code: "already_member",
                    detail: "This session is already in the scope; use reparent to move it.",
                    fields: ["session_id": .string(adoptee.uuidString)]
                )
            }
            if let denial = DomainDelegationScopePlacementPolicy.validateAdopt(
                adoptee: adoptee,
                destination: destination,
                adopteeAncestry: context.projector.organizationalAncestry(of: adoptee),
                destinationAncestry: context.projector.organizationalAncestry(of: destination),
                liveTreeScopes: roots,
                callerScope: batch.scope.grant
            ) {
                return SessionAdminReply.placementRefusal(denial, sessionID: adoptee)
            }
        }
        return nil
    }

    private func reparent(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let destination = try destination(of: batch, required: true)
        return try await applyPlacement(batch, destination: destination, stampScope: nil, op: "reparent") { source in
            self.reparentRefusal(batch, destination: destination, sources: [source])
        }
    }

    private func adopt(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let destination = try destination(of: batch, required: false)
        return try await applyPlacement(batch, destination: destination, stampScope: batch.scope.id, op: "adopt") { adoptee in
            // The card was approved against this state; anything that changed since is re-decided,
            // one item at a time (an earlier item of this batch is a member by now).
            self.adoptRefusal(batch, destination: destination, adoptees: [adoptee])
        }
    }

    private func applyPlacement(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        destination: UUID,
        stampScope: UUID?,
        op: String,
        revalidate: (UUID) -> Value?
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
            if let refusal = revalidate(source), let code = refusal.objectValue?["code"]?.stringValue {
                items.append(SessionAdminItemResult(sessionID: source, result: "not_applied", code: code))
                continue
            }
            let written = try await host.setOrganizationalPlacement(
                sessionID: source, parentID: destination, delegationScopeID: stampScope
            )
            items.append(SessionAdminItemResult(
                sessionID: source, result: written ? "moved" : "not_applied",
                code: written ? nil : "session_not_loaded",
                fields: ["parent_session_id": .string(destination.uuidString)]
            ))
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
                "scope": SessionAdminMCPToolService.scopeValue(record, now: now())
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
