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
        let completion: CheckCompletion
    }

    private actor CheckCompletion {
        private struct Waiter {
            let continuation: CheckedContinuation<Bool, Never>
            let deadlineTask: Task<Void, Never>
        }

        private var result: Bool?
        private var waiters: [UUID: Waiter] = [:]

        func wait(until deadline: ContinuousClock.Instant) async -> Bool {
            if let result { return result }
            if Task.isCancelled { return false }

            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let result {
                        continuation.resume(returning: result)
                        return
                    }
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                        return
                    }

                    let deadlineTask = Task { [weak self] in
                        do {
                            try await ContinuousClock().sleep(until: deadline)
                        } catch {
                            return
                        }
                        await self?.expire(waiterID)
                    }
                    waiters[waiterID] = Waiter(
                        continuation: continuation,
                        deadlineTask: deadlineTask
                    )
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancel(waiterID)
                }
            }
        }

        func resolve(_ result: Bool) {
            guard self.result == nil else { return }
            self.result = result
            let resolvedWaiters = waiters.values
            waiters.removeAll()
            for waiter in resolvedWaiters {
                waiter.deadlineTask.cancel()
                waiter.continuation.resume(returning: result)
            }
        }

        private func expire(_ waiterID: UUID) {
            guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
            waiter.continuation.resume(returning: false)
        }

        private func cancel(_ waiterID: UUID) {
            guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(returning: false)
        }
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

            let isReady = await checkServicesReady(windowID: windowID, deadline: deadline)
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

    private func checkServicesReady(
        windowID: Int?,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        let key = windowID.map(CheckKey.window) ?? .application
        let attempt: CheckAttempt
        if let activeCheck = activeChecks[key] {
            attempt = activeCheck
        } else {
            let scopePresenceOperation = scopePresenceOperation
            let windowStateOperation = windowStateOperation
            let task = Task {
                await Self.performReadinessCheck(
                    windowID: windowID,
                    scopePresenceOperation: scopePresenceOperation,
                    windowStateOperation: windowStateOperation
                )
            }
            let completion = CheckCompletion()
            attempt = CheckAttempt(id: UUID(), task: task, completion: completion)
            activeChecks[key] = attempt

            Task { [weak self] in
                let result = await task.value
                await completion.resolve(result)
                await self?.removeActiveCheck(key: key, id: attempt.id)
            }
        }

        #if DEBUG
            await checkJoinedOperation(windowID)
        #endif
        return await attempt.completion.wait(until: deadline)
    }

    private func removeActiveCheck(key: CheckKey, id: UUID) {
        if activeChecks[key]?.id == id {
            activeChecks.removeValue(forKey: key)
        }
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
