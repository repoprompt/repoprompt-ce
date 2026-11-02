import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class WorkspaceSwitchPresentationTests: XCTestCase {
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

#if DEBUG

    /// A nonconverging catalog/index barrier must use a bounded number of rebuilds,
    /// not hold workspace switching indefinitely. Assert operation counts, not timings.
    @MainActor
    final class WorkspaceSearchIndexConvergenceCapTests: XCTestCase {
        func testConvergenceLoopIsBoundedWhenIndexNeverConverges() async throws {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            let defaults = UserDefaults.standard
            let previousStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("convergence-cap-storage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            defaults.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            defer {
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
                if let previousStoragePath {
                    defaults.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    defaults.removeObject(forKey: "GlobalCustomStorageURL")
                }
                try? FileManager.default.removeItem(at: storageRoot)
            }

            let searchService = WorkspaceSearchService()
            let rebuildCounter = RebuildCounter()
            // Always report a generation one behind the live catalog, so the loop's
            // `currentCatalogGeneration != indexGeneration` guard can never be false.
            await searchService.setRebuildIndexReportedGenerationTransformForTesting { generation in
                rebuildCounter.increment()
                return generation &- 1
            }

            let composition = WindowStateCompositionFactory.make(
                windowID: -600 - Int.random(in: 1 ... 99),
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceSearchService: searchService,
                loadStoredAPISettingsDataOnInit: false,
                automaticProviderModelDiscoveryEnabled: false
            )
            let manager = composition.workspaceManager
            await manager.awaitInitialized()
            // The composition's initial workspace activation also hydrates through the
            // convergence loop; reset so the count reflects only this switch.
            rebuildCounter.reset()

            let workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("convergence-cap-ws-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: workspaceRoot.appendingPathComponent("Sources"),
                withIntermediateDirectories: true
            )
            try "one\ntwo\nthree\n".write(
                to: workspaceRoot.appendingPathComponent("Sources/Selected.swift"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: workspaceRoot) }

            let workspace = manager.createWorkspace(
                name: "Convergence Cap Test \(UUID().uuidString.prefix(8))",
                repoPaths: [workspaceRoot.path],
                ephemeral: true
            )

            let result = await manager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "convergenceCapTest"
            )

            XCTAssertEqual(
                result,
                .switched,
                "switch must commit even when the index never converges (repoprompt-ce #419)"
            )
            XCTAssertEqual(
                rebuildCounter.value,
                1 + WorkspaceManagerViewModel.maxSearchIndexConvergenceRebuilds,
                "rebuildIndex must run once for the pre-loop build plus exactly maxSearchIndexConvergenceRebuilds capped loop passes (repoprompt-ce #419)"
            )
        }
    }

    private final class RebuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
#endif
