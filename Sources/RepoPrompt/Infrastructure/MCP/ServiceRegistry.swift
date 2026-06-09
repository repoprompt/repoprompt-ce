//
//  ServiceRegistry.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

/// Instance-owned registry for MCP tool providers. Mutable state stays on the main actor;
/// consumers receive immutable snapshots so request hot paths never scan service catalogs.
@MainActor
final class MCPServiceRegistry {
    enum Scope: Equatable {
        case host
        case window(Int)
    }

    enum Role {
        case ordinary
        case contextRouting
        case appSettings
    }

    /// Immutable after publication. The service revision is advanced synchronously on every
    /// catalog invalidation so queued calls can reject routes captured from an older catalog.
    struct IndexedToolRoute: @unchecked Sendable {
        let serviceIdentity: ObjectIdentifier
        let catalogRevision: UInt64
        let toolIndex: Int
        let service: any Service
        let scope: Scope
        let role: Role
        let tool: Tool
    }

    /// Immutable generation-fenced route catalog safe to hand from MainActor to connection actors.
    struct Snapshot: @unchecked Sendable {
        let generation: UInt64
        let orderedRoutes: [IndexedToolRoute]
        let routesByCanonicalName: [String: [IndexedToolRoute]]

        func routes(forCanonicalName name: String) -> [IndexedToolRoute] {
            routesByCanonicalName[name] ?? []
        }
    }

    /// Fixed listing boundary. Services registered after capture cannot delay or appear in the
    /// result, while every service already registered at capture is awaited and represented.
    struct PublicationBoundary: @unchecked Sendable {
        fileprivate let generation: UInt64
        fileprivate let publications: [ServicePublication]
    }

    private struct RegisteredService {
        let identity: ObjectIdentifier
        let service: any Service
        var catalogRevision: UInt64
    }

    fileprivate struct ServicePublication: @unchecked Sendable {
        let identity: ObjectIdentifier
        let service: any Service
        let catalogRevision: UInt64
        let scope: Scope
        let role: Role
    }

    private var registeredServices: [RegisteredService] = []
    private var requestedGeneration: UInt64 = 0
    private var nextCatalogRevision: UInt64 = 0
    private var snapshotNeedsRebuild = false
    private var committedSnapshot = Snapshot(generation: 0, orderedRoutes: [], routesByCanonicalName: [:])
    private var snapshotDidChangeSink: (@Sendable () async -> Void)?
    private var hasPendingSnapshotChangeNotification = false

    nonisolated init() {}

    var services: [any Service] {
        registeredServices.map(\.service)
    }

    func setSnapshotDidChangeSink(_ sink: @escaping @Sendable () async -> Void) {
        snapshotDidChangeSink = sink
        guard hasPendingSnapshotChangeNotification else { return }
        hasPendingSnapshotChangeNotification = false
        Task { await sink() }
    }

    func contains(_ service: any Service) -> Bool {
        let identity = ObjectIdentifier(service as AnyObject)
        return registeredServices.contains { $0.identity == identity }
    }

    /// Register a new service so its tools become discoverable.
    func register(_ service: any Service) {
        guard !contains(service) else { return }
        invalidateSnapshot()
        nextCatalogRevision &+= 1
        let registrationRevision = nextCatalogRevision
        let serviceIdentity = ObjectIdentifier(service as AnyObject)
        registeredServices.append(RegisteredService(
            identity: serviceIdentity,
            service: service,
            catalogRevision: registrationRevision
        ))
        let registrationGeneration = requestedGeneration

        Task { @MainActor [weak self] in
            #if DEBUG || EDIT_FLOW_PERF
                let serviceTools = await EditFlowPerf.measure(EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication) {
                    await service.tools
                }
            #else
                let serviceTools = await service.tools
            #endif
            guard let self,
                  isCurrent(serviceIdentity: serviceIdentity, catalogRevision: registrationRevision)
            else {
                return
            }
            ToolAvailabilityStore.shared.registerTools(serviceTools)
            await publishSnapshotChangeIfCurrent(expectedGeneration: registrationGeneration)
        }
    }

    /// Invalidate a registered service after its cached catalog changes. The per-service revision
    /// advances before async publication so already-queued routes become stale immediately.
    func invalidateCatalog(for service: any Service) {
        let identity = ObjectIdentifier(service as AnyObject)
        guard let index = registeredServices.firstIndex(where: { $0.identity == identity }) else { return }
        invalidateSnapshot()
        nextCatalogRevision &+= 1
        registeredServices[index].catalogRevision = nextCatalogRevision
        scheduleSnapshotChangePublication(expectedGeneration: requestedGeneration)
    }

    /// Unregister a service and synchronously remove its committed routes.
    func unregister(_ service: any Service) {
        let serviceIdentity = ObjectIdentifier(service as AnyObject)
        guard let index = registeredServices.firstIndex(where: { $0.identity == serviceIdentity }) else {
            return
        }
        registeredServices.remove(at: index)
        invalidateSnapshot()
        committedSnapshot = Self.snapshot(
            generation: requestedGeneration,
            routes: committedSnapshot.orderedRoutes.filter { $0.serviceIdentity != serviceIdentity }
        )
        scheduleSnapshotChangePublication(expectedGeneration: requestedGeneration)
    }

    /// Returns the last committed immutable index without rebuilding on a request hot path.
    func routeSnapshot() -> Snapshot {
        committedSnapshot
    }

    /// Captures the exact set of registered catalogs a listing operation must represent.
    func capturePublicationBoundary() -> PublicationBoundary {
        PublicationBoundary(
            generation: requestedGeneration,
            publications: registeredServices.map(Self.publication(for:))
        )
    }

    /// Resolves a fixed publication boundary without chasing services registered afterward.
    func snapshot(for boundary: PublicationBoundary) async -> Snapshot {
        let routes = await Self.routes(for: boundary.publications)
        ToolAvailabilityStore.shared.registerTools(routes.map(\.tool))
        return Self.snapshot(generation: boundary.generation, routes: routes)
    }

    /// Rebuilds eagerly after registration or invalidation and commits only the newest generation.
    func awaitCurrentSnapshot() async -> Snapshot {
        while snapshotNeedsRebuild {
            let boundary = capturePublicationBoundary()
            let snapshot = await snapshot(for: boundary)

            guard boundary.generation == requestedGeneration,
                  boundaryStillCurrent(boundary)
            else {
                continue
            }
            committedSnapshot = snapshot
            snapshotNeedsRebuild = false
        }
        return committedSnapshot
    }

    func committedSnapshotContains(_ service: any Service) -> Bool {
        let identity = ObjectIdentifier(service as AnyObject)
        return committedSnapshot.orderedRoutes.contains { $0.serviceIdentity == identity }
    }

    func isRegistered(serviceIdentity: ObjectIdentifier) -> Bool {
        registeredServices.contains { $0.identity == serviceIdentity }
    }

    /// Validates the exact service catalog revision captured by an indexed route. Global registry
    /// changes for unrelated services do not invalidate the route.
    func isCurrent(_ route: IndexedToolRoute) -> Bool {
        isCurrent(serviceIdentity: route.serviceIdentity, catalogRevision: route.catalogRevision)
    }

    #if DEBUG
        var debugRequestedGeneration: UInt64 {
            requestedGeneration
        }
    #endif

    private func invalidateSnapshot() {
        requestedGeneration &+= 1
        snapshotNeedsRebuild = true
    }

    private func boundaryStillCurrent(_ boundary: PublicationBoundary) -> Bool {
        guard boundary.publications.count == registeredServices.count else { return false }
        return zip(boundary.publications, registeredServices).allSatisfy { publication, registered in
            publication.identity == registered.identity
                && publication.catalogRevision == registered.catalogRevision
        }
    }

    private func isCurrent(serviceIdentity: ObjectIdentifier, catalogRevision: UInt64) -> Bool {
        registeredServices.contains {
            $0.identity == serviceIdentity && $0.catalogRevision == catalogRevision
        }
    }

    private func scheduleSnapshotChangePublication(expectedGeneration: UInt64) {
        Task { @MainActor [weak self] in
            await self?.publishSnapshotChangeIfCurrent(expectedGeneration: expectedGeneration)
        }
    }

    private func publishSnapshotChangeIfCurrent(expectedGeneration: UInt64) async {
        let snapshot = await awaitCurrentSnapshot()
        guard expectedGeneration == requestedGeneration,
              snapshot.generation == expectedGeneration
        else {
            return
        }
        if let snapshotDidChangeSink {
            await snapshotDidChangeSink()
        } else {
            hasPendingSnapshotChangeNotification = true
        }
    }

    private static func publication(for registered: RegisteredService) -> ServicePublication {
        let service = registered.service
        let scope: Scope = if let windowScoped = service as? WindowScopedService {
            .window(windowScoped.windowID)
        } else {
            .host
        }
        let role: Role = if service is WindowRoutingService {
            .contextRouting
        } else if service is AppSettingsMCPService {
            .appSettings
        } else {
            .ordinary
        }
        return ServicePublication(
            identity: registered.identity,
            service: service,
            catalogRevision: registered.catalogRevision,
            scope: scope,
            role: role
        )
    }

    private static func routes(for publications: [ServicePublication]) async -> [IndexedToolRoute] {
        var routes: [IndexedToolRoute] = []
        for publication in publications {
            for (toolIndex, tool) in await publication.service.tools.enumerated() {
                routes.append(IndexedToolRoute(
                    serviceIdentity: publication.identity,
                    catalogRevision: publication.catalogRevision,
                    toolIndex: toolIndex,
                    service: publication.service,
                    scope: publication.scope,
                    role: publication.role,
                    tool: tool
                ))
            }
        }
        return routes
    }

    private static func snapshot(generation: UInt64, routes: [IndexedToolRoute]) -> Snapshot {
        var routesByCanonicalName: [String: [IndexedToolRoute]] = [:]
        for route in routes {
            let canonicalName = MCPToolNameCanonicalizer.canonicalName(for: route.tool.name)
            routesByCanonicalName[canonicalName, default: []].append(route)
        }
        return Snapshot(
            generation: generation,
            orderedRoutes: routes,
            routesByCanonicalName: routesByCanonicalName
        )
    }
}

/// Transitional forwarding facade for legacy tests and audited call sites.
/// Production MCP paths should use the manager-owned `MCPServiceRegistry` instance.
@MainActor
enum ServiceRegistry {
    static var services: [any Service] {
        ServerNetworkManager.shared.serviceRegistry.services
    }

    static func register(_ service: any Service) {
        ServerNetworkManager.shared.serviceRegistry.register(service)
    }

    static func unregister(_ service: any Service) {
        ServerNetworkManager.shared.serviceRegistry.unregister(service)
    }
}
