import AppKit
import Combine
@testable import RepoPromptApp
import RepoPromptSettingsCore
import SwiftUI
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

/// Guards the observation scope of the process-wide `WindowStatesManager`.
///
/// Every `objectWillChange` from the manager invalidates each view that observes it. Window roots
/// and menu commands only need the manager inside callbacks/actions, so observing it made every
/// window open/close re-evaluate all ~W window roots and the App commands.
@MainActor
final class WindowStatesManagerObservationScopeTests: XCTestCase {
    func testObservingWrapperDetectionFindsManagerSubscriptions() {
        // Positive control so the structural assertions below cannot pass vacuously.
        let probe = ObservingProbe(manager: WindowStatesManager.shared)
        XCTAssertEqual(observingManagerWrapperLabels(in: probe), ["_manager"])
    }

    func testWindowRootDoesNotObserveWindowStatesManager() {
        XCTAssertEqual(observingManagerWrapperLabels(in: WindowContentView()), [])
    }

    func testWorkspaceCommandsDoNotObserveWindowStatesManager() {
        let commands = WorkspaceCommands(windowStatesManager: WindowStatesManager.shared)
        XCTAssertEqual(observingManagerWrapperLabels(in: commands), [])
    }

    func testRegisteringWindowPublishesManagerChangeOnce() async throws {
        // Registration and unregistration persist the window session to Application Support. Only run
        // where the coordinated test runner has redirected HOME to a disposable sandbox, so a direct
        // `swift test` or Xcode run can never overwrite the user's real windowSessions.json.
        guard let sandboxRoot = ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"] else {
            throw XCTSkip("Requires the isolated test sandbox (run via ./conductor test)")
        }
        try XCTSkipUnless(
            WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path
                .hasPrefix(URL(fileURLWithPath: sandboxRoot).resolvingSymlinksInPath().path + "/"),
            "Window session storage is not redirected into the test sandbox"
        )

        let manager = WindowStatesManager.shared
        guard manager.pendingURLs.isEmpty else {
            return XCTFail("Precondition: no queued deep links to drain before registering")
        }

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        let emissions = EmissionCounter()
        let subscription = manager.objectWillChange.sink { _ in emissions.count += 1 }

        manager.registerWindowState(window)

        subscription.cancel()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        XCTAssertEqual(
            emissions.count,
            1,
            "Registering one window should publish exactly one manager change (the allWindows append)"
        )

        window.beginClose()
        await window.tearDown()
        manager.unregisterWindowState(window)
    }

    private func observingManagerWrapperLabels(in subject: Any) -> [String] {
        let observingPrefixes = ["SwiftUI.EnvironmentObject<", "SwiftUI.ObservedObject<", "SwiftUI.StateObject<"]
        return Mirror(reflecting: subject).children.compactMap { child in
            let typeName = String(reflecting: type(of: child.value))
            guard observingPrefixes.contains(where: { typeName.hasPrefix($0) }),
                  typeName.contains("WindowStatesManager")
            else { return nil }
            return child.label ?? typeName
        }
    }

    private struct ObservingProbe {
        @ObservedObject var manager: WindowStatesManager
    }

    private final class EmissionCounter {
        var count = 0
    }
}
