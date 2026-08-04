import Foundation
import MCP
import RepoPromptDomainRuntime

extension MCPServerViewModel {
    struct DomainReadAppExecutionContext {
        let metadata: RequestMetadata
        let resolvedTabContext: ResolvedTabContextSnapshot
        let lookupContext: WorkspaceLookupContext
        let targetWindowID: Int
    }

    @MainActor
    func scheduleDomainWindowRegistration(
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64
    ) {
        guard let coordinator = domainRoutingCoordinator,
              !domainRoutingWindowIsClosing,
              domainWindowDescriptor == nil,
              domainWindowRegistrationTask == nil
        else { return }
        let windowID = windowID
        domainWindowRegistrationTask = Task {
            let outcome = await coordinator.openWindow(
                windowID: windowID,
                activeWorkspaceID: activeWorkspaceID,
                activeContextID: activeContextID,
                presentationRevision: presentationRevision,
                operationID: UUID()
            )
            return outcome.snapshot.windows.first { $0.windowID == windowID }
        }
    }

    @MainActor
    private func ensureDomainWindowRegistered(
        activeWorkspaceID: UUID?,
        activeContextID: UUID?,
        presentationRevision: UInt64
    ) async -> DomainWindowDescriptor? {
        if let domainWindowDescriptor { return domainWindowDescriptor }
        scheduleDomainWindowRegistration(
            activeWorkspaceID: activeWorkspaceID,
            activeContextID: activeContextID,
            presentationRevision: presentationRevision
        )
        guard let registrationTask = domainWindowRegistrationTask else { return nil }
        let descriptor = await registrationTask.value
        domainWindowRegistrationTask = nil
        domainWindowDescriptor = descriptor
        return descriptor
    }

    /// Publishes a presentation-cache transition to the runtime routing authority.
    /// M3 read providers may continue reading the local cache, but new binding decisions
    /// and run launch reservations must use the coordinator snapshot/token APIs.
    @MainActor
    func publishDomainRoutingBinding(connectionID: UUID, context: TabContextSnapshot) {
        guard let coordinator = domainRoutingCoordinator else { return }
        if domainWindowPresentationRevision < .max {
            domainWindowPresentationRevision += 1
        }
        let presentationRevision = domainWindowPresentationRevision
        let binding: DomainBinding = if let workspaceID = context.workspaceID {
            if let runID = context.runID {
                .runScoped(
                    runID: runID,
                    context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID)
                )
            } else {
                .context(
                    DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
                    explicit: context.explicitlyBound
                )
            }
        } else {
            .appPresentationWindow(context.windowID)
        }
        let previousPublish = domainRoutingPublishTask
        domainRoutingPublishTask = Task { @MainActor [weak self] in
            await previousPublish?.value
            guard let self, !self.domainRoutingWindowIsClosing else { return }
            guard let descriptor = await ensureDomainWindowRegistered(
                activeWorkspaceID: context.workspaceID,
                activeContextID: context.tabID,
                presentationRevision: presentationRevision
            ),
                !domainRoutingWindowIsClosing
            else { return }
            let updatedDescriptor = DomainWindowDescriptor(
                windowID: descriptor.windowID,
                generation: descriptor.generation,
                activeWorkspaceID: context.workspaceID,
                activeContextID: context.tabID,
                isClosing: false,
                presentationRevision: presentationRevision
            )
            let updated = await coordinator.registerWindow(updatedDescriptor, operationID: UUID())
            guard !domainRoutingWindowIsClosing, updated.disposition != .staleGeneration else { return }
            domainWindowDescriptor = updated.snapshot.windows.first {
                $0.windowID == context.windowID
            }

            var registration = updated.snapshot.connections.first {
                $0.registration.connectionID == connectionID
            }?.registration
            if registration == nil {
                // Re-checked above so a straggler cannot resurrect a connection binding
                // after `unregisterDomainRoutingWindow` tore the window down.
                let registered = await coordinator.registerConnection(
                    connectionID: connectionID,
                    operationID: UUID()
                )
                registration = registered.snapshot.connections.first {
                    $0.registration.connectionID == connectionID
                }?.registration
            }
            guard let registration, !domainRoutingWindowIsClosing else { return }
            domainRoutingConnectionIDs.insert(connectionID)
            let bound = await coordinator.bind(
                connection: registration,
                binding: binding,
                operationID: UUID()
            )
            if bound.disposition != .applied, bound.disposition != .unchanged {
                logger.warning("Domain routing bind rejected: \(bound.diagnostic ?? String(describing: bound.disposition))")
            }
        }
    }

    @MainActor
    func publishDomainRoutingRelease(connectionID: UUID) {
        guard let coordinator = domainRoutingCoordinator else {
            domainRoutingConnectionIDs.remove(connectionID)
            return
        }
        let previousPublish = domainRoutingPublishTask
        domainRoutingPublishTask = Task { @MainActor [weak self] in
            await previousPublish?.value
            let snapshot = await coordinator.snapshot()
            guard let registration = snapshot.connections.first(where: {
                $0.registration.connectionID == connectionID
            })?.registration else {
                self?.domainRoutingConnectionIDs.remove(connectionID)
                return
            }
            let released = await coordinator.unregisterConnection(
                registration,
                operationID: UUID()
            )
            if released.disposition == .applied || released.disposition == .unchanged {
                await AppDomainRuntimeComposition.shared.runtime.domainHost.releaseConnection(
                    connectionID: registration.connectionID,
                    connectionGeneration: registration.generation
                )
            }
            if released.disposition != .applied, released.disposition != .unchanged {
                self?.logger.warning(
                    "Domain routing release rejected: \(released.diagnostic ?? String(describing: released.disposition))"
                )
            }
            self?.domainRoutingConnectionIDs.remove(connectionID)
        }
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
        requirement: DomainReadContextRequirement
    ) async throws -> DomainReadInvocationContext {
        // History and oracle transcript lookup have always been workspace-independent. Do not even
        // capture MainActor routing metadata for them.
        guard requirement != .workspaceIndependent else {
            return DomainReadInvocationContext(handle: nil, connectionID: nil)
        }

        let metadata: RequestMetadata
        if let admitted = MCPDomainAdmittedContextValues.current {
            guard admitted.windowID == windowID else {
                throw MCPError.internalError(
                    "Admitted domain context window \(admitted.windowID) does not match provider window \(windowID)"
                )
            }
            metadata = await RequestMetadata(
                connectionID: admitted.connectionID,
                clientName: nil,
                windowID: admitted.windowID,
                runPurpose: ServerNetworkManager.shared.runPurpose(for: admitted.connectionID),
                tabContextHint: TabContextHint(
                    tabID: admitted.contextID,
                    workspaceID: admitted.workspaceID,
                    windowID: admitted.windowID
                )
            )
        } else {
            metadata = await captureRequestMetadata()
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
        domainRoutingConnectionIDs.insert(connectionID)
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
            let invocation = DomainReadInvocationContext(handle: handle, connectionID: connectionID)
            domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
                metadata: metadata,
                resolvedTabContext: resolved,
                lookupContext: targetServer.lookupContext(for: context),
                targetWindowID: context.windowID
            )
            return invocation
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
        domainReadAppExecutionContexts[invocation.invocationID] = await DomainReadAppExecutionContext(
            metadata: metadata,
            resolvedTabContext: resolved,
            lookupContext: targetServer.lookupContext(for: context),
            targetWindowID: context.windowID
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
        domainRoutingWindowIsClosing = true
        domainReadAppExecutionContexts.removeAll()
        let pendingPublish = domainRoutingPublishTask
        domainRoutingPublishTask = nil
        await pendingPublish?.value
        domainWindowRegistrationTask?.cancel()
        if domainWindowDescriptor == nil,
           let registrationTask = domainWindowRegistrationTask
        {
            domainWindowDescriptor = await registrationTask.value
        }
        domainWindowRegistrationTask = nil
        guard let coordinator = domainRoutingCoordinator,
              let descriptor = domainWindowDescriptor
        else { return }
        let routing = await coordinator.snapshot()
        let ownedConnectionIDs = domainRoutingConnectionIDs
        domainRoutingConnectionIDs.removeAll()
        for connection in routing.connections where ownedConnectionIDs.contains(connection.registration.connectionID) {
            let released = await coordinator.unregisterConnection(
                connection.registration,
                operationID: UUID()
            )
            if released.disposition == .applied || released.disposition == .unchanged {
                await AppDomainRuntimeComposition.shared.runtime.domainHost.releaseConnection(
                    connectionID: connection.registration.connectionID,
                    connectionGeneration: connection.registration.generation
                )
            }
        }
        _ = await coordinator.unregisterWindow(
            windowID: descriptor.windowID,
            generation: descriptor.generation,
            operationID: UUID()
        )
        domainWindowDescriptor = nil
    }
}
