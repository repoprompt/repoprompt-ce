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
