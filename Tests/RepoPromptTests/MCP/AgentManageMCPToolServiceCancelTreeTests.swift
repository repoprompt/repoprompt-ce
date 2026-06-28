import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentManageMCPToolServiceCancelTreeTests: XCTestCase {
    private var windows: [WindowState] = []

    override func tearDown() async throws {
        for window in windows {
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        windows.removeAll()
        try await super.tearDown()
    }

    func testCancelTreeCancelsActiveDescendantsBeforeTarget() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let viewModel = window.agentModeViewModel
        let root = try await makeRunningSession(window: window, name: "root", turnID: "root-turn", recorder: recorder)
        let child = try await makeRunningSession(window: window, name: "child", parentSessionID: root.sessionID, turnID: "child-turn", recorder: recorder)
        let grandchild = try await makeRunningSession(window: window, name: "grandchild", parentSessionID: child.sessionID, turnID: "grandchild-turn", recorder: recorder)
        let rootContext = try XCTUnwrap(root.session.mcpControlContext)

        let result = try await makeService(window: window).execute(args: [
            "op": .string("cancel_tree"),
            "session_id": .string(root.sessionID.uuidString)
        ])
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["cancelled_count"]?.intValue, 3)
        XCTAssertEqual(object["skipped_count"]?.intValue, 0)
        XCTAssertEqual(
            object["ordered_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [grandchild.sessionID.uuidString, child.sessionID.uuidString, root.sessionID.uuidString]
        )
        XCTAssertEqual(recorder.interruptedTurnIDs(), ["grandchild-turn", "child-turn", "root-turn"])
        XCTAssertEqual(root.session.runState, .cancelled)
        XCTAssertEqual(child.session.runState, .cancelled)
        XCTAssertEqual(grandchild.session.runState, .cancelled)
        XCTAssertNotNil(try viewModel.authoritativeLiveSession(for: root.sessionID))
        XCTAssertNotNil(try viewModel.authoritativeLiveSession(for: child.sessionID))
        XCTAssertNotNil(try viewModel.authoritativeLiveSession(for: grandchild.sessionID))
        XCTAssertEqual(root.session.mcpControlContext?.activationID, rootContext.activationID)
    }

    func testCancelTreeSkipsTerminalDescendantWithReason() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let viewModel = window.agentModeViewModel
        let root = try await makeRunningSession(window: window, name: "root", turnID: "root-turn", recorder: recorder)
        let terminalChild = try await makeRunningSession(window: window, name: "terminal-child", parentSessionID: root.sessionID, turnID: "terminal-turn", recorder: recorder)
        terminalChild.session.runState = .completed
        terminalChild.session.codexAuthoritativeActiveTurn = nil

        let result = try await makeService(window: window).execute(args: [
            "op": .string("cancel_tree"),
            "session_id": .string(root.sessionID.uuidString)
        ])
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["status"]?.stringValue, "partial")
        XCTAssertEqual(object["cancelled_count"]?.intValue, 1)
        XCTAssertEqual(object["skipped_count"]?.intValue, 1)
        XCTAssertEqual(recorder.interruptedTurnIDs(), ["root-turn"])
        XCTAssertEqual(root.session.runState, .cancelled)
        XCTAssertEqual(terminalChild.session.runState, .completed)

        let skipped = try XCTUnwrap(object["skipped_sessions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(skipped["session_id"]?.stringValue, terminalChild.sessionID.uuidString)
        XCTAssertEqual(skipped["reason"]?.stringValue, "terminal")
    }

    func testCancelTreePreservesSessionsAndControlContexts() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let viewModel = window.agentModeViewModel
        let root = try await makeRunningSession(window: window, name: "root", turnID: "root-turn", recorder: recorder)
        let child = try await makeRunningSession(window: window, name: "child", parentSessionID: root.sessionID, turnID: "child-turn", recorder: recorder)
        let rootActivationID = try XCTUnwrap(root.session.mcpControlContext?.activationID)
        let childActivationID = try XCTUnwrap(child.session.mcpControlContext?.activationID)

        _ = try await makeService(window: window).execute(args: [
            "op": .string("cancel_tree"),
            "session_id": .string(root.sessionID.uuidString)
        ])

        XCTAssertNotNil(try viewModel.authoritativeLiveSession(for: root.sessionID))
        XCTAssertNotNil(try viewModel.authoritativeLiveSession(for: child.sessionID))
        XCTAssertEqual(root.session.mcpControlContext?.activationID, rootActivationID)
        XCTAssertEqual(child.session.mcpControlContext?.activationID, childActivationID)
    }

    func testCancelTreeDoesNotCancelForeignLiveSessionPointingAtTargetRoot() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let root = try await makeRunningSession(window: window, name: "root", turnID: "root-turn", recorder: recorder)
        let foreign = try await makeRunningSession(
            window: window,
            name: "foreign-child",
            parentSessionID: root.sessionID,
            turnID: "foreign-turn",
            recorder: recorder,
            installComposeTab: false
        )

        let result = try await makeService(window: window).execute(args: [
            "op": .string("cancel_tree"),
            "session_id": .string(root.sessionID.uuidString)
        ])
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["cancelled_count"]?.intValue, 1)
        XCTAssertEqual(object["skipped_count"]?.intValue, 0)
        XCTAssertEqual(object["ordered_session_ids"]?.arrayValue?.compactMap(\.stringValue), [root.sessionID.uuidString])
        XCTAssertEqual(
            object["cancelled_sessions"]?.arrayValue?.compactMap { $0.objectValue?["session_id"]?.stringValue },
            [root.sessionID.uuidString]
        )
        XCTAssertEqual(recorder.interruptedTurnIDs(), ["root-turn"])
        XCTAssertEqual(root.session.runState, .cancelled)
        XCTAssertEqual(foreign.session.runState, .running)
    }

    func testCancelTreeDoesNotCancelStaleLiveSessionWithMismatchedWorkspaceBinding() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let root = try await makeRunningSession(window: window, name: "root", turnID: "root-turn", recorder: recorder)
        let staleChild = try await makeRunningSession(
            window: window,
            name: "stale-child",
            parentSessionID: root.sessionID,
            turnID: "stale-turn",
            recorder: recorder
        )
        rebindComposeTabForSession(window: window, tabID: staleChild.session.tabID, sessionID: UUID())

        let result = try await makeService(window: window).execute(args: [
            "op": .string("cancel_tree"),
            "session_id": .string(root.sessionID.uuidString)
        ])
        let object = try XCTUnwrap(result.objectValue)

        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["cancelled_count"]?.intValue, 1)
        XCTAssertEqual(object["skipped_count"]?.intValue, 0)
        XCTAssertEqual(object["ordered_session_ids"]?.arrayValue?.compactMap(\.stringValue), [root.sessionID.uuidString])
        XCTAssertEqual(recorder.interruptedTurnIDs(), ["root-turn"])
        XCTAssertEqual(root.session.runState, .cancelled)
        XCTAssertEqual(staleChild.session.runState, .running)
    }

    func testCancelTreeRejectsNotLiveTarget() async throws {
        let recorder = CancelTreeRecorder()
        let window = try await makeWindow(recorder: recorder)
        let sessionID = UUID()
        installIndexedSession(window: window, sessionID: sessionID)

        do {
            _ = try await makeService(window: window).execute(args: [
                "op": .string("cancel_tree"),
                "session_id": .string(sessionID.uuidString)
            ])
            XCTFail("Expected not-live cancel_tree target to fail")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("is not currently live and cannot be cancelled as a tree"))
        }
    }

    private func makeWindow(recorder: CancelTreeRecorder) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        windows.append(window)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Cancel Tree \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageCancelTreeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        window.agentModeViewModel.test_initializeRunService()
        return window
    }

    private func makeService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "cancel-tree-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }

    private func makeRunningSession(
        window: WindowState,
        name: String,
        parentSessionID: UUID? = nil,
        turnID: String,
        recorder: CancelTreeRecorder,
        installComposeTab: Bool = true
    ) async throws -> (sessionID: UUID, session: AgentModeViewModel.TabSession) {
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .codexExec
        session.selectedModelRaw = AgentModel.defaultModel.rawValue
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parentSessionID
        session.runID = UUID()
        session.runState = .running
        let controller = CancelTreeCodexController(recorder: recorder)
        session.codexController = controller
        session.codexConversationID = "cancel-tree-\(name)"
        session.beginRunAttempt(source: "cancel_tree.\(name)")
        session.codexAuthoritativeActiveTurn = AgentModeViewModel.TabSession.CodexAuthoritativeTurnIdentity(
            threadID: session.codexConversationID!,
            turnID: turnID,
            turnKind: .user,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: session.runID!,
            runAttemptID: session.activeRunAttemptID!
        )
        viewModel.test_installLiveSession(session)
        if installComposeTab {
            installComposeTabForSession(window: window, tabID: session.tabID, sessionID: sessionID, name: name)
        }
        viewModel.applySpawnParentSessionID(parentSessionID, to: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: UUID(),
            taskLabelKind: .pair,
            startPending: false
        )
        return (sessionID, session)
    }

    private func installComposeTabForSession(
        window: WindowState,
        tabID: UUID,
        sessionID: UUID,
        name: String
    ) {
        guard let workspaceID = window.workspaceManager.activeWorkspace?.id,
              let index = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        let tab = ComposeTabState(id: tabID, name: name, activeAgentSessionID: sessionID)
        window.workspaceManager.workspaces[index].composeTabs.append(tab)
    }

    private func rebindComposeTabForSession(window: WindowState, tabID: UUID, sessionID: UUID) {
        guard let workspaceID = window.workspaceManager.activeWorkspace?.id,
              let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = window.workspaceManager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        window.workspaceManager.workspaces[workspaceIndex].composeTabs[tabIndex].activeAgentSessionID = sessionID
    }

    private func installIndexedSession(window: WindowState, sessionID: UUID) {
        let workspace = window.workspaceManager.activeWorkspace!
        let tabID = UUID()
        let entry = AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "persisted only",
            lastUserMessageAt: nil,
            savedAt: Date(),
            lastRunStateRaw: AgentSessionRunState.completed.rawValue,
            itemCount: 0,
            agentKindRaw: AgentProviderKind.codexExec.rawValue,
            agentModelRaw: AgentModel.defaultModel.rawValue,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: true,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        window.agentModeViewModel.test_installSessionIndexSnapshot(
            [sessionID: entry],
            owner: AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1),
            latestOwner: AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1),
            activeWorkspace: workspace
        )
    }
}

private final class CancelTreeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [String] = []

    func recordInterrupt(_ turnID: String) {
        lock.lock()
        turns.append(turnID)
        lock.unlock()
    }

    func interruptedTurnIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return turns
    }
}

private final class CancelTreeCodexController: CodexSessionControlling {
    private let recorder: CancelTreeRecorder
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init(recorder: CancelTreeRecorder) {
        self.recorder = recorder
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        true
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "cancel-tree", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "cancel-tree", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "cancel-tree", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "cancel-tree",
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
    func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "cancel-tree-submission")
    }

    func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        recorder.recordInterrupt(expectedTurnID)
        return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

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
