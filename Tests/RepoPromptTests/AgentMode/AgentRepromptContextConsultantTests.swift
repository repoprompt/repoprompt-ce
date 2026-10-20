import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRepromptContextConsultantTests: XCTestCase {
    func testNoneStartsNothingAndBothStartBeforeAwaitingAnswers() async {
        var starts: [String] = []
        let consultant = AgentRepromptContextConsultant(
            oracle: { _ in starts.append("oracle")
                return .init(result: .init(kind: .oracle, status: "success", text: "answer"))
            },
            contextBuilder: { _ in starts.append("builder")
                return .init(result: .init(kind: .contextBuilder, status: "success", text: "files"))
            },
            readSelection: { nil }, restoreSelection: { _ in XCTFail("No selection to restore") }
        )
        consultant.start([])
        let empty = await consultant.results()
        XCTAssertTrue(empty.isEmpty)
        consultant.start([.init(kind: .oracle, question: "pattern?"), .init(kind: .contextBuilder, instructions: "find files")])
        for _ in 0 ..< 20 where starts.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(Set(starts), ["oracle", "builder"])
        let results = await consultant.results()
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status == "success" })
    }

    func testSelectionRestoresOnlyWhenStillEqualToCommittedSelection() async {
        for userEdited in [false, true] {
            let original = StoredSelection(selectedPaths: ["original.swift"])
            let committed = StoredSelection(selectedPaths: ["discovered.swift"])
            var selection = original
            let consultant = AgentRepromptContextConsultant(
                oracle: { _ in throw CancellationError() },
                contextBuilder: { _ in
                    selection = committed
                    return .init(result: .init(kind: .contextBuilder, status: "success", text: "files"), committedSelection: committed)
                },
                readSelection: { selection }, restoreSelection: { selection = $0 }
            )
            consultant.start([.init(kind: .contextBuilder, instructions: "find files")])
            _ = await consultant.results()
            if userEdited {
                selection = StoredSelection(selectedPaths: ["user.swift"])
            }
            consultant.cancel()
            XCTAssertEqual(selection, userEdited ? StoredSelection(selectedPaths: ["user.swift"]) : original)
        }
    }

    func testSkipUnblocksWaiterAndFailuresAreNonfatal() async {
        let consultant = AgentRepromptContextConsultant(
            oracle: { _ in throw AgentRepromptError.timeout },
            contextBuilder: { _ in
                try? await Task.sleep(for: .seconds(10))
                return .init(result: .init(kind: .contextBuilder, status: "success", text: "late"))
            },
            readSelection: { nil }, restoreSelection: { _ in }
        )
        consultant.start([.init(kind: .oracle, question: "why?"), .init(kind: .contextBuilder, instructions: "find")])
        await Task.yield()
        consultant.cancel()
        let results = await consultant.results()
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status != "success" })
    }

    func testExactPromptCommitPolicySuppressesEmptyPromptFallback() {
        let runID = UUID()
        let context = MCPTabContextSnapshot(
            tabID: UUID(), windowID: 1, workspaceID: UUID(), promptText: "",
            selection: .init(), selectedMetaPromptIDs: [], tabName: "Test", runID: runID, explicitlyBound: true
        )
        let protected = context.applyingPromptCommitPolicy(expectedRunID: runID, fallback: "Unrequested generated prompt", preserveExactly: true)
        XCTAssertEqual(protected.promptText, "")
        XCTAssertFalse(protected.usedAgentOutputAsPrompt)
        XCTAssertTrue(protected.preservesPromptOnCommit)
        let ordinary = context.applyingPromptCommitPolicy(expectedRunID: runID, fallback: "Ordinary fallback", preserveExactly: false)
        XCTAssertEqual(ordinary.promptText, "Ordinary fallback")
        XCTAssertTrue(ordinary.usedAgentOutputAsPrompt)
    }

    func testApprovalKeepsSelectionAcrossLateCommitAndRepeatedCleanup() async throws {
        let original = StoredSelection(selectedPaths: ["original.swift"])
        let committed = StoredSelection(selectedPaths: ["discovered.swift"])
        var selection = original
        var resume: CheckedContinuation<Void, Never>?
        var didReturn = false
        let consultant = AgentRepromptContextConsultant(
            oracle: { _ in throw CancellationError() },
            contextBuilder: { _ in
                await withCheckedContinuation { resume = $0 }
                selection = committed
                didReturn = true
                return .init(result: .init(kind: .contextBuilder, status: "success", text: "late"), committedSelection: committed)
            },
            readSelection: { selection }, restoreSelection: { selection = $0 }
        )
        consultant.start([.init(kind: .contextBuilder, instructions: "find")])
        try await AsyncTestWait.waitUntil("consult started", timeout: 3) { resume != nil }
        consultant.cancel(keepSelection: true)
        // Canonical selection observation can race with the async consult returning.
        selection = committed
        consultant.noteCommittedSelection(committed)
        XCTAssertEqual(selection, committed)
        consultant.cancel()
        consultant.restoreIfUnchanged()
        resume?.resume()
        try await AsyncTestWait.waitUntil("late consult returned", timeout: 3) { didReturn }
        await Task.yield()
        XCTAssertEqual(selection, committed, "Approval-kept selection must never be rolled back.")
    }

    func testCancelledLateCommitRestoresAndCannotBePromotedToKeep() {
        let original = StoredSelection(selectedPaths: ["original.swift"])
        let committed = StoredSelection(selectedPaths: ["discovered.swift"])
        var selection = original
        let consultant = AgentRepromptContextConsultant(
            oracle: { _ in throw CancellationError() }, contextBuilder: { _ in throw CancellationError() },
            readSelection: { selection }, restoreSelection: { selection = $0 }
        )
        consultant.cancel()
        consultant.cancel(keepSelection: true)
        selection = committed
        consultant.noteCommittedSelection(committed)
        XCTAssertEqual(selection, original, "A skipped/cancelled consult still owns rollback of late commits.")
    }

    func testRepromptCommitDoesNotNotifyButOrdinaryBuilderStillDoes() {
        XCTAssertTrue(MCPServerViewModel.shouldNotifyContextBuilderCommit(preservesPrompt: false, hasSelectionObserver: false))
        for (preservesPrompt, hasObserver) in [(true, false), (false, true), (true, true)] {
            XCTAssertFalse(MCPServerViewModel.shouldNotifyContextBuilderCommit(preservesPrompt: preservesPrompt, hasSelectionObserver: hasObserver))
        }
    }

    func testManifestAndConsultResultBounds() {
        let paths = (0 ..< 100).map { "file\($0).swift" }
        let manifest = AgentRepromptContextConsultant.manifest(rootNames: ["Project"], selectedPaths: paths)
        XCTAssertTrue(manifest.contains("+50 more"))
        XCTAssertFalse(manifest.contains("file50.swift"))
        let huge = AgentRepromptContextConsultant.manifest(rootNames: [String(repeating: "x", count: 5000)], selectedPaths: paths)
        XCTAssertLessThanOrEqual(huge.utf8.count, 4096)
        let result = AgentRepromptContextConsultant.boundedResult(String(repeating: "é", count: 10000))
        XCTAssertLessThanOrEqual(result.utf8.count, 16384)
        XCTAssertTrue(result.hasSuffix("[truncated]"))
    }
}
