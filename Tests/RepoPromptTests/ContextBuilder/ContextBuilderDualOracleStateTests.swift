import enum MCP.Value
@testable import RepoPromptApp
import XCTest

final class ContextBuilderDualOracleStateTests: XCTestCase {
    @MainActor
    func testPairedPublicationKeepsPrimaryPreviewAndAttributedFailure() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -931)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let primary = UUID()
            let secondary = UUID()
            let generation = viewModel.beginBackgroundPlanGenerationForTesting(tabID: fixture.tabID)

            try viewModel.publishFollowUpOracleSessionIDsForTesting(
                [primary, secondary],
                primarySessionID: primary,
                tabID: fixture.tabID,
                generation: generation
            )
            viewModel.publishPrimaryProgressForTesting(
                text: "Primary preview",
                reasoning: "Primary reasoning",
                tabID: fixture.tabID,
                generation: generation
            )
            viewModel.publishLaneOutcomeForTesting(
                lane: .secondary,
                outcome: .failed("Secondary unavailable"),
                tabID: fixture.tabID,
                generation: generation
            )

            var state = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertEqual(state.sessionIDs, [primary, secondary])
            XCTAssertEqual(state.chatID, primary.uuidString)
            XCTAssertEqual(state.response, "Primary preview")
            XCTAssertEqual(state.reasoning, "Primary reasoning")
            XCTAssertEqual(state.error, "Secondary Oracle failed: Secondary unavailable")

            try viewModel.publishFollowUpCompletionForTesting(
                primaryChatID: "primary-short",
                primaryResponse: "Primary partial response",
                failureSummary: "Secondary Oracle failed: Secondary unavailable",
                tabID: fixture.tabID,
                generation: generation
            )
            state = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertFalse(state.isGenerating)
            XCTAssertTrue(state.sessionIDs.isEmpty)
            XCTAssertEqual(state.chatID, "primary-short")
            XCTAssertEqual(state.response, "Primary partial response")
            XCTAssertEqual(state.error, "Secondary Oracle failed: Secondary unavailable")
        #endif
    }

    @MainActor
    func testReplacementCancelsOldLanesAndRejectsStaleCallbacks() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -932)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let recorder = CancellationRecorder()
            viewModel.installRunTestHooks(ContextBuilderAgentViewModel.RunTestHooks(
                beforeProcessingProviderEvent: nil,
                providerEventDisposition: nil,
                teardownCompleted: nil,
                cancelFollowUpOracleSession: { sessionID in
                    await recorder.record(sessionID)
                }
            ))
            defer { viewModel.installRunTestHooks(nil) }

            let oldPrimary = UUID()
            let oldSecondary = UUID()
            let oldGeneration = viewModel.beginBackgroundPlanGenerationForTesting(tabID: fixture.tabID)
            try viewModel.publishFollowUpOracleSessionIDsForTesting(
                [oldPrimary, oldSecondary],
                primarySessionID: oldPrimary,
                tabID: fixture.tabID,
                generation: oldGeneration
            )

            let newGeneration = viewModel.beginBackgroundPlanGenerationForTesting(tabID: fixture.tabID)
            await viewModel.waitForBackgroundPlanCancellationForTesting(tabID: fixture.tabID)
            let replacedCancellationIDs = await recorder.snapshot()
            XCTAssertEqual(Set(replacedCancellationIDs), [oldPrimary, oldSecondary])

            XCTAssertThrowsError(try viewModel.publishFollowUpOracleSessionIDsForTesting(
                [UUID()],
                primarySessionID: UUID(),
                tabID: fixture.tabID,
                generation: oldGeneration
            )) { error in
                XCTAssertTrue(error is CancellationError)
            }
            viewModel.publishPrimaryProgressForTesting(
                text: "stale",
                reasoning: nil,
                tabID: fixture.tabID,
                generation: oldGeneration
            )
            viewModel.publishLaneOutcomeForTesting(
                lane: .secondary,
                outcome: .failed("stale lane failure"),
                tabID: fixture.tabID,
                generation: oldGeneration
            )

            let newPrimary = UUID()
            try viewModel.publishFollowUpOracleSessionIDsForTesting(
                [newPrimary],
                primarySessionID: newPrimary,
                tabID: fixture.tabID,
                generation: newGeneration
            )
            var state = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertEqual(state.sessionIDs, [newPrimary])
            XCTAssertNil(state.response)
            XCTAssertNil(state.error)

            viewModel.cancelBackgroundPlanGeneration(forTabID: fixture.tabID)
            await viewModel.waitForBackgroundPlanCancellationForTesting(tabID: fixture.tabID)
            let cancelled = await recorder.snapshot()
            XCTAssertEqual(cancelled.count(where: { $0 == oldPrimary }), 1)
            XCTAssertEqual(cancelled.count(where: { $0 == oldSecondary }), 1)
            XCTAssertEqual(cancelled.count(where: { $0 == newPrimary }), 1)
            state = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertFalse(state.isGenerating)
            XCTAssertTrue(state.sessionIDs.isEmpty)
            XCTAssertNil(state.chatID)
            XCTAssertNil(state.error)
        #endif
    }

    @MainActor
    func testHistoryPersistenceFailureProducesLiveWarning() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -934)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let warning = viewModel.oraclePairFailureSummaryForTesting(from: [
                "oracle_results": .object([
                    OracleLane.secondary.rawValue: .object([
                        "status": .string("failed"),
                        "error": .string("provider unavailable")
                    ])
                ]),
                "oracle_pair_history_persistence_error": .string("disk unavailable")
            ])

            XCTAssertEqual(
                warning,
                "Secondary Oracle failed: provider unavailable\nOracle pair history persistence failed: disk unavailable"
            )
        #endif
    }

    @MainActor
    func testPrimaryOnlyPublicationNeverCreatesPhantomSecondaryState() async throws {
        #if DEBUG
            let fixture = try await makeFixture(windowID: -933)
            defer { fixture.cleanup() }
            let viewModel = fixture.composition.contextBuilderAgentViewModel
            let primary = UUID()
            let generation = viewModel.beginBackgroundPlanGenerationForTesting(tabID: fixture.tabID)

            try viewModel.publishFollowUpOracleSessionIDsForTesting(
                [primary],
                primarySessionID: primary,
                tabID: fixture.tabID,
                generation: generation
            )
            let live = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertEqual(live.sessionIDs, [primary])

            try viewModel.publishFollowUpCompletionForTesting(
                primaryChatID: "primary-only",
                primaryResponse: "Primary response",
                failureSummary: nil,
                tabID: fixture.tabID,
                generation: generation
            )
            let completed = viewModel.backgroundPlanStateForTesting(tabID: fixture.tabID)
            XCTAssertTrue(completed.sessionIDs.isEmpty)
            XCTAssertEqual(completed.response, "Primary response")
            XCTAssertNil(completed.error)
        #endif
    }

    @MainActor
    private func makeFixture(windowID: Int) async throws -> Fixture {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition = WindowStateCompositionFactory.make(
            windowID: windowID,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await composition.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderDualOracleStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = composition.workspaceManager.createWorkspace(
            name: "Dual Oracle state test",
            repoPaths: [root.path],
            ephemeral: true
        )
        await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "ContextBuilderDualOracleStateTests"
        )
        let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id)
        return Fixture(composition: composition, tabID: tabID, root: root)
    }
}

@MainActor
private struct Fixture {
    let composition: WindowStateComposition
    let tabID: UUID
    let root: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor CancellationRecorder {
    private var sessionIDs: [UUID] = []

    func record(_ sessionID: UUID) {
        sessionIDs.append(sessionID)
    }

    func snapshot() -> [UUID] {
        sessionIDs
    }
}
