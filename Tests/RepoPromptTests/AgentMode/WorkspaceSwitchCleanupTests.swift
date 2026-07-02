import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeWorkspaceSwitchCleanupTests: XCTestCase {
    private let fullSuiteAsyncTimeoutNanoseconds: UInt64 = 30_000_000_000

    func testNilWorkspaceSwitchClearsStateWhenLastKnownSnapshotExists() async throws {
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Loaded workspace",
            repoPaths: [],
            composeTabs: [
                ComposeTabState(
                    id: tabID,
                    name: "Active tab",
                    activeAgentSessionID: sessionID
                )
            ],
            activeComposeTabID: tabID
        )
        let fixture = makeWorkspaceFixture(workspaces: [workspace])
        fixture.manager.activeWorkspace = workspace

        let viewModel = makeViewModel()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        viewModel.test_setSidebarAutoArchiveDependencies(
            promptManager: fixture.prompt,
            workspaceManager: fixture.manager
        )
        let owner = viewModel.test_receiveWorkspaceSwitchNotification(workspace)
        await viewModel.test_handleWorkspaceSwitch(workspace, owner: owner)

        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.hasLoadedPersistedState = true
        session.replaceItems([.user("active", sequenceIndex: 0)])
        viewModel.refreshDerivedTranscriptState(for: session)
        viewModel.applySessionToBindings(session)
        viewModel.test_setActiveSessionBindingsAreHydrated(true)
        XCTAssertEqual(viewModel.test_bindingResolution(sessionID: sessionID), .unique(tabID: tabID))
        XCTAssertEqual(viewModel.activeTranscriptPresentation.hydratedPersistentBinding?.sessionID, sessionID)

        viewModel.test_setCurrentTabIDOverride(nil)
        fixture.manager.activeWorkspace = nil
        await viewModel.handleWorkspaceSwitch(nil)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.activeTranscriptPresentation.hydratedPersistentBinding)
        try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup(timeoutNanoseconds: fullSuiteAsyncTimeoutNanoseconds)
    }

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

    private func makeWorkspaceFixture(
        workspaces: [WorkspaceModel]
    ) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.workspaces = workspaces
        return (manager, prompt)
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
