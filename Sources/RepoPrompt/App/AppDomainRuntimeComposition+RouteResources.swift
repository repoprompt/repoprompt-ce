import Foundation
import RepoPromptDomainRuntime

extension AppDomainRuntimeComposition {
    @MainActor
    struct WeakRouteResources {
        weak var owner: MCPHostRouteResources?
    }

    enum IndependentRouteLookup {
        case unregistered
        case unavailable
        case available(MCPHostRouteResources)
    }

    @MainActor
    func recordRouteResources(_ owner: MCPHostRouteResources, in runtime: MCPDomainRuntime) {
        guard owner.identity.kind == .independent, let descriptor = owner.descriptor else { return }
        let key = ObjectIdentifier(runtime)
        if let existing = independentRouteOwners[key]?[descriptor.windowID]?.owner,
           let generation = existing.descriptor?.generation, generation > descriptor.generation { return }
        independentRouteOwners[key, default: [:]][descriptor.windowID] = .init(owner: owner)
    }

    @MainActor
    func forgetRouteResources(_ owner: MCPHostRouteResources, in runtime: MCPDomainRuntime) {
        let key = ObjectIdentifier(runtime)
        guard independentRouteOwners[key]?[owner.identity.routeID]?.owner === owner else { return }
        independentRouteOwners[key]?.removeValue(forKey: owner.identity.routeID)
        if independentRouteOwners[key]?.isEmpty == true { independentRouteOwners.removeValue(forKey: key) }
    }

    /// Resolve only an independently registered route. No window, writer, catalog or admission
    /// is manufactured by this index, and a stale owner cannot win against the domain generation.
    @MainActor
    func independentRouteResources(
        routeID: Int,
        in suppliedRuntime: MCPDomainRuntime? = nil
    ) async -> IndependentRouteLookup {
        let runtime = suppliedRuntime ?? runtime
        let key = ObjectIdentifier(runtime)
        guard let entry = independentRouteOwners[key]?[routeID] else { return .unregistered }
        guard entry.owner != nil else {
            independentRouteOwners[key]?.removeValue(forKey: routeID)
            if independentRouteOwners[key]?.isEmpty == true { independentRouteOwners.removeValue(forKey: key) }
            return .unavailable
        }
        let currentDescriptor = await runtime.routingCoordinator.windowDescriptor(windowID: routeID)
        guard let owner = independentRouteOwners[key]?[routeID]?.owner,
              !owner.isClosing,
              let descriptor = owner.descriptor,
              let currentDescriptor, currentDescriptor.generation == descriptor.generation, !currentDescriptor.isClosing
        else { return .unavailable }
        return .available(owner)
    }
}
