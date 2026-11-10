import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAIContracts
import XCTest

final class DevinModelCatalogOwnerTests: XCTestCase {
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

    private static let snapshot = ACPDiscoveredSessionModels(
        options: [
            AgentModelOption(rawValue: "gpt-6-sol-medium", displayName: "GPT-6 Sol", description: nil, isPlaceholderDefault: false, isProviderDefault: true),
            AgentModelOption(rawValue: "swe-2-high", displayName: "SWE-2", description: nil, isPlaceholderDefault: false, isProviderDefault: false),
            AgentModelOption(rawValue: "swe-1-7-medium", displayName: "SWE-1.7", description: nil, isPlaceholderDefault: false, isProviderDefault: false),
            AgentModelOption(rawValue: "fusion-a-high-sidekick-b-medium", displayName: "Fusion", description: nil, isPlaceholderDefault: false, isProviderDefault: false),
            AgentModelOption(rawValue: "claude-opus-4-6", displayName: "Claude Opus 4.6", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
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
}
