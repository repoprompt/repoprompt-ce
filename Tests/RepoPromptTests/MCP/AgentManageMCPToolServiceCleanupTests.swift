import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPrompt
import XCTest

@MainActor
final class AgentManageMCPToolServiceCleanupTests: XCTestCase {
    func testCleanupSessionsIncludesPersistedProviderCleanupOutcome() async throws {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let recorder = AgentManageCleanupRecorder(outcome: .succeeded(message: "archived from MCP cleanup"))
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Cleanup Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 298),
            itemCount: 0,
            agentKind: AgentProviderKind.codexExec.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            autoEditEnabled: true,
            codexConversationID: "mcp-cleanup-thread",
            codexRolloutPath: "/tmp/mcp-cleanup-rollout.jsonl",
            isMCPOriginated: true
        )
        try await AgentSessionDataService.shared.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let service = makeService(window: window)
        let result = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["deleted_count"]?.intValue, 1)
        let deletedSessions = try XCTUnwrap(object["deleted_sessions"]?.arrayValue)
        let deleted = try XCTUnwrap(deletedSessions.first?.objectValue)
        let cleanup = try XCTUnwrap(deleted["provider_cleanup"]?.objectValue)
        XCTAssertEqual(cleanup["status"]?.stringValue, "succeeded")
        XCTAssertEqual(cleanup["message"]?.stringValue, "archived from MCP cleanup")

        let calls = recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.handle.conversationID, "mcp-cleanup-thread")
        XCTAssertEqual(calls.first?.handle.rolloutPath, "/tmp/mcp-cleanup-rollout.jsonl")
        XCTAssertEqual(calls.first?.action, .archive)
    }

    func testCleanupSessionsReportsUnsupportedProviderCleanupForNonCodexPersistedSession() async throws {
        let previousAction = GlobalSettingsStore.shared.providerConversationCleanupAction()
        GlobalSettingsStore.shared.setProviderConversationCleanupAction(.archive, commit: false)
        defer { GlobalSettingsStore.shared.setProviderConversationCleanupAction(previousAction, commit: false) }

        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let recorder = AgentManageCleanupRecorder(outcome: .succeeded(message: "should not run"))
        window.agentModeViewModel.test_setPersistedProviderConversationCleaner { handle, action in
            recorder.record(handle: handle, action: action)
            return recorder.outcome
        }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Unsupported Cleanup Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 299),
            itemCount: 0,
            agentKind: AgentProviderKind.openCode.rawValue,
            lastRunState: AgentSessionRunState.completed.rawValue,
            providerSessionID: "open-code-session",
            autoEditEnabled: true,
            isMCPOriginated: true
        )
        try await AgentSessionDataService.shared.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let service = makeService(window: window)
        let result = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "completed")
        XCTAssertEqual(object["deleted_count"]?.intValue, 1)
        let deletedSessions = try XCTUnwrap(object["deleted_sessions"]?.arrayValue)
        let deleted = try XCTUnwrap(deletedSessions.first?.objectValue)
        let cleanup = try XCTUnwrap(deleted["provider_cleanup"]?.objectValue)
        XCTAssertEqual(cleanup["status"]?.stringValue, "unsupported")
        XCTAssertEqual(
            cleanup["message"]?.stringValue,
            "ACP provider openCode has session metadata but no verified conversation cleanup API."
        )
        XCTAssertTrue(recorder.calls().isEmpty)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Cleanup Sessions \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageCleanupSessionsTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "cleanup-sessions-regression",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }
}

private final class AgentManageCleanupRecorder: @unchecked Sendable {
    struct Call {
        let handle: ProviderConversationCleanupHandle
        let action: ProviderConversationCleanupAction
    }

    let outcome: ProviderConversationCleanupOutcome
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    init(outcome: ProviderConversationCleanupOutcome) {
        self.outcome = outcome
    }

    func record(handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) {
        lock.lock()
        recordedCalls.append(.init(handle: handle, action: action))
        lock.unlock()
    }

    func calls() -> [Call] {
        lock.lock()
        let calls = recordedCalls
        lock.unlock()
        return calls
    }
}
