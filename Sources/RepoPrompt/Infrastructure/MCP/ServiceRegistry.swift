//
//  ServiceRegistry.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

/// Central registry for all `Service` instances that want to expose tools
/// to external MCP clients.  Services register themselves at runtime.
@MainActor
enum ServiceRegistry {
    private static var _services: [any Service] = []

    /// Read-only view of all registered services.
    static var services: [any Service] {
        _services
    }

    /// Register a new service so its tools become discoverable.
    static func register(_ service: any Service) {
        // Avoid duplicate registrations
        if _services.contains(where: { $0 as AnyObject === service as AnyObject }) {
            return
        }
        _services.append(service)
        // Inform the availability store so the Settings UI can list them
        Task {
            #if DEBUG || EDIT_FLOW_PERF
                let serviceTools = await EditFlowPerf.measure(EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication) {
                    await service.tools
                }
                await ToolAvailabilityStore.shared.registerTools(serviceTools)
            #else
                await ToolAvailabilityStore.shared.registerTools(service.tools)
            #endif
            // Tools list has effectively changed; notify connected clients
            await ServerNetworkManager.shared.broadcastToolListChanged()
        }
    }

    /// Unregister a service to remove its tools.
    static func unregister(_ service: any Service) {
        if let idx = _services.firstIndex(where: { $0 as AnyObject === service as AnyObject }) {
            _services.remove(at: idx)
            // Broadcast tool list change to connected clients
            Task {
                await ServerNetworkManager.shared.broadcastToolListChanged()
            }
        }
    }
}
