//
//  MCPToolCatalogReadiness.swift
//  RepoPrompt
//
//  Ensures the MCP tool catalog is fully ready before serving tools/list.
//  This prevents clients from caching an incomplete tool list.
//

import Foundation
import RepoPromptDomainRuntime

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
/// Readiness observes only actor-owned scope/name presence. It never materializes
/// definitions, fingerprints, or catalog digests, and concurrent callers share
/// an in-flight check for the same scope.
actor MCPToolCatalogReadiness {
    struct WindowRegistrationState {
        let toolsEnabled: Bool
        let toolsRequested: Bool
    }

    private enum CheckKey: Hashable {
        case application
        case window(Int)
    }

    private struct CheckAttempt {
        let id: UUID
        let task: Task<Bool, Never>
    }

    typealias ScopePresenceOperation = @Sendable (
        _ requiredToolNames: [String],
        _ scope: MCPDomainToolRegistrationScope
    ) async -> MCPDomainToolScopePresence
    typealias WindowStateOperation = @Sendable (_ windowID: Int) async -> WindowRegistrationState?

    static let shared = MCPToolCatalogReadiness()

    private let scopePresenceOperation: ScopePresenceOperation
    private let windowStateOperation: WindowStateOperation
    private var activeChecks: [CheckKey: CheckAttempt] = [:]
    #if DEBUG
        private let checkJoinedOperation: @Sendable (Int?) async -> Void
    #endif

    private init() {
        scopePresenceOperation = { requiredToolNames, scope in
            await AppDomainRuntimeComposition.shared.scopePresence(
                requiredToolNames: requiredToolNames,
                scope: scope
            )
        }
        windowStateOperation = { windowID in
            await MainActor.run {
                guard let server = WindowStatesManager.shared.window(withID: windowID)?.mcpServer else {
                    return nil
                }
                return WindowRegistrationState(
                    toolsEnabled: server.windowToolsEnabled,
                    toolsRequested: server.windowToolsAreRequested
                )
            }
        }
        #if DEBUG
            checkJoinedOperation = { _ in }
        #endif
    }

    #if DEBUG
        init(
            scopePresenceOperation: @escaping ScopePresenceOperation,
            windowStateOperation: @escaping WindowStateOperation,
            checkJoinedOperation: @escaping @Sendable (Int?) async -> Void = { _ in }
        ) {
            self.scopePresenceOperation = scopePresenceOperation
            self.windowStateOperation = windowStateOperation
            self.checkJoinedOperation = checkJoinedOperation
        }
    #endif

    /// Default timeout for readiness wait
    static let defaultTimeout: TimeInterval = 5.0

    /// Wait for the tool catalog to be ready for a given window.
    func awaitReady(windowID: Int?, timeout: TimeInterval = defaultTimeout) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        var pollInterval: TimeInterval = 0.025

        while true {
            if Task.isCancelled { return false }
            guard clock.now < deadline else { break }

            let isReady = await checkServicesReady(windowID: windowID)
            if Task.isCancelled { return false }
            guard clock.now <= deadline else { break }
            if isReady {
                mcpToolCatalogReadinessLog("Tool catalog ready for window \(windowID.map(String.init) ?? "nil")")
                return true
            }

            let nextPoll = min(
                clock.now.advanced(by: .seconds(pollInterval)),
                deadline
            )
            do {
                try await clock.sleep(until: nextPoll, tolerance: .milliseconds(2))
            } catch {
                return false
            }
            pollInterval = min(pollInterval * 2, 0.2)
        }

        return false
    }

    private func checkServicesReady(windowID: Int?) async -> Bool {
        let key = windowID.map(CheckKey.window) ?? .application
        if let activeCheck = activeChecks[key] {
            #if DEBUG
                await checkJoinedOperation(windowID)
            #endif
            return await activeCheck.task.value
        }

        let scopePresenceOperation = scopePresenceOperation
        let windowStateOperation = windowStateOperation
        let task = Task {
            await Self.performReadinessCheck(
                windowID: windowID,
                scopePresenceOperation: scopePresenceOperation,
                windowStateOperation: windowStateOperation
            )
        }
        let attempt = CheckAttempt(id: UUID(), task: task)
        activeChecks[key] = attempt
        #if DEBUG
            await checkJoinedOperation(windowID)
        #endif
        let result = await task.value
        if activeChecks[key]?.id == attempt.id {
            activeChecks.removeValue(forKey: key)
        }
        return result
    }

    private static func performReadinessCheck(
        windowID: Int?,
        scopePresenceOperation: ScopePresenceOperation,
        windowStateOperation: WindowStateOperation
    ) async -> Bool {
        let globalPresence = await scopePresenceOperation(
            MCPDomainToolCatalog.globalToolNames,
            .application
        )
        guard globalPresence.isComplete else {
            mcpToolCatalogReadinessLog("Application-scoped global domain registrations are not ready")
            return false
        }

        guard let windowID else { return true }
        guard let windowState = await windowStateOperation(windowID) else {
            mcpToolCatalogReadinessLog("Window \(windowID) not found during readiness check")
            return false
        }

        if !windowState.toolsEnabled {
            if windowState.toolsRequested {
                mcpToolCatalogReadinessLog("Window \(windowID) requested tools but registration is not ready")
                return false
            }
            mcpToolCatalogReadinessLog("Window \(windowID) intentionally has tools disabled after global readiness")
            return true
        }

        let windowPresence = await scopePresenceOperation(
            MCPDomainToolCatalog.windowToolNames,
            .window(id: windowID)
        )
        if !windowPresence.isComplete {
            mcpToolCatalogReadinessLog("Window domain tool registration for window \(windowID) not ready")
        }
        return windowPresence.isComplete
    }
}
