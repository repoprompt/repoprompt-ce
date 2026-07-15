import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentChatTitlebarSafetyTests: XCTestCase {
    func testButtonPointerStandardAndAccessibilityActivationUseTargetAction() throws {
        let probe = ButtonActionProbe()
        let button = AgentChatOptionsButton()
        button.frame = NSRect(x: 0, y: 0, width: 26, height: 24)
        button.target = probe
        button.action = #selector(ButtonActionProbe.activate(_:))

        XCTAssertEqual(button.focusRingType, .exterior)
        XCTAssertEqual(button.focusRingMaskBounds, button.bounds)

        let pointerEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        button.mouseDown(with: pointerEvent)
        XCTAssertEqual(probe.senders.count, 1)
        XCTAssertTrue(probe.senders.last === button)

        button.performClick(nil)
        XCTAssertEqual(probe.senders.count, 2)
        XCTAssertTrue(probe.senders.last === button)

        _ = button.accessibilityPerformPress()
        XCTAssertEqual(probe.senders.count, 3)
        XCTAssertTrue(probe.senders.last === button)
    }

    func testMenuItemsCaptureImmutableRepresentedTarget() throws {
        let target = AgentChatOptionsMenuTarget(
            workspaceID: UUID(),
            tabID: UUID(),
            agentSessionID: UUID(),
            tabName: "Captured"
        )
        let snapshot = AgentChatOptionsMenuSnapshot(target: target, isPinned: true)
        var invocations: [(String, AgentChatOptionsMenuTarget)] = []
        let menu = AgentChatOptionsMenuPresenter.makeMenu(
            snapshot: snapshot,
            actions: AgentChatOptionsMenuActions(
                togglePin: { invocations.append(("pin", $0)) },
                rename: { invocations.append(("rename", $0)) },
                stash: { invocations.append(("stash", $0)) },
                delete: { invocations.append(("delete", $0)) }
            )
        )

        XCTAssertEqual(menu.items.map(\.title), [
            "Unpin Chat",
            "Rename Chat…",
            "Stash Chat",
            "",
            "Delete Chat…"
        ])

        for index in [0, 1, 2, 4] {
            let item = menu.items[index]
            XCTAssertTrue(item.target === item)
            XCTAssertTrue(try NSApplication.shared.sendAction(
                XCTUnwrap(item.action),
                to: item.target,
                from: item
            ))
        }

        XCTAssertEqual(invocations.map(\.0), ["pin", "rename", "stash", "delete"])
        XCTAssertEqual(invocations.map(\.1), Array(repeating: target, count: 4))
    }

    func testSnapshotAndTargetValidationFailClosedAcrossLifecycleChanges() async throws {
        try await withFixture { fixture in
            let snapshot = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot())
            let target = snapshot.target
            XCTAssertEqual(target.workspaceID, fixture.workspaceID)
            XCTAssertEqual(target.tabID, fixture.tabAID)
            XCTAssertEqual(target.agentSessionID, fixture.sessionAID)
            XCTAssertEqual(target.tabName, "Alpha")
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    workspaceID: UUID(),
                    tabID: target.tabID,
                    agentSessionID: target.agentSessionID,
                    tabName: target.tabName
                )
            ))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    workspaceID: target.workspaceID,
                    tabID: UUID(),
                    agentSessionID: target.agentSessionID,
                    tabName: target.tabName
                )
            ))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(
                AgentChatOptionsMenuTarget(
                    workspaceID: target.workspaceID,
                    tabID: target.tabID,
                    agentSessionID: UUID(),
                    tabName: target.tabName
                )
            ))

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabBID)
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, true)
            XCTAssertEqual(fixture.tab(fixture.tabBID)?.isPinned, false)

            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabAID)
            XCTAssertNil(fixture.window.agentChatTitleClusterMenuSnapshot())
            fixture.viewModel.test_setCurrentTabIDOverride(fixture.tabBID)

            fixture.window.promptManager.renameComposeTab(fixture.tabAID, to: "Alpha Renamed")
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, true)
            fixture.window.promptManager.renameComposeTab(fixture.tabAID, to: "Alpha")
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            fixture.sessionA.testInstallPersistentSessionBinding(sessionID: UUID())
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
            fixture.window.agentChatTitleClusterMenuActions().togglePin(target)
            XCTAssertEqual(fixture.tab(fixture.tabAID)?.isPinned, true)
            XCTAssertEqual(fixture.tab(fixture.tabBID)?.isPinned, false)
        }
    }

    func testGuardedCloseAndStashRejectStaleMutationContext() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.closeComposeTab(
                fixture.tabAID,
                isMutationContextCurrent: { false }
            )
            XCTAssertNotNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))

            await fixture.window.promptManager.stashTab(
                fixture.tabAID,
                isMutationContextCurrent: { false }
            )
            XCTAssertNotNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))
            XCTAssertFalse(
                fixture.window.workspaceManager.activeWorkspace?.stashedTabs
                    .contains(where: { $0.tab.id == fixture.tabAID }) == true
            )
        }
    }

    func testGuardedCloseCommitsTabRemovalAfterListenerCleanupInvalidatesTarget() async throws {
        try await withFixture { fixture in
            let target = try XCTUnwrap(fixture.window.agentChatTitleClusterMenuSnapshot()?.target)
            XCTAssertTrue(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))

            await fixture.window.promptManager.closeComposeTab(
                fixture.tabAID,
                isMutationContextCurrent: {
                    fixture.window.agentChatTitleClusterMenuTargetIsValid(target)
                }
            )

            XCTAssertNil(fixture.tab(fixture.tabAID))
            XCTAssertNotNil(fixture.tab(fixture.tabBID))
            XCTAssertNil(fixture.viewModel.explicitActiveSessionID(for: fixture.tabAID))
            XCTAssertFalse(fixture.window.agentChatTitleClusterMenuTargetIsValid(target))
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChatTitlebarSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Titlebar Safety",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentChatTitlebarSafetyTests"
            )

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "Alpha", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "Beta", activeAgentSessionID: sessionBID)
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = viewModel.session(for: tabAID)
            _ = viewModel.session(for: tabBID)
            viewModel.setAgentModeActive(true)
            viewModel.test_setCurrentTabIDOverride(tabAID)
            window.setAgentTitlebarAccessoryVisible(true, onNewSession: {})

            return Fixture(
                window: window,
                rootURL: rootURL,
                workspaceID: workspace.id,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionA: sessionA
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.viewModel.test_setCurrentTabIDOverride(nil)
        fixture.window.setAgentTitlebarAccessoryVisible(false)
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private final class ButtonActionProbe: NSObject {
        var senders: [NSButton] = []

        @objc func activate(_ sender: NSButton) {
            senders.append(sender)
        }
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let workspaceID: UUID
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionA: AgentModeViewModel.TabSession

        @MainActor
        func tab(_ id: UUID) -> ComposeTabState? {
            window.workspaceManager.activeWorkspace?.composeTabs.first(where: { $0.id == id })
        }
    }
}
