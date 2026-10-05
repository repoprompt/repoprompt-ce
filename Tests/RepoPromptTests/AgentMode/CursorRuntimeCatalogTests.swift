import AppKit
import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CursorRuntimeCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        super.tearDown()
    }

    func testRefreshPublishesNewModelAcrossAgentAndChatCatalogsWithExactParameters() throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        let model = AgentModelOption(rawValue: "grok-4.7", displayName: "Grok 4.7", description: nil, isDefault: false)
        let definition = ACPModelParameterDefinition(
            kind: .thinking,
            configID: "runtime-reasoning-id",
            displayName: "Effort",
            choices: [.init(rawValue: "extra-high", displayName: "Extra High")],
            currentValueRaw: "extra-high"
        )
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [model],
                currentModelRaw: model.rawValue,
                modelParameterSets: [.init(baseModelRaw: model.rawValue, parameters: [definition])]
            ),
            for: .cursor
        ))
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        XCTAssertEqual(AgentModelCatalog.options(for: .cursor, availability: availability), [model])
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: model.rawValue, for: .cursor, availability: availability))
        XCTAssertEqual(ACPAIModelCatalog.cursorModelsFromStore().map(\.modelName), [model.rawValue])
        XCTAssertEqual(try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: model.rawValue)).parameters, [definition])
        let unsupportedPin = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: model.rawValue,
            kind: .thinking,
            configID: definition.configID,
            valueRaw: "formerly-advertised"
        )
        let resolved = try XCTUnwrap(ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: model.rawValue,
            persistedSelections: [unsupportedPin]
        ).first)
        XCTAssertEqual(resolved.selectedChoice.rawValue, unsupportedPin.valueRaw)
        XCTAssertEqual(resolved.definition.choices, definition.choices)
        XCTAssertEqual(ACPModelParameterResolver.effectiveSelections(
            providerID: .cursor,
            selectedModelRaw: model.rawValue,
            persistedSelections: [unsupportedPin]
        ), [unsupportedPin])
    }

    func testNestedMenuDistinguishesSavedPinFromRuntimeDefaultAndExecutesExactActions() throws {
        let model = AgentModelOption(rawValue: "new-runtime-model", displayName: "New Model", description: nil, isDefault: false)
        let definition = ACPModelParameterDefinition(
            kind: .thinking,
            configID: "opaque-selector",
            displayName: "Effort",
            choices: [.init(rawValue: "vendor-value", displayName: "Vendor Effort")],
            currentValueRaw: "vendor-value"
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            .init(
                options: [model],
                currentModelRaw: model.rawValue,
                modelParameterSets: [.init(baseModelRaw: model.rawValue, parameters: [definition])]
            ), for: .cursor
        )
        var selectedModel: String?
        var selectedPin: ACPModelParameterSelection?
        var clearedIdentity: ACPModelParameterIdentity?
        let items = AgentModelStableMenuItems.cursorModelItems(
            options: [model], selectedModelRaw: model.rawValue, selections: [],
            onSelectModel: { selectedModel = $0.rawValue },
            onSelectParameter: { _, pin in selectedPin = pin },
            onClearParameter: { _, identity in clearedIdentity = identity }
        )
        let menu = NSMenu.stableMenu(from: items)
        let submenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Select Model", "Use Runtime Default", "Vendor Effort"])
        XCTAssertEqual(submenu.items.map(\.state), [.on, .on, .off])
        for item in submenu.items {
            let action = try XCTUnwrap(item.action)
            _ = (item.target as? NSObject)?.perform(action, with: item)
        }
        XCTAssertEqual(selectedModel, model.rawValue)
        XCTAssertEqual(selectedPin?.configID, "opaque-selector")
        XCTAssertEqual(selectedPin?.valueRaw, "vendor-value")
        XCTAssertEqual(clearedIdentity, selectedPin?.identity)
    }

    func testExactAdvertisedAliasKeepsItsOwnParameterIdentity() {
        let raws = ["grok-4.6", "cursor-grok-4.6"]
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            .init(
                options: raws.map { .init(rawValue: $0, displayName: $0, description: nil, isDefault: false) },
                currentModelRaw: raws[0],
                modelParameterSets: raws.map { raw in
                    .init(baseModelRaw: raw, parameters: [.init(
                        kind: .thinking,
                        configID: raw,
                        displayName: "Effort",
                        choices: [.init(rawValue: "high", displayName: "High")],
                        currentValueRaw: "high"
                    )])
                }
            ), for: .cursor
        )
        XCTAssertNotEqual(
            ACPModelParameterIdentity(providerID: .cursor, baseModelRaw: raws[0], kind: .thinking),
            ACPModelParameterIdentity(providerID: .cursor, baseModelRaw: raws[1], kind: .thinking)
        )
        XCTAssertEqual(ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: raws[1])?.parameters.first?.configID, raws[1])
    }

    func testLegacyAbsenceAndCompleteEmptyMetadataRemainDistinctAcrossPersistence() throws {
        let model = AgentModelOption(rawValue: "grok-4.6", displayName: "Grok 4.6", description: nil, isDefault: false)
        for hasMetadata in [false, true] {
            let snapshot = ACPDiscoveredSessionModels(
                options: [model],
                currentModelRaw: model.rawValue,
                modelParameterSets: [],
                hasModelParameterMetadata: hasMetadata
            )
            let record = try XCTUnwrap(ACPDynamicModelStore.canonicalProviderRecord(from: snapshot, providerID: .cursor))
            XCTAssertEqual(record.modelParameterSets != nil, hasMetadata)
            let decoded = try JSONDecoder().decode(ACPDynamicProviderRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(try XCTUnwrap(ACPDynamicModelStore.snapshot(from: decoded)).hasModelParameterMetadata, hasMetadata)
            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .cursor)
            XCTAssertNil(CursorAIModelCatalog.parameterSet(for: model.rawValue))
        }
    }
}
