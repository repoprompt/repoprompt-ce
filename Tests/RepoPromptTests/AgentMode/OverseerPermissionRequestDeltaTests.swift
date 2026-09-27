import Foundation
@testable import RepoPromptApp
import XCTest

final class OverseerPermissionRequestDeltaTests: XCTestCase {
    func testPreexistingPromptIsNeverSweptWhenAnotherRequestChanges() {
        var delta = OverseerPermissionRequestDelta()
        let preexistingApproval = UUID()
        let newPermissionsRequest = UUID()

        delta.observe([preexistingApproval])
        XCTAssertTrue(delta.newRequestIDs.isEmpty, "subscription must not accept an existing prompt")

        delta.observe([preexistingApproval, newPermissionsRequest])
        XCTAssertEqual(delta.newRequestIDs, [newPermissionsRequest])

        delta.observe([preexistingApproval])
        XCTAssertTrue(delta.newRequestIDs.isEmpty)
        delta.observe([preexistingApproval, newPermissionsRequest])
        XCTAssertEqual(delta.newRequestIDs, [newPermissionsRequest])
    }

    func testOnlyReplacementPromptIsNew() {
        var delta = OverseerPermissionRequestDelta()
        let old = UUID()
        let replacement = UUID()

        delta.observe([old])
        delta.observe([replacement])
        XCTAssertEqual(delta.newRequestIDs, [replacement])
    }
}
