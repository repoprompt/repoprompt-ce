import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class BindContextRoutingRecoveryTests: XCTestCase {
    @MainActor
    func testContextIDBindIgnoresStaleAffinityToInactiveSavedWorkspace() async throws {
        let contextID = UUID()
        let target = workspace(name: "NickClaw", root: "/tmp/nickclaw", contextID: contextID)
        let unrelated = workspace(name: "TTA", root: "/tmp/tta", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let targetWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([staleWindow, targetWindow])
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
        XCTAssertNotNil(staleWindow.workspaceManager.composeTab(for: .init(
            workspaceID: target.id,
            tabID: contextID
        )))

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )

        XCTAssertEqual(resolved.windowID, targetWindow.windowID)
        XCTAssertEqual(resolved.workspaceID, target.id)
        XCTAssertEqual(resolved.repoPaths, target.repoPaths)
    }

    @MainActor
    func testContextIDBindLowestWindowFallbackExcludesInactiveSavedWorkspace() async throws {
        let contextID = UUID()
        let target = workspace(name: "NickClaw", root: "/tmp/nickclaw", contextID: contextID)
        let unrelated = workspace(name: "TTA", root: "/tmp/tta", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let targetWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([staleWindow, targetWindow])
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
        XCTAssertNotNil(staleWindow.workspaceManager.composeTab(for: .init(
            workspaceID: target.id,
            tabID: contextID
        )))

        let resolved = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: nil
        )

        XCTAssertEqual(resolved.windowID, targetWindow.windowID)
    }

    @MainActor
    func testContextIDBindPreservesActiveSameWorkspaceMultiWindowRouting() async throws {
        let contextID = UUID()
        let target = workspace(name: "Shared", root: "/tmp/shared", contextID: contextID)
        let firstWindow = try await makeWindow(activeWorkspace: target)
        let secondWindow = try await makeWindow(activeWorkspace: target)
        let service = installWindows([firstWindow, secondWindow])

        let preferred = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: secondWindow.windowID
        )
        XCTAssertEqual(preferred.windowID, secondWindow.windowID)
        XCTAssertEqual(preferred.workspaceID, target.id)
        XCTAssertEqual(preferred.tabID, contextID)

        let lowest = try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: nil
        )
        XCTAssertEqual(
            lowest.windowID,
            min(firstWindow.windowID, secondWindow.windowID)
        )
    }

    @MainActor
    func testContextIDBindFailsClosedWhenContextExistsOnlyInInactiveWorkspace() async throws {
        let contextID = UUID()
        let target = workspace(name: "NickClaw", root: "/tmp/nickclaw", contextID: contextID)
        let unrelated = workspace(name: "TTA", root: "/tmp/tta", contextID: UUID())
        let staleWindow = try await makeWindow(activeWorkspace: unrelated, savedWorkspaces: [target])
        let service = installWindows([staleWindow])
        XCTAssertEqual(staleWindow.workspaceManager.activeWorkspaceID, unrelated.id)
        XCTAssertNotNil(staleWindow.workspaceManager.composeTab(for: .init(
            workspaceID: target.id,
            tabID: contextID
        )))

        XCTAssertThrowsError(try service.test_resolveContextIDBindTarget(
            contextID: contextID,
            connectionPreferredWindowID: staleWindow.windowID
        )) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("No open RepoPrompt window actively shows context_id"), message)
            XCTAssertTrue(message.contains("working_dirs"), message)
        }
    }

    func testBindContextParsesWorkingDirsAndPrefersSelectedWindow() throws {
        let projectSourcePath = "/Users/repoprompt-test/project/Sources"
        let request = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .array([
                .string(" /Users/repoprompt-test/project/./Sources "),
                .string(projectSourcePath)
            ]),
            "create_if_missing": .bool(true),
            "tab_name": .string("Recovered")
        ])

        XCTAssertEqual(request.op, .bind)
        XCTAssertEqual(request.matchKind, .workingDirs)
        XCTAssertEqual(request.workingDirs, [projectSourcePath])
        XCTAssertTrue(request.createIfMissing)
        XCTAssertEqual(request.tabName, "Recovered")

        XCTAssertEqual(
            WindowRoutingService.test_preferredOpenWindowID(
                showingWindowIDs: [2, 6, 9],
                selectedWindowID: 6,
                focusedWindowID: 9
            ),
            6
        )
    }

    func testBindContextParsesReadOnlyOperationsWithoutSelectors() throws {
        let status = try WindowRoutingService.parseBindContextRequest(["op": .string("status")])
        XCTAssertEqual(status.op, .status)
        XCTAssertNil(status.matchKind)

        let list = try WindowRoutingService.parseBindContextRequest(["op": .string("list")])
        XCTAssertEqual(list.op, .list)
        XCTAssertNil(list.matchKind)
    }

    func testBindContextParsesCommaSeparatedWorkingDirs() throws {
        let request = try WindowRoutingService.parseBindContextRequest([
            "op": .string("bind"),
            "working_dirs": .string(" /tmp/repoprompt-a, /tmp/repoprompt-b , /tmp/repoprompt-a ")
        ])

        XCTAssertEqual(request.matchKind, .workingDirs)
        XCTAssertEqual(request.workingDirs, ["/tmp/repoprompt-a", "/tmp/repoprompt-b"])
    }

    func testBindContextRejectsInvalidPrimarySelectorCombinations() {
        do {
            let caseLabel = "testBindContextRejectsMultiplePrimarySelectors"
            XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
                "op": .string("bind"),
                "context_id": .string(UUID().uuidString),
                "working_dirs": .array([.string("/tmp/repoprompt-a")])
            ]), caseLabel)
        }

        do {
            let caseLabel = "testBindContextRejectsCreateIfMissingWithoutWorkingDirs"
            XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
                "op": .string("bind"),
                "window_id": .int(1),
                "create_if_missing": .bool(true)
            ]), caseLabel)
        }
    }

    func testMCPConnectionManagerHasNoIncompleteBindContextFastPathOrUnsafeRegisteredServicesSnapshot() throws {
        let source = try readMCPConnectionManagerSource()
        XCTAssertFalse(source.contains("fastBindContextReadOnlyResult"))
        XCTAssertFalse(source.contains("served read-only request via fast path"))
        XCTAssertFalse(source.contains("registeredServicesSnapshot"))
        XCTAssertFalse(source.contains("nonisolated(unsafe) private var registeredServicesSnapshot"))
    }

    func testStandardWorkspaceSwitchBindsConnectionOnlyWhenWindowIDIsExplicit() {
        XCTAssertTrue(WindowRoutingService.shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: true))
        XCTAssertFalse(WindowRoutingService.shouldBindConnectionAfterStandardWorkspaceSwitch(explicitWindowIDProvided: false))
    }

    private func readMCPConnectionManagerSource() throws -> String {
        let root = try RepoRoot.url()
        let url = root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func workspace(name: String, root: String, contextID: UUID) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [root],
            composeTabs: [ComposeTabState(id: contextID, name: "Context")],
            activeComposeTabID: contextID
        )
    }

    @MainActor
    private func makeWindow(
        activeWorkspace: WorkspaceModel,
        savedWorkspaces: [WorkspaceModel] = []
    ) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        window.workspaceManager.workspaces = [activeWorkspace] + savedWorkspaces
        let result = await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "bindContextRoutingRecoveryTest"
        )
        guard result.didSwitch else {
            throw XCTSkip("Could not activate test workspace")
        }
        return window
    }

    @MainActor
    private func installWindows(_ windows: [WindowState]) -> WindowRoutingService {
        let previousWindows = WindowStatesManager.shared.allWindows
        WindowStatesManager.shared.allWindows = windows
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.allWindows = previousWindows
        }
        return WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
    }
}
