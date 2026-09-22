import Foundation
@testable import RepoPromptApp
import XCTest

final class ModelRouterSettingsNavigationTests: XCTestCase {
    func testRouterSectionFollowsAgentModeAndOwnsOnlyModelRouterTab() {
        XCTAssertEqual(SettingsView.sidebarSectionOrder.prefix(2), [.agentMode, .router])
        XCTAssertEqual(SettingsTab.modelRouter.section, .router)
        XCTAssertEqual(SettingsTab.allCases.filter { $0.section == .router }, [.modelRouter])
        XCTAssertEqual(SettingsTab.modelRouter.title, "Model Router")
    }

    func testRouterDeepLinkNotificationHasDedicatedIdentity() {
        XCTAssertEqual(Notification.Name.showModelRouterSettingsTab.rawValue, "showModelRouterSettingsTab")
        XCTAssertNotEqual(Notification.Name.showModelRouterSettingsTab, .showAgentModeSettingsTab)
    }
}
