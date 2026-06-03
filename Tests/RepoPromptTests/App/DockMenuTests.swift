import Cocoa
@testable import RepoPrompt
import XCTest

@MainActor
final class DockMenuTests: XCTestCase {
    func testDockNewWindowMenuItemReflectsOpenerAvailability() throws {
        defer { AppWindowOpener.shared.resetForTesting() }

        let delegate = AppDelegate()

        AppWindowOpener.shared.resetForTesting()
        let unavailableItem = try newWindowDockMenuItem(from: delegate)
        XCTAssertEqual(unavailableItem.title, "New Window")
        XCTAssertTrue(unavailableItem.target === delegate)
        XCTAssertNotNil(unavailableItem.action)
        XCTAssertFalse(unavailableItem.isEnabled)

        AppWindowOpener.shared.installForTesting {}
        let availableItem = try newWindowDockMenuItem(from: delegate)
        XCTAssertEqual(availableItem.title, "New Window")
        XCTAssertTrue(availableItem.target === delegate)
        XCTAssertNotNil(availableItem.action)
        XCTAssertTrue(availableItem.isEnabled)
    }

    private func newWindowDockMenuItem(from delegate: AppDelegate) throws -> NSMenuItem {
        let menu = try XCTUnwrap(delegate.applicationDockMenu(NSApplication.shared))
        XCTAssertEqual(menu.items.count, 1)
        return try XCTUnwrap(menu.items.first)
    }
}
