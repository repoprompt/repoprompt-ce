import AppKit
import Combine
@testable import RepoPromptApp
import XCTest

/// Regression coverage for cancellation-aware workspace approval waits: a cancelled
/// caller (for example a bounded tool-execution watchdog) must settle as `.denied`
/// instead of parking forever on the approval continuation while the operation's
/// side effects remain pending behind the dialog.
@MainActor
final class WorkspaceApprovalCancellationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        WorkspaceApprovalManager.shared.cancelAllPending()
        WorkspaceApprovalManager.shared.setAutoApproveAll(false)
        WorkspaceApprovalManager.shared.setAutoApproveOperation(.createWorkspace, enabled: false)
    }

    override func tearDown() {
        WorkspaceApprovalManager.shared.cancelAllPending()
        super.tearDown()
    }

    func testCancellingAwaitedApprovalResolvesDeniedAndClearsOverlay() async throws {
        let manager = WorkspaceApprovalManager.shared
        let request = makeRequest(label: "active-cancel")
        let presented = expectation(description: "workspace approval presented")
        let presentationObservation = manager.$pendingRequest
            .compactMap { $0 }
            .filter { $0.id == request.id }
            .prefix(1)
            .sink { _ in presented.fulfill() }

        let approvalTask = Task { @MainActor in
            await manager.requestApproval(for: request)
        }
        await fulfillment(of: [presented], timeout: 2)
        presentationObservation.cancel()
        XCTAssertTrue(manager.isApprovalOverlayVisible)

        approvalTask.cancel()
        let result = await approvalTask.value

        guard case .denied = result else {
            return XCTFail("Expected cancelled approval wait to resolve as denied, got \(result)")
        }
        XCTAssertNil(manager.pendingRequest)
        XCTAssertFalse(manager.isApprovalOverlayVisible)
    }

    func testApprovalRequestedFromCancelledTaskResolvesDeniedWithoutPresentingOverlay() async {
        let manager = WorkspaceApprovalManager.shared
        let request = makeRequest(label: "pre-cancelled")

        let approvalTask = Task { @MainActor () -> WorkspaceApprovalResult in
            while !Task.isCancelled {
                await Task.yield()
            }
            return await manager.requestApproval(for: request)
        }
        approvalTask.cancel()
        let result = await approvalTask.value

        guard case .denied = result else {
            return XCTFail("Expected pre-cancelled approval request to resolve as denied, got \(result)")
        }
        XCTAssertNil(manager.pendingRequest)
        XCTAssertFalse(manager.isApprovalOverlayVisible)
    }

    private func makeRequest(label: String) -> WorkspaceApprovalRequest {
        WorkspaceApprovalRequest(
            clientID: "approval-cancellation-tests-\(label)-\(UUID().uuidString)",
            operation: .createWorkspace,
            workspaceName: "Approval Cancellation \(label)",
            windowID: nil
        )
    }
}
