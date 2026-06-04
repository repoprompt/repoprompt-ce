//
//  MCPToolCatalogReadiness.swift
//  RepoPrompt
//
//  Ensures the MCP tool catalog is fully ready before serving tools/list.
//  This prevents clients from caching an incomplete tool list.
//

import Foundation
import Logging

private let log = Logger(label: "com.repoprompt.mcp.readiness")

#if DEBUG
    private var mcpToolCatalogReadinessDebugLoggingEnabled = false
    private func mcpToolCatalogReadinessLog(_ message: @autoclosure () -> String) {
        guard mcpToolCatalogReadinessDebugLoggingEnabled else { return }
        print("[MCPToolCatalogReadiness] \(message())")
    }
#else
    private func mcpToolCatalogReadinessLog(_ message: @autoclosure () -> String) {}
#endif

/// Coordinates tool catalog readiness for MCP connections.
/// Ensures that before a connection can list tools, all required services
/// are registered and their tools are built.
actor MCPToolCatalogReadiness {
    static let shared = MCPToolCatalogReadiness()

    private init() {}

    /// Default timeout for readiness wait
    static let defaultTimeout: TimeInterval = 5.0

    /// Wait for the tool catalog to be ready for a given window.
    /// This ensures required services are registered and tools are built.
    ///
    /// - Parameters:
    ///   - windowID: The window ID to wait for (nil to skip window-specific checks)
    ///   - timeout: Maximum time to wait
    /// - Returns: true if ready, false if timeout
    func awaitReady(windowID: Int?, timeout: TimeInterval = defaultTimeout) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.05 // 50ms

        while Date() < deadline {
            // Check if required services are registered
            let isReady = await MainActor.run {
                checkServicesReady(windowID: windowID)
            }

            if isReady {
                mcpToolCatalogReadinessLog("Tool catalog ready for window \(windowID.map(String.init) ?? "nil")")
                return true
            }

            // Wait a bit before checking again
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                return false // Task cancelled
            }
        }

        log.warning("Tool catalog readiness timeout for window \(windowID.map(String.init) ?? "nil")")
        return false
    }

    /// Ensure tools are built for a window by accessing them.
    /// This forces lazy tool cache population and AWAITS completion.
    func warmToolCache(windowID: Int) async {
        // Get the MCPServerViewModel on MainActor
        let mcpServer: MCPServerViewModel? = await MainActor.run {
            WindowStatesManager.shared.window(withID: windowID)?.mcpServer
        }

        guard let mcpServer else {
            mcpToolCatalogReadinessLog("Cannot warm tool cache - window \(windowID) not found")
            return
        }

        // Actually await the catalog service tools to force cache build.
        // This will hop to MainActor internally since MCPServerViewModel is @MainActor.
        #if DEBUG || EDIT_FLOW_PERF
            let readinessWarmAccessState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess)
        #endif
        _ = await mcpServer.windowMCPTools
        #if DEBUG || EDIT_FLOW_PERF
            EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess, readinessWarmAccessState)
        #endif
        mcpToolCatalogReadinessLog("Tool cache warmed for window \(windowID)")
    }

    /// Check if required services are ready (MainActor)
    @MainActor
    private func checkServicesReady(windowID: Int?) -> Bool {
        if let windowID {
            // Check if the window exists
            guard let window = WindowStatesManager.shared.window(withID: windowID) else {
                mcpToolCatalogReadinessLog("Window \(windowID) not found during readiness check")
                return false
            }

            // If tools are disabled for this window, that's a valid ready state even before registration.
            if !window.mcpServer.windowToolsEnabled {
                mcpToolCatalogReadinessLog("Window \(windowID) has tools disabled - considered ready")
                return true
            }
        }

        // Always require WindowRoutingService to be registered (provides routing tools)
        let hasRoutingService = ServiceRegistry.services.contains { service in
            service is WindowRoutingService
        }

        if !hasRoutingService {
            mcpToolCatalogReadinessLog("WindowRoutingService not yet registered")
            return false
        }

        // If no specific window required, routing service is enough
        guard let windowID else {
            return true
        }

        // Check if the window's catalog service is registered.
        let catalogService = WindowStatesManager.shared.window(withID: windowID)?.mcpServer.windowMCPToolCatalogService
        let isWindowServiceRegistered = ServiceRegistry.services.contains { service in
            guard let catalogService else { return false }
            return (service as AnyObject) === (catalogService as AnyObject)
        }

        if !isWindowServiceRegistered {
            mcpToolCatalogReadinessLog("MCPWindowToolCatalogService for window \(windowID) not yet registered")
            return false
        }

        return true
    }
}
