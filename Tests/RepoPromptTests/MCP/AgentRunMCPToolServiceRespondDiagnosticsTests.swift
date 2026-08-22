import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceRespondDiagnosticsTests: XCTestCase {
    func testApprovalRespondRejectsNoncanonicalResponseArgumentsWithoutMutation() async throws {
        let fixture = try await ControlledApprovalSessionFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        fixture.installProviderApproval(kind: .fileChange)
        let interactionID = try XCTUnwrap(fixture.session.pendingApproval?.id)

        let cases: [(String, [String: Value], String)] = [
            (
                "missing response",
                [:],
                "response is required for approval interactions. Provide a top-level scalar string, for example response=\"accept\". No response was applied."
            ),
            (
                "decision only",
                ["decision": .string("accept")],
                "decision is not a supported field for agent_run op=respond. For approval interactions, use the top-level scalar response field, for example response=\"accept\". No response was applied."
            ),
            (
                "non-scalar response",
                ["response": .object(["decision": .string("accept")])],
                "response must be a non-empty top-level scalar string for approval interactions, for example response=\"accept\"; nested response objects are not supported. No response was applied."
            ),
            (
                "response and decision",
                ["response": .string("accept"), "decision": .string("accept")],
                "decision is not a supported field for agent_run op=respond. For approval interactions, use the top-level scalar response field, for example response=\"accept\". No response was applied."
            )
        ]

        for (label, arguments, expectedMessage) in cases {
            let pendingApproval = try XCTUnwrap(fixture.session.pendingApproval)
            await assertInvalidParams(
                service: fixture.service,
                sessionID: fixture.sessionID,
                interactionID: interactionID,
                arguments: arguments,
                expectedMessage: expectedMessage,
                label: label
            )
            XCTAssertEqual(fixture.session.pendingApproval, pendingApproval, label)
        }
    }

    func testApprovalRespondInvalidResponseErrorsNameResponseAcrossLiveVariants() async throws {
        let fixture = try await ControlledApprovalSessionFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }

        let cases: [(String, () -> UUID, String)] = [
            (
                "worktree merge",
                { fixture.installWorktreeMergeReview() },
                "response must be one of: accept, decline, cancel."
            ),
            (
                "permissions",
                { fixture.installPermissionsRequest() },
                "response must be one of: accept, accept_for_session, decline, cancel."
            ),
            (
                "provider command",
                { fixture.installProviderApproval(kind: .commandExecution) },
                "response must be one of: accept, accept_for_session, accept_with_amendment, decline, cancel."
            ),
            (
                "provider file change",
                { fixture.installProviderApproval(kind: .fileChange) },
                "response must be one of: accept, accept_for_session, decline, cancel."
            )
        ]

        for (label, install, expectedMessage) in cases {
            fixture.clearPendingApprovals()
            let interactionID = install()
            await assertInvalidParams(
                service: fixture.service,
                sessionID: fixture.sessionID,
                interactionID: interactionID,
                arguments: ["response": .string("invalid")],
                expectedMessage: expectedMessage,
                label: label
            )
            XCTAssertEqual(fixture.currentPendingInteractionID, interactionID, label)
        }
    }

    func testApprovalRespondWithStaleInteractionIDReportsCurrentSafeIdentityWithoutMutation() async throws {
        let fixture = try await ControlledApprovalSessionFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let currentInteractionID = fixture.installProviderApproval(kind: .commandExecution, privacySentinels: true)
        let staleInteractionID = UUID()
        let pendingApproval = try XCTUnwrap(fixture.session.pendingApproval)
        let expectedMessage = "interaction_id \"\(staleInteractionID.uuidString)\" does not match the current pending approval interaction_id \"\(currentInteractionID.uuidString)\". No response was applied. Call agent_run with op=\"poll\" or op=\"wait\" and session_id=\"\(fixture.sessionID.uuidString)\" to fetch the latest snapshot before responding."

        let arguments: [(String, [String: Value])] = [
            ("missing response", [:]),
            ("empty response", ["response": .string("   ")]),
            ("non-scalar response", ["response": .object(["decision": .string("accept")])]),
            ("decision only", ["decision": .string("accept")]),
            ("response and decision", ["response": .string("accept"), "decision": .string("accept")])
        ]
        for (label, payload) in arguments {
            await assertInvalidParams(
                service: fixture.service,
                sessionID: fixture.sessionID,
                interactionID: staleInteractionID,
                arguments: payload,
                expectedMessage: expectedMessage,
                label: label
            )
            XCTAssertEqual(fixture.session.pendingApproval, pendingApproval, label)
        }
        for sentinel in ControlledApprovalSessionFixture.privacySentinels {
            XCTAssertFalse(expectedMessage.contains(sentinel), sentinel)
        }
    }

    func testHookApprovalStaleInteractionDiagnosticDoesNotLeakMetadata() async throws {
        let fixture = try await ControlledApprovalSessionFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let currentInteractionID = try fixture.installHookApprovalPrivacySentinels()
        let staleInteractionID = UUID()
        let pendingReview = try XCTUnwrap(fixture.session.pendingCodexHookReview)
        let expectedMessage = "interaction_id \"\(staleInteractionID.uuidString)\" does not match the current pending hook_approval interaction_id \"\(currentInteractionID.uuidString)\". No response was applied. Call agent_run with op=\"poll\" or op=\"wait\" and session_id=\"\(fixture.sessionID.uuidString)\" to fetch the latest snapshot before responding."

        await assertInvalidParams(
            service: fixture.service,
            sessionID: fixture.sessionID,
            interactionID: staleInteractionID,
            arguments: ["response": .string("approve_selected")],
            expectedMessage: expectedMessage,
            label: "hook approval stale identity"
        )
        XCTAssertEqual(fixture.session.pendingCodexHookReview, pendingReview)
        for sentinel in [
            "HOOK_KEY_SENTINEL",
            "HOOK_PATH_SENTINEL",
            "HOOK_HASH_SENTINEL",
            "HOOK_COMMAND_SENTINEL",
            "HOOK_ERROR_SENTINEL"
        ] {
            XCTAssertFalse(expectedMessage.contains(sentinel), sentinel)
        }
    }

    private func assertInvalidParams(
        service: AgentRunMCPToolService,
        sessionID: UUID,
        interactionID: UUID,
        arguments: [String: Value],
        expectedMessage: String,
        label: String
    ) async {
        var args = arguments
        args["op"] = .string("respond")
        args["session_id"] = .string(sessionID.uuidString)
        args["interaction_id"] = .string(interactionID.uuidString)

        do {
            _ = try await service.execute(args: args)
            XCTFail("Expected invalid params: \(label)")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602, label)
            guard case let .invalidParams(message) = error else {
                return XCTFail("Expected MCPError.invalidParams for \(label), got code \(error.code)")
            }
            XCTAssertEqual(message, expectedMessage, label)
        } catch {
            XCTFail("Expected MCPError.invalidParams for \(label), got \(error)")
        }
    }

    @MainActor
    private final class ControlledApprovalSessionFixture {
        static let privacySentinels = [
            "PROMPT_SENTINEL", "COMMAND_SENTINEL", "CWD_SENTINEL", "REASON_SENTINEL",
            "SCOPE_SENTINEL", "OPTION_SENTINEL", "AMENDMENT_SENTINEL", "ANSWER_SENTINEL",
            "ELICITATION_SENTINEL", "ASSISTANT_SENTINEL", "RESPONSE_SENTINEL", "WORKTREE_SENTINEL"
        ]

        private let context: AgentRunMCPControlledSessionContext

        var window: WindowState {
            context.window
        }

        var sessionID: UUID {
            context.sessionID
        }

        var session: AgentModeViewModel.TabSession {
            context.session
        }

        var service: AgentRunMCPToolService {
            context.service
        }

        private init(context: AgentRunMCPControlledSessionContext) {
            self.context = context
        }

        static func make() async throws -> ControlledApprovalSessionFixture {
            let context = try await AgentRunMCPControlledSessionContext.make(
                workspaceNamePrefix: "Respond Diagnostics",
                workspaceSwitchReason: "agentRunRespondDiagnosticsTests",
                clientName: "agent-run-respond-diagnostics-tests",
                unusedStartRunMessage: "startRun should not be used by respond diagnostics tests"
            )
            context.session.runState = .waitingForApproval
            return ControlledApprovalSessionFixture(context: context)
        }

        var currentPendingInteractionID: UUID? {
            session.pendingCodexHookReview?.id
                ?? session.pendingWorktreeMergeReview?.id
                ?? session.pendingPermissionsRequest?.id
                ?? session.pendingApproval?.id
        }

        func clearPendingApprovals() {
            session.pendingCodexHookReview = nil
            session.pendingWorktreeMergeReview = nil
            session.pendingPermissionsRequest = nil
            session.pendingApproval = nil
        }

        @discardableResult
        func installProviderApproval(kind: AgentApprovalKind, privacySentinels: Bool = false) -> UUID {
            let id = UUID()
            session.pendingApproval = AgentApprovalRequest(
                id: id,
                requestID: .codex(.int(1)),
                method: "item/requestApproval",
                kind: kind,
                threadID: "thread",
                turnID: "turn",
                itemID: "item",
                reason: privacySentinels ? "REASON_SENTINEL" : nil,
                command: privacySentinels ? "COMMAND_SENTINEL" : nil,
                cwd: privacySentinels ? "CWD_SENTINEL" : nil,
                grantRoot: privacySentinels ? "SCOPE_SENTINEL" : nil,
                proposedExecpolicyAmendmentJSON: privacySentinels ? "AMENDMENT_SENTINEL" : nil,
                details: privacySentinels ? [.init(label: "OPTION_SENTINEL", value: "RESPONSE_SENTINEL")] : []
            )
            return id
        }

        func installHookApprovalPrivacySentinels() throws -> UUID {
            let metadata = try CodexHookMetadata(
                eventName: "PreToolUse",
                source: "project",
                sourcePath: "/private/HOOK_PATH_SENTINEL",
                key: "HOOK_KEY_SENTINEL",
                currentHash: "HOOK_HASH_SENTINEL",
                enabled: true,
                handlerType: "command",
                trustStatus: .untrusted,
                commandOrHandler: "HOOK_COMMAND_SENTINEL"
            )
            let request = AgentCodexHookReviewRequest(
                tabID: session.tabID,
                runAttemptID: nil,
                runID: nil,
                executionCWD: "/private/HOOK_PATH_SENTINEL",
                hooks: [AgentCodexHookReviewHook(metadata: metadata)],
                phase: .writeFailed,
                errorMessage: "HOOK_ERROR_SENTINEL",
                gateGeneration: 1
            )
            session.pendingCodexHookReview = request
            return request.id
        }

        @discardableResult
        func installPermissionsRequest() -> UUID {
            let id = UUID()
            session.pendingPermissionsRequest = AgentPermissionsRequest(
                id: id,
                requestID: .int(2),
                method: "item/permissions/requestApproval",
                threadID: "thread",
                turnID: "turn",
                itemID: "item",
                cwd: "/tmp",
                permissionsJSON: "{}"
            )
            return id
        }

        @discardableResult
        func installWorktreeMergeReview() -> UUID {
            let id = UUID()
            session.pendingWorktreeMergeReview = PendingWorktreeMergeReview(
                id: id,
                scope: WorktreeMergeReviewScope(windowID: window.windowID, tabID: session.tabID),
                preview: Self.makePreview()
            )
            return id
        }

        func cleanup() async {
            await context.cleanup()
        }

        private static func makePreview() -> GitWorktreeMergePreview {
            let source = GitWorktreeMergeEndpoint(
                worktreeID: "wt_source", repositoryID: "repo", repoKey: "repo", path: "/tmp/source",
                name: "source", branch: "feature", head: "aaaaaaaa", isMain: false
            )
            let target = GitWorktreeMergeEndpoint(
                worktreeID: "wt_target", repositoryID: "repo", repoKey: "repo", path: "/tmp/target",
                name: "target", branch: "main", head: "bbbbbbbb", isMain: true
            )
            let inspection = GitWorktreeMergeInspection(
                source: source,
                target: target,
                mergeBase: "cccccccc",
                sourceHead: source.head,
                targetHead: target.head,
                sourceFingerprint: GitDiffFingerprint(
                    headSHA: source.head, baseRef: "HEAD", statusHash: "source", generatedAt: Date()
                ),
                targetFingerprint: GitDiffFingerprint(
                    headSHA: target.head, baseRef: "HEAD", statusHash: "target", generatedAt: Date()
                ),
                blockers: [],
                conflictPrediction: GitWorktreeMergeConflictPrediction(status: .clean),
                summary: GitWorktreeMergeSummary(commits: 1, files: 1, insertions: 1, deletions: 0),
                visualization: "WORKTREE_SENTINEL"
            )
            return GitWorktreeMergePreview(operationID: "merge", inspection: inspection, artifacts: nil)
        }
    }
}
