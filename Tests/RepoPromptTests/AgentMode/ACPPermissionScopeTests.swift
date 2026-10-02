import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class ACPPermissionScopeTests: XCTestCase {
    func testOrdinaryApproveNeverSelectsAnAlwaysGrantForGenericProviders() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity] {
            for optionID in ["allow_always", "always", "opaque-always", "once", "allow_once"] {
                for decision: AgentApprovalDecision in [.accept, .acceptForSession, .acceptWithExecpolicyAmendment("remember")] {
                    let outcome = try await permissionOutcome(providerID: providerID, decision: decision, optionID: optionID)
                    let oneTime = decision == .accept
                    XCTAssertEqual(outcome["outcome"], oneTime ? "cancelled" : "selected", "\(providerID): \(decision)")
                    XCTAssertEqual(outcome["optionId"], oneTime ? nil : optionID, "\(providerID): \(decision)")
                }
            }
        }
    }

    func testNoOneTimeOptionDisablesPlainApproveForEveryACPProvider() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            let outcome = try await permissionOutcome(providerID: providerID, decision: .decline, optionID: "allow_always")
            XCTAssertEqual(outcome["outcome"], "selected")
            XCTAssertEqual(outcome["optionId"], "reject_once")
        }
    }

    func testOneTimeOptionKeepsPlainApprovalAvailable() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            let outcome = try await permissionOutcome(
                providerID: providerID, decision: .accept, optionID: "allow_once", optionKind: "allow_once"
            )
            XCTAssertEqual(outcome["outcome"], "selected")
            XCTAssertEqual(outcome["optionId"], "allow_once")
        }
    }

    private func permissionOutcome(
        providerID: ACPProviderID,
        decision: AgentApprovalDecision,
        optionID: String,
        optionKind: String = "allow_always"
    ) async throws -> [String: String] {
        let directory = try makeTestDirectory(name: "ACPPermissionScope")
        let executable = directory.appendingPathComponent("scripted-acp")
        let record = directory.appendingPathComponent("response.json")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        prompt_id = None
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                send({"id": "permission-1", "method": "session/request_permission", "params": {
                    "sessionId": "test-session", "toolCall": {"toolCallId": "tool-1", "title": "Shell command", "kind": "execute"},
                    "options": [
                        {"optionId": "\#(optionID)", "kind": "\#(optionKind)", "name": "Allow"},
                        {"optionId": "reject_once", "kind": "reject_once", "name": "Decline"}
                    ]
                }})
            elif request.get("id") == "permission-1":
                with open(r"\#(record.path)", "w", encoding="utf-8") as output:
                    json.dump(request["result"]["outcome"], output)
                send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let agentKind: AgentProviderKind = switch providerID {
        case .openCode: .openCode
        case .cursor: .cursor
        case .antigravity: .antigravity
        case .grokBuild: .grokBuild
        case .devin: .devin
        }
        let request = ACPRunRequest(
            agentKind: agentKind, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: ScriptedScopeProvider(providerID: providerID, executable: executable.path), runRequest: request
        )
        do {
            _ = try await controller.bootstrap()
            let events = await controller.events
            let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "Run"), request: request) }
            for await event in events {
                if case let .approvalRequested(approval) = event {
                    XCTAssertEqual(approval.supportsPlainApprove, optionKind == "allow_once", "\(providerID): \(optionID)")
                    await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: decision)
                    break
                }
            }
            try await prompt.value
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: String])
    }
}

/// A local scripted transport; never resolves or launches a real provider.
private struct ScriptedScopeProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let executable: String

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID, command: executable, arguments: [], environment: [:],
            workingDirectory: request.workspacePath, additionalPathHints: [], enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(mode: .new, workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path, mcpServers: [])
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

@MainActor
final class ACPApprovalAvailabilityTests: XCTestCase {
    func testUnavailablePlainApprovalStaysPendingAcrossSharedSubmissionPaths() async throws {
        let context = try await AgentRunMCPControlledSessionContext.make(
            workspaceNamePrefix: "ACP approval availability", workspaceSwitchReason: "acpApprovalAvailabilityTests",
            clientName: "acp-approval-availability-tests", unusedStartRunMessage: "No provider starts"
        )
        addTeardownBlock { @MainActor in await context.cleanup() }
        let viewModel = context.window.agentModeViewModel
        for available in [false, true] {
            let request = approval(available: available)
            context.session.pendingApproval = request
            context.session.runState = .waitingForApproval
            XCTAssertEqual(request.supportsPlainApprove, available)
            let interaction = try XCTUnwrap(viewModel.mcpPendingInteraction(for: context.session))
            XCTAssertEqual(interaction.options.map(\.label).contains("accept"), available)
            XCTAssertTrue(interaction.options.map(\.label).contains("accept_for_session"))
            let descriptor = try XCTUnwrap(AgentPendingInteractionDescriptor.make(from: context.session))
            let actions = AgentNotificationActionEligibility.actions(
                for: descriptor, isMCPControlled: false, preferences: .defaults
            )
            XCTAssertEqual(actions.contains(.approve), available)
            for response in ["accept", "approve"] {
                let payload = AgentModeViewModel.MCPInteractionResponsePayload(
                    text: nil, skip: false, responseArgument: .scalar(response), amendment: nil, answersByQuestionID: [:]
                )
                if available {
                    _ = try viewModel.mcpPendingInteractionResolution(
                        for: context.session, kind: .approval, interactionID: request.id, payload: payload
                    )
                } else {
                    XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
                        for: context.session, kind: .approval, interactionID: request.id, payload: payload
                    ))
                    XCTAssertEqual(context.session.pendingApproval, request)
                }
            }
            let submitted = viewModel.submitApprovalDecision(tabID: context.session.tabID, requestID: request.id, decision: .accept)
            XCTAssertEqual(submitted, available)
            if !available {
                XCTAssertEqual(context.session.pendingApproval, request)
                XCTAssertEqual(context.session.runState, .waitingForApproval)
                viewModel.submitApprovalDecision(tabID: context.session.tabID, decision: .accept)
                XCTAssertEqual(context.session.pendingApproval, request, "Unchecked/batch callers must not consume the prompt")
            }
            for decision: AgentApprovalDecision in [.acceptForSession, .acceptWithExecpolicyAmendment("remember"), .decline] {
                context.session.pendingApproval = request
                XCTAssertTrue(viewModel.submitApprovalDecision(tabID: context.session.tabID, requestID: request.id, decision: decision))
            }
        }
    }

    func testOtherProvidersKeepPlainApproveAndUnknownACPAvailabilityFailsClosed() {
        let request = AgentApprovalRequest(
            requestID: .codex(.int(1)), method: "requestApproval", kind: .commandExecution,
            threadID: "thread", turnID: "turn", itemID: "item"
        )
        XCTAssertTrue(request.supportsPlainApprove)
        XCTAssertFalse(approval(available: nil).supportsPlainApprove)
    }

    private func approval(available: Bool?) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .acp("permission"), method: "session/request_permission", kind: .commandExecution,
            threadID: "thread", turnID: "turn", itemID: "item", command: "ls",
            plainApproveAvailable: available
        )
    }
}
