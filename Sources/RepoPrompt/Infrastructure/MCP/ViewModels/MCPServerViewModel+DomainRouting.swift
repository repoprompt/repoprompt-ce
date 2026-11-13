import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptMCPServer
import RepoPromptWorkspaceContext

extension MCPServerViewModel {
    struct DomainReadAppExecutionContext {
        let invocationContext: ToolInvocationContext
        let metadata: RequestMetadata
        let resolvedTabContext: ResolvedTabContextSnapshot
        let lookupContext: WorkspaceLookupContext
        let frozenFileToolAuthority: FrozenFileToolAuthority?
        let targetWindowID: Int
        let fileToolDependencies: MCPFileToolProvider.Dependencies
    }

    private func requiresFrozenFileAuthority(toolName: String) -> Bool {
        MCPAppToolGroup.files.orderedToolNames.contains(toolName)
            && toolName != MCPWindowToolName.fileActions
    }

    @MainActor
    func scheduleDomainWindowRegistration(
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64
    ) {
        routeResources.scheduleRegistration(
            workspaceID: activeWorkspaceID, contextID: activeContextID, revision: presentationRevision
        )
    }

    /// Decides whether a scoped read may (re)issue `coordinator.bind` for its connection.
    ///
    /// The binding publication that follows a routed tab switch is asynchronous, so a connection
    /// can still carry the previous target when the next read resolves. Non-run bindings are
    /// rebindable by design (`DomainRoutingCoordinator.bind` applies them), so the read rebinds to
    /// the freshly resolved routing truth instead of failing closed on a stale handle. Run-scoped
    /// bindings remain immutable for the lifetime of their run and are never rebound here.
    nonisolated static func shouldRebindDomainReadConnection(
        existing: DomainBinding?,
        target: DomainBinding
    ) -> Bool {
        switch existing {
        case nil, .unbound:
            true
        case .context, .appPresentationWindow:
            existing != target
        case .runScoped:
            false
        }
    }

    /// Final read-handle validation for run identity: the resolved binding must carry exactly
    /// the run the routed request claims. Same-context/different-run, run-scoped-over-plain, and
    /// plain-over-run-scoped are all mismatches; run-scoped bindings are immutable so the caller
    /// fails closed instead of rebinding.
    nonisolated static func domainReadBindingSatisfiesRequestedRun(
        requestedRunID: UUID?,
        resolvedBindingKind: DomainReadBindingKind
    ) -> Bool {
        switch (requestedRunID, resolvedBindingKind) {
        case let (.some(requestedRunID), .runScoped(actualRunID)):
            requestedRunID == actualRunID
        case (.some, _):
            false
        case (nil, .runScoped):
            false
        case (nil, _):
            true
        }
    }

    @MainActor
    func resolveDomainReadContext(
        toolName: String,
        requirement: DomainReadContextRequirement,
        invocationContext explicitInvocationContext: ToolInvocationContext? = nil
    ) async throws -> DomainReadInvocationContext {
        // History and oracle transcript lookup have always been workspace-independent. Do not even
        // capture MainActor routing metadata for them.
        guard requirement != .workspaceIndependent else {
            return DomainReadInvocationContext(handle: nil, connectionID: nil)
        }

        // The actual binding supplies this captured packet explicitly. Direct internal
        // callers must establish an explicit trusted-local scope, never infer one from nil.
        let invocationContext = try explicitInvocationContext
            ?? MCPInvocationContextBridge.require(toolName: toolName)
        let metadata = invocationContext.metadata
        if let admitted = MCPDomainAdmittedContextValues.current {
            guard admitted.windowID == windowID,
                  admitted.connectionID == metadata.connectionID,
                  metadata.tabContextHint?.tabID == admitted.contextID,
                  metadata.tabContextHint?.workspaceID == admitted.workspaceID
            else {
                throw MCPError.internalError("Admitted domain context does not match the captured app invocation")
            }
        }
        let connectionID = metadata.connectionID

        // App compatibility remains the physical fallback for graceful/no-workspace tools and
        // focused tests. Routing errors must not preempt their historical backend diagnostics.
        let resolved: ResolvedTabContextSnapshot
        do {
            resolved = try resolveTabContextSnapshot(
                from: metadata,
                toolName: toolName
            )
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "tab context unavailable: \(error.localizedDescription)"
            )
        }
        let context = resolved.snapshot
        if domainRoutingCoordinator == nil
            || connectionID == nil
            || domainWorkspaceAuthorityClient == nil
        {
            return try await registerFallbackDomainReadContext(
                toolName: toolName,
                requirement: requirement,
                metadata: metadata,
                invocationContext: invocationContext,
                resolved: resolved
            )
        }
        guard let coordinator = domainRoutingCoordinator,
              let connectionID
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "connection or routing coordinator unavailable"
            )
        }
        guard let targetWindow = WindowStatesManager.shared.window(withID: context.windowID),
              !targetWindow.isClosing
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "target window unavailable"
            )
        }
        let targetServer = targetWindow.mcpServer
        let targetWorkspaceManager = targetWindow.workspaceManager
        guard let workspaceID = context.workspaceID,
              let workspace = targetWorkspaceManager.workspaces.first(where: { $0.id == workspaceID }),
              let targetWorkspaceAuthorityClient = targetServer.domainWorkspaceAuthorityClient
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "workspace authority unavailable"
            )
        }

        // File authority must be complete before coordinator registration or rebinding so a
        // retryable hydration failure cannot replace the connection's last usable domain route.
        let prevalidatedFileAuthority: FrozenFileToolAuthority? = if requiresFrozenFileAuthority(toolName: toolName) {
            try await targetServer.requiredFileToolLookupContext(from: metadata)
        } else {
            nil
        }

        do {
            // The shared provider may be owned by a different window than the routed tab. Register
            // against the resolved target window so awaited reads also cover ephemeral workspaces.
            // Consecutive reads over unchanged working state skip the O(document-size)
            // encode/decode/digest entirely: the manager's dirty-tracking state version is the
            // cache key, and the token is confirmed only after the awaited registration succeeds.
            if let registrationToken = targetWorkspaceManager.domainReadRegistrationToken(
                for: workspace,
                fileURL: targetWorkspaceManager.workspaceFileURL(for: workspace)
            ) {
                _ = try await targetWorkspaceAuthorityClient.registerForRead(
                    workspace,
                    fileURL: registrationToken.fileURL
                )
                targetWorkspaceManager.confirmDomainReadRegistration(registrationToken)
            }
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "transient authority registration failed: \(error.localizedDescription)"
            )
        }

        let routing = await coordinator.snapshot()
        let existingConnection = routing.connections.first {
            $0.registration.connectionID == connectionID
        }
        var registration = existingConnection?.registration
        var observedRoutingRevision = routing.revision
        var observedBinding = existingConnection?.binding
        if registration == nil {
            let registered = await coordinator.registerConnection(
                connectionID: connectionID,
                operationID: UUID()
            )
            registration = registered.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.registration
            observedRoutingRevision = registered.snapshot.revision
            observedBinding = registered.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.binding
        }
        guard let registration else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "connection registration unavailable"
            )
        }
        routeResources.retainConnection(registration)
        let targetContext = DomainContextIdentity(
            workspaceID: workspaceID,
            contextID: context.tabID
        )
        let binding: DomainBinding = if let runID = context.runID {
            .runScoped(runID: runID, context: targetContext)
        } else {
            .context(targetContext, explicit: context.explicitlyBound)
        }
        // CAS rebind loop: every bind pins the routing revision observed alongside the binding
        // decision, so a concurrent publication (tab switch, another read, run launch) that
        // advanced routing cannot be clobbered by this read's stale observation. On a revision
        // conflict the outcome snapshot re-observes routing; if the newer publication already
        // satisfies the target the loop exits without a redundant bind, otherwise it retries
        // boundedly and fails closed.
        var bindAttempts = 0
        while Self.shouldRebindDomainReadConnection(existing: observedBinding, target: binding) {
            let bound = await coordinator.bind(
                connection: registration,
                binding: binding,
                operationID: UUID(),
                expectedRevision: observedRoutingRevision
            )
            if bound.disposition == .applied || bound.disposition == .unchanged { break }
            bindAttempts += 1
            guard bound.disposition == .conflict, bindAttempts < 3 else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: connectionID,
                    diagnostic: bound.diagnostic ?? "context binding rejected"
                )
            }
            observedRoutingRevision = bound.snapshot.revision
            observedBinding = bound.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.binding
        }
        do {
            let handle = try await coordinator.resolveReadContext(connection: registration)
            guard handle.context == targetContext else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: connectionID,
                    diagnostic: "bound context changed before execution"
                )
            }
            // Context identity alone is not sufficient: run-scoped bindings are immutable, so a
            // connection still bound to a *different* run over the same workspace/context must
            // fail closed rather than serve this read under the wrong run identity — and a
            // run-scoped request must never execute over a non-run binding (or vice versa).
            guard Self.domainReadBindingSatisfiesRequestedRun(
                requestedRunID: context.runID,
                resolvedBindingKind: handle.bindingKind
            ) else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: connectionID,
                    diagnostic: "bound run identity changed before execution"
                )
            }
            let lookupContext: WorkspaceLookupContext = if let prevalidatedFileAuthority {
                prevalidatedFileAuthority.lookupContext
            } else {
                await targetServer.lookupContext(for: context)
            }
            let executionHandle: DomainReadContextHandle
            if requiresFrozenFileAuthority(toolName: toolName) {
                let currentHandle = try await coordinator.resolveReadContext(connection: registration)
                guard currentHandle.context == targetContext,
                      Self.domainReadBindingSatisfiesRequestedRun(
                          requestedRunID: context.runID,
                          resolvedBindingKind: currentHandle.bindingKind
                      )
                else {
                    return try domainReadUnavailable(
                        toolName: toolName,
                        requirement: requirement,
                        connectionID: connectionID,
                        diagnostic: "bound context changed while file authority was resolving"
                    )
                }
                executionHandle = currentHandle
            } else {
                executionHandle = handle
            }
            let invocation = DomainReadInvocationContext(handle: executionHandle, connectionID: connectionID)
            domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
                invocationContext: invocationContext,
                metadata: metadata,
                resolvedTabContext: resolved,
                lookupContext: lookupContext,
                frozenFileToolAuthority: prevalidatedFileAuthority,
                targetWindowID: context.windowID,
                fileToolDependencies: targetServer.domainReadFileToolDependencies()
            )
            return invocation
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MCPError {
            throw error
        } catch {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: connectionID,
                diagnostic: "domain context resolution failed: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func registerFallbackDomainReadContext(
        toolName: String,
        requirement: DomainReadContextRequirement,
        metadata: RequestMetadata,
        invocationContext: ToolInvocationContext,
        resolved: ResolvedTabContextSnapshot
    ) async throws -> DomainReadInvocationContext {
        let context = resolved.snapshot
        guard let identity = domainReadFallbackRuntimeIdentity,
              let workspaceID = context.workspaceID
        else {
            return try domainReadUnavailable(
                toolName: toolName,
                requirement: requirement,
                connectionID: metadata.connectionID,
                diagnostic: "registered fallback authority unavailable"
            )
        }
        let connectionID = metadata.connectionID ?? UUID()
        let revision = max(context.selectionRevision, 1)
        let bindingKind: DomainReadBindingKind = if let runID = context.runID {
            .runScoped(runID: runID)
        } else if context.explicitlyBound {
            .explicit
        } else {
            .appPresentation
        }
        let handle = DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: connectionID,
            connectionGeneration: 1,
            context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
            workspaceRevision: revision,
            contextRevision: revision,
            routingRevision: 0,
            bindingKind: bindingKind
        )
        let invocation = DomainReadInvocationContext(
            handle: handle,
            connectionID: metadata.connectionID,
            refreshesDomainRouting: false
        )
        let targetServer = WindowStatesManager.shared.window(withID: context.windowID)?.mcpServer ?? self
        let frozenFileToolAuthority: FrozenFileToolAuthority? = if requiresFrozenFileAuthority(toolName: toolName) {
            try await targetServer.requiredFileToolLookupContext(from: metadata)
        } else {
            nil
        }
        let lookupContext = if let frozenFileToolAuthority {
            frozenFileToolAuthority.lookupContext
        } else {
            await targetServer.lookupContext(for: context)
        }
        if requiresFrozenFileAuthority(toolName: toolName) {
            let currentResolved = try targetServer.resolveTabContextSnapshot(
                from: metadata,
                toolName: toolName
            )
            guard targetServer.fileToolLookupSnapshotMatches(context, currentResolved.snapshot) else {
                return try domainReadUnavailable(
                    toolName: toolName,
                    requirement: requirement,
                    connectionID: metadata.connectionID,
                    diagnostic: "fallback context changed while file authority was resolving"
                )
            }
        }
        domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
            invocationContext: invocationContext,
            metadata: metadata,
            resolvedTabContext: resolved,
            lookupContext: lookupContext,
            frozenFileToolAuthority: frozenFileToolAuthority,
            targetWindowID: context.windowID,
            fileToolDependencies: targetServer.domainReadFileToolDependencies()
        )
        return invocation
    }

    @MainActor
    func domainReadAppExecutionContext(
        for invocation: DomainReadInvocationContext
    ) -> DomainReadAppExecutionContext? {
        domainReadAppExecutionContexts[invocation.invocationID]
    }

    @MainActor
    func releaseDomainReadAppExecutionContext(
        for invocation: DomainReadInvocationContext
    ) {
        domainReadAppExecutionContexts.removeValue(forKey: invocation.invocationID)
    }

    private func domainReadUnavailable(
        toolName: String,
        requirement: DomainReadContextRequirement,
        connectionID: UUID?,
        diagnostic: String
    ) throws -> DomainReadInvocationContext {
        guard requirement == .workspaceRequired else {
            return DomainReadInvocationContext(handle: nil, connectionID: connectionID)
        }
        throw MCPError.internalError("Domain authority unavailable for \(toolName): \(diagnostic)")
    }

    /// Runs before the server is stopped so no presentation binding can outlive its window.
    @MainActor
    func unregisterDomainRoutingWindow() async {
        routeResources.closeDomainAdmission()
        domainReadAppExecutionContexts.removeAll()
        await routeResources.closeDomainRoute()
    }
}
