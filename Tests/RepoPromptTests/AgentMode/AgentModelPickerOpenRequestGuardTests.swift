import Foundation
@testable import RepoPrompt
import XCTest

final class AgentModelPickerOpenRequestGuardTests: XCTestCase {
    func testAllowsMatchingWindowAndCurrentTab() {
        let tabID = UUID()
        let notification = Notification(
            name: .showAgentModelPicker,
            object: nil,
            userInfo: ["windowID": 42]
        )

        XCTAssertTrue(
            AgentModelPickerOpenRequestGuard.shouldOpen(
                notification: notification,
                composerWindowID: 42,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                hasAvailableAgentProviders: true,
                modelControlsDisabled: false
            )
        )
    }

    func testRejectsMismatchedWindow() {
        let tabID = UUID()
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                requestWindowID: 41,
                composerWindowID: 42,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID
            )
        )
    }

    func testRejectsMissingWindow() {
        let tabID = UUID()
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                requestWindowID: nil,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID
            )
        )
    }

    func testRejectsMissingComposerTab() {
        let tabID = UUID()
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                composerCurrentTabID: nil,
                propsCurrentTabID: tabID
            )
        )
    }

    func testRejectsMismatchedPropsTab() {
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                composerCurrentTabID: UUID(),
                propsCurrentTabID: UUID()
            )
        )
    }

    func testRejectsMissingProviders() {
        let tabID = UUID()
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                hasAvailableAgentProviders: false
            )
        )
    }

    func testRejectsDisabledModelControls() {
        let tabID = UUID()
        XCTAssertFalse(
            modelPickerShortcutGuardAllows(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                modelControlsDisabled: true
            )
        )
    }

    private func modelPickerShortcutGuardAllows(
        requestWindowID: Int? = 42,
        composerWindowID: Int = 42,
        composerCurrentTabID: UUID?,
        propsCurrentTabID: UUID?,
        hasAvailableAgentProviders: Bool = true,
        modelControlsDisabled: Bool = false
    ) -> Bool {
        AgentModelPickerOpenRequestGuard.shouldOpen(
            requestWindowID: requestWindowID,
            composerWindowID: composerWindowID,
            composerCurrentTabID: composerCurrentTabID,
            propsCurrentTabID: propsCurrentTabID,
            hasAvailableAgentProviders: hasAvailableAgentProviders,
            modelControlsDisabled: modelControlsDisabled
        )
    }
}

final class AgentEffortPickerOpenRequestGuardTests: XCTestCase {
    func testRoutesCodexEffortPickerWhenCodexEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertEqual(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            ),
            .codexReasoningEffort
        )
    }

    func testNotificationOverloadRoutesByWindowUserInfo() {
        let tabID = UUID()
        let notification = Notification(
            name: .showAgentEffortPicker,
            object: nil,
            userInfo: ["windowID": 42]
        )

        XCTAssertEqual(
            AgentEffortPickerOpenRequestGuard.target(
                notification: notification,
                composerWindowID: 42,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                hasAvailableAgentProviders: true,
                modelControlsDisabled: false,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true,
                claudeEffortsAvailable: false
            ),
            .codexReasoningEffort
        )
    }

    func testRoutesClaudeEffortPickerWhenClaudeEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertEqual(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .claudeCode,
                claudeEffortsAvailable: true
            ),
            .claudeEffortLevel
        )
    }

    func testRejectsAgentsWithoutEffortPicker() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .openCode,
                codexEffortsAvailable: false,
                claudeEffortsAvailable: false
            )
        )
    }

    func testRejectsClaudeWhenOnlyCodexEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .claudeCode,
                codexEffortsAvailable: true,
                claudeEffortsAvailable: false
            )
        )
    }

    func testRejectsCodexWhenOnlyClaudeEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .codexExec,
                codexEffortsAvailable: false,
                claudeEffortsAvailable: true
            )
        )
    }

    func testRejectsCodexWhenNoEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .codexExec,
                codexEffortsAvailable: false
            )
        )
    }

    func testRejectsClaudeWhenNoEffortsAreAvailable() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .claudeCode,
                claudeEffortsAvailable: false
            )
        )
    }

    func testRejectsMismatchedWindow() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                requestWindowID: 41,
                composerWindowID: 42,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            )
        )
    }

    func testRejectsMissingWindow() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                requestWindowID: nil,
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            )
        )
    }

    func testRejectsMismatchedTab() {
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: UUID(),
                propsCurrentTabID: UUID(),
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            )
        )
    }

    func testRejectsMissingProviders() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                hasAvailableAgentProviders: false,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            )
        )
    }

    func testRejectsDisabledModelControls() {
        let tabID = UUID()
        XCTAssertNil(
            effortPickerShortcutTarget(
                composerCurrentTabID: tabID,
                propsCurrentTabID: tabID,
                modelControlsDisabled: true,
                selectedAgent: .codexExec,
                codexEffortsAvailable: true
            )
        )
    }

    private func effortPickerShortcutTarget(
        requestWindowID: Int? = 42,
        composerWindowID: Int = 42,
        composerCurrentTabID: UUID?,
        propsCurrentTabID: UUID?,
        hasAvailableAgentProviders: Bool = true,
        modelControlsDisabled: Bool = false,
        selectedAgent: AgentProviderKind,
        codexEffortsAvailable: Bool = false,
        claudeEffortsAvailable: Bool = false
    ) -> AgentEffortPickerOpenTarget? {
        AgentEffortPickerOpenRequestGuard.target(
            requestWindowID: requestWindowID,
            composerWindowID: composerWindowID,
            composerCurrentTabID: composerCurrentTabID,
            propsCurrentTabID: propsCurrentTabID,
            hasAvailableAgentProviders: hasAvailableAgentProviders,
            modelControlsDisabled: modelControlsDisabled,
            selectedAgent: selectedAgent,
            codexEffortsAvailable: codexEffortsAvailable,
            claudeEffortsAvailable: claudeEffortsAvailable
        )
    }
}
