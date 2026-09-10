import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Model selection for the two ACP providers added alongside these tests: catalog exposure,
/// provider/family grouping in the pickers, and the runner's pre-prompt selection decision.
@MainActor
final class DevinOMPModelSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .omp)
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .omp)
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        super.tearDown()
    }

    // MARK: - Catalog exposure

    func testOMPAndDevinExposeProviderDefaultBeforeAnyDiscovery() {
        for agentKind in [AgentProviderKind.omp, .devin] {
            let options = AgentModelCatalog.options(
                for: agentKind,
                availability: availability(for: agentKind)
            )

            XCTAssertEqual(
                options.map(\.rawValue),
                [AgentModel.defaultModel.rawValue],
                "\(agentKind.rawValue) must offer its provider-managed default with no discovery"
            )
            XCTAssertTrue(
                AgentModelCatalog.isValid(
                    rawModel: AgentModel.defaultModel.rawValue,
                    for: agentKind,
                    availability: availability(for: agentKind)
                )
            )
        }
    }

    func testDiscoveredModelsAppendAfterTheProviderDefault() {
        publishOMPModels()

        let options = AgentModelCatalog.options(for: .omp, availability: availability(for: .omp))

        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertEqual(
            Set(options.dropFirst().map(\.rawValue)),
            ["anthropic/claude-opus-4-5", "openai/gpt-5.2", "openai/gpt-5.2-codex", "local-model"]
        )
        // A single provider-managed default must never be duplicated by discovery.
        XCTAssertEqual(
            options.count { $0.rawValue == AgentModel.defaultModel.rawValue },
            1
        )
    }

    // MARK: - Discovery → run round-trip

    /// `list_agents` is where callers learn which `model_id` values exist, so every ID it emits
    /// must be accepted verbatim by the run surface. The raw values here carry `/`, `.`, and `:`,
    /// plus a bare model that also has an effort-suffixed sibling — the shape that used to be
    /// rendered as a fabricated `base-{effort}` token.
    func testEveryEmittedOMPModelIDRoundTripsBackToTheSameAgentAndModel() throws {
        publishPunctuatedOMPModels()
        let availability = availability(for: .omp)

        let targets = try emittedOMPStartTargets(availability: availability)

        XCTAssertEqual(
            Set(targets.map(\.modelRaw)),
            Set([AgentModel.defaultModel.rawValue] + Self.punctuatedOMPRawValues)
        )
        for target in targets {
            let emitted = target.selectionID.rawValue
            let parsed = try XCTUnwrap(AgentModelSelectionID.parse(emitted), emitted)
            XCTAssertEqual(parsed.agentRaw, AgentProviderKind.omp.rawValue, emitted)
            XCTAssertEqual(parsed.modelRaw, target.modelRaw, emitted)
            XCTAssertTrue(
                AgentModelCatalog.isValid(
                    rawModel: parsed.modelRaw,
                    for: .omp,
                    availability: availability
                ),
                "list_agents emitted '\(emitted)' but the run surface rejects it"
            )
        }
    }

    /// The rendered text is the surface agents actually copy from, so it must reproduce each
    /// `model_id` verbatim — no collapsed families, no dropped entries.
    func testRenderedAgentListEmitsEveryModelIDVerbatimAndNothingElse() throws {
        publishPunctuatedOMPModels()
        let availability = availability(for: .omp)
        let targets = try emittedOMPStartTargets(availability: availability)

        let text = try renderedListAgentsText(for: targets)
        let renderedIDs = Self.backtickedModelIDs(in: text)

        XCTAssertEqual(Set(renderedIDs), Set(targets.map(\.selectionID.rawValue)))
        XCTAssertEqual(renderedIDs.count, targets.count, "no model_id may be rendered twice")
        for emitted in renderedIDs {
            let parsed = try XCTUnwrap(AgentModelSelectionID.parse(emitted), emitted)
            XCTAssertEqual(parsed.agentRaw, AgentProviderKind.omp.rawValue, emitted)
            XCTAssertTrue(
                AgentModelCatalog.isValid(
                    rawModel: parsed.modelRaw,
                    for: .omp,
                    availability: availability
                ),
                "rendered list_agents advertises '\(emitted)' but the run surface rejects it"
            )
        }
    }

    // MARK: - Picker grouping

    func testOMPGroupsByAdvertisedProviderPrefixAndNeverEmitsABlankLabel() {
        publishOMPModels()
        let options = AgentModelCatalog.options(for: .omp, availability: availability(for: .omp))

        let groups = AgentModelCatalog.ompModelGroups(for: options)

        XCTAssertEqual(groups.map(\.providerID), [nil, "anthropic", "openai"])
        XCTAssertEqual(
            groups.first(where: { $0.providerID == "openai" })?.options.map(\.rawValue),
            ["openai/gpt-5.2", "openai/gpt-5.2-codex"]
        )
        // The placeholder default and an unprefixed model stay inline rather than under an
        // empty submenu title.
        XCTAssertEqual(
            Set(groups.first(where: { $0.providerID == nil })?.options.map(\.rawValue) ?? []),
            [AgentModel.defaultModel.rawValue, "local-model"]
        )
        for group in groups {
            XCTAssertNotEqual(group.providerID, "", "a submenu label must never be blank")
            XCTAssertFalse(group.options.isEmpty, "a rendered group must never be empty")
        }
    }

    func testDevinGroupsByNativeFamilyAndKeepsUnfamiliedModelsInline() {
        publishDevinModels()
        let options = AgentModelCatalog.options(for: .devin, availability: availability(for: .devin))

        let groups = AgentModelCatalog.devinModelGroups(for: options)

        XCTAssertEqual(groups.map { $0.family?.id }, [nil, "family-claude", "family-gpt"])
        XCTAssertEqual(
            groups.first(where: { $0.family?.id == "family-claude" })?.family?.displayName,
            "Claude"
        )
        XCTAssertEqual(
            groups.first(where: { $0.family?.id == "family-claude" })?.options.map(\.rawValue),
            ["devin-claude-opus", "devin-claude-sonnet"]
        )
        XCTAssertEqual(
            Set(groups.first(where: { $0.family == nil })?.options.map(\.rawValue) ?? []),
            [AgentModel.defaultModel.rawValue, "devin-unclassified"]
        )
        for group in groups {
            XCTAssertNotEqual(group.family?.displayName, "", "a family submenu label must never be blank")
        }
    }

    /// The reference implementation shipped blank submenu rows because a discovered option
    /// carried no `displayName`; the store must fall back to the raw model ID instead.
    func testDiscoveredOptionWithoutADisplayNameFallsBackToItsRawValue() {
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [option(raw: "openai/gpt-5.2", displayName: "")],
                currentModelRaw: nil
            ),
            for: .omp
        )

        let options = AgentModelCatalog.options(for: .omp, availability: availability(for: .omp))

        XCTAssertEqual(
            options.first(where: { $0.rawValue == "openai/gpt-5.2" })?.displayName,
            "openai/gpt-5.2"
        )
        XCTAssertFalse(options.contains { $0.displayName.isEmpty })
    }

    // MARK: - Family metadata persistence

    func testModelFamilySurvivesTheDiscoveredModelStoreRoundTrip() throws {
        let family = AgentModelFamily(id: "family-gpt", displayName: "GPT")
        let snapshot = ACPDiscoveredSessionModels(
            options: [option(raw: "devin-gpt-5.2", displayName: "GPT 5.2", family: family)],
            currentModelRaw: "devin-gpt-5.2"
        )
        let record = try XCTUnwrap(
            ACPDynamicModelStore.canonicalProviderRecord(from: snapshot, providerID: .devin)
        )

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ACPDynamicProviderRecord.self, from: encoded)
        let restored = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: decoded))

        XCTAssertEqual(restored.options.first?.modelFamily, family)
    }

    /// Records persisted before family support must keep decoding.
    func testRecordWithoutAFamilyStillDecodes() throws {
        let json = """
        {
          "providerID": "devin",
          "currentModelRaw": "devin-gpt-5.2",
          "options": [{
            "rawValue": "devin-gpt-5.2",
            "displayName": "GPT 5.2",
            "isPlaceholderDefault": false,
            "isProviderDefault": false,
            "supportedReasoningEfforts": []
          }]
        }
        """

        let decoded = try JSONDecoder().decode(
            ACPDynamicProviderRecord.self,
            from: Data(json.utf8)
        )
        let restored = try XCTUnwrap(ACPDynamicModelStore.snapshot(from: decoded))

        XCTAssertNil(restored.options.first?.modelFamily)
        XCTAssertEqual(restored.options.first?.rawValue, "devin-gpt-5.2")
    }

    // MARK: - `devin models list` family catalog

    func testDevinFamilyCatalogParsesAccountFamilies() throws {
        let json = """
        {"families": [
          {"family_uid": "family-claude", "family_label": "Claude", "variants": [
            {"model_uid": "devin-claude-opus"}, {"model_uid": "devin-claude-sonnet"}]},
          {"family_uid": "family-gpt", "family_label": "GPT", "variants": [
            {"model_uid": "devin-gpt-5.2"}]}
        ]}
        """

        let parsed = try DevinModelFamilyCatalog.parse(Data(json.utf8))

        XCTAssertEqual(
            parsed["devin-claude-opus"],
            AgentModelFamily(id: "family-claude", displayName: "Claude")
        )
        XCTAssertEqual(
            parsed["devin-claude-sonnet"],
            AgentModelFamily(id: "family-claude", displayName: "Claude")
        )
        XCTAssertEqual(parsed["devin-gpt-5.2"], AgentModelFamily(id: "family-gpt", displayName: "GPT"))
        XCTAssertEqual(parsed.count, 3)
    }

    /// Ambiguous identity is rejected wholesale rather than grouping models under a label
    /// that cannot be trusted.
    func testDevinFamilyCatalogRejectsBlankOrDuplicateIdentity() {
        let cases = [
            "{\"families\": [{\"family_uid\": \"\", \"family_label\": \"Claude\", \"variants\": []}]}",
            "{\"families\": [{\"family_uid\": \"f\", \"family_label\": \" \", \"variants\": []}]}",
            """
            {"families": [
              {"family_uid": "f", "family_label": "A", "variants": [{"model_uid": "m"}]},
              {"family_uid": "f", "family_label": "B", "variants": []}]}
            """,
            """
            {"families": [
              {"family_uid": "a", "family_label": "A", "variants": [{"model_uid": "m"}]},
              {"family_uid": "b", "family_label": "B", "variants": [{"model_uid": "m"}]}]}
            """
        ]

        for json in cases {
            XCTAssertThrowsError(
                try DevinModelFamilyCatalog.parse(Data(json.utf8)),
                "expected rejection for \(json)"
            )
        }
    }

    // MARK: - Selection reaches the ACP run

    func testSelectedModelIsAppliedBeforeThePromptForBothProviders() throws {
        publishOMPModels()
        publishDevinModels()

        XCTAssertEqual(
            try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: .omp,
                modelString: "openai/gpt-5.2"
            ),
            "openai/gpt-5.2"
        )
        XCTAssertEqual(
            try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: .devin,
                modelString: "devin-claude-opus"
            ),
            "devin-claude-opus"
        )
    }

    /// "default" is a provider-managed placeholder: it must send no model mutation.
    func testProviderManagedDefaultSendsNoModelMutation() throws {
        publishOMPModels()
        publishDevinModels()

        for agentKind in [AgentProviderKind.omp, .devin] {
            XCTAssertNil(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: agentKind,
                modelString: AgentModel.defaultModel.rawValue
            ))
            XCTAssertNil(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: agentKind,
                modelString: nil
            ))
        }
    }

    func testUndiscoveredModelFailsClosedInsteadOfSilentlyRunningTheDefault() {
        publishOMPModels()
        publishDevinModels()

        for agentKind in [AgentProviderKind.omp, .devin] {
            XCTAssertThrowsError(try ACPIntegratedAgentModeRunner.testExplicitSelectedModel(
                agentKind: agentKind,
                modelString: "never-advertised"
            )) { error in
                guard case let AIProviderError.invalidConfiguration(detail) = error else {
                    return XCTFail("Expected an invalid configuration error, got \(error)")
                }
                XCTAssertTrue(detail.contains("never-advertised"), detail)
            }
        }
    }

    // MARK: - Oracle / chat exposure for OMP

    func testConnectedOMPAndDevinModelsAppearInOracleAvailability() async {
        publishOMPModels()
        publishDevinModels()
        let apiSettings = makeAPISettingsViewModel()
        apiSettings.isOMPConnected = true
        apiSettings.isDevinConnected = true

        await apiSettings.updateAvailableModels()

        XCTAssertTrue(apiSettings.availableModels.contains(.ompCustom(name: "openai/gpt-5.2")))
        XCTAssertTrue(apiSettings.availableModels.contains(.devinCustom(name: "devin-gpt-5.2")))
        apiSettings.prepareForWindowClose()
    }

    func testOMPChatModelsRoundTripThroughAIModel() {
        publishOMPModels()

        let parsed = AIModel.fromModelName("omp_custom_openai/gpt-5.2")

        XCTAssertEqual(parsed, .ompCustom(name: "openai/gpt-5.2"))
        XCTAssertEqual(parsed?.providerType, .omp)
        XCTAssertEqual(parsed?.modelName, "openai/gpt-5.2")
        XCTAssertEqual(parsed?.rawValue, "omp_custom_openai/gpt-5.2")
    }

    func testDevinChatModelsRoundTripThroughAIModel() {
        publishDevinModels()

        let parsed = AIModel.fromModelName("devin_custom_devin-gpt-5.2")

        XCTAssertEqual(parsed, .devinCustom(name: "devin-gpt-5.2"))
        XCTAssertEqual(parsed?.providerType, .devin)
        XCTAssertEqual(parsed?.modelName, "devin-gpt-5.2")
        XCTAssertEqual(parsed?.displayName, "GPT 5.2")
        XCTAssertEqual(parsed?.rawValue, "devin_custom_devin-gpt-5.2")
    }

    func testProviderOwnedOracleConfigsPreserveSelectedModelsWithoutMCP() {
        let omp = OMPCLIProvider.test_makeHeadlessConfig(modelName: "openai/gpt-5.2")
        let devin = DevinCLIProvider.test_makeHeadlessConfig(modelName: "devin-gpt-5.2")

        XCTAssertEqual(omp.modelString, "openai/gpt-5.2")
        XCTAssertFalse(omp.includeRepoPromptMCPServer)
        XCTAssertEqual(devin.modelString, "devin-gpt-5.2")
        XCTAssertFalse(devin.includeRepoPromptMCPServer)
    }

    func testOMPChatPickerGroupsDiscoveredModelsWithoutBlankSubmenus() {
        publishOMPModels()
        let models = ACPAIModelCatalog.ompModelsFromStore()

        let groups = AIModel.ompMenuGroups(for: models)

        XCTAssertEqual(groups.map(\.displayName), [nil, "anthropic", "openai"])
        XCTAssertEqual(
            groups.first(where: { $0.displayName == "openai" })?.models.map(\.modelName),
            ["openai/gpt-5.2", "openai/gpt-5.2-codex"]
        )
        for group in groups {
            XCTAssertNotEqual(group.displayName, "")
            XCTAssertFalse(group.models.isEmpty)
        }
    }

    // MARK: - Helpers

    private func makeAPISettingsViewModel() -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
    }

    private func availability(for agentKind: AgentProviderKind) -> AgentModelCatalog.AvailabilityContext {
        AgentModelCatalog.AvailabilityContext(
            ompAvailable: agentKind == .omp,
            devinAvailable: agentKind == .devin
        )
    }

    private func option(
        raw: String,
        displayName: String,
        family: AgentModelFamily? = nil
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: raw,
            displayName: displayName,
            description: nil,
            isDefault: false,
            modelFamily: family
        )
    }

    /// OMP advertises fully qualified provider paths, so raw values contain `/` and `.`, and
    /// Bedrock identifiers additionally contain `:`.
    private static let punctuatedOMPRawValues = [
        "amazon-bedrock/anthropic.claude-sonnet-5",
        "amazon-bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0",
        "litellm/claude-sonnet-5",
        "litellm/claude-sonnet-5-xhigh",
        "litellm/gpt-5.4-pro-med"
    ]

    private func publishPunctuatedOMPModels() {
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: Self.punctuatedOMPRawValues.map { option(raw: $0, displayName: "Model \($0)") },
                currentModelRaw: nil
            ),
            for: .omp
        )
    }

    private func emittedOMPStartTargets(
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> [AgentModelCatalog.DiscoveryStartTarget] {
        let agent = try XCTUnwrap(
            AgentModelCatalog.discoveryAgents(availability: availability).first { $0.agent == .omp }
        )
        XCTAssertTrue(agent.available)
        let targets = agent.models.flatMap(\.startTargets)
        XCTAssertFalse(targets.isEmpty)
        return targets
    }

    /// Mirrors the `list_agents` payload shape produced by `AgentManageMCPToolService`.
    private func renderedListAgentsText(
        for targets: [AgentModelCatalog.DiscoveryStartTarget]
    ) throws -> String {
        let models: [Value] = targets.map { target in
            .object([
                "model_id": .string(target.selectionID.rawValue),
                "name": .string(target.name)
            ])
        }
        let payload = Value.object([
            "agents": .array([
                .object([
                    "name": .string(AgentProviderKind.omp.displayName),
                    "available": .bool(true),
                    "models": .array(models)
                ])
            ])
        ])

        let blocks = ToolOutputFormatter.formatAgentManage(
            args: ["op": .string("list_agents")],
            value: payload
        )
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }

    /// Every backticked token that looks like an `omp:` compound ID in the rendered output.
    private static func backtickedModelIDs(in text: String) -> [String] {
        text.split(separator: "`")
            .map(String.init)
            .filter { $0.hasPrefix("\(AgentProviderKind.omp.rawValue):") }
    }

    private func publishOMPModels() {
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    option(raw: "openai/gpt-5.2", displayName: "GPT 5.2"),
                    option(raw: "openai/gpt-5.2-codex", displayName: "GPT 5.2 Codex"),
                    option(raw: "anthropic/claude-opus-4-5", displayName: "Claude Opus 4.5"),
                    option(raw: "local-model", displayName: "Local Model")
                ],
                currentModelRaw: nil
            ),
            for: .omp
        )
    }

    private func publishDevinModels() {
        let claude = AgentModelFamily(id: "family-claude", displayName: "Claude")
        let gpt = AgentModelFamily(id: "family-gpt", displayName: "GPT")
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    option(raw: "devin-claude-opus", displayName: "Claude Opus", family: claude),
                    option(raw: "devin-claude-sonnet", displayName: "Claude Sonnet", family: claude),
                    option(raw: "devin-gpt-5.2", displayName: "GPT 5.2", family: gpt),
                    option(raw: "devin-unclassified", displayName: "Unclassified")
                ],
                currentModelRaw: nil
            ),
            for: .devin
        )
    }
}
