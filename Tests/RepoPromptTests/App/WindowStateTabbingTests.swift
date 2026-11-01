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

/// #143 (chunk 3): the per-window "Enable MCP tools for this window" switch is part of the saved
/// window session. New windows still seed from the global default; restored windows use their own
/// saved value; neither path writes the global default.
@MainActor
final class WindowSessionMCPToolsPreferenceTests: XCTestCase {
    func testLegacySnapshotDecodesWithoutPreferenceAndExplicitValuesStayPerWindow() throws {
        let workspaceID = UUID()
        let legacy = """
        {"version":1,"windows":[
          {"windowKind":"standard","workspaceID":"\(workspaceID.uuidString)","isSystemWorkspace":false,"isEphemeral":false,"lastFocused":true}
        ]}
        """
        let decodedLegacy = try JSONDecoder().decode(WindowSessionSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(decodedLegacy.windows[0].mcpToolsEnabled)

        // Two windows on the same workspace may restore different values.
        let snapshot = WindowSessionSnapshot(version: 1, windows: [
            makeEntry(workspaceID: workspaceID, mcpToolsEnabled: true),
            makeEntry(workspaceID: workspaceID, mcpToolsEnabled: false),
            makeEntry(workspaceID: workspaceID, mcpToolsEnabled: nil)
        ])
        let roundTripped = try JSONDecoder().decode(WindowSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTripped.windows.map(\.mcpToolsEnabled), [true, false, nil])
    }

    func testRestoredEnabledPreferenceOverridesDisabledGlobalDefaultWithoutMutatingIt() async throws {
        let window = try await makeWindow(globalDefault: false)
        XCTAssertFalse(window.mcpServer.windowToolsAreRequested)

        window.applyWindowRestoreEntry(makeEntry(workspaceID: UUID(), mcpToolsEnabled: true))
        try await waitUntil("restored preference enables tools") { window.mcpServer.windowToolsAreRequested }
        XCTAssertFalse(GlobalSettingsStore.shared.mcpAutoStart(), "Restoring a window never writes the global default")
    }

    func testRestoredDisabledPreferenceOverridesEnabledGlobalDefault() async throws {
        let window = try await makeWindow(globalDefault: true)
        try await waitUntil("global default seeds the new window") { window.mcpServer.windowToolsAreRequested }

        window.applyWindowRestoreEntry(makeEntry(workspaceID: UUID(), mcpToolsEnabled: false))
        try await waitUntil("restored preference disables tools") { !window.mcpServer.windowToolsAreRequested }
        XCTAssertTrue(GlobalSettingsStore.shared.mcpAutoStart())
    }

    func testLegacyEntryWithoutPreferenceKeepsGlobalDefaultSeeding() async throws {
        let window = try await makeWindow(globalDefault: false)
        window.applyWindowRestoreEntry(makeEntry(workspaceID: UUID(), mcpToolsEnabled: nil))
        // Give any (incorrect) transition a chance to run before asserting nothing changed.
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertFalse(window.mcpServer.windowToolsAreRequested)
    }

    func testLiveSessionCaptureRecordsThisWindowsSwitch() async throws {
        let window = try await makeWindow(globalDefault: false)
        let workspace = WorkspaceModel(name: "Captured", repoPaths: [NSTemporaryDirectory()])
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.setWorkspaceInstanceAssignment(.init(workspaceID: workspace.id, number: 1))

        XCTAssertEqual(window.sessionCaptureCandidate().entry?.mcpToolsEnabled, false)

        _ = await window.mcpServer.setWindowToolsEnabled(true)
        XCTAssertEqual(window.sessionCaptureCandidate().entry?.mcpToolsEnabled, true)
        XCTAssertFalse(GlobalSettingsStore.shared.mcpAutoStart())
    }

    // MARK: - Helpers

    private func makeWindow(globalDefault: Bool) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(globalDefault, commit: false)
        let window = WindowState()
        addTeardownBlock { @MainActor in
            _ = await window.mcpServer.setWindowToolsEnabled(false)
            window.beginClose()
            await window.tearDown()
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        }
        return window
    }

    private func makeEntry(workspaceID: UUID, mcpToolsEnabled: Bool?) -> WindowSessionEntry {
        WindowSessionEntry(
            windowKind: .standard,
            workspaceID: workspaceID,
            workspaceName: "Saved",
            isSystemWorkspace: false,
            isEphemeral: false,
            primaryRepoPath: nil,
            lastFocused: true,
            workspaceInstanceNumber: 1,
            mcpToolsEnabled: mcpToolsEnabled
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("Timed out waiting for: \(description)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
