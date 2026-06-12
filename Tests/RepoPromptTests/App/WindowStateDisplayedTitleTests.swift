import Foundation
@testable import RepoPrompt
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
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "windowStateDisplayedTitleTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            try await waitForDisplayedTitle(window, expected: workspaceName)
        } catch {
            await cleanup(window: window, rootURL: rootURL)
            throw error
        }
        await cleanup(window: window, rootURL: rootURL)
    }

    private func cleanup(window: WindowState, rootURL: URL) async {
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// The displayed title is published from a deferred task, so poll briefly instead of
    /// asserting immediately after the workspace switch returns. The title may carry an
    /// Agent session prefix ("T1 — <workspace>"), so only the workspace suffix is asserted.
    private func waitForDisplayedTitle(
        _ window: WindowState,
        expected: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if window.displayedWindowTitle.hasSuffix(expected) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("displayedWindowTitle was \"\(window.displayedWindowTitle)\", expected suffix \"\(expected)\"")
    }
}
