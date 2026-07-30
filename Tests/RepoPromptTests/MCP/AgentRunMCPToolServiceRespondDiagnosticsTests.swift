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
            XCTAssertEqual(String(describing: error), "[-32602] Invalid params: \(expectedMessage)", label)
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

        let window: WindowState
        let sessionID: UUID
        let session: AgentModeViewModel.TabSession
        let service: AgentRunMCPToolService

        private init(window: WindowState, sessionID: UUID, session: AgentModeViewModel.TabSession) {
            self.window = window
            self.sessionID = sessionID
            self.session = session
            let windowID = window.windowID
            service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: UUID(),
                        clientName: "agent-run-respond-diagnostics-tests",
                        windowID: windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                    throw MCPError.internalError("startRun should not be used by respond diagnostics tests")
                }
            )
        }

        static func make() async throws -> ControlledApprovalSessionFixture {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            do {
                let workspace = window.workspaceManager.createWorkspace(
                    name: "Respond Diagnostics \(UUID().uuidString.prefix(8))",
                    repoPaths: [FileManager.default.currentDirectoryPath],
                    ephemeral: true
                )
                await window.workspaceManager.switchWorkspace(
                    to: workspace,
                    saveState: false,
                    reason: "agentRunRespondDiagnosticsTests"
                )
                guard let activeWorkspace = window.workspaceManager.activeWorkspace else {
                    throw MCPError.internalError("Expected active ephemeral workspace")
                }
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

                let sessionID = UUID()
                let session = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
                _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
                try await window.agentModeViewModel.mcpActivateControlContext(
                    forTabID: session.tabID,
                    sessionID: sessionID,
                    originatingConnectionID: nil,
                    startPending: true
                )
                session.runState = .waitingForApproval
                return ControlledApprovalSessionFixture(window: window, sessionID: sessionID, session: session)
            } catch {
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                throw error
            }
        }

        var currentPendingInteractionID: UUID? {
            session.pendingWorktreeMergeReview?.id ?? session.pendingPermissionsRequest?.id ?? session.pendingApproval?.id
        }

        func clearPendingApprovals() {
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
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
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
