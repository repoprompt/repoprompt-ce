import Foundation

/// Snapshot of a session needed for background cleanup after workspace switch.
struct WorkspaceSwitchSessionCleanupTarget {
    let tabID: UUID
    let session: AgentModeViewModel.TabSession
    let boundSessionID: UUID?
    let runID: UUID?
}

/// Owns the background cleanup of sessions discarded during a workspace switch.
///
/// The synchronous discard (`prepareWorkspaceSwitchSessionDiscard`) and the
/// switch orchestration (`handleWorkspaceSwitch`) remain on the view model
/// because they are deeply coupled to VM state (~20 fields, ~10 methods).
/// This provider encapsulates the detached async cleanup that runs after the
/// switch: MCP control teardown, MCP run routing cleanup, provider dispose,
/// ACP controller shutdown, and codex/claude coordinator shutdown.
///
/// The VM calls `scheduleBackgroundCleanup(targets:reason:)` and the provider
/// runs the cleanup as a detached task, calling back into the VM for
/// MCP-specific teardown via the delegate protocol.
@MainActor
protocol WorkspaceSwitchSessionProviderDelegate: AnyObject {
    /// Teardown MCP control for a discarded session (cancels observation,
    /// clears mcpControlContext, etc.). The session is already detached
    /// from the active workspace.
    func teardownMCPControlForDiscardedSession(
        _ session: AgentModeViewModel.TabSession,
        cleanupSessionStore: Bool,
        publishChanges: Bool,
        deactivateLiveControlContext: Bool
    ) async

    /// Cleanup MCP run routing for a discarded session.
    func cleanupMCPRunRoutingForDiscardedSession(
        boundSessionID: UUID?,
        liveSession: AgentModeViewModel.TabSession,
        explicitRunID: UUID?,
        reason: String
    ) async
}

@MainActor
final class AgentModeWorkspaceSwitchCleanupProvider {
    weak var delegate: WorkspaceSwitchSessionProviderDelegate?

    private let codexCoordinator: CodexAgentModeCoordinator
    private let claudeCoordinator: ClaudeAgentModeCoordinator

    private var backgroundCleanupTasks: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
        private(set) var test_backgroundCleanupDrainTasks: [UUID: Task<Void, Never>] = [:]
        private var test_backgroundCleanupDrainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var test_backgroundCleanupDrainTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    #endif

    init(
        codexCoordinator: CodexAgentModeCoordinator,
        claudeCoordinator: ClaudeAgentModeCoordinator
    ) {
        self.codexCoordinator = codexCoordinator
        self.claudeCoordinator = claudeCoordinator
    }

    /// Schedules background cleanup for discarded sessions after a workspace
    /// switch. Each session has its MCP control torn down, MCP run routing
    /// cleaned up, provider disposed, and coordinators shut down — all in a
    /// detached task that yields between sessions to avoid blocking the main
    /// actor.
    func scheduleBackgroundCleanup(
        targets: [WorkspaceSwitchSessionCleanupTarget],
        reason: String
    ) {
        guard !targets.isEmpty else { return }
        let cleanupID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.backgroundCleanupTasks.removeValue(forKey: cleanupID)
            }
            #if DEBUG
                defer {
                    self?.test_completeBackgroundCleanup(cleanupID)
                }
            #endif
            await Task.yield()
            guard let self else { return }
            for target in targets {
                await delegate?.teardownMCPControlForDiscardedSession(
                    target.session,
                    cleanupSessionStore: true,
                    publishChanges: false,
                    deactivateLiveControlContext: false
                )
                await delegate?.cleanupMCPRunRoutingForDiscardedSession(
                    boundSessionID: target.boundSessionID,
                    liveSession: target.session,
                    explicitRunID: target.runID,
                    reason: reason
                )
                await Task.yield()
            }
            for target in targets {
                await Self.disposeDetachedTarget(
                    target,
                    codexCoordinator: codexCoordinator,
                    claudeCoordinator: claudeCoordinator
                )
                await Task.yield()
            }
        }
        backgroundCleanupTasks[cleanupID] = task
        #if DEBUG
            test_backgroundCleanupDrainTasks[cleanupID] = task
        #endif
    }

    private static func disposeDetachedTarget(
        _ target: WorkspaceSwitchSessionCleanupTarget,
        codexCoordinator: CodexAgentModeCoordinator,
        claudeCoordinator: ClaudeAgentModeCoordinator
    ) async {
        let session = target.session
        await session.disposeProviderIfPresent()
        await session.teardownACPControllerIfPresent()
        await codexCoordinator.shutdownCodexSession(
            session,
            clearTabScopedCoordinatorState: false,
            detachedRunID: target.runID
        )
        await claudeCoordinator.shutdownClaudeSession(
            session,
            clearTabScopedCoordinatorState: false,
            detachedRunID: target.runID
        )
    }

    // MARK: - Debug test support

    #if DEBUG
        private func test_completeBackgroundCleanup(_ cleanupID: UUID) {
            test_backgroundCleanupDrainTasks.removeValue(forKey: cleanupID)
            if let waiter = test_backgroundCleanupDrainWaiters.removeValue(forKey: cleanupID) {
                waiter.resume()
            }
            test_backgroundCleanupDrainTimeoutTasks.removeValue(forKey: cleanupID)?.cancel()
        }

        func test_drainBackgroundCleanup(timeoutNanoseconds: UInt64) async throws {
            let cleanupIDs = Array(test_backgroundCleanupDrainTasks.keys)
            for cleanupID in cleanupIDs {
                guard test_backgroundCleanupDrainTasks[cleanupID] != nil else { continue }
                let task = test_backgroundCleanupDrainTasks[cleanupID]
                try await withTaskCancellationHandler(handler: {
                    task?.cancel()
                }, operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        test_backgroundCleanupDrainWaiters[cleanupID] = continuation
                        let timeoutTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                            if let waiter = test_backgroundCleanupDrainWaiters.removeValue(forKey: cleanupID) {
                                waiter.resume(throwing: AgentModeWorkspaceSwitchCleanupDrainTimeoutError(timeoutNanoseconds: timeoutNanoseconds))
                            }
                        }
                        test_backgroundCleanupDrainTimeoutTasks[cleanupID] = timeoutTask
                    }
                })
            }
        }
    #endif

    func cancelAllBackgroundCleanup() {
        for task in backgroundCleanupTasks.values {
            task.cancel()
        }
        backgroundCleanupTasks.removeAll()
        #if DEBUG
            for task in test_backgroundCleanupDrainTasks.values {
                task.cancel()
            }
            test_backgroundCleanupDrainTasks.removeAll()
            for (_, waiter) in test_backgroundCleanupDrainWaiters {
                waiter.resume(throwing: CancellationError())
            }
            test_backgroundCleanupDrainWaiters.removeAll()
            for task in test_backgroundCleanupDrainTimeoutTasks.values {
                task.cancel()
            }
            test_backgroundCleanupDrainTimeoutTasks.removeAll()
        #endif
    }
}

extension AgentModeViewModel.TabSession {
    func disposeProviderIfPresent() async {
        let provider = provider
        self.provider = nil
        if let provider {
            await provider.dispose()
        }
    }

    func teardownACPControllerIfPresent() async {
        acpSteeringFlushTask?.cancel()
        acpSteeringFlushTask = nil
        pendingACPSteeringInstructions.removeAll()
        guard let controller = acpController else { return }
        acpController = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: self)
        await controller.cancelPrompt()
        await controller.shutdown()
    }
}

#if DEBUG
    private struct AgentModeWorkspaceSwitchCleanupDrainTimeoutError: LocalizedError {
        let timeoutNanoseconds: UInt64

        var errorDescription: String? {
            let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
            return "Timed out waiting for workspace-switch background cleanup after \(timeoutSeconds)s."
        }
    }
#endif
