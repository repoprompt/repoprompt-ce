import AppKit
import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeComputerUseSettingsViewModelTests: XCTestCase {
    override func tearDown() {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        CodexComputerUseWorkflow.setPrerequisiteSnapshotForTesting(nil)
        super.tearDown()
    }

    func testStatusUsesEffectiveOptInOverrideForSettingsConsistency() throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let store = try makeStore()
        store.setCodexComputerUseEnabled(false)

        let viewModel = AgentModeComputerUseSettingsViewModel(
            globalSettings: store,
            statusService: .testing(),
            pasteboard: makePasteboard()
        )

        XCTAssertFalse(viewModel.optInEnabled)
        XCTAssertTrue(viewModel.status.optInEnabled)
        XCTAssertTrue(viewModel.status.isReady)
    }

    func testSetOptInEnabledWritesInjectedSettingsStore() throws {
        CodexComputerUseWorkflow.setEnabledForTesting(nil)
        let store = try makeStore()
        store.setCodexComputerUseEnabled(false)
        let viewModel = AgentModeComputerUseSettingsViewModel(
            globalSettings: store,
            statusService: .testing(),
            pasteboard: makePasteboard()
        )

        viewModel.setOptInEnabled(true)

        XCTAssertTrue(store.codexComputerUseEnabled())
        XCTAssertTrue(viewModel.optInEnabled)
        XCTAssertTrue(viewModel.status.optInEnabled)
        XCTAssertTrue(viewModel.status.isReady)
    }

    func testPermissionRequestRefreshesStatusAndMessage() throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let store = try makeStore()
        store.setCodexComputerUseEnabled(true)
        var screenRecordingStatus = CodexComputerUsePermissionStatus.notGranted
        var requestedScreenRecording = false
        let service = CodexComputerUseStatusService.testing(
            permissionClient: .init(
                screenRecordingStatus: { screenRecordingStatus },
                accessibilityStatus: { .granted },
                requestScreenRecording: {
                    requestedScreenRecording = true
                    screenRecordingStatus = .granted
                    return .granted
                },
                requestAccessibility: { .granted }
            )
        )
        let viewModel = AgentModeComputerUseSettingsViewModel(
            globalSettings: store,
            statusService: service,
            pasteboard: makePasteboard()
        )

        XCTAssertEqual(viewModel.status.screenRecording, .notGranted)

        viewModel.requestScreenRecordingAccess()

        XCTAssertTrue(requestedScreenRecording)
        XCTAssertEqual(viewModel.status.screenRecording, .granted)
        XCTAssertEqual(viewModel.lastActionMessage, CodexComputerUsePermissionRequestResult.granted.userMessage)
    }

    func testOpenAndCopyActionsUseInjectedDependencies() throws {
        CodexComputerUseWorkflow.setEnabledForTesting(true)
        let store = try makeStore()
        store.setCodexComputerUseEnabled(true)
        var openedURLs: [URL] = []
        let pasteboard = makePasteboard()
        let viewModel = AgentModeComputerUseSettingsViewModel(
            globalSettings: store,
            statusService: .testing(),
            openURL: { openedURLs.append($0) },
            pasteboard: pasteboard
        )

        viewModel.openAccessibilitySettings()
        viewModel.openScreenRecordingSettings()
        viewModel.openCodexComputerUseGuide()
        viewModel.copyManualSetupInstructions(for: .screenRecording)

        XCTAssertEqual(openedURLs.map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "https://developers.openai.com/codex/app/computer-use"
        ])
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("Screen Recording") == true)
        XCTAssertEqual(viewModel.lastActionMessage, "Copied setup instructions to the clipboard.")
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentModeComputerUseSettingsViewModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "AgentModeComputerUseSettingsViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentModeComputerUseSettingsViewModelTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
