import AppKit
import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class WindowStateDisplayedTitleTests: XCTestCase {
    func testDisplayedWindowTitleFollowsWorkspaceName() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateDisplayedTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let nsWindow = makeTestWindow()
        window.attachWindow(nsWindow)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspaceName = "Displayed Title \(UUID().uuidString.prefix(8))"
            let workspace = window.workspaceManager.createWorkspace(
                name: workspaceName,
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            let titleUpdated = expectation(description: "workspace title published")
            let titleObservation = window.$displayedWindowTitle
                .filter { $0.hasSuffix(workspaceName) }
                .prefix(1)
                .sink { _ in titleUpdated.fulfill() }
            defer { titleObservation.cancel() }

            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedTitleTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            await fulfillment(of: [titleUpdated], timeout: 2)
            XCTAssertTrue(window.displayedWindowTitle.hasSuffix(workspaceName))
            XCTAssertTrue(nsWindow.title.hasSuffix(workspaceName))
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }
        await cleanup(window: window, rootURL: rootURL)
    }

    func testDisplayedWindowTitleRefreshesWhenActiveAgentSessionIsRenamedThroughAgentMode() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStateDisplayedTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let nsWindow = makeTestWindow()
        window.attachWindow(nsWindow)
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspaceName = "Rename Title \(UUID().uuidString.prefix(8))"
            let workspace = window.workspaceManager.createWorkspace(
                name: workspaceName,
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedTitleRenameTests"
            )
            let activeTabID = try XCTUnwrap(window.promptManager.activeComposeTabID)
            let expectedTitle = "Renamed Agent Session — \(workspaceName)"
            let titleUpdated = expectation(description: "renamed Agent session title published")
            let titleObservation = window.$displayedWindowTitle
                .filter { $0 == expectedTitle }
                .prefix(1)
                .sink { _ in titleUpdated.fulfill() }
            defer { titleObservation.cancel() }

            window.agentModeViewModel.renameSession(tabID: activeTabID, to: "Renamed Agent Session")

            await fulfillment(of: [titleUpdated], timeout: 2)
            XCTAssertEqual(window.displayedWindowTitle, expectedTitle)
            XCTAssertEqual(nsWindow.title, expectedTitle)
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }
        await cleanup(window: window, rootURL: rootURL)
    }

    private func makeTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func cleanup(window: WindowState, rootURL: URL) async {
        window.attachWindow(nil)
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
