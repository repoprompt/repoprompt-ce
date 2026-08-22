import AppKit
@testable import RepoPromptApp
import XCTest

final class AppIconControllerTests: XCTestCase {
    func testExplicitModesRemainExplicit() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(AppIconMode.light.resolved(for: darkAppearance), .light)
        XCTAssertEqual(AppIconMode.dark.resolved(for: lightAppearance), .dark)
    }

    func testSystemModeFollowsEffectiveAppearance() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(AppIconMode.system.resolved(for: lightAppearance), .light)
        XCTAssertEqual(AppIconMode.system.resolved(for: darkAppearance), .dark)
    }
}
