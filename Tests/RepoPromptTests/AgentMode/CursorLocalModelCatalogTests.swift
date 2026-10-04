import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CursorLocalModelCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        super.tearDown()
    }

    private func advertise(_ modelRaw: String, parameters: [ACPModelParameterDefinition] = []) {
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [.init(rawValue: modelRaw, displayName: modelRaw, description: nil, isDefault: false)],
                currentModelRaw: modelRaw,
                modelParameterSets: parameters.isEmpty ? [] : [.init(baseModelRaw: modelRaw, parameters: parameters)]
            ), for: .cursor
        )
    }

    private func effort(_ values: [String], current: String, configID: String = "effort") -> ACPModelParameterDefinition {
        .init(
            kind: .thinking,
            configID: configID,
            displayName: "Effort",
            choices: values.map { .init(rawValue: $0, displayName: $0.capitalized) },
            currentValueRaw: current
        )
    }

    private func speed(current: String) -> ACPModelParameterDefinition {
        .init(
            kind: .speed,
            configID: "fast",
            displayName: "Speed",
            choices: [.init(rawValue: "false", displayName: "Standard"), .init(rawValue: "true", displayName: "Fast")],
            currentValueRaw: current
        )
    }

    func testRefreshReplacesMembershipWithoutReleaseFiltering() {
        advertise("grok-4.6")
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "Cursor Grok 4.6"))
        advertise("grok-4.7")
        XCTAssertEqual(CursorAIModelCatalog.options.map(\.rawValue), ["grok-4.7"])
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "grok-4.7"))
        XCTAssertFalse(CursorAIModelCatalog.contains(modelRaw: "grok-4.6"))
    }

    func testGrok46PreservesAdvertisedEffortAndSpeedMetadata() throws {
        advertise("grok-4.6", parameters: [effort(["low", "medium", "high", "xhigh"], current: "high"), speed(current: "true")])
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "grok-4.6"))

        XCTAssertEqual(parameterSet.baseModelRaw, "grok-4.6")
        XCTAssertEqual(parameterSet.parameters.map(\.kind), [.thinking, .speed])
        XCTAssertEqual(parameterSet.parameters.map(\.configID), ["effort", "fast"])

        let effort = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .thinking })
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(effort.currentValueRaw, "high")

        let speed = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .speed })
        XCTAssertEqual(speed.choices.map(\.rawValue), ["false", "true"])
        XCTAssertEqual(speed.choices.map(\.displayName), ["Standard", "Fast"])
        XCTAssertEqual(speed.currentValueRaw, "true")
    }

    func testComposer25DoesNotAddEffortToAdvertisedSpeedOnlyMetadata() throws {
        advertise("composer-2.5", parameters: [speed(current: "true")])
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "composer-2.5"))

        XCTAssertEqual(parameterSet.parameters.map(\.kind), [.speed])
        XCTAssertEqual(parameterSet.parameters.first?.currentValueRaw, "true")
    }

    func testPersistedLegacyComposer2SelectionCanonicalizesWithoutDuplicatingPickerOption() {
        advertise("composer-2.5")
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)

        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "composer-2",
            availability: availability
        )

        XCTAssertEqual(normalized.agent, .cursor)
        XCTAssertEqual(normalized.modelRaw, "composer-2.5")
        XCTAssertEqual(
            AgentModelCatalog.options(for: .cursor, availability: availability)
                .count(where: { $0.rawValue == "composer-2.5" }),

            1
        )
        XCTAssertFalse(
            AgentModelCatalog.options(for: .cursor, availability: availability)
                .contains { $0.rawValue == "composer-2" }
        )
    }

    func testGrok45PreservesAdvertisedEffortAndSpeedDefaults() throws {
        advertise("grok-4.5", parameters: [effort(["low", "medium", "high"], current: "high"), speed(current: "true")])
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "grok-4.5"))

        let effort = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .thinking })
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high"])
        XCTAssertEqual(effort.currentValueRaw, "high")

        let speed = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .speed })
        XCTAssertEqual(speed.choices.map(\.rawValue), ["false", "true"])
        XCTAssertEqual(speed.currentValueRaw, "true")
    }

    func testModelOnlyRuntimeRecordsDoNotInferHistoricalParameterChoices() {
        struct Expectation {
            let model: String
            let effortValues: [String]
            let hasSpeed: Bool
        }
        let expectations = [
            Expectation(model: "claude-fable-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: false),
            Expectation(model: "claude-opus-4-6", effortValues: ["low", "medium", "high", "max"], hasSpeed: false),
            Expectation(model: "claude-opus-4-7", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-opus-4-8", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-opus-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-sonnet-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: false),
            Expectation(model: "claude-sonnet-4-6", effortValues: ["low", "medium", "high", "max"], hasSpeed: false),
            Expectation(model: "gemini-3.6-flash", effortValues: ["minimal", "low", "medium", "high"], hasSpeed: false),
            Expectation(model: "gemini-3.7-flash", effortValues: ["low", "medium", "high"], hasSpeed: false),
            Expectation(model: "glm-5.2", effortValues: ["high", "max"], hasSpeed: false),
            Expectation(model: "gpt-5.1", effortValues: ["low", "medium", "high"], hasSpeed: false),
            Expectation(model: "gpt-5.2", effortValues: ["low", "medium", "high", "extra-high"], hasSpeed: true),
            Expectation(model: "gpt-5.3-codex", effortValues: ["low", "medium", "high", "extra-high"], hasSpeed: true),
            Expectation(model: "gpt-5.4", effortValues: ["none", "low", "medium", "high", "extra-high"], hasSpeed: true),
            Expectation(model: "gpt-5.4-mini", effortValues: ["none", "low", "medium", "high", "xhigh"], hasSpeed: false),
            Expectation(model: "gpt-5.4-nano", effortValues: ["none", "low", "medium", "high", "xhigh"], hasSpeed: false),
            Expectation(model: "gpt-5.5", effortValues: ["none", "low", "medium", "high", "extra-high"], hasSpeed: true),
            Expectation(model: "gpt-5.6-luna", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "gpt-5.6-sol", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "gpt-5.6-terra", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "kimi-k3", effortValues: ["low", "high", "max"], hasSpeed: false)
        ]

        for expectation in expectations {
            advertise(expectation.model)
            XCTAssertNil(CursorAIModelCatalog.parameterSet(for: expectation.model), expectation.model)
        }
    }

    func testEveryCatalogParameterDefaultIsAnAdvertisedChoice() {
        advertise("grok-4.6", parameters: [effort(["low", "high"], current: "low"), speed(current: "false")])
        for option in CursorAIModelCatalog.options {
            guard let parameterSet = CursorAIModelCatalog.parameterSet(for: option.rawValue) else { continue }
            for definition in parameterSet.parameters {
                XCTAssertNotNil(
                    definition.choice(matching: definition.currentValueRaw),
                    "\(option.rawValue) \(definition.configID) has an invalid local default"
                )
            }
        }
    }

    func testBooleanOnlyThinkingModelsDoNotExposeEffortControls() {
        for model in ["claude-haiku-4-5", "claude-opus-4-5", "claude-sonnet-4", "claude-sonnet-4-5"] {
            XCTAssertNil(CursorAIModelCatalog.parameterSet(for: model), model)
        }
    }

    func testLiveCatalogReconciliationAcceptsExactMetadataAndReportsEffortDrift() throws {
        advertise("gpt-5.4", parameters: [effort(["none", "low", "medium", "high", "extra-high"], current: "medium", configID: "reasoning"), speed(current: "false")])
        let exactSets = CursorAIModelCatalog.options.compactMap {
            CursorAIModelCatalog.parameterSet(for: $0.rawValue)
        }
        let liveOptions = CursorAIModelCatalog.options.map { option in
            option.rawValue == AgentModel.cursorAuto.rawValue
                ? AgentModelOption(rawValue: "default", displayName: "Auto", description: nil, isDefault: true)
                : option
        }
        let exactSnapshot = ACPDiscoveredSessionModels(
            options: liveOptions,
            currentModelRaw: "grok-4.6",
            modelParameterSets: exactSets
        )
        XCTAssertFalse(CursorAIModelCatalog.reconciliationIssues(comparedTo: exactSnapshot).contains { $0.hasPrefix("gpt-5.4 ") })

        let gpt54 = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "gpt-5.4"))
        let effort = try XCTUnwrap(gpt54.definition(kind: .thinking))
        let driftedEffort = ACPModelParameterDefinition(
            kind: .thinking,
            configID: effort.configID,
            displayName: effort.displayName,
            choices: effort.choices.filter { $0.rawValue != "extra-high" },
            currentValueRaw: effort.currentValueRaw
        )
        let driftedSets = exactSets.map { set in
            set.baseModelRaw == gpt54.baseModelRaw
                ? ACPModelParameterSet(
                    baseModelRaw: set.baseModelRaw,
                    parameters: set.parameters.map { $0.kind == .thinking ? driftedEffort : $0 }
                )
                : set
        }
        let driftedSnapshot = ACPDiscoveredSessionModels(
            options: liveOptions,
            currentModelRaw: "grok-4.6",
            modelParameterSets: driftedSets
        )

        XCTAssertEqual(
            CursorAIModelCatalog.reconciliationIssues(comparedTo: driftedSnapshot).filter { $0.hasPrefix("gpt-5.4 ") },
            ["gpt-5.4 Effort choices changed (local: none, low, medium, high, extra-high; live: none, low, medium, high)"]
        )
    }

    func testAgentModelCatalogUsesDiscoveredCursorMembershipWithoutReleaseGating() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [.init(
                    rawValue: "future-cursor-model",
                    displayName: "Future Cursor Model",
                    description: nil,
                    isDefault: false
                )],
                currentModelRaw: "future-cursor-model"
            ),
            for: .cursor
        ))

        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        XCTAssertEqual(
            AgentModelCatalog.options(for: .cursor, availability: availability),
            CursorAIModelCatalog.options
        )
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "Cursor Grok 4.6",
            for: .cursor,
            availability: availability
        ))
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "future-cursor-model",
            for: .cursor,
            availability: availability
        ))
    }
}
