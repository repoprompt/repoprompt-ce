import Foundation
import Logging
import RepoPromptDomainRuntime
import RepoPromptMCPServer

/// Concrete route resources, independent of a server/presentation VM. DomainRoutingCoordinator
/// and the domain tool registry remain the authorities; this owner retains their exact receipts.
/// Closing admission never cancels tools or claims that a run has drained.
@MainActor
final class MCPHostRouteResources {
    enum RegistrationFailure: Error { case closing, wrongRoute, differentCatalog }

    struct ConnectionKey: Hashable {
        let owner: ObjectIdentifier
        let connectionID: UUID
    }

    func connectionKey(_ connectionID: UUID) -> ConnectionKey {
        .init(owner: ObjectIdentifier(self), connectionID: connectionID)
    }

    struct PolicyContextInstallation {
        let token: MCPRunRouteBindings.PendingPolicyToken
        let workspaceID: UUID?
        let tabID: UUID?
    }

    /// The catalog's actual context owner supplies these operations. No window lookup is part of
    /// registration or teardown; the original route and token are passed to every operation.
    struct RunRouting {
        let install: @MainActor (MCPHostRouteResources, MCPRunRoutingCleanupReceipt, UUID, String?, UUID?) -> PolicyContextInstallation?
        let rollback: @MainActor (MCPHostRouteResources, MCPRunRouteBindings.PendingPolicyToken, String?, UUID?) -> MCPServerViewModel.PendingPolicyRunIDMappingRollbackResult
        let removeContext: @MainActor (MCPHostRouteResources, MCPRunRoutingCleanupReceipt, UUID) -> Void
    }

    private struct RetainedConnection {
        let registration: DomainConnectionRegistration
        let policyID: UUID?
    }

    let identity: MCPHostRouteIdentity
    let coordinator: DomainRoutingCoordinator?
    private let domainRuntime: MCPDomainRuntime
    private let logger = Logger(label: "com.repoprompt.mcp.host-route")
    let runRouteBindings: MCPRunRouteBindings
    let toolExecutionRuntime = MCPToolExecutionRuntime()
    var readFileAutoSelectionCoordinator: MCPReadFileAutoSelectionCoordinator?
    private var ownerLifetime: MCPRunRouteBindings.OwnerLifetime?
    private(set) var isClosing = false
    var descriptor: DomainWindowDescriptor?
    private var connections: [UUID: RetainedConnection] = [:]
    private var registrationTask: Task<DomainWindowDescriptor?, Never>?
    private var closeTask: Task<Void, Never>?
    private var catalogTransitionTail: Task<Void, Never>?
    private(set) var catalogHandle: MCPDomainToolRegistrationHandle?
    private var catalog: MCPAppToolCatalogRegistration?
    private var runRouting: RunRouting?
    private var presentationRevision: UInt64 = 0
    private var routingPublicationTail: Task<Void, Never>?

    init(
        identity: MCPHostRouteIdentity,
        coordinator: DomainRoutingCoordinator?,
        runtime: MCPDomainRuntime = AppDomainRuntimeComposition.shared.runtime
    ) {
        self.identity = identity
        self.coordinator = coordinator
        precondition(coordinator == nil || coordinator === runtime.routingCoordinator, "A route must use one domain runtime")
        domainRuntime = runtime
        let lifetime = MCPRunRouteBindings.OwnerLifetime()
        ownerLifetime = lifetime
        runRouteBindings = MCPRunRouteBindings(ownerLifetime: lifetime)
    }

    /// The domain protocol still calls its route slots "windows". This allocates only a routing
    /// descriptor, never a WindowState, UI registration, workspace projection or window selector.
    func scheduleRegistration(workspaceID: UUID?, contextID: UUID?, revision: UInt64) {
        guard let coordinator, !isClosing, descriptor == nil, registrationTask == nil else { return }
        let routeID = identity.routeID
        registrationTask = Task {
            let outcome = await coordinator.openWindow(
                windowID: routeID, activeWorkspaceID: workspaceID, activeContextID: contextID,
                presentationRevision: revision, operationID: UUID()
            )
            return outcome.snapshot.windows.first { $0.windowID == routeID }
        }
    }

    func ensureRegistered(workspaceID: UUID?, contextID: UUID?, revision: UInt64) async -> DomainWindowDescriptor? {
        guard !isClosing else { return nil }
        if let descriptor { return descriptor }
        scheduleRegistration(workspaceID: workspaceID, contextID: contextID, revision: revision)
        guard let task = registrationTask else { return nil }
        let registered = await task.value
        // Close joins this very task and retracts its receipt. A late waiter cannot resurrect it.
        guard !isClosing else { return nil }
        registrationTask = nil
        descriptor = registered
        AppDomainRuntimeComposition.shared.recordRouteResources(self, in: domainRuntime)
        return registered
    }

    /// Publish against this route's descriptor, never a successor presentation's route.
    /// The tail serializes binding and release effects and is joined by route teardown.
    func publishBinding(connectionID: UUID, context: MCPTabContextSnapshot, cleanupReceipt: MCPRunRoutingCleanupReceipt? = nil) {
        let ownership = cleanupReceipt?.mappingOwnership ?? runRouteBindings.cleanupOwnership(for: connectionID)
        guard let coordinator, !isClosing, ownership?.isConsumed != true else { return }
        if presentationRevision < .max { presentationRevision += 1 }
        let revision = presentationRevision
        let binding: DomainBinding = if let workspaceID = context.workspaceID {
            if let runID = context.runID {
                .runScoped(runID: runID, context: DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID))
            } else {
                .context(DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID), explicit: context.explicitlyBound)
            }
        } else {
            .appPresentationWindow(context.windowID)
        }
        let predecessor = routingPublicationTail
        routingPublicationTail = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self, !isClosing, ownership?.isConsumed != true else { return }
            guard let descriptor = await ensureRegistered(
                workspaceID: context.workspaceID, contextID: context.tabID, revision: revision
            ), !isClosing else { return }
            let updatedDescriptor = DomainWindowDescriptor(
                windowID: descriptor.windowID, generation: descriptor.generation,
                activeWorkspaceID: context.workspaceID, activeContextID: context.tabID,
                isClosing: false, presentationRevision: revision
            )
            let updated = await coordinator.registerWindow(updatedDescriptor, operationID: UUID())
            guard !isClosing, updated.disposition != .staleGeneration else { return }
            self.descriptor = updated.snapshot.windows.first { $0.windowID == self.identity.routeID }
            guard ownership?.isConsumed != true else { return }
            // A new owned policy gets a new domain connection generation, even when the numeric
            // connection/run IDs are reused. Old route cleanup then cannot retract its successor.
            var registration: DomainConnectionRegistration?
            if let ownership {
                if connections[connectionID]?.policyID == ownership.policyID {
                    registration = connections[connectionID]?.registration
                }
            } else {
                registration = updated.snapshot.connections.first {
                    $0.registration.connectionID == connectionID
                }?.registration
            }
            if registration == nil {
                let registered = await coordinator.registerConnection(connectionID: connectionID, operationID: UUID())
                registration = registered.snapshot.connections.first {
                    $0.registration.connectionID == connectionID
                }?.registration
            }
            guard let registration else { return }
            connections[connectionID] = RetainedConnection(registration: registration, policyID: ownership?.policyID)
            guard !isClosing, ownership?.isConsumed != true else { return }
            let bound = await coordinator.bind(connection: registration, binding: binding, operationID: UUID())
            if bound.disposition != .applied, bound.disposition != .unchanged {
                logger.warning("Domain routing bind rejected: \(bound.diagnostic ?? String(describing: bound.disposition))")
            }
        }
    }

    func publishRelease(connectionID: UUID) {
        let ownership = runRouteBindings.cleanupOwnership(for: connectionID)
        let predecessor = routingPublicationTail
        routingPublicationTail = Task { @MainActor in
            await predecessor?.value
            if let ownership {
                guard let retained = self.connections[connectionID], retained.policyID == ownership.policyID else { return }
                self.connections.removeValue(forKey: connectionID)
                await self.releaseConnection(retained.registration)
            } else {
                await self.releaseDisconnectedConnection(connectionID)
            }
        }
    }

    func installPendingPolicy(_ receipt: MCPRunRoutingCleanupReceipt, connectionID: UUID, clientName: String?, tabID: UUID?) -> PolicyContextInstallation? {
        guard !isClosing, !receipt.isConsumed, receipt.routeOwner === self else { return nil }
        return runRouting?.install(self, receipt, connectionID, clientName, tabID)
    }

    func rollbackPendingPolicy(_ receipt: MCPRunRoutingCleanupReceipt, token: MCPRunRouteBindings.PendingPolicyToken, clientName: String?) -> MCPServerViewModel.PendingPolicyRunIDMappingRollbackResult? {
        guard receipt.routeOwner === self else { return nil }
        return runRouting?.rollback(self, token, clientName, receipt.routingWaitGeneration)
    }

    func consumeCleanup(_ receipt: MCPRunRoutingCleanupReceipt) async {
        guard receipt.routeOwner === self else { return }
        runRouteBindings.consumeCleanup(receipt) { connectionID in
            runRouting?.removeContext(self, receipt, connectionID)
            // The mutable snapshot may already have been consumed by a committed child; its
            // original domain registration still needs release. Repeated release is exact/idempotent.
            publishRelease(connectionID: connectionID)
        }
        await settleRoutingPublications()
        releaseContextOwnerIfUnregisteredAndDrained()
    }

    func settleRoutingPublications() async {
        await routingPublicationTail?.value
    }

    /// Serialize effects even with no VM adapter. Cancelling a waiter does not erase a successful
    /// registration receipt or cancel the independent cleanup owner.
    func registerCatalog(_ catalog: MCPAppToolCatalogRegistration) async throws -> MCPDomainToolRegistrationHandle {
        guard !isClosing else { throw RegistrationFailure.closing }
        let predecessor = catalogTransitionTail
        let task = Task { @MainActor in
            await predecessor?.value
            return try await self.performCatalogRegistration(catalog)
        }
        catalogTransitionTail = Task { _ = await task.result }
        return try await task.value
    }

    private func performCatalogRegistration(_ catalog: MCPAppToolCatalogRegistration) async throws -> MCPDomainToolRegistrationHandle {
        guard !isClosing else { throw RegistrationFailure.closing }
        guard catalog.windowID == identity.routeID else { throw RegistrationFailure.wrongRoute }
        if let installed = self.catalog, installed !== catalog { throw RegistrationFailure.differentCatalog }
        let registration = try await AppDomainRuntimeComposition.shared.register(catalog, in: domainRuntime)
        if isClosing {
            await AppDomainRuntimeComposition.shared.unregister(registration.handle, in: domainRuntime)
            throw RegistrationFailure.closing
        }
        self.catalog = catalog
        runRouting = catalog.runRouting
        catalogHandle = registration.handle
        return registration.handle
    }

    func hasActiveCatalog() async -> Bool {
        guard let handle = catalogHandle else { return false }
        return await domainRuntime.toolRegistry.isActive(handle)
    }

    func unregisterCatalog(_ handle: MCPDomainToolRegistrationHandle) async {
        let predecessor = catalogTransitionTail
        let task = Task { @MainActor in
            await predecessor?.value
            await AppDomainRuntimeComposition.shared.unregister(handle, in: self.domainRuntime)
            if self.catalogHandle == handle {
                self.catalogHandle = nil
                self.releaseContextOwnerIfUnregisteredAndDrained()
            }
        }
        catalogTransitionTail = task
        await task.value
    }

    /// Full route-resource release; no tool cancellation or session retirement is implied.
    /// Callers must separately join their run/tool users before releasing their resources.
    func close() async {
        closeDomainAdmission()
        ownerLifetime = nil
        await catalogTransitionTail?.value
        if let handle = catalogHandle { await unregisterCatalog(handle) }
        await closeDomainRoute()
        // A prematurely closed route must retain its original context cleanup operations until
        // their mappings have been consumed; never resolve a reopened catalog for that obligation.
        releaseContextOwnerIfUnregisteredAndDrained()
    }

    private func releaseContextOwnerIfUnregisteredAndDrained() {
        guard catalogHandle == nil, runRouteBindings.connectionIDToRunID.isEmpty,
              !runRouteBindings.hasRetainedCleanupOwnership else { return }
        catalog = nil
        runRouting = nil
    }

    /// Retain the observed registration even if close has just begun: teardown must retract an
    /// in-flight producer's exact effect. This receipt is cleanup ownership, not fresh admission.
    func retainConnection(_ registration: DomainConnectionRegistration) {
        connections[registration.connectionID] = RetainedConnection(registration: registration, policyID: nil)
    }

    /// Transport disconnect may arrive through a different legacy server than the provider that
    /// observed this connection. Resolve that disconnect once; owner teardown never uses this path.
    func releaseDisconnectedConnection(_ connectionID: UUID) async {
        guard let coordinator else { return }
        let snapshot = await coordinator.snapshot()
        guard let registration = snapshot.connections.first(where: { $0.registration.connectionID == connectionID })?.registration else { return }
        if connections[connectionID]?.registration == registration { connections.removeValue(forKey: connectionID) }
        await releaseConnection(registration)
    }

    private func releaseConnection(_ registration: DomainConnectionRegistration) async {
        guard let coordinator else { return }
        let released = await coordinator.unregisterConnection(registration, operationID: UUID())
        if released.disposition == .applied || released.disposition == .unchanged {
            await domainRuntime.domainHost.releaseConnection(
                connectionID: registration.connectionID, connectionGeneration: registration.generation
            )
        } else {
            logger.warning("Domain connection release refused connection=\(registration.connectionID) generation=\(registration.generation) disposition=\(String(describing: released.disposition))")
        }
    }

    /// Legacy window teardown closes domain admission before draining runs. Keep the mapping owner
    /// alive through that drain, just as the server-owned lifetime was before resource extraction.
    func closeDomainAdmission() {
        isClosing = true
    }

    /// The caller first closes and joins its publication producers. Already-installed connection
    /// generations are withdrawn through the canonical coordinator, never by a guessed successor.
    func closeDomainRoute() async {
        closeDomainAdmission()
        if let closeTask { await closeTask.value
            return
        }
        let task = Task { @MainActor in
            await self.routingPublicationTail?.value
            self.routingPublicationTail = nil
            self.registrationTask?.cancel()
            if self.descriptor == nil, let registration = self.registrationTask {
                self.descriptor = await registration.value
            }
            self.registrationTask = nil
            defer { AppDomainRuntimeComposition.shared.forgetRouteResources(self, in: self.domainRuntime) }
            guard let coordinator = self.coordinator else { return }
            for connectionID in Array(self.connections.keys) {
                guard let registration = self.connections.removeValue(forKey: connectionID) else { continue }
                await self.releaseConnection(registration.registration)
            }
            guard let descriptor = self.descriptor else { return }
            _ = await coordinator.unregisterWindow(
                windowID: descriptor.windowID, generation: descriptor.generation, operationID: UUID()
            )
            self.descriptor = nil
        }
        closeTask = task
        await task.value
        closeTask = nil
    }
}
