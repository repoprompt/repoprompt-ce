import Foundation
import MCP
import RepoPromptDomainRuntime

/// App-side adapter for the domain-owned `DomainAgentSessionOperationAuthorizer`.
///
/// Routing is not authorization. `agent_run` and `agent_manage` historically resolved a target from a
/// caller-supplied reference and then acted on it, so a full UUID plus same-window routing was enough
/// to reach an unrelated session. This guard adds the missing execution-time proof: the caller is
/// derived only from server-owned run routing, the target's immutable spawn provenance is looked up
/// independently, and the decision matrix lives in the domain runtime.
///
/// Every denial reuses the exact "not found" wording so an unauthorized UUID is indistinguishable
/// from a nonexistent one.
@MainActor
enum AgentSessionTargetOperationGuard {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias SpawnParentSessionResolver = (RequestMetadata, WindowState) async -> UUID?
    /// Resolves the caller's **exact endpoint incarnation** from server-owned run routing.
    typealias ObserverEndpointResolver =
        (RequestMetadata, WindowState) async -> DomainAgentSessionLinkEndpointIdentity?

    static func denialError(reference: String) -> MCPError {
        MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
    }

    static func denialError(sessionID: UUID) -> MCPError {
        denialError(reference: sessionID.uuidString)
    }

    /// Classifies the caller from non-spoofable server-owned routing only.
    ///
    /// Three-way and ordered by strength:
    ///
    /// 1. **Proven Agent session** — a non-nil spawn-parent resolution. That resolver requires an
    ///    `agentModeRun` connection purpose plus an exact run-installed/handover/pending-run tab
    ///    context, and rejects explicit bindings and hints.
    /// 2. **Unresolved Agent run** — any server-owned evidence that this connection belongs to an
    ///    app-started run, without an exact session resolution. Always fails closed.
    /// 3. **Administrative principal** — no run-scoped evidence of any kind.
    ///
    /// `.administrativePrincipal` is the permissive outcome, so it is selected only when *every*
    /// run-scoped signal is absent rather than merely inconclusive.
    static func resolveCaller(
        metadata: RequestMetadata,
        targetWindow: WindowState,
        resolveSpawnParentSessionID: SpawnParentSessionResolver
    ) async -> DomainAgentSessionCallerIdentity {
        if let callerSessionID = await resolveSpawnParentSessionID(metadata, targetWindow) {
            return .agentSession(callerSessionID)
        }
        return await isAgentOriginConnection(metadata: metadata, targetWindow: targetWindow)
            ? .unresolvedAgentRun
            : .administrativePrincipal
    }

    /// Resolves the caller as one exact oversight endpoint incarnation, or `nil`.
    ///
    /// Oversight is a user-granted relationship between two live *incarnations*, so its caller
    /// identity is a full `(window, tab, workspace, session, binding generations)` tuple rather than
    /// a session UUID. A session UUID can be live in more than one window at once — the resolver
    /// models that explicitly as `.ambiguous` — and a UUID-level caller identity would let the
    /// incarnation the user never authorized exercise, enumerate, and be attributed with the other's
    /// grants.
    ///
    /// Every non-Agent principal, every Agent run whose routing does not resolve exactly, and every
    /// tab without a live durable binding fails closed to `nil`.
    static func resolveObserverEndpoint(
        metadata: RequestMetadata,
        targetWindow: WindowState,
        resolveObserverEndpoint: ObserverEndpointResolver
    ) async -> DomainAgentSessionLinkEndpointIdentity? {
        await resolveObserverEndpoint(metadata, targetWindow)
    }

    /// Reconciles the captured/live/cached run-purpose triple that `agent_run.start` uses to refuse
    /// ambiguous launch routing, plus the connection→run mapping itself.
    ///
    /// Capture-time `metadata.runPurpose` alone is not sufficient: during an Agent Mode reconnect or
    /// handover it can still read `.unknown` while the live connection purpose or the cached
    /// run-policy purpose already says Agent Mode. Trusting the capture-time value alone would
    /// classify that reconnecting agent as an administrative principal and hand it unrestricted
    /// target authority, so this fails closed whenever *any* authoritative signal is Agent-origin.
    ///
    /// The purpose triple is not sufficient either. A reconnect or handover can lose every one of
    /// them at once — capture-time metadata predates the new purpose, the live connection purpose has
    /// not been reapplied, and no run policy is cached to rehydrate from — while the connection is
    /// still an Agent Mode run's own connection. A purpose-only test reads exactly that state as
    /// "administrative".
    ///
    /// The remaining evidence is the connection's **run-scoped tab context**: a run-installed,
    /// handed-over, or pending-run-scoped context is server-installed routing for the run itself.
    /// A bare connection→run mapping is deliberately *not* used, because an external supervisor that
    /// started a run carries one too; only the run's own connection carries run-installed context.
    ///
    /// There is deliberately no positive external/administrative marker to require instead: an
    /// ordinary external MCP client is characterized by the *absence* of run-scoped routing, so
    /// demanding affirmative administrative proof would deny every external client rather than
    /// tighten anything. The strongest available rule is therefore "no run-scoped evidence at all".
    ///
    /// - Parameter targetWindow: the routed window, used only to consult its server-owned tab-context
    ///   store. Omitting it narrows the check to the purpose triple.
    static func isAgentOriginConnection(
        metadata: RequestMetadata,
        targetWindow: WindowState? = nil
    ) async -> Bool {
        guard metadata.connectionID != nil else {
            // Nothing but the capture-time purpose can speak for a connectionless request.
            return metadata.runPurpose.map { $0 != .unknown } ?? false
        }
        if await hasAuthoritativeAgentRunPurpose(metadata: metadata) { return true }
        // No authoritative purpose survived; fall back to server-installed run routing.
        return targetWindow?.mcpServer.hasExactRunScopedTabContext(metadata: metadata) ?? false
    }

    /// The captured/live/cached run-purpose triple, reconciled with a rehydration attempt.
    private static func hasAuthoritativeAgentRunPurpose(metadata: RequestMetadata) async -> Bool {
        guard let connectionID = metadata.connectionID else {
            return metadata.runPurpose.map { $0 != .unknown } ?? false
        }
        let networkManager = ServerNetworkManager.shared
        var livePurpose = await networkManager.runPurpose(for: connectionID)
        if livePurpose == .agentModeRun || livePurpose == .discoverRun || livePurpose == .unknown {
            _ = await networkManager.rehydrateRunTabContextForConnectionIfPossible(connectionID)
            livePurpose = await networkManager.runPurpose(for: connectionID)
        }
        var cachedRunPolicyPurpose: MCPRunPurpose?
        if let runID = await networkManager.runIDForConnection(connectionID) {
            cachedRunPolicyPurpose = await networkManager.runPolicyPurpose(for: runID)
        }
        let signals: [MCPRunPurpose] = [metadata.runPurpose, livePurpose, cachedRunPolicyPurpose]
            .compactMap { purpose in
                guard let purpose, purpose != .unknown else { return nil }
                return purpose
            }
        // Any Agent-origin signal wins, including a conflicting triple: an administrative
        // classification is the permissive outcome here, so ambiguity must never select it.
        return !signals.isEmpty
    }

    /// Immutable spawn provenance for an already-loaded session.
    static func provenance(
        for sessionID: UUID,
        loadedParentSessionID: UUID?
    ) -> DomainAgentSessionTargetProvenance {
        .known(targetSessionID: sessionID, parentSessionID: loadedParentSessionID)
    }

    /// Best-effort provenance lookup for a target the caller has not already loaded.
    ///
    /// Falls back through hydrated live state, the workspace session index, and persisted metadata.
    /// An unresolvable target stays `unknown` so an Agent-origin caller fails closed.
    static func provenance(
        for sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        workspace: WorkspaceModel?
    ) async -> DomainAgentSessionTargetProvenance {
        if let liveSession = try? agentModeVM.authoritativeLiveSession(for: sessionID),
           liveSession.hasLoadedPersistedState
        {
            return .known(targetSessionID: sessionID, parentSessionID: liveSession.parentSessionID)
        }
        if let entry = agentModeVM.sessionIndex[sessionID] {
            return .known(targetSessionID: sessionID, parentSessionID: entry.parentSessionID)
        }
        if let workspace,
           let meta = try? await AgentSessionDataService.shared
           .metadataRecordForSessionID(sessionID, for: workspace)?
           .agentSessionMeta()
        {
            return .known(targetSessionID: sessionID, parentSessionID: meta.parentSessionID)
        }
        return .unknown(targetSessionID: sessionID)
    }

    static func require(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        provenance: DomainAgentSessionTargetProvenance,
        reference: String
    ) throws {
        let decision = DomainAgentSessionOperationAuthorizer.authorize(
            operation: operation,
            caller: caller,
            target: provenance
        )
        guard decision.isAuthorized else {
            throw denialError(reference: reference)
        }
    }

    /// Resolves provenance and authorizes one target in a single step.
    static func require(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        sessionID: UUID,
        reference: String? = nil,
        agentModeVM: AgentModeViewModel,
        workspace: WorkspaceModel?
    ) async throws {
        let provenance = await provenance(
            for: sessionID,
            agentModeVM: agentModeVM,
            workspace: workspace
        )
        try require(
            operation: operation,
            caller: caller,
            provenance: provenance,
            reference: reference ?? sessionID.uuidString
        )
    }
}
