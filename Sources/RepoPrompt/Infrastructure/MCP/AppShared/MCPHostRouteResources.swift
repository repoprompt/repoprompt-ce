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

    struct ProviderContext {
        let snapshot: MCPTabContextSnapshot
        let isCurrent: @MainActor @Sendable () -> Bool
        let validateCarrier: @MainActor @Sendable () async -> Bool
    }

    typealias ProviderContextResolver = @MainActor @Sendable () async -> ProviderContext?
    typealias ProviderContextSource = @MainActor (_ runID: UUID, _ tabID: UUID?) -> ProviderContextResolver?

    enum ProviderContextAdmission {
        case compatibility
        case refused
        case canonical(ProviderContextResolver)
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
        let rollback: @MainActor (MCPHostRouteResources, MCPRunRouteBindings.PendingPolicyToken, String?, UUID?) -> MCPRunRouteBindings.PendingPolicyRollbackResult?
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
    private(set) var providerContextSource: ProviderContextSource?
    /// Only an entered context/mapping producer retains its original physical cleanup adapter.
    /// Catalog construction alone must not keep a presentation VM alive.
    private var contextCleanupOwner: AnyObject?

    var readSideEffectCoordinator: DomainReadSideEffectCoordinator {
        domainRuntime.readSideEffectCoordinator
    }

    func fileTreeContextIsCurrent(_ original: MCPTabContextSnapshot, connectionID: UUID) -> Bool {
        guard !isClosing, let current = runRouteBindings.tabContextByConnectionID[connectionID] else { return false }
        return current.windowID == original.windowID && current.workspaceID == original.workspaceID
            && current.tabID == original.tabID && current.runID == original.runID
            && current.readFileAutoSelectionGeneration == original.readFileAutoSelectionGeneration
            && current.routeOwnerIdentity == original.routeOwnerIdentity
            && current.fileToolAuthoritySourceIdentity == original.fileToolAuthoritySourceIdentity
    }

    /// Consume only this route's existing connection receipt. Query dispatch never binds a new
    /// connection, follows a presenter or adopts a same-ID replacement.
    func fileTreeReadHandle(metadata: MCPRequestMetadata, context: DomainContextIdentity) async throws -> DomainReadContextHandle {
        guard !isClosing, let coordinator, let connectionID = metadata.connectionID,
              let retained = connections[connectionID],
              let routed = runRouteBindings.tabContextByConnectionID[connectionID],
              metadata.windowID == identity.routeID,
              routed.windowID == identity.routeID, routed.routeOwnerIdentity == ObjectIdentifier(self),
              routed.workspaceID == context.workspaceID, routed.tabID == context.contextID,
              runRouteBindings.connectionIDToRunID[connectionID].map({ $0 == routed.runID }) ?? true,
              metadata.tabContextHint.map({ $0.tabID == context.contextID && ($0.workspaceID == nil || $0.workspaceID == context.workspaceID) }) ?? true
        else { throw MCPFileToolAuthorityFailure.unavailable }
        let handle = try await coordinator.resolveReadContext(connection: retained.registration)
        guard !isClosing, connections[connectionID]?.registration == retained.registration,
              fileTreeContextIsCurrent(routed, connectionID: connectionID),
              handle.context == context,
              MCPServerViewModel.domainReadBindingSatisfiesRequestedRun(requestedRunID: routed.runID, resolvedBindingKind: handle.bindingKind)
        else { throw MCPFileToolAuthorityFailure.superseded }
        return handle
    }

    func drainFileTreeSelection(metadata: MCPRequestMetadata) async throws {
        guard !isClosing, let connectionID = metadata.connectionID,
              let context = runRouteBindings.tabContextByConnectionID[connectionID],
              context.windowID == identity.routeID, context.routeOwnerIdentity == ObjectIdentifier(self)
        else { throw MCPFileToolAuthorityFailure.unavailable }
        let key = MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: context.windowID, workspaceID: context.workspaceID, tabID: context.tabID,
            route: .bound(connectionID: connectionID, runID: context.runID),
            bindingGeneration: context.readFileAutoSelectionGeneration, routeOwnerIdentity: context.routeOwnerIdentity
        )
        guard let coordinator = readFileAutoSelectionCoordinator else { return }
        var keys: [MCPReadFileAutoSelectionCoordinator.ContextKey] = []
        if let lineage = runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID[connectionID],
           lineage.successorKey == key, let runID = context.runID,
           runRouteBindings.connectionIDByRunID[runID] == connectionID,
           runRouteBindings.connectionIDToRunID[connectionID] == runID
        {
            keys = lineage.predecessorKeys
        }
        for candidate in keys + [key] {
            try await MCPServerViewModel.requireReadFileAutoSelectionPrerequisite {
                await coordinator.drain(.canonicalSelection, for: candidate)
            }
        }
    }

    var historyWorkspaceLocations: HistoryWorkspaceLocationResolver {
        .init(workspaceStore: { [domainRuntime] in domainRuntime.workspaceStore })
    }

    func retainContextCleanupOwner(_ owner: AnyObject) -> Bool {
        guard contextCleanupOwner == nil || contextCleanupOwner === owner else { return false }
        contextCleanupOwner = owner
        return true
    }

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

    #if DEBUG
        /// Suspend the actual transfer after tentative publication to exercise actor reentrancy.
        var test_afterProcessConnectionTransfer: (@MainActor @Sendable (MCPRunRoutingCleanupReceipt) async -> Void)?
    #endif

    /// Join original publications before transferring the existing domain receipt and context.
    /// No new connection generation or catalog lookup is manufactured for a process refresh.
    func transferProcessConnection(_ connectionID: UUID, from origin: MCPRunRoutingCleanupReceipt, to successor: MCPRunRoutingCleanupReceipt) async -> Bool {
        await settleRoutingPublications()
        guard !isClosing, origin.routeOwner === self, successor.routeOwner === self,
              coordinator == nil || connections[connectionID]?.policyID == origin.policyID,
              runRouteBindings.transferProcessConnection(connectionID, from: origin, to: successor)
        else { return false }
        if let retained = connections[connectionID] {
            connections[connectionID] = RetainedConnection(registration: retained.registration, policyID: successor.policyID)
        }
        #if DEBUG
            await test_afterProcessConnectionTransfer?(successor)
        #endif
        return true
    }

    func installProviderContextSource(_ source: @escaping ProviderContextSource) {
        precondition(identity.kind == .independent && providerContextSource == nil)
        precondition(!isClosing && !runRouteBindings.hasRetainedCleanupOwnership)
        providerContextSource = source
        runRouting = nil
    }

    func admitProviderContext(runID: UUID, tabID: UUID?) -> ProviderContextAdmission {
        guard !isClosing else { return .refused }
        guard let providerContextSource else { return .compatibility }
        guard let resolve = providerContextSource(runID, tabID) else { return .refused }
        return .canonical(resolve)
    }

    func installPendingPolicy(_ receipt: MCPRunRoutingCleanupReceipt, connectionID: UUID, clientName: String?, tabID: UUID?) async -> PolicyContextInstallation? {
        guard !isClosing, !receipt.isConsumed, receipt.routeOwner === self else { return nil }
        guard providerContextSource != nil else {
            return runRouting?.install(self, receipt, connectionID, clientName, tabID)
        }
        guard let resolve = receipt.providerContextResolver, let context = await resolve() else { return nil }
        return installProviderContext(context, receipt: receipt, connectionID: connectionID, tabID: tabID)
    }

    func canCommitPendingPolicy(_ receipt: MCPRunRoutingCleanupReceipt, token: MCPRunRouteBindings.PendingPolicyToken) async -> Bool {
        func isCurrent() -> Bool {
            !isClosing && receipt.routeOwner === self && !receipt.isConsumed
                && runRouteBindings.cleanupOwnership(for: token.connectionID)?.policyID == receipt.policyID
                && runRouteBindings.isCurrent(token)
        }
        guard isCurrent() else { return false }
        if let validate = token.validateProviderCarrier {
            await settleRoutingPublications()
            guard isCurrent(), await providerBindingIsPublished(receipt, connectionID: token.connectionID),
                  await validate()
            else { return false }
        }
        return isCurrent()
    }

    private func providerBindingIsPublished(_ receipt: MCPRunRoutingCleanupReceipt, connectionID: UUID) async -> Bool {
        guard let coordinator else { return true }
        guard let registration = connections[connectionID], registration.policyID == receipt.policyID,
              let context = runRouteBindings.tabContextByConnectionID[connectionID], let workspaceID = context.workspaceID,
              let handle = try? await coordinator.resolveReadContext(connection: registration.registration),
              connections[connectionID]?.registration == registration.registration,
              handle.context == DomainContextIdentity(workspaceID: workspaceID, contextID: context.tabID),
              handle.bindingKind == .runScoped(runID: receipt.runID)
        else { return false }
        return true
    }

    func rollbackPendingPolicy(_ receipt: MCPRunRoutingCleanupReceipt, token: MCPRunRouteBindings.PendingPolicyToken, clientName: String?) -> MCPRunRouteBindings.PendingPolicyRollbackResult? {
        guard receipt.routeOwner === self else { return nil }
        if providerContextSource != nil {
            return rollbackProviderContext(receipt, token: token)
        }
        return runRouting?.rollback(self, token, clientName, receipt.routingWaitGeneration)
    }

    func consumeCleanup(_ receipt: MCPRunRoutingCleanupReceipt) async {
        guard receipt.routeOwner === self else { return }
        runRouteBindings.consumeCleanup(receipt) { connectionID in
            if providerContextSource != nil {
                removeProviderContext(connectionID: connectionID, runID: receipt.runID)
                runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
            } else {
                runRouting?.removeContext(self, receipt, connectionID)
            }
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
        runRouting = providerContextSource == nil ? catalog.runRouting : nil
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

    func releaseContextOwnerIfUnregisteredAndDrained() {
        guard runRouteBindings.connectionIDToRunID.isEmpty,
              !runRouteBindings.hasRetainedCleanupOwnership else { return }
        contextCleanupOwner = nil
        if catalogHandle == nil {
            catalog = nil
            runRouting = nil
        }
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
