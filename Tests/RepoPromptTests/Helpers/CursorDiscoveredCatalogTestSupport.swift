import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Cursor's model catalogue is projected from its ACP discovery snapshot, so tests that need
/// concrete Cursor models and their selectors publish them through the shared registry instead of
/// depending on a compiled model table.
///
/// The seeded shape mirrors what `cursor/list_available_models` advertises: Cursor's own Auto entry
/// (`default`), one model with effort + speed selectors and one speed-only model.
enum CursorDiscoveredCatalogTestSupport {
    static var effortDefinition: ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .thinking,
            configID: "effort",
            displayName: "Effort",
            choices: ["low", "medium", "high", "xhigh"].map {
                ACPModelParameterChoice(
                    rawValue: $0,
                    displayName: $0 == "xhigh" ? "Extra High" : $0.capitalized
                )
            },
            currentValueRaw: "high"
        )
    }

    static var speedDefinition: ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .speed,
            configID: "fast",
            displayName: "Speed",
            choices: [
                ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
                ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
            ],
            currentValueRaw: "true"
        )
    }

    static var standardSnapshot: ACPDiscoveredSessionModels {
        ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: "default",
                    displayName: "Auto",
                    description: nil,
                    isDefault: true
                ),
                AgentModelOption(
                    rawValue: "grok-4.6",
                    displayName: "Cursor Grok 4.6",
                    description: nil,
                    isDefault: false
                ),
                AgentModelOption(
                    rawValue: "composer-2.5",
                    displayName: "Composer 2.5",
                    description: nil,
                    isDefault: false
                )
            ],
            currentModelRaw: "grok-4.6",
            modelParameterSets: [
                ACPModelParameterSet(baseModelRaw: "grok-4.6", parameters: [effortDefinition, speedDefinition]),
                ACPModelParameterSet(baseModelRaw: "composer-2.5", parameters: [speedDefinition])
            ]
        )
    }

    static func seedStandardCatalog(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            AgentACPModelRegistry.shared.updateDiscoveredModels(standardSnapshot, for: .cursor),
            "Expected the seeded Cursor catalogue to publish",
            file: file,
            line: line
        )
    }

    static func reset() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
    }
}
