import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceSteerResumeTests: XCTestCase {
    func testSteerCompletedUserOwnedSessionWithoutControlContextReactivatesAndStartsFollowUp() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await installCompletedSession(
            sessionID: sessionID,
            in: viewModel,
            isMCPOriginated: false
        )
        addControlContextTeardown(sessionID: sessionID, viewModel: viewModel)
        let originalTabID = session.tabID
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertNil(session.mcpControlContext)

        var service = makeService(window: window, connectionID: UUID())
        service.testDispatchSteerInstruction = { dispatchedSessionID, dispatchedText, dispatchedWorkflow, dispatchedViewModel in
            XCTAssertEqual(dispatchedSessionID, sessionID)
            XCTAssertEqual(dispatchedText, "follow up")
            XCTAssertNil(dispatchedWorkflow)
            let controlled = try XCTUnwrap(dispatchedViewModel.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertTrue(controlled === session)
            XCTAssertFalse(controlled.runState.isActive)
            XCTAssertNotNil(controlled.mcpControlContext)
            XCTAssertFalse(controlled.isMCPOriginated)

            await dispatchedViewModel.prepareMCPWaitTrackingForRunStart(session: controlled)
            let ownership = controlled.beginRunAttempt(source: "test.steerResume.reactivated")
            XCTAssertEqual(ownership.turnEpoch?.transitionKind, .steering)
            controlled.runState = .running
            dispatchedViewModel.publishMCPStateChange(for: controlled)
            return .startedRun
        }

        let value = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("follow up")
        ])

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(session.tabID, originalTabID)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertTrue(viewModel.mcpControlledSession(sessionID: sessionID) === session)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        XCTAssertEqual(epoch.transitionKind, .steering)
        XCTAssertNil(context.pendingEpochTransition)
        XCTAssertNil(context.preparedEpoch)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertEqual(currentRegistration, context.registration)
    }

    func testSteerReactivationDispatchFailureCleansControlContext() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await installCompletedSession(
            sessionID: sessionID,
            in: viewModel,
            isMCPOriginated: false
        )
        addControlContextTeardown(sessionID: sessionID, viewModel: viewModel)
        let originalAutoEditEnabled = session.autoEditEnabled
        XCTAssertNil(session.mcpControlContext)

        var didDispatch = false
        var service = makeService(window: window, connectionID: UUID())
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, dispatchedViewModel in
            didDispatch = true
            let controlled = try XCTUnwrap(dispatchedViewModel.mcpControlledSession(sessionID: dispatchedSessionID))
            XCTAssertTrue(controlled === session)
            XCTAssertNotNil(controlled.mcpControlContext)
            throw MCPError.internalError("simulated steer dispatch failure")
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("follow up")
            ])
            XCTFail("Expected simulated steer dispatch failure")
        } catch let error as MCPError {
            guard case let .internalError(message) = error else {
                return XCTFail("Unexpected MCP error: \(error)")
            }
            XCTAssertEqual(message, "simulated steer dispatch failure")
        }

        XCTAssertTrue(didDispatch)
        XCTAssertNil(viewModel.mcpControlledSession(sessionID: sessionID))
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(session.mcpFollowUpRunPending)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertEqual(session.permissionProfile, .userConfigured)
        XCTAssertEqual(session.autoEditEnabled, originalAutoEditEnabled)
        let hasRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasRegistration)
    }

    func testSteerUnknownSessionIDStillFailsWithoutCreatingRegistration() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let unknownSessionID = UUID()
        var service = makeService(window: window, connectionID: UUID())
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Steer dispatch should not run for an unknown session")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(unknownSessionID.uuidString),
                "message": .string("follow up")
            ])
            XCTFail("Expected steering an unknown session to fail")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error else {
                return XCTFail("Unexpected MCP error: \(error)")
            }
            let diagnostic = message ?? ""
            XCTAssertTrue(diagnostic.contains("was not found"), diagnostic)
        }

        let hasRegistration = await AgentRunSessionStore.hasActiveRegistration(
            sessionID: unknownSessionID
        )
        XCTAssertFalse(hasRegistration)
    }

    func testSteerActiveUncontrolledSessionIsRejected() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await installCompletedSession(
            sessionID: sessionID,
            in: viewModel,
            isMCPOriginated: false
        )
        addControlContextTeardown(sessionID: sessionID, viewModel: viewModel)
        session.runState = .running
        XCTAssertNil(session.mcpControlContext)

        var service = makeService(window: window, connectionID: UUID())
        service.testDispatchSteerInstruction = { _, _, _, _ in
            XCTFail("Steer dispatch should not run for an active uncontrolled session")
            return .startedRun
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("steer"),
                "session_id": .string(sessionID.uuidString),
                "message": .string("follow up")
            ])
            XCTFail("Expected steering an active uncontrolled session to fail")
        } catch let error as MCPError {
            guard case let .invalidParams(message) = error else {
                return XCTFail("Unexpected MCP error: \(error)")
            }
            let diagnostic = message ?? ""
            XCTAssertTrue(diagnostic.contains("active but is not MCP-controlled"), diagnostic)
        }

        XCTAssertNil(session.mcpControlContext)
        let hasRegistration = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(hasRegistration)
    }

    private func addControlContextTeardown(
        sessionID: UUID,
        viewModel: AgentModeViewModel
    ) {
        addTeardownBlock { @MainActor in
            await viewModel.mcpDeactivateControlContext(
                sessionID: sessionID,
                cleanupSessionStore: true
            )
        }
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Steer Resume \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSteerResumeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func installCompletedSession(
        sessionID: UUID,
        in viewModel: AgentModeViewModel,
        isMCPOriginated: Bool
    ) async -> AgentModeViewModel.TabSession {
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .completed
        session.isMCPOriginated = isMCPOriginated
        viewModel.publishMCPStateChange(for: session)
        return session
    }

    private func makeService(
        window: WindowState,
        connectionID: UUID
    ) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "steer-resume-regression",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by steer resume tests")
            }
        )
    }
}
