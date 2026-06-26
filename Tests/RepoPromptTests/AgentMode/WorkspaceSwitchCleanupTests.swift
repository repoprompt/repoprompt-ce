import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeWorkspaceSwitchCleanupTests: XCTestCase {
    private let fullSuiteAsyncTimeoutNanoseconds: UInt64 = 30_000_000_000

    func testWorkspaceSwitchClearsForegroundBeforeSlowProviderDisposeCompletes() async throws {
        let provider = BlockingHeadlessProvider()
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .openCode
        session.provider = provider
        session.runID = UUID()
        session.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        try await provider.waitUntilDisposeIsSuspended(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let startedBeforeRelease = await provider.isDisposeStarted()
        let finishedBeforeRelease = await provider.isDisposeFinished()
        XCTAssertTrue(startedBeforeRelease)
        XCTAssertFalse(finishedBeforeRelease)

        await provider.releaseDispose()
        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let finishedAfterDrain = await provider.isDisposeFinished()
        XCTAssertTrue(finishedAfterDrain)
    }

    func testWorkspaceSwitchReleasesSessionWorktreeOwnershipBeforeDiscardingSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeWorkspaceSwitchOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "seed".write(to: root.appendingPathComponent("Seed.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceFileContextStore()
        let sessionID = UUID()
        let preparation = try await store.prepareSessionWorktreeOwnership(
            ownerID: sessionID,
            bindingFingerprint: "workspace-switch-release",
            physicalRootPaths: [root.path]
        )
        let ownedRoots = try await store.commitSessionWorktreeOwnership(preparation)
        XCTAssertEqual(ownedRoots.count, 1)

        let viewModel = makeViewModel(workspaceFileContextStore: store)
        let session = viewModel.session(for: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)

        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        let loadedRoots = await store.roots()
        XCTAssertTrue(loadedRoots.isEmpty)
        let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
        XCTAssertEqual(ownership.installedOwnerCount, 0)
        XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        XCTAssertEqual(ownership.rootClaimCount, 0)
        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
    }

    func testWorkspaceSwitchBackgroundCleanupUsesCapturedRunIDAfterForegroundSessionsAreCleared() async throws {
        let routing = RoutingRecorder()
        let cancelled = RoutingRecorder()
        let oldRunID = UUID()
        let viewModel = makeViewModel(
            mcpRunRoutingCleaner: { runID, _, reason in
                await routing.record(runID: runID, reason: reason)
            },
            mcpRunToolCanceller: { runID, reason in
                cancelled.recordSync(runID: runID, reason: reason ?? "nil")
                return 1
            }
        )
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .openCode
        session.runID = oldRunID
        session.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let routingCleaned = await routing.contains(runID: oldRunID, reason: "workspace_switch")
        XCTAssertTrue(routingCleaned)
        XCTAssertTrue(cancelled.containsSync(runID: oldRunID, reason: "workspace_switch"))
    }

    func testDetachedMCPTeardownDoesNotDeactivateNewLiveControlContextWithSameSessionID() async throws {
        let routing = RoutingRecorder()
        let mcpSessionID = UUID()
        let oldRunID = UUID()
        let tabID = UUID()
        let viewModel = makeViewModel(
            mcpRunRoutingCleaner: { runID, _, reason in
                await routing.record(runID: runID, reason: reason)
            }
        )
        let oldSession = viewModel.session(for: tabID)
        oldSession.selectedAgent = .openCode
        oldSession.runID = oldRunID
        oldSession.mcpControlContext = makeMCPControlContext(sessionID: mcpSessionID)

        await viewModel.handleWorkspaceSwitch(nil)
        let newSession = viewModel.session(for: tabID)
        newSession.selectedAgent = .openCode
        newSession.mcpControlContext = makeMCPControlContext(sessionID: mcpSessionID)
        viewModel.test_setMCPControlledTabIDs([tabID])

        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let routingCleaned = await routing.contains(runID: oldRunID, reason: "workspace_switch")
        XCTAssertTrue(routingCleaned)
        XCTAssertEqual(newSession.mcpControlContext?.sessionID, mcpSessionID)
    }

    func testDetachedWorkspaceSwitchCleanupDoesNotClearNewSessionOnSameTab() async throws {
        let provider = BlockingHeadlessProvider()
        let tabID = UUID()
        let oldRunID = UUID()
        let newRunID = UUID()
        let viewModel = makeViewModel()
        let oldSession = viewModel.session(for: tabID)
        oldSession.selectedAgent = .openCode
        oldSession.provider = provider
        oldSession.providerSessionID = "old-provider-session"
        oldSession.runID = oldRunID
        oldSession.runState = .running

        await viewModel.handleWorkspaceSwitch(nil)
        let newSession = viewModel.session(for: tabID)
        newSession.selectedAgent = .openCode
        newSession.providerSessionID = "new-provider-session"
        newSession.runID = newRunID
        newSession.runState = .running

        try await provider.waitUntilDisposeIsSuspended(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let startedBeforeRelease = await provider.isDisposeStarted()
        let finishedBeforeRelease = await provider.isDisposeFinished()
        XCTAssertTrue(startedBeforeRelease)
        XCTAssertFalse(finishedBeforeRelease)

        await provider.releaseDispose()
        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
        let finishedAfterDrain = await provider.isDisposeFinished()
        XCTAssertTrue(finishedAfterDrain)

        XCTAssertTrue(viewModel.sessions[tabID] === newSession)
        XCTAssertEqual(newSession.providerSessionID, "new-provider-session")
        XCTAssertEqual(newSession.runID, newRunID)
        XCTAssertEqual(newSession.runState, .running)
    }

    private func makeMCPControlContext(sessionID: UUID) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(sessionID: sessionID, generation: 0),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: false,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: nil
        )
    }

    private func makeViewModel(
        workspaceFileContextStore: WorkspaceFileContextStore? = nil,
        mcpRunRoutingCleaner: @escaping AgentModeViewModel.MCPRunRoutingCleaner = { _, _, _ in },
        mcpRunToolCanceller: AgentModeViewModel.MCPRunToolCanceller? = nil
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in FakeCodexSessionController() },
            mcpRunRoutingCleaner: mcpRunRoutingCleaner,
            mcpRunToolCanceller: mcpRunToolCanceller,
            testWorkspaceFileContextStore: workspaceFileContextStore
        )
    }

    // MARK: - Consolidated cleanup: nil-session tabs and stale bookkeeping

    private func makeWorkspace(
        name: String,
        tabs: [ComposeTabState],
        activeTabID: UUID?
    ) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: activeTabID
        )
    }

    private func makeIndexEntry(
        id: UUID,
        tabID: UUID,
        lastUserMessageAt: Date? = nil
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id,
            tabID: tabID,
            name: "Agent",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: Date(),
            lastRunStateRaw: nil,
            itemCount: lastUserMessageAt == nil ? 0 : 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func seedSidebarBoundNilSessionTab(
        _ viewModel: AgentModeViewModel,
        tabID: UUID,
        sessionID: UUID
    ) {
        let workspace = makeWorkspace(
            name: "Nil-session sidebar binding",
            tabs: [ComposeTabState(id: tabID, name: "Nil-session")],
            activeTabID: tabID
        )
        let owner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        let entry = makeIndexEntry(
            id: sessionID,
            tabID: tabID,
            lastUserMessageAt: Date(timeIntervalSince1970: 1)
        )
        viewModel.test_installSessionIndexSnapshot(
            [entry.id: entry],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
    }

    /// A tab with a sidebar-bound session but no live `TabSession` must still
    /// release worktree ownership for the bound session ID when closed/stashed.
    /// This covers the unconditional `releaseSessionWorktreeOwnership` path in
    /// `handleComposeTabsWillClose` for never-instantiated tabs.
    func testComposeTabRemovalReleasesWorktreeOwnershipForSidebarBoundNilSessionTab() async {
        let reasons: [PromptViewModel.ComposeTabRemovalReason] = [.close, .stash, .deleteStashed]
        for reason in reasons {
            let viewModel = makeViewModel()
            let tabID = UUID()
            let sessionID = UUID()
            seedSidebarBoundNilSessionTab(viewModel, tabID: tabID, sessionID: sessionID)

            // No live session exists for this tab; the session is sidebar-bound only.
            XCTAssertNil(viewModel.sessions[tabID])
            XCTAssertEqual(viewModel.boundSessionID(for: tabID), sessionID)

            let recordedBefore = viewModel.test_releaseSessionWorktreeOwnershipCalls
            await viewModel.handleComposeTabsWillClose([tabID], reason: reason)

            let recordedAfter = viewModel.test_releaseSessionWorktreeOwnershipCalls
            XCTAssertEqual(recordedAfter.count, recordedBefore.count + 1)
            XCTAssertEqual(recordedAfter.last, sessionID)
            // The live session map must remain empty for this tab.
            XCTAssertNil(viewModel.sessions[tabID])
        }
    }

    /// `finalizeDeletedAgentSessionReferences` unconditionally clears stale
    /// tab-scoped bookkeeping (`sessionListSortDates`, `tabsWithActiveAgentRun`,
    /// `mcpControlledTabIDs`) for every candidate tabID, even when no live
    /// session matches. Stale entries for candidate tabIDs must disappear while
    /// unrelated active entries remain untouched.
    func testFinalizeDeletedReferencesClearsStaleTabBookkeepingWhilePreservingUnrelatedEntries() async {
        let viewModel = makeViewModel()
        let staleTabID = UUID()
        let unrelatedTabID = UUID()
        let deletedSessionID = UUID()

        // Empty session index so removeSessionIndex(deletedSessionID) is a no-op
        // and does not rebuild sort dates, isolating the loop's clearing logic.
        let workspace = makeWorkspace(name: "Stale bookkeeping", tabs: [], activeTabID: nil)
        let owner = AgentModeViewModel.SessionIndexOwner(
            workspaceID: workspace.id,
            activationEpoch: 1
        )
        viewModel.test_installSessionIndexSnapshot(
            [:],
            owner: owner,
            latestOwner: owner,
            activeWorkspace: workspace
        )
        // Keep the active tab off the affected set so onTabChanged is not invoked.
        viewModel.test_setCurrentTabIDOverride(unrelatedTabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let staleDate = Date(timeIntervalSince1970: 10)
        let unrelatedDate = Date(timeIntervalSince1970: 20)
        viewModel.test_setSessionListSortDates([
            staleTabID: staleDate,
            unrelatedTabID: unrelatedDate
        ])
        viewModel.test_setTabsWithActiveAgentRun([staleTabID, unrelatedTabID])
        viewModel.test_setMCPControlledTabIDs([staleTabID, unrelatedTabID])

        _ = await viewModel.finalizeDeletedAgentSessionReferences(
            sessionID: deletedSessionID,
            workspaceID: nil,
            knownTabIDs: [staleTabID],
            reason: "test_stale_bookkeeping"
        )

        // Stale candidate entries are cleared.
        XCTAssertNil(viewModel.sessionListSortDates[staleTabID])
        XCTAssertFalse(viewModel.tabsWithActiveAgentRun.contains(staleTabID))
        XCTAssertFalse(viewModel.mcpControlledTabIDs.contains(staleTabID))
        // Unrelated active entries remain.
        XCTAssertEqual(viewModel.sessionListSortDates[unrelatedTabID], unrelatedDate)
        XCTAssertTrue(viewModel.tabsWithActiveAgentRun.contains(unrelatedTabID))
        XCTAssertTrue(viewModel.mcpControlledTabIDs.contains(unrelatedTabID))
        // Ownership for the deleted session ID is released.
        XCTAssertEqual(viewModel.test_releaseSessionWorktreeOwnershipCalls, [deletedSessionID])
    }
}

private actor BlockingHeadlessProvider: HeadlessAgentProvider {
    private var disposeContinuation: CheckedContinuation<Void, Never>?
    private var disposeSuspendedWaiter: CheckedContinuation<Void, Error>?
    private var disposeSuspendedWaiterTimeoutTask: Task<Void, Never>?
    private var disposeReleaseRequested = false
    private(set) var disposeStarted = false
    private(set) var disposeFinished = false

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {
        disposeStarted = true
        if !disposeReleaseRequested {
            await withCheckedContinuation { continuation in
                disposeContinuation = continuation
                resumeDisposeSuspendedWaiter()
            }
        }
        disposeFinished = true
    }

    func waitUntilDisposeIsSuspended(
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        guard disposeContinuation == nil else { return }
        try await withCheckedThrowingContinuation { continuation in
            precondition(disposeSuspendedWaiter == nil)
            disposeSuspendedWaiter = continuation
            disposeSuspendedWaiterTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                await self?.timeoutDisposeSuspendedWaiter(timeoutNanoseconds: timeoutNanoseconds)
            }
        }
    }

    func releaseDispose() {
        guard !disposeFinished else { return }
        disposeReleaseRequested = true
        disposeContinuation?.resume()
        disposeContinuation = nil
    }

    private func resumeDisposeSuspendedWaiter() {
        disposeSuspendedWaiterTimeoutTask?.cancel()
        disposeSuspendedWaiterTimeoutTask = nil
        disposeSuspendedWaiter?.resume()
        disposeSuspendedWaiter = nil
    }

    private func timeoutDisposeSuspendedWaiter(timeoutNanoseconds: UInt64) {
        guard let disposeSuspendedWaiter else { return }
        self.disposeSuspendedWaiter = nil
        disposeSuspendedWaiterTimeoutTask = nil
        disposeSuspendedWaiter.resume(
            throwing: BlockingHeadlessProviderTimeoutError(timeoutNanoseconds: timeoutNanoseconds)
        )
    }

    func isDisposeStarted() -> Bool {
        disposeStarted
    }

    func isDisposeFinished() -> Bool {
        disposeFinished
    }
}

private struct BlockingHeadlessProviderTimeoutError: LocalizedError {
    let timeoutNanoseconds: UInt64

    var errorDescription: String? {
        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        return "Timed out waiting for dispose() to reach its suspension point after \(timeoutSeconds)s."
    }
}

private final class RoutingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(UUID, String)] = []

    func record(runID: UUID, reason: String) async {
        recordSync(runID: runID, reason: reason)
    }

    func contains(runID: UUID, reason: String) async -> Bool {
        containsSync(runID: runID, reason: reason)
    }

    func recordSync(runID: UUID, reason: String) {
        lock.lock()
        records.append((runID, reason))
        lock.unlock()
    }

    func containsSync(runID: UUID, reason: String) -> Bool {
        lock.lock()
        let result = records.contains { $0.0 == runID && $0.1 == reason }
        lock.unlock()
        return result
    }
}

private final class FakeCodexSessionController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
