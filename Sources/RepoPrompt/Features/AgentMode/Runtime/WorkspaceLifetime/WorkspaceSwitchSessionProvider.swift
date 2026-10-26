import Foundation

/// Bookkeeping snapshot captured by the first, prepare phase of workspace-switch
/// discard, before the canonical cancellation awaits run. Provider/controller
/// ownership is intentionally NOT captured here: graceful `cancelAgentRun`
/// still needs the live session's provider state.
struct WorkspaceSwitchSessionDiscardContext {
    let tabID: UUID
    let session: AgentTabSession
    let boundSessionID: UUID?
    /// Run identity observed when the discard decision was made.
    let preparedRunID: UUID?
}

/// Ownership-transfer snapshot produced by the second, finalize phase of
/// workspace-switch discard. Finalize runs synchronously after all cancellation
/// awaits and in the same main-actor slice as `sessions.removeAll()`, so these
/// handles are provably the discarded session's own — background cleanup
/// operates on them exclusively and never reads live session or tab-keyed
/// coordinator state after a suspension point.
struct WorkspaceSwitchSessionCleanupTarget {
    let tabID: UUID
    let session: AgentTabSession
    let boundSessionID: UUID?
    /// Distinct run IDs needing MCP run-routing cleanup: the run captured at
    /// prepare time plus any successor run present at finalize time.
    let runIDs: [UUID]
    let provider: HeadlessAgentProvider?
    let acpController: ACPAgentSessionController?
    let detachedClaude: ClaudeAgentModeCoordinator.DetachedClaudeController?
    let detachedCodex: CodexAgentModeCoordinator.DetachedCodexController?
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
        _ session: AgentTabSession,
        cleanupSessionStore: Bool,
        publishChanges: Bool,
        deactivateLiveControlContext: Bool
    ) async

    /// Cleanup MCP run routing for a discarded session.
    func cleanupMCPRunRoutingForDiscardedSession(
        boundSessionID: UUID?,
        liveSession: AgentTabSession,
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
    ///
    /// The coordinators are captured before the initial yield so that process
    /// termination (`disposeDetachedTarget`) can complete even if the provider
    /// is deallocated before the task resumes. Only the delegate-dependent MCP
    /// teardown is skipped when the provider/delegate is gone — that state is
    /// owned by the delegate and is irrelevant once it is deallocated.
    func scheduleBackgroundCleanup(
        targets: [WorkspaceSwitchSessionCleanupTarget],
        reason: String
    ) {
        guard !targets.isEmpty else { return }
        let cleanupID = UUID()
        // Capture coordinators strongly before the yield so process termination
        // does not depend on `self` surviving past the initial suspension.
        let codexCoordinator = codexCoordinator
        let claudeCoordinator = claudeCoordinator
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
            // MCP control teardown requires the delegate; skip if provider is
            // gone. Process termination below does not depend on `self`.
            if let delegate = self?.delegate {
                for target in targets {
                    if Task.isCancelled { break }
                    await delegate.teardownMCPControlForDiscardedSession(
                        target.session,
                        cleanupSessionStore: true,
                        publishChanges: false,
                        deactivateLiveControlContext: false
                    )
                    let explicitRunIDs: [UUID?] = target.runIDs.isEmpty ? [nil] : target.runIDs
                    for explicitRunID in explicitRunIDs {
                        await delegate.cleanupMCPRunRoutingForDiscardedSession(
                            boundSessionID: target.boundSessionID,
                            liveSession: target.session,
                            explicitRunID: explicitRunID,
                            reason: reason
                        )
                    }
                    await Task.yield()
                }
            }
            // Process termination must run even if the provider is deallocated.
            // Coordinators were captured before the yield.
            for target in targets {
                if Task.isCancelled { break }
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

    /// Handle-only disposal: every provider/controller reference was captured by
    /// the synchronous finalize phase. The discarded `AgentTabSession`'s provider,
    /// controller, run, and presentation state must not be read or mutated here
    /// — a same-tab successor may already be live by the time this runs.
    private static func disposeDetachedTarget(
        _ target: WorkspaceSwitchSessionCleanupTarget,
        codexCoordinator: CodexAgentModeCoordinator,
        claudeCoordinator: ClaudeAgentModeCoordinator
    ) async {
        if let provider = target.provider {
            await provider.dispose()
        }
        if let acpController = target.acpController {
            await acpController.cancelPrompt()
            await acpController.shutdown()
        }
        if let detachedCodex = target.detachedCodex {
            await codexCoordinator.retireDetachedControllerForWorkspaceSwitch(detachedCodex)
        }
        if let detachedClaude = target.detachedClaude {
            await claudeCoordinator.retireDetachedControllerForWorkspaceSwitch(
                detachedClaude,
                discardedSession: target.session
            )
        }
    }

    // MARK: - Debug test support

    #if DEBUG
        private func test_completeBackgroundCleanup(_ cleanupID: UUID) {
            test_backgroundCleanupDrainTasks.removeValue(forKey: cleanupID)
        }

        func test_drainBackgroundCleanup(timeoutNanoseconds: UInt64) async throws {
            let cleanupIDs = Array(test_backgroundCleanupDrainTasks.keys)
            for cleanupID in cleanupIDs {
                let started = DispatchTime.now().uptimeNanoseconds
                let pollIntervalNanoseconds: UInt64 = 10_000_000 // 10ms
                while test_backgroundCleanupDrainTasks[cleanupID] != nil {
                    try Task.checkCancellation()
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                    guard elapsed < timeoutNanoseconds else {
                        throw AgentModeWorkspaceSwitchCleanupDrainTimeoutError(timeoutNanoseconds: timeoutNanoseconds)
                    }
                    // Sleeping yields the main actor to cleanup. Do not race a second timer
                    // after expiry: subtracting an expired deadline wraps UInt64, and a
                    // cancelled timer must not become the drain's reported failure.
                    try await Task.sleep(nanoseconds: min(pollIntervalNanoseconds, timeoutNanoseconds - elapsed))
                }
                test_backgroundCleanupDrainTasks.removeValue(forKey: cleanupID)
            }
        }
    #endif

    /// Stops tracking background cleanup tasks without cancelling them.
    ///
    /// Cancellation was previously used here, but the cleanup body calls
    /// `ProcessTermination.terminateAndReap` which uses `try? Task.sleep` in
    /// its polling loop — cancelling the parent task makes those sleeps return
    /// immediately, turning a bounded wait into a busy poll on the main actor.
    /// Instead of cancelling, we simply stop tracking the tasks and let them
    /// drain naturally. The tasks hold their own references to sessions and
    /// coordinators (captured before the initial yield), so process
    /// termination completes even if the provider is deallocated.
    func cancelAllBackgroundCleanup() {
        backgroundCleanupTasks.removeAll()
        #if DEBUG
            test_backgroundCleanupDrainTasks.removeAll()
        #endif
    }
}

extension AgentTabSession {
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
        acpSteeringFlushID = nil
        settlePendingManagedACPSteeringAsNotAccepted()
        pendingACPSteeringInstructions.removeAll()
        guard let controller = acpController else { return }
        acpController = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: self)
        await controller.cancelPrompt()
        await controller.shutdown()
    }
}

#if DEBUG
    struct AgentModeWorkspaceSwitchCleanupDrainTimeoutError: LocalizedError {
        let timeoutNanoseconds: UInt64

        var errorDescription: String? {
            let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
            return "Timed out waiting for workspace-switch background cleanup after \(timeoutSeconds)s."
        }
    }
#endif
