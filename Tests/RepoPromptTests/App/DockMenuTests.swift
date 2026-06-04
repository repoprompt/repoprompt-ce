import Cocoa
@testable import RepoPrompt
import XCTest

@MainActor
final class DockMenuTests: XCTestCase {
    func testDockNewWindowMenuItemIsAlwaysEnabled() throws {
        let delegate = AppDelegate()

        let item = try newWindowDockMenuItem(from: delegate)
        XCTAssertEqual(item.title, "New Window")
        XCTAssertTrue(item.target === delegate)
        XCTAssertNotNil(item.action)
        XCTAssertTrue(item.isEnabled)
    }

    private func newWindowDockMenuItem(from delegate: AppDelegate) throws -> NSMenuItem {
        let menu = try XCTUnwrap(delegate.applicationDockMenu(NSApplication.shared))
        XCTAssertEqual(menu.items.count, 1)
        return try XCTUnwrap(menu.items.first)
    }
}
