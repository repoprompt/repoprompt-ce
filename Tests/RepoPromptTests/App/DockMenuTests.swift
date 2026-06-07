import Cocoa
@testable import RepoPrompt
import XCTest

@MainActor
final class DockMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppWindowOpener.shared.resetForTesting()
    }

    override func tearDown() {
        AppWindowOpener.shared.resetForTesting()
        super.tearDown()
    }

    func testDockNewWindowMenuItemMetadataAndNilSenderRouting() throws {
        var requestCount = 0
        let controller = DockMenuController {
            requestCount += 1
        }

        let menu = controller.makeMenu()
        XCTAssertEqual(menu.items.count, 1)

        let item = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(item.title, "New Window")
        XCTAssertTrue(item.target === controller)
        XCTAssertNotNil(item.action)
        XCTAssertTrue(item.isEnabled)

        let didSend = try NSApplication.shared.sendAction(
            XCTUnwrap(item.action),
            to: item.target,
            from: nil
        )
        XCTAssertTrue(didSend)
        XCTAssertEqual(requestCount, 1)
    }

    func testDockRequestsQueueUntilOpenerIsInstalled() throws {
        var openCount = 0
        let controller = DockMenuController()
        let item = try XCTUnwrap(controller.makeMenu().items.first)
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertFalse(AppWindowOpener.shared.isAvailable)
        XCTAssertEqual(openCount, 0)

        AppWindowOpener.shared.install {
            openCount += 1
        }
        XCTAssertEqual(openCount, 2)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertEqual(openCount, 3)
    }

    func testThrowingOpenMainWindowStillReportsUnavailableOpener() {
        XCTAssertThrowsError(try AppWindowOpener.shared.openMainWindow()) { error in
            guard let windowError = error as? WindowOpenError,
                  case .openerUnavailable = windowError
            else {
                return XCTFail("Expected WindowOpenError.openerUnavailable, got \(error)")
            }
        }
    }
}
