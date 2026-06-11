import AppKit
@testable import RepoPrompt
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

        let approvalTask = Task { @MainActor in
            await manager.requestApproval(for: request)
        }
        try await waitUntil { manager.pendingRequest?.id == request.id }
        XCTAssertTrue(manager.isApprovalOverlayVisible)

        approvalTask.cancel()
        let result = await approvalTask.value

        guard case .denied = result else {
            return XCTFail("Expected cancelled approval wait to resolve as denied, got \(result)")
        }
        XCTAssertNil(manager.pendingRequest)
        XCTAssertFalse(manager.isApprovalOverlayVisible)
    }

    func testCancellingQueuedApprovalLeavesActiveRequestPending() async throws {
        let manager = WorkspaceApprovalManager.shared
        let activeRequest = makeRequest(label: "active")
        let queuedRequest = makeRequest(label: "queued")

        let activeTask = Task { @MainActor in
            await manager.requestApproval(for: activeRequest)
        }
        try await waitUntil { manager.pendingRequest?.id == activeRequest.id }

        let queuedTask = Task { @MainActor in
            await manager.requestApproval(for: queuedRequest)
        }
        try await waitUntil { manager.pendingQueueCountForTesting == 1 }

        queuedTask.cancel()
        let queuedResult = await queuedTask.value

        guard case .denied = queuedResult else {
            return XCTFail("Expected cancelled queued approval to resolve as denied, got \(queuedResult)")
        }
        XCTAssertEqual(manager.pendingRequest?.id, activeRequest.id)
        XCTAssertEqual(manager.pendingQueueCountForTesting, 0)
        XCTAssertTrue(manager.isApprovalOverlayVisible)

        manager.resolveApproval(allow: false)
        let activeResult = await activeTask.value
        guard case .denied = activeResult else {
            return XCTFail("Expected explicit denial for the active request, got \(activeResult)")
        }
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

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
