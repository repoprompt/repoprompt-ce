#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import RepoPromptShared
    import XCTest

    /// Behavioral guard for repoprompt-ce #419.
    ///
    /// The search-readiness convergence loop in `loadWorkspaceFolders` is uncancellable
    /// by construction (its guards check hydration but never `Task.isCancelled`) and had
    /// no iteration cap, so under multi-window catalog churn it could spin indefinitely on
    /// the MainActor — wedging `switchWorkspace` and `agent_run` provisioning until the MCP
    /// client idle timeout. This test drives the loop into a deterministic non-converging
    /// state and asserts the cap bounds it.
    ///
    /// On a regression (cap removed), `switchWorkspace` never returns and the test fails via
    /// the XCTest watchdog rather than an assertion — the accepted trade for an unbounded-loop
    /// defect, matching `HeadlessAgentConnectionGateDeadlineTests`.
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
                workspaceSearchService: searchService
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

            let clock = ContinuousClock()
            let start = clock.now
            let result = await manager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "convergenceCapTest"
            )
            let elapsed = start.duration(to: clock.now)

            XCTAssertEqual(
                result,
                .switched,
                "switch must commit even when the index never converges (repoprompt-ce #419)"
            )
            XCTAssertLessThan(
                elapsed,
                .seconds(10),
                "the convergence loop must be bounded by the cap, not spin on the MainActor (repoprompt-ce #419)"
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
