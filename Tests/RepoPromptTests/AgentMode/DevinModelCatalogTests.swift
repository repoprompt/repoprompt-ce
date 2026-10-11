import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class DevinModelCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        super.tearDown()
    }

    // MARK: - Catalog

    func testAdvertisedFamiliesExpandIntoEffortEncodedIDs() {
        let catalog = DevinModelCatalog(snapshot: Self.snapshot)

        XCTAssertEqual(catalog.entries.map(\.option.rawValue), [
            "gpt-6-sol-none", "gpt-6-sol-low", "gpt-6-sol-medium", "gpt-6-sol-high",
            "swe-2-medium", "swe-2-high", "swe-2-max",
            "swe-1-7-medium",
            "fusion-a-high-sidekick-b-medium",
            "claude-opus-4-6"
        ])
        let high = try? XCTUnwrap(catalog.entry(matching: " GPT-6-SOL-HIGH "))
        XCTAssertEqual(high?.option.displayName, "GPT-6 Sol · High")
        XCTAssertEqual(high?.familyDisplayName, "GPT-6 Sol")
        XCTAssertEqual(high?.effortDisplayName, "High")
        XCTAssertEqual(high?.advertisedModelRaw, "gpt-6-sol-medium")
        XCTAssertEqual(high?.thinking, .init(configID: "thought_level", choiceRaw: "high"))
        XCTAssertEqual(catalog.entry(matching: "swe-2-max")?.familyDisplayName, "SWE-2")
        // The advertised ID is itself an encoded selection: choosing it resets the effort.
        XCTAssertEqual(catalog.entry(matching: "gpt-6-sol-medium")?.thinking?.choiceRaw, "medium")
        XCTAssertTrue(catalog.entry(matching: "gpt-6-sol-medium")?.option.isProviderDefault == true)
        XCTAssertFalse(catalog.entry(matching: "gpt-6-sol-high")?.option.isProviderDefault == true)
    }

    func testNonCLIFamiliesAndOpaqueModelsStayAdvertisedOnly() {
        let catalog = DevinModelCatalog(snapshot: Self.snapshot)

        for raw in ["swe-1-7-medium", "fusion-a-high-sidekick-b-medium", "claude-opus-4-6"] {
            let entry = catalog.entry(matching: raw)
            XCTAssertNil(entry?.thinking, raw)
            XCTAssertNil(entry?.effortDisplayName, raw)
        }
        XCTAssertNil(catalog.entry(matching: "swe-1-7-max"))
        XCTAssertNil(catalog.entry(matching: "fusion-a-high-sidekick-b-high"))
        XCTAssertTrue(DevinModelCatalog(snapshot: nil).entries.isEmpty)
    }

    func testMenuGroupsNestEffortsUnderFamilies() {
        let catalog = DevinModelCatalog(snapshot: Self.snapshot)
        let groups = catalog.menuGroups(for: catalog.entries.map(\.option))

        XCTAssertEqual(groups.map(\.displayName), ["GPT-6 Sol", "SWE-2", "SWE-1.7", "Fusion", "Claude Opus 4.6"])
        XCTAssertEqual(groups.map(\.rendersAsSubmenu), [true, true, false, false, false])
        XCTAssertEqual(groups[0].entries.map(\.effortDisplayName), ["None", "Low", "Medium", "High"])
    }

    func testAgentModeAndOracleShareTheSameDevinIDs() {
        AgentACPModelRegistry.shared.updateDiscoveredModels(Self.snapshot, for: .devin)
        let availability = AgentModelCatalog.AvailabilityContext(devinAvailable: true)

        let agentIDs = AgentModelCatalog.options(for: .devin, availability: availability).map(\.rawValue)
        XCTAssertEqual(agentIDs, DevinModelCatalog.current.entries.map(\.option.rawValue))
        XCTAssertEqual(Set(agentIDs), Set(DevinModelCatalog(snapshot: Self.snapshot).entries.map(\.option.rawValue)))
        XCTAssertEqual(ACPAIModelCatalog.devinModelsFromStore().map(\.modelName), agentIDs)
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "gpt-6-sol-high", for: .devin, availability: availability))
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "swe-1-7-max", for: .devin, availability: availability))
        XCTAssertEqual(
            AgentModelCatalog.displayName(
                for: "gpt-6-sol-high",
                agentKind: .devin,
                availability: availability,
                includeEffortSuffix: false
            ),
            "GPT-6 Sol · High"
        )
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-sol-high").displayName, "GPT-6 Sol · High")
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-sol-high").modelName, "gpt-6-sol-high")
    }

    func testStoredDevinParameterPinsAreInert() {
        let pin = ACPModelParameterSelection(
            providerID: .devin,
            baseModelRaw: "gpt-6-sol-medium",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "low"
        )
        XCTAssertTrue(ACPModelParameterSelection.selections(
            for: .devin,
            activeBaseModelRaw: "gpt-6-sol-medium",
            from: [pin]
        ).isEmpty)
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .devin,
            selectedModelRaw: "gpt-6-sol-medium",
            persistedSelections: [pin]
        ).isEmpty)
    }

    func testListAgentsGroupsDevinEffortsByCatalogFamily() {
        AgentACPModelRegistry.shared.updateDiscoveredModels(Self.snapshot, for: .devin)
        let models: [Value] = DevinModelCatalog.current.entries.map {
            .object(["model_id": .string("devin:\($0.option.rawValue)"), "name": .string($0.option.displayName)])
        }
        let content = ToolOutputFormatter.formatAgentManage(
            args: ["op": .string("list_agents")],
            value: .object(["agents": .array([.object([
                "name": .string("Devin CLI"),
                "available": .bool(true),
                "models": .array(models)
            ])])])
        )
        let text = content.compactMap { item -> String? in
            if case let .text(text, _, _) = item { return text }
            return nil
        }.joined()
        let lines = Set(text.split(separator: "\n").map(String.init))

        for expected in [
            "  `devin:gpt-6-sol-{none|low|medium|high}` — GPT-6 Sol",
            "  `devin:swe-2-{medium|high|max}` — SWE-2",
            "  `devin:swe-1-7-medium` — SWE-1.7",
            "  `devin:fusion-a-high-sidekick-b-medium` — Fusion"
        ] {
            XCTAssertTrue(lines.contains(expected), "missing \(expected) in\n\(text)")
        }
    }

    func testRepeatedWindowPickerWorkload() {
        // Generic IDs with the current catalog's cardinality: 123 advertisements,
        // 106 parameter sets, 37 expanding families, and 243 derived rows.
        // The historical startup profiles did not record provider cardinality.
        let snapshot = Self.pickerWorkloadSnapshot()
        let beforePublication = DevinModelCatalog.test_expansionCount
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .devin))
        XCTAssertEqual(DevinModelCatalog.test_expansionCount - beforePublication, 1)
        let models = ACPAIModelCatalog.devinModelsFromStore()
        XCTAssertEqual(models.count, 243)
        let expectedOrder = AIModel.sortedForPicker(models.reversed()).map(\.modelName)
        let before = DevinModelCatalog.test_expansionCount
        let start = ContinuousClock.now
        for _ in 0 ..< 27 {
            for model in models {
                XCTAssertEqual(model.displayName, DevinModelCatalog.current.entry(matching: model.modelName)?.option.displayName)
            }
            XCTAssertEqual(AIModel.sortedForPicker(models.reversed()).map(\.modelName), expectedOrder)
        }
        let expansions = DevinModelCatalog.test_expansionCount - before
        print("DEVIN_PICKER_WORKLOAD advertisements=123 parameterSets=106 expandingFamilies=37 entries=243 windows=27 expansions=\(expansions) elapsed=\(start.duration(to: .now))")
        XCTAssertEqual(expansions, 0)
        XCTAssertFalse(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .devin))
        XCTAssertEqual(DevinModelCatalog.test_expansionCount, before)

        let oldCatalog = DevinModelCatalog.current
        let changed = Self.pickerWorkloadSnapshot(familyLabel: "Updated Family")
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(changed, for: .devin))
        XCTAssertEqual(DevinModelCatalog.test_expansionCount - before, 1)
        XCTAssertEqual(DevinModelCatalog.current.entries.count, 243)
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-family-0-high").displayName, "Updated Family 0 · High")
        let narrowed = Self.pickerWorkloadSnapshot(familyLabel: "Updated Family", includeUltra: false)
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(narrowed, for: .devin))
        XCTAssertEqual(DevinModelCatalog.current.entries.count, 237)
        XCTAssertNil(DevinModelCatalog.current.entry(matching: "gpt-6-family-0-ultra"))
        XCTAssertEqual(oldCatalog.entry(matching: "gpt-6-family-0-high")?.option.displayName, "GPT-6 Family 0 · High")
        XCTAssertEqual(oldCatalog.entries.count, 243)
        XCTAssertEqual(DevinModelCatalog.test_expansionCount - before, 2)
    }

    private static func pickerWorkloadSnapshot(
        familyLabel: String = "GPT-6 Family",
        includeUltra: Bool = true
    ) -> ACPDiscoveredSessionModels {
        // Effort-count distributions only; no real provider IDs or labels are copied.
        let expandingCounts = [(6, 6), (5, 13), (4, 6), (3, 8), (2, 4)]
            .flatMap { Array(repeating: $0.0, count: $0.1) }
        let opaqueCounts = [(5, 63), (4, 2), (3, 2), (2, 2), (0, 17)]
            .flatMap { Array(repeating: $0.0, count: $0.1) }
        let counts = expandingCounts + opaqueCounts
        let options = counts.indices.map { index in
            let raw = index < expandingCounts.count ? "gpt-6-family-\(index)-medium" : "fusion-fixture-\(index)-medium"
            return AgentModelOption(rawValue: raw, displayName: "\(familyLabel) \(index)", description: nil, isDefault: index == 0)
        }
        let parameterSets = counts.indices.compactMap { index -> ACPModelParameterSet? in
            let count = counts[index]
            guard count > 0 else { return nil }
            var choices: [String] = if count == 2 {
                ["medium", "high"]
            } else if count == 3 {
                ["medium", "high", "max"]
            } else {
                Array(["none", "low", "medium", "high", "xhigh", "ultra"].prefix(count))
            }
            if !includeUltra { choices.removeAll { $0 == "ultra" } }
            return thinkingSet(options[index].rawValue, choices, current: "medium")
        }
        return ACPDiscoveredSessionModels(
            options: options,
            currentModelRaw: options[0].rawValue,
            modelParameterSets: parameterSets
        )
    }

    func testStoreWarmKeepsNewerLiveCatalogAndReadsDoNotWarm() async {
        AgentACPModelRegistry.shared.updateDiscoveredModels(Self.snapshot, for: .devin)
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .devin)
        let before = DevinModelCatalog.test_expansionCount
        XCTAssertTrue(DevinModelCatalog.current.entries.isEmpty)
        XCTAssertNil(ACPAIModelCatalog.devinModelOption(for: "gpt-6-sol-high"))
        XCTAssertEqual(DevinModelCatalog.test_expansionCount, before)

        await AgentACPModelRegistry.shared.test_warmStandardStore()
        XCTAssertEqual(DevinModelCatalog.test_expansionCount - before, 1)
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-sol-high").displayName, "GPT-6 Sol · High")

        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: .devin)
        let beforeRace = DevinModelCatalog.test_expansionCount
        await AgentACPModelRegistry.shared.warmStandardStoreIfNeeded {
            // Store A has finished loading. Install live B before A is committed.
            AgentACPModelRegistry.shared.updateDiscoveredModels(Self.pickerWorkloadSnapshot(), for: .devin)
        }
        XCTAssertEqual(DevinModelCatalog.test_expansionCount - beforeRace, 1)
        XCTAssertEqual(DevinModelCatalog.current.entries.count, 243)
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-family-0-high").displayName, "GPT-6 Family 0 · High")
        XCTAssertNil(DevinModelCatalog.current.entry(matching: "gpt-6-sol-high"))

        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        XCTAssertTrue(DevinModelCatalog.current.entries.isEmpty)
    }

    // MARK: - ACP boundary

    func testEncodedIDSelectsAdvertisedModelThenThoughtLevelBeforePrompt() async throws {
        AgentACPModelRegistry.shared.updateDiscoveredModels(Self.snapshot, for: .devin)
        let fixture = try makeFixture()
        _ = try await fixture.controller.bootstrap()

        try await fixture.controller.setSessionModel("gpt-6-sol-high")
        try await fixture.controller.setSessionModel("gpt-6-sol-medium")
        try await fixture.controller.setSessionModel("swe-2-max")
        try await fixture.controller.prompt(AgentMessage(userMessage: "Verify ordering"))
        await fixture.controller.shutdown()

        let requests = recordedRequests(at: fixture.recordURL).filter {
            $0.method == "session/set_config_option" || $0.method == "session/prompt"
        }
        // The session opens on gpt-6-sol-medium, so the same-family picks change only thought_level;
        // the effort-encoded IDs themselves never reach the wire.
        XCTAssertEqual(requests.map { $0.params["configId"] as? String ?? $0.method }, [
            "thought_level",
            "thought_level",
            "model", "thought_level",
            "session/prompt"
        ])
        XCTAssertEqual(requests.compactMap { $0.params["value"] as? String }, [
            "high",
            "medium",
            "swe-2-high", "max"
        ])
    }

    func testUnadvertisedLiveEffortFailsBeforeThoughtMutationOrPrompt() async throws {
        AgentACPModelRegistry.shared.updateDiscoveredModels(Self.snapshot, for: .devin)
        // The live session no longer offers `none` for GPT-6 Sol.
        let fixture = try makeFixture(environment: ["ACP_SOL_CHOICES": "low,medium,high"])
        _ = try await fixture.controller.bootstrap()

        do {
            try await fixture.controller.setSessionModel("gpt-6-sol-none")
            XCTFail("An effort the live session does not advertise must fail closed")
        } catch {}
        await fixture.controller.shutdown()

        let mutations = recordedRequests(at: fixture.recordURL).filter { $0.method == "session/set_config_option" }
        XCTAssertTrue(mutations.isEmpty)
        XCTAssertTrue(recordedRequests(at: fixture.recordURL).allSatisfy { $0.method != "session/prompt" })
    }

    // MARK: - Fixtures

    private static let snapshot = ACPDiscoveredSessionModels(
        options: [
            AgentModelOption(rawValue: "gpt-6-sol-medium", displayName: "GPT-6 Sol", description: nil, isDefault: true),
            AgentModelOption(rawValue: "swe-2-high", displayName: "SWE-2", description: nil, isDefault: false),
            AgentModelOption(rawValue: "swe-1-7-medium", displayName: "SWE-1.7", description: nil, isDefault: false),
            AgentModelOption(rawValue: "fusion-a-high-sidekick-b-medium", displayName: "Fusion", description: nil, isDefault: false),
            AgentModelOption(rawValue: "claude-opus-4-6", displayName: "Claude Opus 4.6", description: nil, isDefault: false)
        ],
        currentModelRaw: "gpt-6-sol-medium",
        modelParameterSets: [
            thinkingSet("gpt-6-sol-medium", ["none", "low", "medium", "high"], current: "medium"),
            thinkingSet("swe-2-high", ["medium", "high", "max"], current: "high"),
            thinkingSet("swe-1-7-medium", ["medium", "max"], current: "medium"),
            thinkingSet("fusion-a-high-sidekick-b-medium", ["low", "medium", "high"], current: "medium")
        ]
    )

    private static func thinkingSet(_ model: String, _ choices: [String], current: String) -> ACPModelParameterSet {
        ACPModelParameterSet(
            baseModelRaw: model,
            parameters: [ACPModelParameterDefinition(
                kind: .thinking,
                configID: "thought_level",
                displayName: "Thinking",
                choices: choices.map {
                    ACPModelParameterChoice(rawValue: $0, displayName: $0 == "xhigh" ? "XHigh" : $0.capitalized)
                },
                currentValueRaw: current
            )]
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

    private func makeFixture(environment: [String: String] = [:]) throws -> Fixture {
        let workspace = try makeTestDirectory(name: "DevinModelCatalogTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let scriptURL = workspace.appendingPathComponent("devin-acp.py")
        try Self.serverScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var environment = environment
        environment["ACP_RECORD_PATH"] = recordURL.path
        let controller = try ACPAgentSessionController(
            provider: ScriptedDevinProvider(commandPath: scriptURL.path, environment: environment),
            runRequest: ACPRunRequest(
                agentKind: .devin,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [],
                taskLabelKind: nil
            ),
            allowsProviderProcessLaunchForTesting: true
        )
        addTeardownBlock { await controller.shutdown() }
        return Fixture(controller: controller, recordURL: recordURL)
    }

    private func recordedRequests(at url: URL) -> [RecordedRequest] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String
            else { return nil }
            return RecordedRequest(method: method, params: object["params"] as? [String: Any] ?? [:])
        }
    }

    /// Mirrors Devin ACP: one advertised model per family, a per-model `thought_level`, and
    /// effort-encoded IDs rejected as `model` values.
    private static let serverScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import sys

    sol = os.environ.get("ACP_SOL_CHOICES", "none,low,medium,high").split(",")
    choices = {"gpt-6-sol-medium": sol, "swe-2-high": ["medium", "high", "max"]}
    defaults = {"gpt-6-sol-medium": "medium", "swe-2-high": "high"}
    model = "gpt-6-sol-medium"
    thought = "medium"

    def selector(id, category, current, values):
        return {"id": id, "name": id, "category": category, "type": "select",
                "currentValue": current, "options": [{"value": v, "name": v.capitalize()} for v in values]}

    def options():
        return [
            selector("mode", "mode", "accept-edits", ["accept-edits", "plan"]),
            selector("model", "model", model, list(choices)),
            selector("thought_level", "thought_level", thought, choices[model]),
        ]

    for line in sys.stdin:
        request = json.loads(line)
        with open(os.environ["ACP_RECORD_PATH"], "a") as record:
            record.write(json.dumps(request) + "\n")
        if "id" not in request:
            continue
        method = request.get("method")
        params = request.get("params", {})
        error = None
        if method == "initialize":
            result = {"agentCapabilities": {"loadSession": False}}
        elif method == "session/new":
            result = {"sessionId": "devin-catalog", "configOptions": options()}
        elif method == "session/set_config_option":
            id, value = params["configId"], params["value"]
            if id == "model" and value not in choices:
                error = {"code": -32602, "message": "Invalid params", "data": "Invalid value '%s' for config option 'model'" % value}
            elif id == "model":
                model, thought = value, defaults[value]
            elif id == "thought_level" and value in choices[model]:
                thought = value
            elif id == "thought_level":
                error = {"code": -32602, "message": "Invalid params"}
            result = {"configOptions": options()}
        elif method == "session/prompt":
            result = {"stopReason": "end_turn"}
        else:
            result = {}
        reply = {"jsonrpc": "2.0", "id": request["id"]}
        reply.update({"error": error} if error else {"result": result})
        print(json.dumps(reply), flush=True)
    """#
}

private struct ScriptedDevinProvider: ACPAgentProvider {
    let commandPath: String
    let environment: [String: String]

    var providerID: ACPProviderID {
        .devin
    }

    var supportsParameterizedModelPicker: Bool {
        true
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        DevinACPAgentProvider(config: DevinAgentConfig()).modelParameterKind(for: input)
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
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
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
