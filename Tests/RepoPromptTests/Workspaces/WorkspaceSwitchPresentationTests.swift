import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceSwitchPresentationTests: XCTestCase {
    func testStaleConfirmationDismissalBindingCannotResolveReplacementConfirmation() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()
        manager.registerSwitchSessionProvider(PresentationWorkspaceSwitchSessionProvider())

        let firstTarget = manager.createWorkspace(
            name: "Presentation First \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let firstRequest = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: firstTarget, reason: "presentationFirst")
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let firstID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)
        let staleBinding = WorkspaceSwitchConfirmationModifier.confirmationPresentationBinding(
            manager: manager,
            confirmationID: firstID
        )
        manager.resolveSwitchConfirmation(id: firstID, allow: false)
        _ = await firstRequest.value

        let secondTarget = manager.createWorkspace(
            name: "Presentation Second \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let secondRequest = Task { @MainActor in
            await manager.requestWorkspaceSwitch(to: secondTarget, reason: "presentationSecond")
        }
        try await waitUntil { manager.pendingSwitchConfirmation != nil }
        let secondID = try XCTUnwrap(manager.pendingSwitchConfirmation?.id)

        staleBinding.wrappedValue = false

        XCTAssertEqual(manager.pendingSwitchConfirmation?.id, secondID)
        XCTAssertTrue(manager.hasPendingSwitchConfirmation)
        manager.resolveSwitchConfirmation(id: secondID, allow: false)
        _ = await secondRequest.value
    }

    func testBlockedResultsPublishSharedNoticeAndStaleDismissalCannotClearReplacement() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()

        manager.isRefreshing = true
        let firstTarget = manager.createWorkspace(
            name: "Blocked Notice First Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let firstResult = await manager.requestWorkspaceSwitch(to: firstTarget, reason: "blockedNoticeFirst")
        guard case let .blocked(firstMessage) = firstResult else {
            return XCTFail("Expected refresh-state request to be blocked")
        }
        let firstNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertEqual(firstNotice.message, firstMessage)
        let staleBinding = WorkspaceSwitchConfirmationModifier.blockedNoticePresentationBinding(
            manager: manager,
            noticeID: firstNotice.id
        )

        let target = manager.createWorkspace(
            name: "Blocked Notice Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let secondResult = await manager.requestWorkspaceSwitch(to: target, reason: "blockedNoticeSecond")
        guard case let .blocked(secondMessage) = secondResult else {
            return XCTFail("Expected refresh-state request to be blocked")
        }
        let secondNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertEqual(secondNotice.message, secondMessage)
        XCTAssertNotEqual(firstNotice.id, secondNotice.id)

        staleBinding.wrappedValue = false

        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.id, secondNotice.id)
        let currentBinding = WorkspaceSwitchConfirmationModifier.blockedNoticePresentationBinding(
            manager: manager,
            noticeID: secondNotice.id
        )
        currentBinding.wrappedValue = false
        XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        manager.isRefreshing = false
    }

    func testActiveWorkspaceRequestIsBlockedWithoutPublishingNotice() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()
        let active = try XCTUnwrap(manager.activeWorkspace)

        let result = await manager.requestWorkspaceSwitch(to: active, reason: "sameWorkspaceNoOp")

        guard case let .blocked(message) = result else {
            return XCTFail("Expected active-workspace request to be blocked")
        }
        XCTAssertEqual(message, "Already on workspace \"\(active.name)\".")
        XCTAssertNil(
            manager.pendingWorkspaceSwitchBlockedNotice,
            "Benign same-workspace requests (launch restore, save-and-exit on the fallback, MCP switch to current) must not raise the blocked alert"
        )
    }

    func testSuccessfulSwitchDoesNotClearUnrelatedBlockedNotice() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()

        manager.isRefreshing = true
        let blockedTarget = manager.createWorkspace(
            name: "Unrelated Blocked Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        guard case .blocked = await manager.requestWorkspaceSwitch(
            to: blockedTarget,
            reason: "unrelatedNotice"
        ) else {
            return XCTFail("Expected refresh-state request to publish a blocked notice")
        }
        manager.isRefreshing = false
        let unrelatedNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertNil(unrelatedNotice.blockingOperationID)
        let target = manager.createWorkspace(
            name: "Unrelated Notice Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )

        let switchResult = await manager.requestWorkspaceSwitch(
            to: target,
            saveState: false,
            reason: "successfulSwitchWithUnrelatedNotice"
        )
        XCTAssertEqual(switchResult, .switched)
        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.id, unrelatedNotice.id)
    }

    func testBlockedNoticeOwnershipDoesNotMatchNewerUnrelatedNotice() {
        let owningOperationID = UUID()
        let relatedNotice = WorkspaceSwitchBlockedNotice(
            message: "related",
            blockingOperationID: owningOperationID
        )
        let newerUnrelatedNotice = WorkspaceSwitchBlockedNotice(
            message: "newer unrelated",
            blockingOperationID: UUID()
        )

        XCTAssertTrue(relatedNotice.isBlocked(by: owningOperationID))
        XCTAssertFalse(newerUnrelatedNotice.isBlocked(by: owningOperationID))
    }

    private func makeComposition() -> WindowStateComposition {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowStateCompositionFactory.make(
            windowID: -1000 - Int.random(in: 1 ... 99),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
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

@MainActor
private final class PresentationWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        [WorkspaceSwitchSessionItem(
            id: "presentation",
            count: 1,
            singularLabel: "presentation session",
            pluralLabel: "presentation sessions"
        )]
    }

    func cancelSwitchSessions() async {}
}
