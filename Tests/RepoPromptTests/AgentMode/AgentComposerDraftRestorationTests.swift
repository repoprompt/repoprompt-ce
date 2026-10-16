import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentComposerDraftRestorationTests: XCTestCase {
    func testCoalescedManualAndQueuedRecoveriesRestoreEachFragmentOnce() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreRejectedManualSubmissionComposerState(
            tabID: tabID,
            session: session,
            draftText: "B",
            images: [],
            taggedFiles: [],
            selectedWorkflow: nil,
            selectedWorkflowMutationGeneration: nil,
            message: "Failed start"
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )

        let finalEvent = try XCTUnwrap(viewModel.draftRestorationEvent)
        let operation = try XCTUnwrap(finalEvent.operation)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB\nD")
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                operation,
                to: "D",
                acknowledgedSequence: 0
            ),
            "C\nB\nD"
        )
    }

    func testConsumedRecoveryAndNewerTypingAreNotDuplicated() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "B",
            message: "Failed start",
            strategy: .prependAlways
        )
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(firstEditorText, "B\nD")

        let editedText = firstEditorText + "\nnew typing"
        viewModel.storeDraftText(
            for: tabID,
            editedText,
            acknowledgingThrough: firstOperation.fragments.last?.sequence ?? 0
        )
        viewModel.restoreComposerDraft(
            tabID: tabID,
            text: "C",
            message: "Stopped queued work",
            strategy: .prependAlways
        )
        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: editedText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nD\nnew typing"
        )
    }

    func testSkippedIntermediateRecoveryStillAppliesOnlyMissingFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let firstOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let firstEditorText = AgentComposerDraftRestorationReducer.apply(
            firstOperation,
            to: "D",
            acknowledgedSequence: 0
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let finalOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                finalOperation,
                to: firstEditorText,
                acknowledgedSequence: firstOperation.fragments.last?.sequence ?? 0
            ),
            "C\nB\nA\nD"
        )
    }

    func testInterleavedTabsRetainEachTabsUnconsumedFragments() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        let otherTabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")

        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: otherTabID, text: "X", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["A", "B"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "D",
            acknowledgedSequence: 0
        )
        XCTAssertEqual(editorText, "B\nA\nD")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "B\nA\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
        XCTAssertEqual(viewModel.draftRestorationLedger.tabs[otherTabID]?.pendingFragments.map(\.text), ["X"])
    }

    func testStaleEditorStorePreservesRecoveryPendingAtTabSwitch() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.storeDraftText(for: tabID, "D")
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)

        // The old editor value is stored as the tab changes before it sees A.
        viewModel.storeDraftText(for: tabID, "D", acknowledgingThrough: 0)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "A\nD")
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A\nD")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    func testLoadedSnapshotAndDeletionDoNotResurrectAcknowledgedRecovery() throws {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.restoreComposerDraft(tabID: tabID, text: "A", message: "", strategy: .prependAlways)
        let oldOperation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        let snapshot = viewModel.loadDraftSnapshotForComposer(for: tabID)
        XCTAssertEqual(snapshot.text, "A")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)

        viewModel.storeDraftText(for: tabID, "", acknowledgingThrough: snapshot.restorationSequence)
        XCTAssertEqual(
            AgentComposerDraftRestorationReducer.apply(
                oldOperation,
                to: "",
                acknowledgedSequence: snapshot.restorationSequence
            ),
            ""
        )
        viewModel.restoreComposerDraft(tabID: tabID, text: "B", message: "", strategy: .prependAlways)
        viewModel.restoreComposerDraft(tabID: tabID, text: "C", message: "", strategy: .prependAlways)

        let operation = try XCTUnwrap(viewModel.draftRestorationEvent?.operation)
        XCTAssertEqual(operation.fragments.map(\.text), ["B", "C"])
        let editorText = AgentComposerDraftRestorationReducer.apply(
            operation,
            to: "",
            acknowledgedSequence: snapshot.restorationSequence
        )
        XCTAssertEqual(editorText, "C\nB")
        viewModel.storeDraftText(
            for: tabID,
            editorText,
            acknowledgingThrough: operation.fragments.last?.sequence ?? 0
        )
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "C\nB")
        XCTAssertTrue(viewModel.draftRestorationLedger.tabs[tabID]?.pendingFragments.isEmpty == true)
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Draft restoration tests must not start Codex")
            },
            headlessProviderFactory: { _, _ in
                UnsupportedHeadlessAgentProvider(reason: "draft restoration test")
            }
        )
    }
}
