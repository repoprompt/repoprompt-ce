import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Wire contract of `agent_run` start/poll/wait/steer snapshots: bounded `assistant_text`
/// (#399) and an explicit effective worktree binding (#400).
final class DomainAgentRunSnapshotPayloadContractTests: XCTestCase {
    // MARK: - assistant_text bound (#399)

    func testAssistantTextAtOrBelowLimitIsPublishedVerbatimWithoutTruncationFields() throws {
        let text = String(repeating: "a", count: DomainAgentRunSnapshot.assistantTextCharacterLimit)
        let object = Self.makeSnapshot(latestAssistantPreview: text).asObject()
        XCTAssertEqual(object["assistant_text"]?.stringValue, text)
        XCTAssertNil(object["assistant_text_truncated"])
        XCTAssertNil(object["assistant_text_characters"])
    }

    func testOversizedAssistantTextIsTruncatedAndFlaggedWhilePayloadStaysBounded() throws {
        let total = 10 * DomainAgentRunSnapshot.assistantTextCharacterLimit
        // A tool-output-shaped reply: long, line-heavy, with no natural stopping point.
        let text = String(repeating: "stdout line of a long-running command\n", count: total / 38 + 1).prefix(total)
        let object = Self.makeSnapshot(latestAssistantPreview: String(text)).asObject()

        let published = try XCTUnwrap(object["assistant_text"]?.stringValue)
        XCTAssertTrue(published.hasPrefix(String(text.prefix(DomainAgentRunSnapshot.assistantTextCharacterLimit))))
        XCTAssertTrue(published.hasSuffix(DomainAgentRunSnapshot.assistantTextTruncationMarker))
        XCTAssertEqual(
            published.count,
            DomainAgentRunSnapshot.assistantTextCharacterLimit + DomainAgentRunSnapshot.assistantTextTruncationMarker.count
        )
        XCTAssertEqual(object["assistant_text_truncated"], .bool(true))
        XCTAssertEqual(object["assistant_text_characters"]?.intValue, total)

        // The whole serialized snapshot stays bounded regardless of how large the reply was.
        let encoded = try JSONEncoder().encode(Value.object(object))
        XCTAssertLessThan(encoded.count, 4 * DomainAgentRunSnapshot.assistantTextCharacterLimit)
        XCTAssertTrue(published.contains("agent_manage get_log"), "truncation must point at the explicit transcript path")
    }

    func testBoundedAssistantTextHelperCountsCharactersNotBytes() {
        let emoji = String(repeating: "🧪", count: DomainAgentRunSnapshot.assistantTextCharacterLimit)
        let bounded = DomainAgentRunSnapshot.boundedAssistantText(emoji)
        XCTAssertFalse(bounded.truncated)
        XCTAssertEqual(bounded.totalCharacters, DomainAgentRunSnapshot.assistantTextCharacterLimit)
        let over = DomainAgentRunSnapshot.boundedAssistantText(emoji + "x")
        XCTAssertTrue(over.truncated)
        XCTAssertEqual(over.totalCharacters, DomainAgentRunSnapshot.assistantTextCharacterLimit + 1)
        XCTAssertTrue(over.text.hasPrefix(emoji))
    }

    // MARK: - Effective worktree binding (#400)

    func testUnboundSnapshotPublishesExplicitUnboundStateInsteadOfOmittingBindingFields() {
        let object = Self.makeSnapshot(worktreeBindings: []).asObject()
        XCTAssertEqual(object["worktree_binding_state"], .string("unbound"))
        XCTAssertEqual(object["worktree"], .null)
        XCTAssertEqual(object["worktree_bindings"], .array([]))
        XCTAssertNil(object["worktree_binding_warning"])
        XCTAssertNil(object["parent_worktree_bound"])
    }

    func testBoundSnapshotPublishesBoundStateAndBindings() throws {
        let binding = Self.makeBinding()
        let object = Self.makeSnapshot(worktreeBindings: [binding]).asObject()
        XCTAssertEqual(object["worktree_binding_state"], .string("bound"))
        XCTAssertEqual(object["worktree"]?.objectValue?["worktree_id"], .string(binding.worktreeID))
        XCTAssertEqual(object["worktree_bindings"]?.arrayValue?.count, 1)
        XCTAssertNil(object["worktree_binding_warning"])
    }

    func testUnboundChildOfBoundParentCarriesWarningAndParentFlag() throws {
        let snapshot = Self.makeSnapshot(
            parentSessionID: UUID(),
            worktreeBindings: [],
            parentIsWorktreeBound: true
        )
        XCTAssertTrue(snapshot.isUnboundChildOfBoundParent)
        let object = snapshot.asObject()
        XCTAssertEqual(object["worktree_binding_state"], .string("unbound"))
        XCTAssertEqual(object["parent_worktree_bound"], .bool(true))
        let warning = try XCTUnwrap(object["worktree_binding_warning"]?.stringValue)
        XCTAssertEqual(warning, DomainAgentRunSnapshot.unboundChildOfBoundParentWarning)
        XCTAssertTrue(warning.contains("inherit_worktree=false"), warning)
    }

    func testNoWarningWhenParentIsUnboundOrChildIsBoundOrParentUnknown() {
        XCTAssertFalse(Self.makeSnapshot(parentSessionID: UUID(), worktreeBindings: [], parentIsWorktreeBound: false).isUnboundChildOfBoundParent)
        XCTAssertFalse(Self.makeSnapshot(parentSessionID: UUID(), worktreeBindings: [Self.makeBinding()], parentIsWorktreeBound: true).isUnboundChildOfBoundParent)
        XCTAssertFalse(Self.makeSnapshot(parentSessionID: UUID(), worktreeBindings: [], parentIsWorktreeBound: nil).isUnboundChildOfBoundParent)
        XCTAssertFalse(Self.makeSnapshot(parentSessionID: nil, worktreeBindings: [], parentIsWorktreeBound: true).isUnboundChildOfBoundParent)
        let unboundParent = Self.makeSnapshot(parentSessionID: UUID(), worktreeBindings: [], parentIsWorktreeBound: false).asObject()
        XCTAssertEqual(unboundParent["parent_worktree_bound"], .bool(false))
        XCTAssertNil(unboundParent["worktree_binding_warning"])
    }

    func testUnknownBindingStateOmitsBindingKeysAndIsNeverInferredFromEmptyBindings() {
        let snapshot = Self.makeSnapshot(worktreeBindings: [], worktreeBindingState: .unknown)
        XCTAssertEqual(snapshot.worktreeBindingState, .unknown)
        let object = snapshot.asObject()
        XCTAssertNil(object["worktree_binding_state"], "unknown keeps the legacy shape: no state key")
        XCTAssertNil(object["worktree"], "unknown must not masquerade as an explicit unbound")
        XCTAssertNil(object["worktree_bindings"])
        XCTAssertNil(object["worktree_binding_warning"])
    }

    func testExpiredHandleKeepsLegacyShapeWithoutBindingClaims() {
        let object = DomainAgentRunSnapshot.expired(sessionID: UUID()).asObject()
        XCTAssertNil(object["worktree_binding_state"])
        XCTAssertNil(object["worktree"])
        XCTAssertNil(object["worktree_bindings"])
        XCTAssertNil(object["worktree_binding_warning"])
        XCTAssertNil(object["parent_worktree_bound"])
    }

    // MARK: - Helpers

    private static func makeSnapshot(
        latestAssistantPreview: String? = "Done.",
        parentSessionID: UUID? = nil,
        worktreeBindings: [DomainAgentRunSnapshot.WorktreeBinding] = [],
        worktreeBindingState: DomainAgentRunSnapshot.WorktreeBindingState? = nil,
        parentIsWorktreeBound: Bool? = nil
    ) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: UUID(),
            runID: UUID(),
            tabID: UUID(),
            sessionName: "Child",
            agentRaw: "claudeCode",
            agentDisplayName: "Claude Code",
            modelRaw: "sonnet",
            reasoningEffortRaw: nil,
            status: .completed,
            statusText: nil,
            latestAssistantPreview: latestAssistantPreview,
            interaction: nil,
            transcriptItemCount: 3,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parentSessionID: parentSessionID,
            failureReason: nil,
            worktreeBindings: worktreeBindings,
            activeWorktreeMerges: [],
            worktreeBindingState: worktreeBindingState,
            parentIsWorktreeBound: parentIsWorktreeBound
        )
    }

    private static func makeBinding() -> DomainAgentRunSnapshot.WorktreeBinding {
        DomainAgentRunSnapshot.WorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo",
            logicalRootPath: "/tmp/repo",
            logicalRootName: "repo",
            worktreeID: "wt_task",
            worktreeRootPath: "/tmp/repo-task",
            worktreeName: "repo-task",
            branch: "task/branch",
            head: "abc123",
            visualLabel: "Task",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "inherited",
            unavailable: false
        )
    }
}
