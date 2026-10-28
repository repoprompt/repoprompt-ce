import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class ACPPermissionScopeTests: XCTestCase {
    func testOrdinaryApproveNeverSelectsAnAlwaysGrantForGenericProviders() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity] {
            for optionID in ["allow_always", "always", "opaque-always", "once", "allow_once"] {
                for decision: AgentApprovalDecision in [.accept, .acceptForSession, .acceptWithExecpolicyAmendment("remember")] {
                    let outcome = try await permissionOutcome(
                        providerID: providerID, decision: decision, optionID: optionID, expectedPlainApprove: false
                    )
                    let oneTime = decision == .accept
                    XCTAssertEqual(outcome["outcome"], oneTime ? "cancelled" : "selected", "\(providerID): \(decision)")
                    XCTAssertEqual(outcome["optionId"], oneTime ? nil : optionID, "\(providerID): \(decision)")
                }
            }
        }
    }

    func testNoOneTimeOptionDisablesPlainApproveForEveryACPProvider() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            let outcome = try await permissionOutcome(
                providerID: providerID, decision: .decline, optionID: "allow_always", expectedPlainApprove: false
            )
            XCTAssertEqual(outcome["outcome"], "selected")
            XCTAssertEqual(outcome["optionId"], "reject_once")
        }
    }

    func testOneTimeOptionKeepsPlainApprovalAvailable() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            let outcome = try await permissionOutcome(
                providerID: providerID, decision: .accept, optionID: "allow_once", optionKind: "allow_once", expectedPlainApprove: true
            )
            XCTAssertEqual(outcome["outcome"], "selected")
            XCTAssertEqual(outcome["optionId"], "allow_once")
        }
    }

    func testGrokShellSessionApprovalUsesOnlyOneTimeOptions() async throws {
        let cases: [(name: String, options: [[String: String]], expectedPlainApprove: Bool, expectedOptionID: String?)] = [
            ("generic Bash", [
                ["optionId": "always-allow", "kind": "allow_always", "name": "Yes, and don't ask again for bash commands"],
                ["optionId": "allow-once", "kind": "allow_once", "name": "Yes, proceed"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"],
                ["optionId": "reject-always", "kind": "reject_always", "name": "No, and don't ask again for this command"]
            ], true, "allow-once"),
            ("remember disabled", [
                ["optionId": "allow-once", "kind": "allow_once", "name": "Yes, proceed"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], true, "allow-once"),
            ("opaque kind fallback", [
                ["optionId": "opaque-persistent", "kind": "allow_always", "name": "Remember"],
                ["optionId": "opaque-once", "kind": "allow_once", "name": "Allow"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], true, "opaque-once"),
            ("always preference", [
                ["optionId": "always", "kind": "allow_always", "name": "Remember"],
                ["optionId": "allow-once", "kind": "allow_once", "name": "Allow"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], true, "allow-once"),
            ("allow_always preference", [
                ["optionId": "allow_always", "kind": "allow_always", "name": "Remember"],
                ["optionId": "allow-once", "kind": "allow_once", "name": "Allow"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], true, "allow-once"),
            ("persistent only", [
                ["optionId": "always-allow", "kind": "allow_always", "name": "Remember"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], false, nil),
            ("one-time ID with persistent kind", [
                ["optionId": "allow-once", "kind": "allow_always", "name": "Remember"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], false, nil),
            ("persistent ID with one-time kind", [
                ["optionId": "always-allow", "kind": "allow_once", "name": "Remember"],
                ["optionId": "opaque-once", "kind": "allow_once", "name": "Allow"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], true, "opaque-once"),
            ("persistent ID with one-time kind only", [
                ["optionId": "always-allow", "kind": "allow_once", "name": "Remember"],
                ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
            ], false, nil)
        ]
        for testCase in cases {
            for decision: AgentApprovalDecision in [.accept, .acceptForSession] {
                let outcome = try await permissionOutcome(
                    providerID: .grokBuild, decision: decision, options: testCase.options,
                    expectedPlainApprove: testCase.expectedPlainApprove, expectedSessionScope: .oneTime
                )
                XCTAssertEqual(
                    outcome["outcome"], testCase.expectedOptionID == nil ? "cancelled" : "selected", "\(testCase.name): \(decision)"
                )
                XCTAssertEqual(outcome["optionId"], testCase.expectedOptionID, "\(testCase.name): \(decision)")
            }
        }
    }

    func testGrokEditSessionApprovalPreservesScope() async throws {
        let options = [
            ["optionId": "allow-edits-session", "kind": "allow_always", "name": "Yes, allow all edits during this session"],
            ["optionId": "allow-once", "kind": "allow_once", "name": "Yes"],
            ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
        ]
        for (decision, expectedOptionID): (AgentApprovalDecision, String) in [
            (.acceptForSession, "allow-edits-session"), (.accept, "allow-once")
        ] {
            let outcome = try await permissionOutcome(
                providerID: .grokBuild, decision: decision, options: options, expectedPlainApprove: true, toolKind: "edit",
                expectedSessionScope: .editsSession
            )
            XCTAssertEqual(outcome["outcome"], "selected", "\(decision)")
            XCTAssertEqual(outcome["optionId"], expectedOptionID, "\(decision)")
        }
    }

    func testUnattestedRepoPromptLabelsAlwaysRequireManualApproval() async throws {
        let toolCalls = [
            #"{"toolCallId":"tool-1","title":"mcp__RepoPromptCE__git","kind":"other"}"#,
            #"{"toolCallId":"tool-1","title":"RepoPromptCE_read_file"}"#,
            #"{"toolCallId":"tool-1","name":"mcp__RepoPromptCE__git","kind":"other"}"#,
            #"{"toolCallId":"tool-1","title":"git","server":"RepoPromptCE","kind":"other"}"#,
            #"{"toolCallId":"tool-1","title":"mcp__RepoPromptCE__git","server":"OtherServer","kind":"other"}"#,
            #"{"toolCallId":"tool-1","title":"mcp__RepoPromptCE__git","kind":"edit"}"#,
            #"{"toolCallId":"tool-1","title":"Shell","kind":"execute","rawInput":{"server":"RepoPromptCE","name":"git"}}"#,
            #"{"toolCallId":"tool-1","title":"mcp__RepoPromptCE__git","_meta":{"cognition.ai/toolName":"mcp__OtherServer__git"}}"#,
            #"{"toolCallId":"tool-1","title":"Calling git","_meta":{"cognition.ai/toolName":"mcp__RepoPromptCE__git"}}"#,
            #"{"toolCallId":"tool-1","name":"mcp__RepoPromptCE__git","server":"RepoPromptCE","_meta":{"cognition.ai/toolName":"mcp__RepoPromptCE__unknown_tool"}}"#,
            #"{"toolCallId":"tool-1","title":"git (RepoPromptCE MCP Server)","_meta":{"cognition.ai/toolName":"mcp__RepoPromptCE__foreign__git"}}"#
        ]
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            for toolCall in toolCalls {
                let result = try await autoApprovalOutcome(toolCallJSON: toolCall, providerID: providerID)
                XCTAssertTrue(result.approvalRequested, "\(providerID): \(toolCall)")
                XCTAssertEqual(result.outcome["optionId"], "reject_once")
            }
        }
    }

    func testAutomaticSelectionsRequireGenuineOneTimeOptions() async throws {
        let toolCall = #"{"toolCallId":"tool-1","_meta":{"cognition.ai/toolName":"mcp__RepoPromptCE__git"}}"#
        let invalidOptions = [
            ["optionId": "allow_once", "kind": "allow_always"],
            ["optionId": "always", "kind": "allow_once"],
            ["optionId": "allow_session", "kind": "allow_once"],
            ["optionId": "allow_global", "kind": "allow_once"],
            ["optionId": "allow_persistent", "kind": "allow_once"],
            ["optionId": "enable-always-approve", "kind": "allow_once"]
        ]
        // Cursor's explicit user full-access setting is the remaining automatic path.
        for option in invalidOptions {
            // Mixed fixtures use distinct wire IDs; the exact allow_once mislabel is
            // covered alone rather than treating duplicate option IDs as valid consent.
            let availabilityCases = option["optionId"] == "allow_once" ? [false] : [false, true]
            for genuineOptionAvailable in availabilityCases {
                var options = [option]
                if genuineOptionAvailable { options.append(["optionId": "allow_once", "kind": "allow_once"]) }
                options.append(["optionId": "reject_once", "kind": "reject_once"])
                let result = try await autoApprovalOutcome(
                    toolCallJSON: toolCall, providerID: .cursor, options: options,
                    fullAccess: true
                )
                XCTAssertEqual(result.approvalRequested, !genuineOptionAvailable, "\(option)")
                XCTAssertEqual(result.outcome["optionId"], genuineOptionAvailable ? "allow_once" : "reject_once")
            }
        }
    }

    func testPendingCursorFullAccessUsesOnlyGenuineOneTimeOptions() async throws {
        let invalidOptions = [
            ["optionId": "allow_always", "kind": "allow_always"],
            ["optionId": "allow_once", "kind": "allow_always"],
            ["optionId": "always", "kind": "allow_once"],
            ["optionId": "allow_session", "kind": "allow_once"],
            ["optionId": "allow_global", "kind": "allow_once"],
            ["optionId": "allow_persistent", "kind": "allow_once"]
        ]
        for option in invalidOptions {
            for genuineOptionAvailable in [false, true] {
                var options = [option]
                if genuineOptionAvailable { options.append(["optionId": "opaque-once", "kind": "allow_once"]) }
                options.append(["optionId": "reject_once", "kind": "reject_once"])
                let result = try await autoApprovalOutcome(
                    toolCallJSON: #"{"toolCallId":"tool-1","title":"Test tool","kind":"execute"}"#,
                    providerID: .cursor, options: options, pendingFullAccess: true,
                    expectedPendingAutoApproval: genuineOptionAvailable
                )
                XCTAssertTrue(result.approvalRequested, "The prompt must first surface with full access disabled")
                XCTAssertEqual(result.outcome["optionId"], genuineOptionAvailable ? "opaque-once" : "reject_once", "\(option)")
            }
        }
    }

    func testPendingCursorFullAccessResolvesApprovalUUIDForTypedWireIDs() async throws {
        for wireIDJSON in [#""7""#, "7"] {
            let result = try await autoApprovalOutcome(
                toolCallJSON: #"{"toolCallId":"tool-1","title":"Test tool","kind":"execute"}"#,
                providerID: .cursor, options: [
                    ["optionId": "allow_always", "kind": "allow_always"],
                    ["optionId": "allow_once", "kind": "allow_once"],
                    ["optionId": "reject_once", "kind": "reject_once"]
                ], pendingFullAccess: true, expectedPendingAutoApproval: true, wireIDJSON: wireIDJSON
            )
            XCTAssertTrue(result.approvalRequested, wireIDJSON)
            XCTAssertEqual(result.outcome["optionId"], "allow_once", wireIDJSON)
        }
    }

    func testPendingFullAccessRequiresCurrentFlagAndSupportedProvider() async throws {
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .grokBuild, .devin] {
            for enabled in [false, true] {
                let expectedSelection = providerID == .cursor && enabled
                let result = try await autoApprovalOutcome(
                    toolCallJSON: #"{"toolCallId":"tool-1","title":"Test tool","kind":"execute"}"#,
                    providerID: providerID, pendingFullAccess: enabled, expectedPendingAutoApproval: expectedSelection
                )
                XCTAssertTrue(result.approvalRequested)
                XCTAssertEqual(result.outcome["optionId"], expectedSelection ? "allow_once" : "reject_once", "\(providerID): \(enabled)")
            }
        }
        // Full-access automation must not rewrite an explicit manual session choice.
        for decision: AgentApprovalDecision in [.acceptForSession, .acceptWithExecpolicyAmendment("remember")] {
            let result = try await autoApprovalOutcome(
                toolCallJSON: #"{"toolCallId":"tool-1","title":"Test tool","kind":"execute"}"#,
                providerID: .cursor, options: [
                    ["optionId": "allow_always", "kind": "allow_always"],
                    ["optionId": "allow_once", "kind": "allow_once"],
                    ["optionId": "reject_once", "kind": "reject_once"]
                ], pendingFullAccess: false, manualDecision: decision
            )
            XCTAssertEqual(result.outcome["optionId"], "allow_always")
        }
    }

    /// Responds through the real controller/transport, distinguishing automatic selection
    /// from surfaced prompts. A manual response after refused automation proves it stayed pending.
    private func autoApprovalOutcome(
        toolCallJSON: String,
        providerID: ACPProviderID = .openCode,
        options: [[String: String]] = [
            ["optionId": "allow_once", "kind": "allow_once", "name": "Allow"],
            ["optionId": "reject_once", "kind": "reject_once", "name": "Decline"]
        ],
        fullAccess: Bool = false,
        pendingFullAccess: Bool? = nil,
        expectedPendingAutoApproval: Bool = false,
        manualDecision: AgentApprovalDecision = .decline,
        wireIDJSON: String = #""permission-1""#
    ) async throws -> (approvalRequested: Bool, outcome: [String: String]) {
        let optionsJSON = try String(decoding: JSONSerialization.data(withJSONObject: options), as: UTF8.self)
        let directory = try makeTestDirectory(name: "ACPAutoApprovalProvenance")
        let executable = directory.appendingPathComponent("scripted-acp")
        let record = directory.appendingPathComponent("response.json")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        prompt_id = None
        permission_id = json.loads(r'\#(wireIDJSON)')
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                send({"id": permission_id, "method": "session/request_permission", "params": {
                    "sessionId": "test-session", "toolCall": json.loads(r'\#(toolCallJSON)'),
                    "options": json.loads(r'\#(optionsJSON)')
                }})
            elif type(request.get("id")) is type(permission_id) and request.get("id") == permission_id:
                with open(r"\#(record.path)", "a", encoding="utf-8") as output:
                    output.write(json.dumps(request["result"]["outcome"]) + "\n")
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
            provider: ScriptedScopeProvider(
                providerID: providerID, executable: executable.path
            ), runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )
        do {
            _ = try await controller.bootstrap()
            await controller.setAutoApproveAllToolPermissions(fullAccess)
            let events = await controller.events
            let consumer = Task { () -> Bool in
                for await event in events {
                    if case let .approvalRequested(approval) = event {
                        if let pendingFullAccess {
                            XCTAssertNotNil(UUID(uuidString: approval.requestID.displayValue), "Approval identity is not the provider's wire ID")
                            // Revoke a previously enabled flag too: the response must use
                            // current actor-owned state, not the caller's activation snapshot.
                            await controller.setAutoApproveAllToolPermissions(true)
                            await controller.setAutoApproveAllToolPermissions(pendingFullAccess)
                            for wireID in ["permission-1", "7", "s:permission-1", "s:7", "i:7"] {
                                let wireIDSubmitted = await controller.respondToPendingPermissionRequestForFullAccess(id: wireID)
                                XCTAssertFalse(wireIDSubmitted, "Wire identities must not authorize an approval incarnation")
                            }
                            let wrongIDSubmitted = await controller.respondToPendingPermissionRequestForFullAccess(id: "not-the-pending-request")
                            XCTAssertFalse(wrongIDSubmitted)
                            let submitted = await controller.respondToPendingPermissionRequestForFullAccess(id: approval.requestID.displayValue)
                            XCTAssertEqual(submitted, expectedPendingAutoApproval)
                            if submitted {
                                let submittedAgain = await controller.respondToPendingPermissionRequestForFullAccess(id: approval.requestID.displayValue)
                                XCTAssertFalse(submittedAgain, "A consumed approval UUID must not send a second response")
                                return true
                            }
                        }
                        await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: manualDecision)
                        return true
                    }
                }
                return false
            }
            try await controller.prompt(AgentMessage(userMessage: "Run"), request: request)
            await controller.shutdown()
            let approvalRequested = await consumer.value
            let responses = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(responses.count, 1, "Exactly one wire response: refused automation must not send or consume the prompt")
            let response = try XCTUnwrap(responses.first)
            let outcome = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: String])
            return (approvalRequested, outcome)
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

private extension XCTestCase {
    func permissionOutcome(
        providerID: ACPProviderID,
        decision: AgentApprovalDecision,
        optionID: String,
        optionKind: String = "allow_always",
        expectedPlainApprove: Bool
    ) async throws -> [String: String] {
        try await permissionOutcome(providerID: providerID, decision: decision, options: [
            ["optionId": optionID, "kind": optionKind, "name": "Allow"],
            ["optionId": "reject_once", "kind": "reject_once", "name": "Decline"]
        ], expectedPlainApprove: expectedPlainApprove)
    }

    func permissionOutcome(
        providerID: ACPProviderID,
        decision: AgentApprovalDecision,
        options: [[String: String]],
        expectedPlainApprove: Bool,
        toolKind: String = "execute",
        expectedSessionScope: AgentApprovalSessionScope? = nil,
        expectedOptionsDetail: Bool? = nil
    ) async throws -> [String: String] {
        let optionsJSON = try String(decoding: JSONSerialization.data(withJSONObject: options), as: UTF8.self)
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
                    "sessionId": "test-session", "toolCall": {
                        "toolCallId": "tool-1", "title": "Test tool", "kind": "\#(toolKind)", "rawInput": {"command": "echo test"}
                    },
                    "options": \#(optionsJSON)
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
            provider: ScriptedScopeProvider(providerID: providerID, executable: executable.path), runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )
        do {
            _ = try await controller.bootstrap()
            let events = await controller.events
            let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "Run"), request: request) }
            for await event in events {
                if case let .approvalRequested(approval) = event {
                    XCTAssertEqual(approval.supportsPlainApprove, expectedPlainApprove, "\(providerID): \(decision)")
                    if let expectedSessionScope {
                        XCTAssertEqual(approval.sessionApprovalScope, expectedSessionScope)
                    } else if providerID != .grokBuild {
                        XCTAssertNil(approval.sessionApprovalScope, "Other providers retain legacy scope")
                    }
                    if let expectedOptionsDetail {
                        XCTAssertEqual(
                            approval.details.map(\.label),
                            ["Tool", "Kind", "Input"] + (expectedOptionsDetail ? ["Options"] : []), "\(providerID): \(toolKind)"
                        )
                        XCTAssertEqual(approval.details.first { $0.label == "Tool" }?.value, "Test tool")
                        XCTAssertEqual(approval.details.first { $0.label == "Kind" }?.value, toolKind)
                        let input = try XCTUnwrap(approval.details.first { $0.label == "Input" })
                        XCTAssertTrue(input.isCode)
                        XCTAssertEqual(
                            try JSONSerialization.jsonObject(with: Data(input.value.utf8)) as? [String: String],
                            ["command": "echo test"]
                        )
                        if expectedOptionsDetail {
                            XCTAssertEqual(
                                approval.details.first { $0.label == "Options" }?.value,
                                options.compactMap { $0["name"] }.joined(separator: "\n")
                            )
                        }
                        XCTAssertEqual(approval.supportsAlwaysAllow, expectedSessionScope != .oneTime)
                    }
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

@MainActor
final class ACPPermissionIdentityTests: XCTestCase {
    func testTypedWireIDsHaveIndependentApprovalIncarnations() async throws {
        let fixture = try await makeFixture(scenario: "typed")
        let watchdog = watchdog(for: fixture)
        defer { watchdog.cancel() }
        var events = await fixture.controller.events.makeAsyncIterator()
        let prompt = Task { try await fixture.controller.prompt(AgentMessage(userMessage: "Run"), request: fixture.request) }
        do {
            let first = try await nextApproval(&events)
            let second = try await nextApproval(&events)
            XCTAssertNotEqual(first.id, second.id)
            await fixture.controller.respondToPermissionRequest(id: first.requestID.displayValue, decision: .accept)
            await fixture.controller.respondToPermissionRequest(id: second.requestID.displayValue, decision: .decline)
            try await prompt.value
            let responses = try fixture.responses()
            XCTAssertEqual(responses.count, 2)
            XCTAssertTrue(responses[0]["id"] is String)
            XCTAssertEqual(responses[1]["id"] as? Int, 7)
            XCTAssertEqual(outcome(responses[0]), "selected")
            await fixture.controller.shutdown()
        } catch {
            await fixture.controller.shutdown()
            throw error
        }
    }

    func testDuplicateDuringAuthorizationInvalidatesPendingApproval() async throws {
        let fixture = try await makeFixture(scenario: "duplicate")
        var events = await fixture.controller.events.makeAsyncIterator()
        let prompt = Task { try await fixture.controller.prompt(AgentMessage(userMessage: "Run"), request: fixture.request) }
        let gate = AuthorizationGate()
        let watchdog = watchdog(for: fixture, gate: gate)
        defer { watchdog.cancel() }
        do {
            let first = try await nextApproval(&events)
            let response = Task {
                await fixture.controller.respondToPermissionRequestForOverseer(id: first.requestID.displayValue, decision: .accept) {
                    await gate.hold()
                }
            }
            await gate.waitForEntry()
            try Data().write(to: fixture.trigger)
            guard case let .stream(error) = await events.next() else {
                gate.release()
                XCTFail("Duplicate active wire IDs must fail the protocol, not publish another approval")
                await fixture.controller.shutdown()
                _ = await response.value
                _ = try? await prompt.value
                return
            }
            XCTAssertEqual(error.type, "error")
            gate.release()
            let result = await response.value
            XCTAssertEqual(result, .notSubmitted)
            do {
                try await prompt.value
                XCTFail("Duplicate active wire IDs must fail the active prompt")
            } catch {}
            await fixture.controller.shutdown()
            XCTAssertTrue(try fixture.responses().isEmpty)
        } catch {
            gate.release()
            await fixture.controller.shutdown()
            throw error
        }
    }

    func testCancellationAndWireIDReuseCannotConsumeAnEarlierApproval() async throws {
        let fixture = try await makeFixture(scenario: "reuse")
        var events = await fixture.controller.events.makeAsyncIterator()
        let prompt = Task { try await fixture.controller.prompt(AgentMessage(userMessage: "Run"), request: fixture.request) }
        let gate = AuthorizationGate()
        let watchdog = watchdog(for: fixture, gate: gate)
        defer { watchdog.cancel() }
        do {
            let first = try await nextApproval(&events)
            let staleResponse = Task {
                await fixture.controller.respondToPermissionRequestForOverseer(id: first.requestID.displayValue, decision: .accept) {
                    await gate.hold()
                }
            }
            await gate.waitForEntry()
            await fixture.controller.cancelPrompt()
            let replacement = try await nextApproval(&events)
            XCTAssertNotEqual(first.id, replacement.id)
            gate.release()
            let staleResult = await staleResponse.value
            XCTAssertEqual(staleResult, .notSubmitted)
            let freshResult = await fixture.controller.respondToPermissionRequestForOverseer(
                id: replacement.requestID.displayValue, decision: .accept, authorize: { true }
            )
            XCTAssertEqual(freshResult, .submitted)
            try await prompt.value
            let responses = try fixture.responses()
            XCTAssertEqual(responses.map { outcome($0) }, ["cancelled", "selected"])
            await fixture.controller.shutdown()
        } catch {
            gate.release()
            await fixture.controller.shutdown()
            throw error
        }
    }

    private func watchdog(for fixture: Fixture, gate: AuthorizationGate? = nil) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            XCTFail("Permission identity fixture exceeded its bounded deadline")
            gate?.release()
            await fixture.controller.shutdown()
        }
    }

    private func nextApproval(_ events: inout AsyncStream<NormalizedAgentRuntimeEvent>.Iterator) async throws -> AgentApprovalRequest {
        while let event = await events.next() {
            if case let .approvalRequested(approval) = event { return approval }
        }
        throw NSError(domain: "ACPPermissionIdentityTests", code: 1)
    }

    private func outcome(_ response: [String: Any]) -> String? {
        ((response["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String
    }

    private struct Fixture {
        let controller: ACPAgentSessionController
        let request: ACPRunRequest
        let trigger: URL
        let record: URL

        func responses() throws -> [[String: Any]] {
            let text = try String(contentsOf: record, encoding: .utf8)
            return try text.split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
    }

    private func makeFixture(scenario: String) async throws -> Fixture {
        let directory = try makeTestDirectory(name: "ACPPermissionIdentity")
        let executable = directory.appendingPathComponent("scripted-acp")
        let trigger = directory.appendingPathComponent("continue")
        let record = directory.appendingPathComponent("responses.jsonl")
        try Data().write(to: record)
        let script = #"""
        #!/usr/bin/env python3
        import json, sys, os, time
        scenario = "\#(scenario)"
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        def permission(wire_id, item):
            send({"id": wire_id, "method": "session/request_permission", "params": {
                "sessionId": "test-session", "toolCall": {"toolCallId": item, "title": item, "kind": "execute"},
                "options": [{"optionId": "once", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]}})
        prompt_id = None
        response_count = 0
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                permission("7", "first")
                if scenario == "typed":
                    permission(7, "second")
                elif scenario == "duplicate":
                    deadline = time.monotonic() + 10
                    while not os.path.exists(r"\#(trigger.path)") and time.monotonic() < deadline:
                        time.sleep(0.01)
                    permission("7", "second")
            elif "result" in request:
                with open(r"\#(record.path)", "a", encoding="utf-8") as output:
                    output.write(json.dumps(request) + "\n")
                response_count += 1
                if scenario == "reuse" and response_count == 1:
                    permission("7", "second")
                elif response_count == 2:
                    send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let request = ACPRunRequest(
            agentKind: .openCode, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: ScriptedScopeProvider(providerID: .openCode, executable: executable.path), runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )
        do { _ = try await controller.bootstrap() } catch {
            await controller.shutdown()
            throw error
        }
        return Fixture(controller: controller, request: request, trigger: trigger, record: record)
    }

    @MainActor
    private final class AuthorizationGate {
        private var entered = false
        private var released = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var continuation: CheckedContinuation<Bool, Never>?

        func hold() async -> Bool {
            if released { return true }
            return await withCheckedContinuation {
                continuation = $0
                entered = true
                entryWaiter?.resume()
                entryWaiter = nil
            }
        }

        func waitForEntry() async {
            if entered || released { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }

        func release() {
            released = true
            entryWaiter?.resume()
            entryWaiter = nil
            continuation?.resume(returning: true)
            continuation = nil
        }
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
    func testGrokOmitsRawOptionsDetailsAndOtherProvidersKeepThem() async throws {
        let bashOptions = [
            ["optionId": "always-allow", "kind": "allow_always", "name": "Yes, and don't ask again for bash commands"],
            ["optionId": "allow-once", "kind": "allow_once", "name": "Yes, proceed"],
            ["optionId": "reject-once", "kind": "reject_once", "name": "No"],
            ["optionId": "reject-always", "kind": "reject_always", "name": "No, and don't ask again for this command"]
        ]
        let editOptions = [
            ["optionId": "allow-edits-session", "kind": "allow_always", "name": "Yes, allow all edits during this session"],
            ["optionId": "allow-once", "kind": "allow_once", "name": "Yes"],
            ["optionId": "reject-once", "kind": "reject_once", "name": "No"]
        ]
        let cases: [(
            providerID: ACPProviderID,
            toolKind: String,
            options: [[String: String]],
            scope: AgentApprovalSessionScope?,
            expectedPlainApprove: Bool,
            showsOptions: Bool,
            selectedOptionID: String
        )] = [
            (.grokBuild, "execute", bashOptions, .oneTime, true, false, "allow-once"),
            (.grokBuild, "edit", editOptions, .editsSession, true, false, "allow-edits-session"),
            (.openCode, "execute", bashOptions, nil, true, true, "always-allow")
        ]
        for testCase in cases {
            let outcome = try await permissionOutcome(
                providerID: testCase.providerID, decision: .acceptForSession, options: testCase.options,
                expectedPlainApprove: testCase.expectedPlainApprove, toolKind: testCase.toolKind, expectedSessionScope: testCase.scope, expectedOptionsDetail: testCase.showsOptions
            )
            XCTAssertEqual(outcome["outcome"], "selected", "\(testCase.providerID): \(testCase.toolKind)")
            XCTAssertEqual(outcome["optionId"], testCase.selectedOptionID, "\(testCase.providerID): \(testCase.toolKind)")
        }
    }

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

    func testOneTimeApprovalRejectsScopedMCPResponsesWithoutConsumingPrompt() async throws {
        let context = try await AgentRunMCPControlledSessionContext.make(
            workspaceNamePrefix: "ACP one-time responses", workspaceSwitchReason: "acpOneTimeResponseTests",
            clientName: "acp-one-time-response-tests", unusedStartRunMessage: "No provider starts"
        )
        addTeardownBlock { @MainActor in await context.cleanup() }
        let viewModel = context.window.agentModeViewModel
        for available in [false, true] {
            let request = approval(available: available, sessionApprovalScope: .oneTime)
            context.session.pendingApproval = request
            context.session.runState = .waitingForApproval
            for (response, amendment): (String, String?) in [
                ("accept_for_session", nil), ("always_allow", nil), ("approve_for_session", nil),
                ("accept_with_amendment", "remember"), ("amend", "remember")
            ] {
                let payload = AgentModeViewModel.MCPInteractionResponsePayload(
                    text: nil, skip: false, responseArgument: .scalar(response), amendment: amendment, answersByQuestionID: [:]
                )
                XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
                    for: context.session, kind: .approval, interactionID: request.id, payload: payload
                ), "\(response), plain approval: \(available)") { error in
                    guard let mcpError = error as? MCPError, case .invalidParams = mcpError else {
                        return XCTFail("Expected MCPError.invalidParams for \(response), got \(error)")
                    }
                }
                XCTAssertEqual(context.session.pendingApproval, request, "\(response) must leave the same approval pending")
                XCTAssertEqual(context.session.runState, .waitingForApproval)
            }
        }
    }

    func testGrokApprovalPresentationMatchesSelectedScope() async throws {
        let context = try await AgentRunMCPControlledSessionContext.make(
            workspaceNamePrefix: "ACP approval scope", workspaceSwitchReason: "acpApprovalScopeTests",
            clientName: "acp-approval-scope-tests", unusedStartRunMessage: "No provider starts"
        )
        addTeardownBlock { @MainActor in await context.cleanup() }
        let cases: [(
            scope: AgentApprovalSessionScope?, kind: AgentApprovalKind, available: Bool,
            label: String?, options: [String], sessionDescription: String?
        )] = [
            (.oneTime, .commandExecution, true, nil, ["accept", "decline", "cancel"], nil),
            (.oneTime, .commandExecution, false, nil, ["decline", "cancel"], nil),
            (
                .editsSession,
                .fileChange,
                true,
                "Allow edits this session",
                ["accept", "accept_for_session", "decline", "cancel"],
                "Allow edits for the rest of this session"
            ),
            (
                .editsSession,
                .commandExecution,
                true,
                "Allow edits this session",
                ["accept", "accept_for_session", "decline", "cancel"],
                "Allow edits for the rest of this session"
            ),
            (
                nil,
                .commandExecution,
                true,
                "Always Allow",
                ["accept", "accept_for_session", "accept_with_amendment", "decline", "cancel"],
                "Allow this action for the rest of the session"
            ),
            (
                nil,
                .fileChange,
                true,
                "Always Allow",
                ["accept", "accept_for_session", "decline", "cancel"],
                "Allow this action for the rest of the session"
            )
        ]
        for testCase in cases {
            let request = AgentApprovalRequest(
                requestID: .acp("permission"), method: "session/request_permission",
                kind: testCase.kind,
                threadID: "thread", turnID: "turn", itemID: "item",
                plainApproveAvailable: testCase.available, sessionApprovalScope: testCase.scope
            )
            XCTAssertEqual(request.supportsAlwaysAllow, testCase.label != nil)
            if let label = testCase.label {
                XCTAssertEqual(request.sessionApprovalLabel, label)
            }
            context.session.pendingApproval = request
            context.session.runState = .waitingForApproval
            let interaction = try XCTUnwrap(context.window.agentModeViewModel.mcpPendingInteraction(for: context.session))
            XCTAssertEqual(
                interaction.options.map(\.label), testCase.options,
                "\(String(describing: testCase.scope)): \(testCase.kind), plain approval: \(testCase.available)"
            )
            if let sessionDescription = testCase.sessionDescription {
                let sessionOption = try XCTUnwrap(interaction.options.first { $0.label == "accept_for_session" })
                XCTAssertEqual(sessionOption.description, sessionDescription)
            }
            if testCase.scope == nil, request.kind == .commandExecution {
                let amendmentOption = try XCTUnwrap(interaction.options.first { $0.label == "accept_with_amendment" })
                XCTAssertEqual(amendmentOption.description, "Allow with exec policy amendment (provide amendment field)")
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

    private func approval(available: Bool?, sessionApprovalScope: AgentApprovalSessionScope? = nil) -> AgentApprovalRequest {
        AgentApprovalRequest(
            requestID: .acp("permission"), method: "session/request_permission", kind: .commandExecution,
            threadID: "thread", turnID: "turn", itemID: "item", command: "ls",
            plainApproveAvailable: available, sessionApprovalScope: sessionApprovalScope
        )
    }
}

@MainActor
final class CodexApprovalChoiceTests: XCTestCase {
    private static let plainCommand = #"{"threadId":"thread","turnId":"turn","itemId":"cmd-b","command":"git status","availableDecisions":["accept","cancel"]}"#
    private static let amendmentCommand = #"{"threadId":"thread","turnId":"turn","itemId":"cmd-a","command":"git status","proposedExecpolicyAmendment":["git","status"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}},"cancel"]}"#

    func testAdvertisedDecisionsBoundMCPOptions() async throws {
        let context = try await makeContext()
        for (json, expected) in [
            (Self.plainCommand, ["accept", "cancel"]),
            (Self.amendmentCommand, ["accept", "accept_with_amendment", "cancel"])
        ] {
            try install(parsedRequest(json), in: context)
            let interaction = try XCTUnwrap(context.window.agentModeViewModel.mcpPendingInteraction(for: context.session))
            XCTAssertEqual(interaction.options.map(\.label), expected, "MCP options must equal availableDecisions: \(json)")
        }
    }

    func testUnadvertisedMCPResponsesAreRejected() async throws {
        let context = try await makeContext()
        let viewModel = context.window.agentModeViewModel
        for (json, rejected, accepted) in [
            (Self.plainCommand, [("accept_for_session", nil), ("accept_with_amendment", #"["git","status"]"#)], [("accept", nil), ("cancel", nil)]),
            (Self.amendmentCommand, [("accept_with_amendment", #"["git"]"#), ("accept_with_amendment", "not-json")], [("accept", nil), ("cancel", nil), ("accept_with_amendment", #"["git","status"]"#)])
        ] as [(String, [(String, String?)], [(String, String?)])] {
            let request = try parsedRequest(json)
            install(request, in: context)
            for (response, amendment) in accepted {
                XCTAssertNoThrow(try viewModel.mcpPendingInteractionResolution(
                    for: context.session, kind: .approval, interactionID: request.id, payload: payload(response, amendment)
                ), "Advertised \(response) \(amendment ?? "") must still resolve: \(json)")
            }
            for (response, amendment) in rejected {
                XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
                    for: context.session, kind: .approval, interactionID: request.id, payload: payload(response, amendment)
                ), "Unadvertised \(response) \(amendment ?? "") must be rejected: \(json)") { error in
                    guard let mcpError = error as? MCPError, case .invalidParams = mcpError else {
                        return XCTFail("Expected MCPError.invalidParams for \(response), got \(error)")
                    }
                }
            }
        }
    }

    func testTopLevelAdvertisedDecisionsFailClosedAndPreserveLegacy() throws {
        let decisions: [AgentApprovalDecision] = [.accept, .acceptForSession, .acceptWithExecpolicyAmendment(#"["git","status"]"#), .decline, .cancel]
        let cases: [(String, String?, [Bool])] = [
            ("absent", nil, [true, true, true, true, true]),
            ("null", "null", [true, true, true, true, true]),
            ("empty", "[]", [false, false, false, false, false]),
            ("nonarray", "42", [false, false, false, false, false]),
            ("writeStdin", #"["accept","cancel"]"#, [true, false, false, false, true]),
            ("network", #"["accept","acceptForSession",{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.test","action":"allow"}}},"future",false,"cancel"]"#, [true, true, false, false, true]),
            ("decline only", #"["decline"]"#, [false, false, false, true, false]),
            ("malformed entries", #"[{},["accept"],17,{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":[]}}]"#, [false, false, false, false, false])
        ]
        for (label, encoded, expected) in cases {
            var params: [String: Any] = ["threadId": "thread", "command": "git status", "kind": "writeStdin"]
            // Neither a nested list nor a nested legacy grant may override the top-level authority.
            params["nested"] = ["availableDecisions": ["acceptForSession"]]
            if let encoded {
                params["availableDecisions"] = try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: .fragmentsAllowed)
            }
            let request = try XCTUnwrap(CodexNativeSessionController.parseApprovalRequest(
                requestID: .int(1), method: "item/commandExecution/requestApproval", params: params,
                activeThreadID: "thread", currentTurnID: "turn"
            ))
            XCTAssertEqual(request.availableDecisions == nil, encoded == nil || encoded == "null", label)
            XCTAssertEqual(decisions.map { request.allows($0) }, expected, label)
            XCTAssertEqual(request.supportsPlainApprove, expected[0], label)
            XCTAssertEqual(request.supportsAlwaysAllow, expected[1], label)
            for (index, decision) in decisions.enumerated() {
                let result = CodexAgentModeCoordinator.buildApprovalResult(decision: decision, request: request)
                XCTAssertEqual(result != nil, expected[index], "\(label): \(decision)")
                if expected[index], index != 2 {
                    XCTAssertEqual(result?["decision"] as? String, ["accept", "acceptForSession", "", "decline", "cancel"][index], label)
                }
            }
        }
    }

    func testAdvertisedAmendmentsRequireExactDecodedTokens() async throws {
        let context = try await makeContext()
        let viewModel = context.window.agentModeViewModel
        let session = context.session
        session.selectedAgent = .codexExec
        let composed = #"["printf","%s","caf\u00e9"]"#
        let decomposed = #"["printf","%s","cafe\u0301"]"#
        let examples: [(advertised: String, denied: String, equivalent: String, expected: [String])] = [
            (composed, decomposed, " [ \"printf\", \"%s\", \"caf\u{E9}\" ] ", ["printf", "%s", "caf\u{E9}"]),
            (decomposed, composed, " [ \"printf\", \"%s\", \"cafe\u{301}\" ] ", ["printf", "%s", "cafe\u{301}"])
        ]
        let sent = expectation(description: "Only exact decoded amendments reach the controller")
        sent.expectedFulfillmentCount = examples.count
        let controller = ApprovalRecordingController(sent: sent)
        session.codexController = controller
        let requests = try examples.enumerated().map { index, example in
            try parsedRequest(#"{"threadId":"thread","itemId":"unicode-\#(index)","command":"printf","availableDecisions":[{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":\#(example.advertised)}}]}"#)
        }
        for (request, example) in zip(requests, examples) {
            install(request, in: context)
            let denied = AgentApprovalDecision.acceptWithExecpolicyAmendment(example.denied)
            XCTAssertFalse(request.allows(denied))
            XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
                for: session, kind: .approval, interactionID: request.id, payload: payload("accept_with_amendment", example.denied)
            ))
            XCTAssertThrowsError(try viewModel.applyPendingInteractionResolution(.approval(request: request, decision: denied), to: session))
            XCTAssertEqual(session.pendingApproval?.id, request.id)
            XCTAssertEqual(session.runState, .waitingForApproval)
        }
        XCTAssertTrue(controller.recorder.events.isEmpty)

        func amendmentBytes(_ result: [String: Any]) throws -> [[UInt8]] {
            let object = try XCTUnwrap(result["decision"] as? [String: [String: [String]]])
            let tokens = try XCTUnwrap(object["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"])
            return tokens.map { Array($0.utf8) }
        }
        for (request, example) in zip(requests, examples) {
            install(request, in: context)
            let decision = AgentApprovalDecision.acceptWithExecpolicyAmendment(example.equivalent)
            XCTAssertTrue(request.allows(decision), "JSON escapes and whitespace must not change token identity")
            let resolution = try viewModel.mcpPendingInteractionResolution(
                for: session, kind: .approval, interactionID: request.id, payload: payload("accept_with_amendment", example.equivalent)
            )
            try viewModel.applyPendingInteractionResolution(resolution, to: session)
            XCTAssertNil(session.pendingApproval)
        }
        await fulfillment(of: [sent], timeout: 3)
        let received = try controller.recorder.events.map { event in
            XCTAssertTrue(event.hasPrefix("1:"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.dropFirst(2).utf8)) as? [String: Any])
            return try amendmentBytes(object)
        }
        XCTAssertEqual(received.count, examples.count)
        for example in examples {
            XCTAssertTrue(received.contains(example.expected.map { Array($0.utf8) }), "Wire comparison must not use String canonical equality")
        }
    }

    func testAmendmentsMatchDecodedAdvertisementAndNeverWidenOnMalformedInput() async throws {
        let params: [String: Any] = [
            "threadId": "thread", "command": "git status", "proposedExecpolicyAmendment": ["wrong"],
            "availableDecisions": [["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]]]
        ]
        let request = try XCTUnwrap(CodexNativeSessionController.parseApprovalRequest(
            requestID: .int(1), method: "item/commandExecution/requestApproval", params: params,
            activeThreadID: "thread", currentTurnID: "turn"
        ))
        let equal = AgentApprovalDecision.acceptWithExecpolicyAmendment(" [ \"git\", \"status\" ] ")
        XCTAssertTrue(request.allows(equal))
        XCTAssertFalse(request.allows(.acceptWithExecpolicyAmendment(#"["wrong"]"#)))
        XCTAssertFalse(request.allows(.acceptForSession))
        var withoutProposal = params
        withoutProposal.removeValue(forKey: "proposedExecpolicyAmendment")
        let advertisedOnly = try XCTUnwrap(CodexNativeSessionController.parseApprovalRequest(
            requestID: .int(1), method: "item/commandExecution/requestApproval", params: withoutProposal,
            activeThreadID: "thread", currentTurnID: "turn"
        ))
        XCTAssertEqual(advertisedOnly.rememberedDecision, request.rememberedDecision)
        let remembered = try XCTUnwrap(request.rememberedDecision)
        XCTAssertTrue(request.allows(remembered), "The advertised payload, not the top-level proposal, owns Remember")
        let wire = try XCTUnwrap(CodexAgentModeCoordinator.buildApprovalResult(decision: remembered, request: request))
        let object = try XCTUnwrap(wire["decision"] as? [String: [String: [String]]])
        XCTAssertEqual(object, ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]])

        let context = try await makeContext()
        let presentations: [(String, AgentApprovalRequest, [String]?)] = try [
            ("inconsistent proposal", request, ["git", "status"]),
            ("advertised only", advertisedOnly, ["git", "status"]),
            ("present without amendment", parsedRequest(#"{"threadId":"thread","command":"git status","proposedExecpolicyAmendment":["wrong"],"availableDecisions":["accept","cancel"]}"#), nil),
            ("absent legacy", parsedRequest(#"{"threadId":"thread","command":"git status","proposedExecpolicyAmendment":["wrong"]}"#), ["wrong"]),
            ("null legacy", parsedRequest(#"{"threadId":"thread","command":"git status","proposedExecpolicyAmendment":["wrong"],"availableDecisions":null}"#), ["wrong"])
        ]
        for (label, target, expected) in presentations {
            install(target, in: context)
            let cardDetails = target.details.filter { $0.label == "Execpolicy Amendment" }
            let interaction = try XCTUnwrap(context.window.agentModeViewModel.mcpPendingInteraction(for: context.session))
            let mcpDetails = interaction.details.filter { ["Suggested Amendment", "Execpolicy Amendment"].contains($0.label) }
            XCTAssertEqual(cardDetails.count, expected == nil ? 0 : 1, label)
            XCTAssertEqual(mcpDetails.count, expected == nil ? 0 : 2, label)
            for value in cardDetails.map(\.value) + mcpDetails.map(\.value) {
                let tokens = try XCTUnwrap(AgentApprovalDecision.parseExecpolicyAmendment(value))
                XCTAssertEqual(tokens.map { Array($0.utf8) }, expected?.map { Array($0.utf8) } ?? [], label)
            }
            if let expected {
                let decision = try XCTUnwrap(target.rememberedDecision)
                let result = try XCTUnwrap(CodexAgentModeCoordinator.buildApprovalResult(decision: decision, request: target))
                let object = try XCTUnwrap(result["decision"] as? [String: [String: [String]]])
                let tokens = try XCTUnwrap(object["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"])
                XCTAssertEqual(tokens.map { Array($0.utf8) }, expected.map { Array($0.utf8) }, label)
            }
        }

        let legacy = try parsedRequest(#"{"threadId":"thread","command":"git status"}"#)
        let fileChange = AgentApprovalRequest(
            requestID: .codex(.int(1)), method: "item/fileChange/requestApproval", kind: .fileChange,
            threadID: "thread", turnID: "turn", itemID: "file"
        )
        XCTAssertTrue(legacy.allows(equal))
        XCTAssertFalse(fileChange.allows(equal))
        for malformed in ["not-json", "null", "{}", "[]", "[1]", "[true]", #"["git",1]"#] {
            for target in [request, legacy, fileChange] {
                let decision = AgentApprovalDecision.acceptWithExecpolicyAmendment(malformed)
                XCTAssertFalse(target.allows(decision), malformed)
                XCTAssertNil(CodexAgentModeCoordinator.buildApprovalResult(decision: decision, request: target), malformed)
            }
        }
    }

    func testCheckedApplyPreservesRejectedRequestsAndRecordsOnlyAllowedWireResponses() async throws {
        let context = try await makeContext()
        let viewModel = context.window.agentModeViewModel
        let session = context.session
        session.selectedAgent = .codexExec
        let sent = expectation(description: "Only the six allowed responses reach the passive controller")
        sent.expectedFulfillmentCount = 6
        let controller = ApprovalRecordingController(sent: sent)
        session.codexController = controller
        let plain = try parsedRequest(Self.plainCommand)
        let amendment = try parsedRequest(Self.amendmentCommand)
        install(plain, in: context)
        for (response, value) in [
            ("accept_for_session", nil), ("always_allow", nil), ("approve_for_session", nil),
            ("decline", nil), ("reject", nil), ("amend", #"["git"]"#), ("accept_with_amendment", "not-json")
        ] as [(String, String?)] {
            XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
                for: session, kind: .approval, interactionID: plain.id, payload: payload(response, value)
            )) { error in
                guard case let MCPError.invalidParams(message) = error, let message else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains("accept, cancel"))
                XCTAssertTrue(message.contains("No response was applied."))
            }
            XCTAssertEqual(session.pendingApproval, plain)
            XCTAssertEqual(session.runState, .waitingForApproval)
        }
        for decision: AgentApprovalDecision in [.acceptForSession, .decline, .acceptWithExecpolicyAmendment(#"["git"]"#)] {
            XCTAssertFalse(viewModel.submitApprovalDecision(tabID: session.tabID, requestID: plain.id, decision: decision))
            XCTAssertThrowsError(try viewModel.applyPendingInteractionResolution(.approval(request: plain, decision: decision), to: session))
            XCTAssertEqual(session.pendingApproval, plain)
            XCTAssertEqual(session.runState, .waitingForApproval)
        }
        let stale = try viewModel.mcpPendingInteractionResolution(
            for: session, kind: .approval, interactionID: plain.id, payload: payload("accept", nil)
        )
        install(amendment, in: context)
        XCTAssertThrowsError(try viewModel.applyPendingInteractionResolution(stale, to: session))
        XCTAssertFalse(viewModel.submitApprovalDecision(tabID: session.tabID, requestID: plain.id, decision: .accept))
        XCTAssertEqual(session.pendingApproval, amendment)
        XCTAssertEqual(session.runState, .waitingForApproval)

        let legacy = try parsedRequest(#"{"threadId":"thread","command":"git status"}"#)
        install(legacy, in: context)
        let beforeCU = try viewModel.mcpPendingInteractionResolution(
            for: session, kind: .approval, interactionID: legacy.id, payload: payload("accept_for_session", nil)
        )
        session.codexControllerFeatureState = .init(computerUseEnabled: true, goalSupportEnabled: false, reasoningSummariesEnabled: false, memoriesEnabled: false)
        XCTAssertEqual(try XCTUnwrap(viewModel.mcpPendingInteraction(for: session)).options.map(\.label), ["accept", "decline", "cancel"])
        XCTAssertThrowsError(try viewModel.mcpPendingInteractionResolution(
            for: session, kind: .approval, interactionID: legacy.id, payload: payload("accept_for_session", nil)
        ))
        XCTAssertThrowsError(try viewModel.applyPendingInteractionResolution(beforeCU, to: session))
        XCTAssertEqual(session.pendingApproval, legacy)
        XCTAssertEqual(session.runState, .waitingForApproval)
        XCTAssertTrue(controller.recorder.events.isEmpty)
        session.codexControllerFeatureState = nil

        let cancelOnly = try parsedRequest(#"{"threadId":"thread","command":"git status","availableDecisions":["cancel"]}"#)
        let network = try parsedRequest(#"{"threadId":"thread","command":"git status","availableDecisions":["accept","acceptForSession","cancel"]}"#)
        let fileChange = AgentApprovalRequest(
            requestID: .codex(.int(1)), method: "item/fileChange/requestApproval", kind: .fileChange,
            threadID: "thread", turnID: "turn", itemID: "file"
        )
        let cases: [(AgentApprovalRequest, String, String?, [AgentNotificationAction], String)] = [
            (plain, "accept", nil, [.approve, .review], #"{"decision":"accept"}"#),
            (cancelOnly, "cancel", nil, [.review], #"{"decision":"cancel"}"#),
            (amendment, "accept_with_amendment", " [ \"git\", \"status\" ] ", [.approve, .review], #"{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}}}"#),
            (legacy, "decline", nil, [.approve, .decline, .review], #"{"decision":"decline"}"#),
            (fileChange, "decline", nil, [.decline, .review], #"{"decision":"decline"}"#),
            (network, "accept_for_session", nil, [.approve, .review], #"{"decision":"acceptForSession"}"#)
        ]
        for (request, response, value, expectedActions, _) in cases {
            install(request, in: context)
            let descriptor = try XCTUnwrap(AgentPendingInteractionDescriptor.make(from: session))
            XCTAssertEqual(descriptor.supportsDecline, expectedActions.contains(.decline))
            let actions = AgentNotificationActionEligibility.actions(for: descriptor, isMCPControlled: false, preferences: .defaults)
            XCTAssertEqual(actions, expectedActions)
            let category = try XCTUnwrap(AgentNotificationAction.category(for: actions, interactionID: nil))
            XCTAssertTrue(AgentNotificationAction.staticCategories.contains(category), "Non-choice approval actions must remain registered")
            let resolution = try viewModel.mcpPendingInteractionResolution(
                for: session, kind: .approval, interactionID: request.id, payload: payload(response, value)
            )
            try viewModel.applyPendingInteractionResolution(resolution, to: session)
            XCTAssertNil(session.pendingApproval)
            XCTAssertNotEqual(session.runState, .waitingForApproval)
            XCTAssertFalse(viewModel.submitApprovalDecision(tabID: session.tabID, requestID: request.id, decision: .cancel))
            XCTAssertThrowsError(try viewModel.applyPendingInteractionResolution(resolution, to: session))
        }
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertEqual(controller.recorder.events.sorted(), cases.map { "1:\($0.4)" }.sorted())
    }

    private final class ApprovalRecordingController: CodexSessionControllerPassiveStubDefaults {
        let recorder = LifecycleRecorder()
        let sent: XCTestExpectation
        init(sent: XCTestExpectation) {
            self.sent = sent
        }

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { $0.finish() }
        }

        func shutdown() async {}
        func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                recorder.record("\(id.displayValue):\(String(decoding: data, as: UTF8.self))")
            } catch { XCTFail("Invalid wire result: \(error)") }
            sent.fulfill()
        }
    }

    private func makeContext() async throws -> AgentRunMCPControlledSessionContext {
        let context = try await AgentRunMCPControlledSessionContext.make(
            workspaceNamePrefix: "Codex approval choices", workspaceSwitchReason: "codexApprovalChoiceTests",
            clientName: "codex-approval-choice-tests", unusedStartRunMessage: "No provider starts"
        )
        addTeardownBlock { @MainActor in await context.cleanup() }
        return context
    }

    private func parsedRequest(_ json: String) throws -> AgentApprovalRequest {
        let params = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "Fixture must be a JSON object"
        )
        return try XCTUnwrap(CodexNativeSessionController.parseApprovalRequest(
            requestID: .int(1), method: "item/commandExecution/requestApproval", params: params,
            activeThreadID: "thread", currentTurnID: "turn"
        ), "Codex fixture must parse: \(json)")
    }

    private func install(_ request: AgentApprovalRequest, in context: AgentRunMCPControlledSessionContext) {
        context.session.pendingApproval = request
        context.session.runState = .waitingForApproval
    }

    private func payload(_ response: String, _ amendment: String?) -> AgentModeViewModel.MCPInteractionResponsePayload {
        AgentModeViewModel.MCPInteractionResponsePayload(
            text: nil, skip: false, responseArgument: .scalar(response), amendment: amendment, answersByQuestionID: [:]
        )
    }
}
