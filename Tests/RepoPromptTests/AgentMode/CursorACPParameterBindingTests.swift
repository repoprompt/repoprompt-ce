import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CursorACPParameterBindingTests: XCTestCase {
    func testCursorParameterizedModelPickerAdvertisesCapabilityAndAppliesExactIndependentValues() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_INCLUDE_PARAMETERS": "1"
            ],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()

        let initialize = try XCTUnwrap(recordedRequests(at: fixture.recordURL, method: "initialize").first)
        let capabilities = try XCTUnwrap(initialize.params["clientCapabilities"] as? [String: Any])
        let metadata = try XCTUnwrap(capabilities["_meta"] as? [String: Any])
        XCTAssertEqual(metadata["parameterizedModelPicker"] as? Bool, true)

        let discoveredSnapshot = await fixture.controller.currentDiscoveredSessionModels()
        let snapshot = try XCTUnwrap(discoveredSnapshot)
        XCTAssertEqual(snapshot.options.map(\.rawValue), ["model-a", "model-b"])
        let parameterSet = try XCTUnwrap(snapshot.modelParameterSets.first)
        XCTAssertEqual(parameterSet.baseModelRaw, "model-a")
        XCTAssertEqual(parameterSet.parameters.map(\.kind), [.thinking, .speed])
        XCTAssertEqual(parameterSet.parameters.map(\.configID), ["Cursor.Thought-Level", "Cursor.Fast-Mode"])

        try await fixture.controller.setSessionModel("model-b")
        let savedSelections: [ACPModelParameterSelection] = [
            .init(
                providerID: .cursor,
                baseModelRaw: "model-a",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "medium"
            ),
            .init(
                providerID: .cursor,
                baseModelRaw: "model-b",
                kind: .speed,
                configID: "Cursor.Fast-Mode",
                valueRaw: "true"
            ),
            .init(
                providerID: .cursor,
                baseModelRaw: "model-b",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "HIGH"
            )
        ]
        let activeSelections = ACPModelParameterSelection.selections(
            for: .cursor,
            activeBaseModelRaw: "Model B [Default]",
            from: savedSelections
        )
        XCTAssertEqual(activeSelections.map(\.baseModelRaw), ["model-b", "model-b"])

        let report = try await fixture.controller.applySessionModelParameterSelections(activeSelections)
        try await fixture.controller.setSessionMode("plan")
        try await fixture.controller.prompt(AgentMessage(userMessage: "Verify ordering"))
        await fixture.controller.shutdown()

        XCTAssertEqual(report.applied.map(\.kind), [.thinking, .speed])
        XCTAssertTrue(report.skipped.isEmpty)
        let mutations = recordedMutationRequests(at: fixture.recordURL)
        XCTAssertEqual(
            mutations.map { $0.params["configId"] as? String },
            ["model", "Cursor.Thought-Level", "Cursor.Fast-Mode", "mode"]
        )
        XCTAssertEqual(mutations.map { $0.params["value"] as? String }, ["model-b", "High", "true", "plan"])
        let configurationAndPromptMethods = recordedRequests(at: fixture.recordURL)
            .map(\.method)
            .filter { $0 == "session/set_config_option" || $0 == "session/prompt" }
        XCTAssertEqual(configurationAndPromptMethods, [
            "session/set_config_option",
            "session/set_config_option",
            "session/set_config_option",
            "session/set_config_option",
            "session/prompt"
        ])
    }

    func testCursorObservedFastSelectorAppliesExactConfigIDAndBooleanStringValue() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_INCLUDE_PARAMETERS": "1",
                "ACP_OBSERVED_FAST_SELECTOR": "1"
            ],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()

        let report = try await fixture.controller.applySessionModelParameterSelections([.init(
            providerID: .cursor,
            baseModelRaw: "model-a",
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )])

        XCTAssertEqual(report.applied.map(\.valueRaw), ["true"])
        XCTAssertTrue(report.alreadyCurrent.isEmpty)
        XCTAssertTrue(report.skipped.isEmpty)
        let mutation = try XCTUnwrap(recordedMutationRequests(at: fixture.recordURL).first)
        XCTAssertEqual(mutation.params["configId"] as? String, "fast")
        XCTAssertEqual(mutation.params["value"] as? String, "true")
    }

    func testCursorSemanticEffortSelectionResolvesLegacyPersistedIDToLiveEffortSelector() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: [
                "ACP_INCLUDE_MODEL": "1",
                "ACP_INCLUDE_PARAMETERS": "1",
                "ACP_OBSERVED_EFFORT_SELECTOR": "1"
            ],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()

        let report = try await fixture.controller.applySessionModelParameterSelections([.init(
            providerID: .cursor,
            baseModelRaw: "model-a",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "High"
        )])

        XCTAssertEqual(report.applied.map(\.valueRaw), ["High"])
        XCTAssertTrue(report.skipped.isEmpty)
        let mutation = try XCTUnwrap(recordedMutationRequests(at: fixture.recordURL).first)
        XCTAssertEqual(mutation.params["configId"] as? String, "effort")
        XCTAssertEqual(mutation.params["value"] as? String, "High")
    }

    func testCursorAlreadyCurrentParameterIsSuccessfulNoOpNotUnsupportedSkip() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: ["ACP_INCLUDE_MODEL": "1", "ACP_INCLUDE_PARAMETERS": "1"],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "model-a",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "medium"
        )

        let report = try await fixture.controller.applySessionModelParameterSelections([selection])

        XCTAssertTrue(report.applied.isEmpty)
        XCTAssertEqual(report.alreadyCurrent, [selection])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
    }

    func testCursorAliasDuplicateParameterSelectionsApplyNewestValueExactlyOnce() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: ["ACP_INCLUDE_MODEL": "1", "ACP_INCLUDE_PARAMETERS": "1"],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()

        let report = try await fixture.controller.applySessionModelParameterSelections([
            .init(
                providerID: .cursor,
                baseModelRaw: "Model A",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "Medium"
            ),
            .init(
                providerID: .cursor,
                baseModelRaw: "model-a",
                kind: .thinking,
                configID: "Cursor.Thought-Level",
                valueRaw: "High"
            )
        ])

        XCTAssertEqual(report.applied.map(\.valueRaw), ["High"])
        XCTAssertEqual(recordedMutationRequests(at: fixture.recordURL).count, 1)
        XCTAssertEqual(recordedMutationRequests(at: fixture.recordURL).first?.params["value"] as? String, "High")
    }

    func testOpenCodeDoesNotAdvertiseParameterizedModelPickerCapability() async throws {
        let fixture = try makeFixture(shape: "modern", providerID: .openCode)
        _ = try await fixture.controller.bootstrap()
        await fixture.controller.shutdown()

        let initialize = try XCTUnwrap(recordedRequests(at: fixture.recordURL, method: "initialize").first)
        let capabilities = try XCTUnwrap(initialize.params["clientCapabilities"] as? [String: Any])
        XCTAssertNil(capabilities["_meta"])
    }

    func testOlderCursorWithoutParameterizedOptionsReportsPersistedSelectionAsUnsupported() async throws {
        let fixture = try makeFixture(
            shape: "modern",
            extraEnvironment: ["ACP_INCLUDE_MODEL": "1"],
            providerID: .cursor
        )
        _ = try await fixture.controller.bootstrap()
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "model-a",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "High"
        )
        let report = try await fixture.controller.applySessionModelParameterSelections([selection])
        await fixture.controller.shutdown()

        XCTAssertTrue(report.applied.isEmpty)
        XCTAssertEqual(report.skipped, [selection])
        XCTAssertTrue(recordedMutationRequests(at: fixture.recordURL).isEmpty)
    }

    func testPromptRejectsParametersInvalidatedByLaterSpeedOrModeMutationOnFreshAndReusedTurns() async throws {
        for reused in [false, true] {
            for trigger in ["fast", "mode"] {
                for initiallyCurrent in [false, true] {
                    try await assertPromptAdmission(
                        reused: reused,
                        trigger: trigger,
                        requestedEffort: initiallyCurrent ? "medium" : "High",
                        resetEffort: initiallyCurrent ? "High" : "medium",
                        resetModel: false,
                        shouldReject: true
                    )
                }
            }
        }
    }

    func testPromptRejectsModelInvalidatedByModeMutationOnFreshAndReusedTurns() async throws {
        for reused in [false, true] {
            try await assertPromptAdmission(
                reused: reused, trigger: "mode", requestedEffort: "High",
                resetEffort: nil, resetModel: true, shouldReject: true
            )
        }
    }

    func testPromptAcceptsCompleteUnchangedSelectionUsingLiveSemanticBindings() async throws {
        for reused in [false, true] {
            try await assertPromptAdmission(
                reused: reused, trigger: "mode", requestedEffort: "High",
                resetEffort: nil, resetModel: false, shouldReject: false
            )
        }
    }

    func testResumeFallbackStillRejectsInvalidatedEffectiveParameters() async throws {
        try await assertPromptAdmission(
            reused: false, trigger: "mode", requestedEffort: "High",
            resetEffort: "medium", resetModel: false, shouldReject: true, fallback: true
        )
    }

    private func assertPromptAdmission(
        reused: Bool,
        trigger: String,
        requestedEffort: String,
        resetEffort: String?,
        resetModel: Bool,
        shouldReject: Bool,
        fallback: Bool = false
    ) async throws {
        var environment = [
            "ACP_INCLUDE_MODEL": "1", "ACP_INCLUDE_PARAMETERS": "1",
            "ACP_OBSERVED_EFFORT_SELECTOR": "1", "ACP_OBSERVED_FAST_SELECTOR": "1",
            "ACP_RESET_TRIGGER": trigger
        ]
        environment["ACP_RESET_EFFORT"] = resetEffort
        if resetModel { environment["ACP_RESET_MODEL"] = "model-b" }
        let fixture = try makeFixture(shape: "modern", extraEnvironment: environment, providerID: .cursor, resumeSessionID: fallback ? "missing-session" : nil)
        _ = try await fixture.controller.bootstrap()
        if reused {
            try await fixture.controller.prompt(AgentMessage(userMessage: "First turn"))
        }
        let selections: [ACPModelParameterSelection] = [
            .init(
                providerID: .cursor,
                baseModelRaw: "Model A",
                kind: .thinking,
                configID: "legacy-effort-id",
                valueRaw: requestedEffort
            ),
            .init(
                providerID: .cursor,
                baseModelRaw: "model-a",
                kind: .speed,
                configID: "legacy-speed-id",
                valueRaw: "true"
            )
        ]
        let report = try await fixture.controller.applySessionModelParameterSelections(selections)
        XCTAssertTrue(report.skipped.isEmpty)
        try await fixture.controller.setSessionMode("plan")
        let request = ACPRunRequest(
            agentKind: .cursor, modelString: "Model A", workspacePath: nil,
            resumeSessionID: fallback ? "missing-session" : nil, attachments: [], taskLabelKind: nil,
            sessionModeID: "plan", modelParameterSelections: selections
        )
        do {
            try await fixture.controller.prompt(AgentMessage(userMessage: "Configured turn"), request: request)
            if shouldReject { XCTFail("Prompt must reject a configuration changed by a later mutation") }
        } catch {
            if !shouldReject { throw error }
            XCTAssertTrue(error.localizedDescription.contains("before prompt"), error.localizedDescription)
        }
        await fixture.controller.shutdown()
        XCTAssertEqual(
            recordedRequests(at: fixture.recordURL, method: "session/prompt").count,
            (reused ? 1 : 0) + (shouldReject ? 0 : 1)
        )
    }

    private struct Fixture {
        let controller: ACPAgentSessionController
        let recordURL: URL
    }

    private struct RecordedRequest {
        let method: String
        let params: [String: Any]
    }

    private func makeFixture(
        shape _: String,
        extraEnvironment: [String: String] = [:],
        providerID: ACPProviderID = .openCode,
        resumeSessionID: String? = nil
    ) throws -> Fixture {
        let workspace = try makeTestDirectory(name: "CursorACPParameterBindingTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let scriptURL = workspace.appendingPathComponent("parameters.py")
        try Self.serverScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var environment = extraEnvironment
        environment["ACP_RECORD_PATH"] = recordURL.path
        let provider = CursorParameterBindingProvider(
            commandPath: scriptURL.path,
            environment: environment,
            providerID: providerID
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: ACPRunRequest(
                agentKind: providerID == .cursor ? .cursor : .openCode,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: resumeSessionID,
                attachments: [],
                taskLabelKind: nil
            )
        )
        addTeardownBlock { await controller.shutdown() }
        return Fixture(controller: controller, recordURL: recordURL)
    }

    private func recordedMutationRequests(at url: URL) -> [RecordedRequest] {
        recordedRequests(at: url).filter { request in
            request.method == "session/set_config_option"
        }
    }

    private func recordedRequests(at url: URL, method: String? = nil) -> [RecordedRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordedMethod = object["method"] as? String,
                  method == nil || method == recordedMethod
            else { return nil }
            return RecordedRequest(
                method: recordedMethod,
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    private static let serverScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    model = "model-a"
    effort = "medium"
    fast = "false"
    mode = "ask"
    effort_id = "effort" if os.environ.get("ACP_OBSERVED_EFFORT_SELECTOR") else "Cursor.Thought-Level"
    fast_id = "fast" if os.environ.get("ACP_OBSERVED_FAST_SELECTOR") else "Cursor.Fast-Mode"

    def selector(id, name, category, current, choices):
        return {"id": id, "name": name, "category": category, "type": "select",
                "currentValue": current, "options": [{"value": v, "name": n} for v, n in choices]}

    def options():
        result = [selector("mode", "Mode", "mode", mode, [("ask", "Ask"), ("plan", "Plan")])]
        if os.environ.get("ACP_INCLUDE_MODEL"):
            result.append(selector("model", "Model", "model", model, [("model-a", "Model A"), ("model-b", "Model B")]))
        if os.environ.get("ACP_INCLUDE_PARAMETERS"):
            result.append(selector(effort_id, "Effort", "thought_level", effort, [("medium", "Medium"), ("High", "High")]))
            result.append(selector(fast_id, "Speed", "model_config", fast, [("false", "Standard"), ("true", "Fast")]))
        return result

    for line in sys.stdin:
        request = json.loads(line)
        with open(os.environ["ACP_RECORD_PATH"], "a") as record:
            record.write(json.dumps(request) + "\n")
        if "id" not in request:
            continue
        method = request.get("method")
        params = request.get("params", {})
        if method == "initialize":
            result = {"agentCapabilities": {"loadSession": True}}
        elif method == "session/load":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32602, "message": "Session not found"}}), flush=True)
            continue
        elif method == "session/new":
            result = {"sessionId": "parameter-binding", "configOptions": options()}
        elif method == "session/set_config_option":
            id, value = params["configId"], params["value"]
            if id == "model": model = value
            elif id == effort_id: effort = value
            elif id == fast_id: fast = value
            elif id == "mode": mode = value
            if id == os.environ.get("ACP_RESET_TRIGGER"):
                effort = os.environ.get("ACP_RESET_EFFORT", effort)
                model = os.environ.get("ACP_RESET_MODEL", model)
            result = {"configOptions": options()}
        elif method == "session/prompt":
            result = {"stopReason": "end_turn"}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    """#
}

private struct CursorParameterBindingProvider: ACPAgentProvider {
    let commandPath: String
    var environment: [String: String] = [:]

    let providerID: ACPProviderID
    var supportsParameterizedModelPicker: Bool {
        providerID == .cursor
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        guard providerID == .cursor else { return nil }
        return CursorACPAgentProvider(config: CursorAgentConfig()).modelParameterKind(for: input)
    }

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: request.resumeSessionID.map { .load(existingSessionID: $0) } ?? .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
