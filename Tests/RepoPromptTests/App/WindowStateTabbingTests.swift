import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class WindowStateTabbingTests: XCTestCase {
    func testAttachedMainWindowsShareAutomaticTabbingIdentity() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let firstState = WindowState()
        let secondState = WindowState()
        let firstWindow = makeTestWindow()
        let secondWindow = makeTestWindow()
        firstWindow.tabbingMode = .disallowed
        secondWindow.tabbingMode = .disallowed
        firstWindow.tabbingIdentifier = "test.first"
        secondWindow.tabbingIdentifier = "test.second"

        firstState.attachWindow(firstWindow)
        secondState.attachWindow(secondWindow)

        XCTAssertEqual(firstWindow.tabbingMode, .automatic)
        XCTAssertEqual(secondWindow.tabbingMode, .automatic)
        XCTAssertFalse(firstWindow.tabbingIdentifier.isEmpty)
        XCTAssertEqual(firstWindow.tabbingIdentifier, secondWindow.tabbingIdentifier)

        firstState.attachWindow(nil)
        secondState.attachWindow(nil)
        firstState.beginClose()
        secondState.beginClose()
        await firstState.tearDown()
        await secondState.tearDown()
    }

    private func makeTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
