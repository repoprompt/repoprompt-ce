import AppKit
import Combine
import Foundation
import RepoPromptApp
import XCTest

/// Pins the presentation scope of workspace approvals.
///
/// `WorkspaceApprovalManager` is a process-wide singleton observed by every window,
/// so a request that names a target window must be presented by that window alone.
/// The fallback below is what keeps that scoping from making a request unanswerable.
@MainActor
final class WorkspaceApprovalWindowScopeTests: XCTestCase {
    private let targetWindowID = 7777
    private let unrelatedWindowID = 3

    override func setUp() {
        super.setUp()
        // The presenter touches NSApp; without a realized NSApplication it is nil.
        _ = NSApplication.shared
    }

    // MARK: - Scope policy

    func testTargetedApprovalIsPresentedOnlyByItsOwnWindow() {
        XCTAssertTrue(
            WorkspaceApprovalPresentationPolicy.shouldPresent(
                targetWindowID: targetWindowID,
                inWindowID: targetWindowID
            )
        )
        XCTAssertFalse(
            WorkspaceApprovalPresentationPolicy.shouldPresent(
                targetWindowID: targetWindowID,
                inWindowID: unrelatedWindowID
            ),
            "An approval targeted at another window must not be presented here."
        )
    }

    func testUntargetedApprovalIsPresentedByEveryWindow() {
        XCTAssertTrue(
            WorkspaceApprovalPresentationPolicy.shouldPresent(
                targetWindowID: nil,
                inWindowID: targetWindowID
            )
        )
        XCTAssertTrue(
            WorkspaceApprovalPresentationPolicy.shouldPresent(
                targetWindowID: nil,
                inWindowID: unrelatedWindowID
            )
        )
    }

    // MARK: - Liveness fallback (drives the real approval broker)

    /// A request naming a window that is not live must still reach a window that can
    /// answer it, otherwise window scoping would strand it until the broker deadline.
    func testApprovalForANonLiveWindowFallsBackToAppWidePresentation() async throws {
        let manager = WorkspaceApprovalManager.shared
        let clientID = "window-scope-probe-\(UUID().uuidString)"
        try XCTSkipIf(
            manager.settings.shouldAutoApprove(operation: .addFolder, clientID: clientID),
            "A local auto-approval policy would bypass presentation entirely."
        )

        let request = WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .addFolder,
            workspaceName: "ScopeProbe",
            workspaceID: UUID(),
            folderPath: "/tmp/workspace-approval-scope-probe",
            windowID: targetWindowID
        )

        let pending = Task { await manager.requestApproval(for: request) }
        try await waitUntilPresented(manager, requestID: request.id)

        XCTAssertEqual(
            manager.pendingRequest?.windowID,
            targetWindowID,
            "The request must keep its original target for cancellation and display."
        )
        XCTAssertNil(
            manager.presentedTargetWindowID,
            "No window with that ID is live, so presentation must fall back to app-wide."
        )
        XCTAssertTrue(
            WorkspaceApprovalPresentationPolicy.shouldPresent(
                targetWindowID: manager.presentedTargetWindowID,
                inWindowID: unrelatedWindowID
            ),
            "The fallback must leave some window able to answer the request."
        )

        manager.resolveApproval(requestID: request.id, respondingWindowID: unrelatedWindowID, allow: true)
        let result = await pending.value
        XCTAssertTrue(result.isApproved)
        XCTAssertNil(manager.pendingRequest)
        XCTAssertNil(manager.presentedTargetWindowID)
    }

    private func waitUntilPresented(_ manager: WorkspaceApprovalManager, requestID: UUID) async throws {
        let presented = expectation(description: "Request presented")
        let observation = manager.$pendingRequest
            .first { $0?.id == requestID }
            .sink { _ in presented.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [presented], timeout: 5)
        XCTAssertEqual(manager.pendingRequest?.id, requestID)
    }
}
