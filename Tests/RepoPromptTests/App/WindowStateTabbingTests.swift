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

    func testTerminationTeardownDoesNotOverwriteCapturedPreference() async throws {
        let window = try await makeWindow(globalDefault: false)
        let workspace = WorkspaceModel(name: "Captured", repoPaths: [NSTemporaryDirectory()])
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.setWorkspaceInstanceAssignment(.init(workspaceID: workspace.id, number: 1))
        _ = await window.mcpServer.setWindowToolsEnabled(true)

        // Same order as quit: the synchronous termination fence pins the preference, then
        // `stopAllServers()` disables every window's tools during async teardown.
        window.freezeMCPToolsPreferenceForTermination()
        await window.mcpServer.stopServer()
        XCTAssertFalse(window.mcpServer.windowToolsAreRequested)
        XCTAssertEqual(
            window.sessionCaptureCandidate().entry?.mcpToolsEnabled,
            true,
            "Quit teardown must not be persisted as the window's MCP tools choice"
        )

        // The `applicationWillTerminate` fallback re-signals termination; it must not re-pin.
        window.freezeMCPToolsPreferenceForTermination()
        XCTAssertEqual(window.sessionCaptureCandidate().entry?.mcpToolsEnabled, true)
    }

    // MARK: - Persistence follows the requested intent, not registration state

    func testEnablingPersistsIntentWhileRegistrationIsStillPending() async throws {
        let (window, recorder) = try await makeCapturedWindow()
        let gate = RegistrationGate()
        window.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting { [gate] in await gate.hold() }

        let enable = Task { await window.mcpServer.setWindowToolsEnabled(true) }
        try await waitUntil("registration is held") { gate.isHolding }
        XCTAssertEqual(recorder.preferences, [true], "The intent change persists before registration completes")
        XCTAssertFalse(window.mcpServer.windowToolsEnabled)
        let persisted = await writeAndReadBack(recorder)
        XCTAssertEqual(persisted, true)

        gate.release()
        _ = await enable.value
        XCTAssertEqual(recorder.preferences, [true], "Registration completing is not a second user change")
    }

    func testFailedRegistrationStillPersistsTheRequestedSwitch() async throws {
        let (window, recorder) = try await makeCapturedWindow()
        window.mcpServer.setWindowToolRegistrationFailureForTesting(TestRegistrationFailure())

        let registered = await window.mcpServer.setWindowToolsEnabled(true)
        XCTAssertFalse(registered)
        XCTAssertFalse(window.mcpServer.windowToolsEnabled)
        XCTAssertTrue(window.mcpServer.windowToolsAreRequested)
        XCTAssertEqual(recorder.preferences, [true])
        let persisted = await writeAndReadBack(recorder)
        XCTAssertEqual(persisted, true)

        // Retrying the unchanged intent re-runs registration but is not a new change to persist.
        window.mcpServer.setWindowToolRegistrationFailureForTesting(nil)
        let retried = await window.mcpServer.setWindowToolsEnabled(true)
        XCTAssertTrue(retried)
        XCTAssertTrue(window.mcpServer.windowToolsEnabled)
        XCTAssertEqual(recorder.preferences, [true])
    }

    func testRapidOnThenOffWhileRegistrationIsGatedPersistsFinalIntent() async throws {
        let (window, recorder) = try await makeCapturedWindow()
        let gate = RegistrationGate()
        window.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting { [gate] in await gate.hold() }

        let enable = Task { await window.mcpServer.setWindowToolsEnabled(true) }
        try await waitUntil("registration is held") { gate.isHolding }
        // `windowToolsEnabled` stays false across both changes; the old sink saw nothing here.
        let disable = Task { await window.mcpServer.setWindowToolsEnabled(false) }
        try await waitUntil("disable intent recorded") { recorder.preferences.count == 2 }
        XCTAssertEqual(recorder.preferences, [true, false])
        let persisted = await writeAndReadBack(recorder)
        XCTAssertEqual(persisted, false)

        gate.release()
        _ = await enable.value
        _ = await disable.value
        XCTAssertFalse(window.mcpServer.windowToolsEnabled)
        XCTAssertEqual(recorder.preferences, [true, false])
    }

    func testRestoredDisabledPreferenceWinsOverAutoStartSeedingInCapturedSession() async throws {
        let (window, recorder) = try await makeCapturedWindow(globalDefault: true)
        try await waitUntil("global default seeds the new window") { window.mcpServer.windowToolsAreRequested }

        window.applyWindowRestoreEntry(makeEntry(workspaceID: UUID(), mcpToolsEnabled: false))
        try await waitUntil("restored preference disables tools") { !window.mcpServer.windowToolsAreRequested }
        XCTAssertEqual(recorder.preferences.last, false)
        XCTAssertEqual(window.sessionCaptureCandidate().entry?.mcpToolsEnabled, false)
        XCTAssertTrue(GlobalSettingsStore.shared.mcpAutoStart(), "Restore never writes the global default")
    }

    func testTerminationTeardownDoesNotRequestPersistence() async throws {
        let (window, recorder) = try await makeCapturedWindow()
        _ = await window.mcpServer.setWindowToolsEnabled(true)
        XCTAssertEqual(recorder.preferences, [true])

        WindowStatesManager.shared.setTerminatingForTesting(true)
        defer { WindowStatesManager.shared.setTerminatingForTesting(false) }
        window.freezeMCPToolsPreferenceForTermination()
        await window.mcpServer.stopServer()
        XCTAssertEqual(recorder.preferences, [true], "Quit teardown is not a user change")
        XCTAssertEqual(window.sessionCaptureCandidate().entry?.mcpToolsEnabled, true)
    }

    // MARK: - Helpers

    @MainActor
    private final class PersistRequestRecorder {
        var entries: [WindowSessionEntry?] = []
        var preferences: [Bool?] {
            entries.map { $0?.mcpToolsEnabled }
        }
    }

    @MainActor
    private final class RegistrationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isHolding = false

        func hold() async {
            guard !released else { return }
            isHolding = true
            await withCheckedContinuation { continuation = $0 }
            isHolding = false
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct TestRegistrationFailure: Error {}

    /// A window on a real (non-system) workspace whose MCP persistence requests are recorded with
    /// the entry session capture would write at that moment.
    private func makeCapturedWindow(
        globalDefault: Bool = false
    ) async throws -> (WindowState, PersistRequestRecorder) {
        let window = try await makeWindow(globalDefault: globalDefault)
        let workspace = WorkspaceModel(name: "Captured", repoPaths: [NSTemporaryDirectory()])
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [workspace]
        window.workspaceManager.activeWorkspace = workspace
        window.setWorkspaceInstanceAssignment(.init(workspaceID: workspace.id, number: 1))
        let recorder = PersistRequestRecorder()
        window.mcpToolsPersistRequestObserverForTesting = { [recorder] in recorder.entries.append($0) }
        addTeardownBlock { @MainActor in
            window.mcpServer.setAfterWindowToolRegistrationBeforeRetentionForTesting(nil)
            window.mcpServer.setWindowToolRegistrationFailureForTesting(nil)
        }
        return (window, recorder)
    }

    /// Writes the latest requested persistence through the real session writer and reads the file.
    private func writeAndReadBack(_ recorder: PersistRequestRecorder) async -> Bool? {
        guard let entry = recorder.entries.last ?? nil else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = WindowSessionDiskWriter(fileURL: directory.appendingPathComponent("windowSessions.json"))
        await writer.writeImmediately(WindowSessionSnapshot(version: 4, windows: [entry]))
        return await writer.load()?.windows.first?.mcpToolsEnabled
    }

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
