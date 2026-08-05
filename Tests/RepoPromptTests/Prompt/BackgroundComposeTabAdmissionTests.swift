@testable import RepoPromptApp
import XCTest

@MainActor
final class BackgroundComposeTabAdmissionTests: XCTestCase {
    func testBackgroundCreationCrossesLegacyLimitWithoutMutatingExistingTabs() async throws {
        let fixture = makeFixture(initialTabCount: 499)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabIDs = originalWorkspace.composeTabs.map(\.id)
        let originalSessionIDsByTabID = Dictionary(
            uniqueKeysWithValues: originalWorkspace.composeTabs.map { ($0.id, $0.activeAgentSessionID) }
        )
        let originalActiveTabID = try XCTUnwrap(originalWorkspace.activeComposeTabID)
        let originalStashedTabs = originalWorkspace.stashedTabs

        for expectedCount in 500 ... 502 {
            let created = await fixture.prompt.createBackgroundComposeTab(
                strategy: .blank,
                name: "Background \(expectedCount)"
            )

            XCTAssertNotNil(created, "Background creation should reach \(expectedCount) tabs")
            XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.count, expectedCount)
        }

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let existingTabs = Array(finalWorkspace.composeTabs.prefix(originalTabIDs.count))
        XCTAssertEqual(existingTabs.map(\.id), originalTabIDs)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.activeAgentSessionID) }),
            originalSessionIDsByTabID
        )
        XCTAssertEqual(finalWorkspace.activeComposeTabID, originalActiveTabID)
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
    }

    func testForegroundAgentCreationCrosses499Through502WithoutUnrelatedMutation() async throws {
        let fixture = makeFixture(initialTabCount: 499)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabs = originalWorkspace.composeTabs
        let originalTabIDs = originalTabs.map(\.id)
        let originalPins = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.isPinned) })
        let originalBindings = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.activeAgentSessionID) })
        let originalStashedTabs = originalWorkspace.stashedTabs
        let originalDirtyTabIDs = Set(originalTabIDs.prefix(7))
        fixture.prompt.testSetDirtyTabIDs(originalDirtyTabIDs)

        let sideEffects = ComposeRemovalSideEffectRecorder()
        fixture.prompt.composeTabCascadeResolver = { tabIDs, _ in
            await sideEffects.recordCascade(tabIDs)
            return .init()
        }
        let closeToken = fixture.prompt.addComposeTabsWillCloseListener { tabIDs, _ in
            await sideEffects.recordClose(tabIDs)
        }
        defer { fixture.prompt.removeComposeTabsWillCloseListener(closeToken) }

        var createdIDs: [UUID] = []
        for expectedCount in 500 ... 502 {
            let creationResult = await viewModel.createAndActivateSessionTab()
            let createdID = try XCTUnwrap(creationResult)
            createdIDs.append(createdID)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, createdID)
            XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, createdID)
            XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.count, expectedCount)
            XCTAssertEqual(fixture.manager.composeTab(with: createdID)?.activeAgentSessionID, viewModel.sessions[createdID]?.activeAgentSessionID)
        }

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let existingTabs = Array(finalWorkspace.composeTabs.prefix(originalTabs.count))
        XCTAssertEqual(existingTabs.map(\.id), originalTabIDs)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.isPinned) }), originalPins)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.activeAgentSessionID) }), originalBindings)
        XCTAssertEqual(fixture.prompt.dirtyTabIDs.intersection(originalTabIDs), originalDirtyTabIDs)
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
        XCTAssertEqual(Array(finalWorkspace.composeTabs.suffix(createdIDs.count)).map(\.id), createdIDs)
        let recordedSideEffects = await sideEffects.snapshot()
        XCTAssertEqual(recordedSideEffects, .init())
    }

    func testFailedForegroundCreationDoesNotReturnOrMarkOldActiveTab() async throws {
        let fixture = makeFixture(initialTabCount: 1)
        let oldActiveTabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        XCTAssertNil(viewModel.sessions[oldActiveTabID])

        fixture.manager.activeWorkspace = nil
        let createdID = await viewModel.createAndActivateSessionTab()

        XCTAssertNil(createdID)
        XCTAssertEqual(fixture.prompt.activeComposeTabID, oldActiveTabID)
        XCTAssertNil(viewModel.sessions[oldActiveTabID])
    }

    func testUnstashAboveFiftyRestoresRequestedTabWithoutUnrelatedMutation() async throws {
        let fixture = makeFixture(initialTabCount: 51)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabs = originalWorkspace.composeTabs
        let originalIDs = originalTabs.map(\.id)
        let originalPins = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.isPinned) })
        let originalBindings = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.activeAgentSessionID) })
        let stashed = try XCTUnwrap(originalWorkspace.stashedTabs.first)
        let dirtyIDs = Set(originalIDs.prefix(5))
        fixture.prompt.testSetDirtyTabIDs(dirtyIDs)

        await fixture.prompt.unstashTab(stashed.id)

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        XCTAssertEqual(finalWorkspace.composeTabs.count, 52)
        XCTAssertEqual(Array(finalWorkspace.composeTabs.prefix(originalIDs.count)).map(\.id), originalIDs)
        XCTAssertEqual(finalWorkspace.composeTabs.last?.id, stashed.tab.id)
        XCTAssertEqual(finalWorkspace.activeComposeTabID, stashed.tab.id)
        XCTAssertTrue(finalWorkspace.stashedTabs.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: finalWorkspace.composeTabs.prefix(originalIDs.count).map { ($0.id, $0.isPinned) }),
            originalPins
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: finalWorkspace.composeTabs.prefix(originalIDs.count).map { ($0.id, $0.activeAgentSessionID) }),
            originalBindings
        )
        XCTAssertEqual(fixture.prompt.dirtyTabIDs.intersection(originalIDs), dirtyIDs)
    }

    func testFailedRequiredFlushKeepsTabRuntimeAndProjection() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.setItemsSilently([.user("must persist", sequenceIndex: 0)], reason: .testOverride)
        session.isDirty = true
        session.runState = .running

        let saveAttempts = SaveAttemptRecorder()
        viewModel.test_setAgentSessionSaver { _, _, _ in
            await saveAttempts.record()
            throw RequiredFlushTestError.injectedFailure
        }
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { tabIDs, reason, workspaceID in
            await viewModel.preflightComposeTabsRemoval(tabIDs, reason: reason, workspaceID: workspaceID)
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let originalOpenIDs = fixture.manager.activeWorkspace?.composeTabs.map(\.id)
        let originalStashedTabs = fixture.manager.activeWorkspace?.stashedTabs
        await fixture.prompt.closeComposeTab(tabID)

        let saveAttemptCount = await saveAttempts.count()
        XCTAssertEqual(saveAttemptCount, 1)
        XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.map(\.id), originalOpenIDs)
        XCTAssertEqual(fixture.manager.activeWorkspace?.stashedTabs, originalStashedTabs)
        XCTAssertEqual(fixture.prompt.activeComposeTabID, tabID)
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.isDirty)
    }

    func testFailedDurableDeletionDoesNotResurrectRemovedComposeTab() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        viewModel.setAgentRunActive(tabID, isActive: true)

        var teardownTabIDs: [UUID] = []
        viewModel.test_setComposeTabRemovalTeardownObserver { removedTabID in
            XCTAssertFalse(fixture.manager.activeWorkspace?.composeTabs.contains(where: { $0.id == removedTabID }) == true)
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains(where: { $0.id == removedTabID }))
            teardownTabIDs.append(removedTabID)
        }
        viewModel.test_setAgentSessionsDeleter { _, _ in
            throw RequiredFlushTestError.injectedFailure
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        await fixture.prompt.closeComposeTab(tabID)

        XCTAssertFalse(fixture.manager.activeWorkspace?.composeTabs.contains(where: { $0.id == tabID }) == true)
        XCTAssertNil(viewModel.sessions[tabID])
        XCTAssertEqual(teardownTabIDs, [tabID])
    }

    func testFailedStashedDeletionDoesNotResurrectRemovedProjection() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let stashedTab = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        _ = viewModel.session(for: stashedTab.tab.id)
        viewModel.test_setAgentSessionsDeleter { _, _ in
            throw RequiredFlushTestError.injectedFailure
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        await fixture.prompt.deleteStashedTab(stashedTab.id)

        XCTAssertFalse(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashedTab.id }))
        XCTAssertFalse(fixture.manager.activeWorkspace?.stashedTabs.contains(where: { $0.id == stashedTab.id }) == true)
        XCTAssertNil(viewModel.sessions[stashedTab.tab.id])
    }

    func testMultiTabDeletionFailureContinuesRemainingCleanup() async throws {
        let fixture = makeFixture(initialTabCount: 3)
        let tabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        for tab in tabs {
            _ = viewModel.session(for: tab.id)
        }
        let orderedTabIDs = tabs.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
        let attempts = DeletionAttemptRecorder(failingTabID: orderedTabIDs[1])
        viewModel.test_setAgentSessionsDeleter { tabID, _ in
            try await attempts.delete(tabID)
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        await fixture.prompt.closeAllComposeTabs()

        let attemptedTabIDs = await attempts.attempted()
        XCTAssertEqual(attemptedTabIDs, orderedTabIDs)
        for tab in tabs {
            XCTAssertNil(viewModel.sessions[tab.id])
        }
    }

    func testStashRunsPostProjectionTeardownWithoutDurableDeletion() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        _ = viewModel.session(for: tabID)
        let attempts = DeletionAttemptRecorder(failingTabID: nil)
        viewModel.test_setAgentSessionsDeleter { deletedTabID, _ in
            try await attempts.delete(deletedTabID)
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        await fixture.prompt.stashTab(tabID)

        XCTAssertTrue(fixture.manager.activeWorkspace?.stashedTabs.contains(where: { $0.tab.id == tabID }) == true)
        XCTAssertNil(viewModel.sessions[tabID])
        let attemptedTabIDs = await attempts.attempted()
        XCTAssertTrue(attemptedTabIDs.isEmpty)
    }

    private func makeFixture(initialTabCount: Int) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
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
        let tabs = (0 ..< initialTabCount).map { index in
            ComposeTabState(
                name: "Existing \(index)",
                lastModified: Date(timeIntervalSince1970: TimeInterval(index)),
                isPinned: index.isMultiple(of: 11),
                activeAgentSessionID: UUID()
            )
        }
        let stashed = StashedTab(
            tab: ComposeTabState(name: "Already stashed", activeAgentSessionID: UUID()),
            stashedAt: Date(timeIntervalSince1970: 1)
        )
        let workspace = WorkspaceModel(
            name: "Background compose admission",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: tabs.last?.id,
            stashedTabs: [stashed]
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        return (manager, prompt)
    }

    private func makeAgentModeViewModel(
        prompt: PromptViewModel,
        manager: WorkspaceManagerViewModel
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in ComposeAdmissionFakeCodexController() }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: manager)
        return viewModel
    }

    private func installDidRemoveListener(
        prompt: PromptViewModel,
        viewModel: AgentModeViewModel
    ) -> UUID {
        prompt.addComposeTabsDidRemoveListener { tabIDs, reason, workspaceID in
            await viewModel.handleComposeTabsDidRemove(tabIDs, reason: reason, workspaceID: workspaceID)
        }
    }
}

private actor ComposeRemovalSideEffectRecorder {
    struct Snapshot: Equatable {
        var cascadeCount = 0
        var closeCount = 0
        var affectedTabIDs: Set<UUID> = []
    }

    private var value = Snapshot()

    func recordCascade(_ tabIDs: Set<UUID>) {
        value.cascadeCount += 1
        value.affectedTabIDs.formUnion(tabIDs)
    }

    func recordClose(_ tabIDs: Set<UUID>) {
        value.closeCount += 1
        value.affectedTabIDs.formUnion(tabIDs)
    }

    func snapshot() -> Snapshot {
        value
    }
}

private actor SaveAttemptRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private actor DeletionAttemptRecorder {
    private let failingTabID: UUID?
    private var tabIDs: [UUID] = []

    init(failingTabID: UUID?) {
        self.failingTabID = failingTabID
    }

    func delete(_ tabID: UUID) throws {
        tabIDs.append(tabID)
        if tabID == failingTabID {
            throw RequiredFlushTestError.injectedFailure
        }
    }

    func attempted() -> [UUID] {
        tabIDs
    }
}

private enum RequiredFlushTestError: Error {
    case injectedFailure
}

private final class ComposeAdmissionFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
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

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
