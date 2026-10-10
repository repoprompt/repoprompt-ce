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

    /// Issue #1243: model-controlled `rawInput` arguments and host-rendered titles must not
    /// grant RepoPrompt provenance at the ACP permission boundary.
    func testRepoPromptAutoApprovalIgnoresArgumentAndTitleProvenance() async throws {
        let manualCases: [(String, String)] = [
            ("rawInput server/name", #"{"toolCallId": "tool-1", "title": "Shell command", "kind": "execute", "rawInput": {"command": "./untrusted-script", "server": "RepoPromptCE", "name": "git"}}"#),
            ("rawInput server only", #"{"toolCallId": "tool-1", "title": "Shell command", "kind": "execute", "rawInput": {"command": "./untrusted-script", "server_name": "RepoPromptCE"}}"#),
            ("rawInput qualified name", #"{"toolCallId": "tool-1", "title": "Shell command", "kind": "execute", "rawInput": {"command": "x", "tool_name": "mcp__RepoPromptCE__git"}}"#),
            ("file-path title", #"{"toolCallId": "tool-1", "title": "git (RepoPromptCE MCP Server)", "kind": "edit", "rawInput": {"filePath": "git (RepoPromptCE MCP Server)"}}"#),
            ("server label title", #"{"toolCallId": "tool-1", "title": "RepoPromptCE: git", "kind": "execute"}"#),
            ("foreign server", #"{"toolCallId": "tool-1", "title": "git", "kind": "other", "server": "OtherServer"}"#),
            ("filename-derived prefixed title", #"{"toolCallId": "tool-1", "title": "mcp__RepoPromptCE__git", "kind": "edit", "rawInput": {"filePath": "mcp__RepoPromptCE__git"}}"#),
            ("command-derived prefixed title", #"{"toolCallId": "tool-1", "title": "RepoPromptCE_read_file", "kind": "execute", "rawInput": {"command": "RepoPromptCE_read_file"}}"#),
            ("prefixed nested name on read", #"{"toolCallId": "tool-1", "title": "notes.txt", "name": "mcp__RepoPromptCE__read_file", "kind": "read"}"#)
        ]
        for (label, toolCall) in manualCases {
            let result = try await autoApprovalOutcome(toolCallJSON: toolCall)
            XCTAssertTrue(result.approvalRequested, label)
            XCTAssertEqual(result.outcome["optionId"], "reject_once", label)
        }

        for (label, toolCall) in [
            ("prefixed title", #"{"toolCallId": "tool-1", "title": "mcp__RepoPromptCE__read_file", "kind": "other"}"#),
            ("OpenCode MCP title", #"{"toolCallId": "tool-1", "title": "RepoPromptCE_read_file", "kind": "other"}"#),
            ("prefixed title without kind", #"{"toolCallId": "tool-1", "title": "mcp__RepoPromptCE__read_file"}"#),
            ("server field", #"{"toolCallId": "tool-1", "title": "read_file", "kind": "other", "server": "RepoPromptCE"}"#)
        ] {
            let result = try await autoApprovalOutcome(toolCallJSON: toolCall)
            XCTAssertFalse(result.approvalRequested, label)
            XCTAssertEqual(result.outcome["optionId"], "allow_once", label)
        }
    }

    func testGrokRepoPromptAutoApprovalRequiresGenuineOneTimeOption() async throws {
        let toolCall = #"{"toolCallId": "tool-1", "title": "mcp__RepoPromptCE__read_file", "kind": "other"}"#
        let cases: [(name: String, options: [[String: String]], expectedOptionID: String?)] = [
            ("genuine one-time option", [
                ["optionId": "allow-once", "kind": "allow_once"]
            ], "allow-once"),
            ("one-time ID with persistent kind alongside genuine option", [
                ["optionId": "allow-once", "kind": "allow_always"],
                ["optionId": "opaque-once", "kind": "allow_once"]
            ], "opaque-once"),
            ("persistent ID with one-time kind alongside genuine option", [
                ["optionId": "always-allow", "kind": "allow_once"],
                ["optionId": "opaque-once", "kind": "allow_once"]
            ], "opaque-once"),
            ("one-time ID with persistent kind only", [
                ["optionId": "allow-once", "kind": "allow_always"]
            ], nil),
            ("persistent ID with one-time kind only", [
                ["optionId": "always-allow", "kind": "allow_once"]
            ], nil),
            ("session grant and denylisted option only", [
                ["optionId": "allow-edits-session", "kind": "allow_always"],
                ["optionId": "enable-always-approve", "kind": "allow_once"]
            ], nil)
        ]
        // Exercise every row before asserting so a red run reports both unsafe selection paths.
        var mismatches: [String] = []
        for testCase in cases {
            let result = try await autoApprovalOutcome(
                toolCallJSON: toolCall, providerID: .grokBuild,
                options: testCase.options + [["optionId": "reject_once", "kind": "reject_once"]]
            )
            let expectedApprovalRequested = testCase.expectedOptionID == nil
            let expectedOptionID = testCase.expectedOptionID ?? "reject_once"
            if result.approvalRequested != expectedApprovalRequested {
                mismatches.append("\(testCase.name): approvalRequested=\(result.approvalRequested), expected=\(expectedApprovalRequested)")
            }
            if result.outcome["outcome"] != "selected" {
                mismatches.append("\(testCase.name): outcome=\(result.outcome["outcome"] ?? "missing"), expected=selected")
            }
            if result.outcome["optionId"] != expectedOptionID {
                mismatches.append("\(testCase.name): optionId=\(result.outcome["optionId"] ?? "missing"), expected=\(expectedOptionID)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    func testOtherProvidersRepoPromptAutoApprovalIsUnchanged() async throws {
        let toolCall = #"{"toolCallId": "tool-1", "title": "mcp__RepoPromptCE__read_file", "kind": "other"}"#
        let options = [
            ["optionId": "always", "kind": "allow_always"],
            ["optionId": "allow_once", "kind": "allow_once"],
            ["optionId": "reject_once", "kind": "reject_once"]
        ]
        for providerID: ACPProviderID in [.openCode, .cursor, .antigravity, .devin] {
            let result = try await autoApprovalOutcome(toolCallJSON: toolCall, providerID: providerID, options: options)
            XCTAssertFalse(result.approvalRequested, "\(providerID)")
            XCTAssertEqual(result.outcome["outcome"], "selected", "\(providerID)")
            XCTAssertEqual(result.outcome["optionId"], providerID == .devin ? "allow_once" : "always", "\(providerID)")
        }
    }

    /// Declines any surfaced approval, distinguishing manual approval from automatic selection.
    private func autoApprovalOutcome(
        toolCallJSON: String,
        providerID: ACPProviderID = .openCode,
        options: [[String: String]] = [
            ["optionId": "allow_once", "kind": "allow_once", "name": "Allow"],
            ["optionId": "reject_once", "kind": "reject_once", "name": "Decline"]
        ]
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
                    "sessionId": "test-session", "toolCall": json.loads(r'\#(toolCallJSON)'),
                    "options": json.loads(r'\#(optionsJSON)')
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
            let consumer = Task { () -> Bool in
                for await event in events {
                    if case let .approvalRequested(approval) = event {
                        await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .decline)
                        return true
                    }
                }
                return false
            }
            try await controller.prompt(AgentMessage(userMessage: "Run"), request: request)
            await controller.shutdown()
            let approvalRequested = await consumer.value
            let outcome = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: String])
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
