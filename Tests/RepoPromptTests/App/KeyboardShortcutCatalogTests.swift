import KeyboardShortcuts
@testable import RepoPrompt
import XCTest

final class KeyboardShortcutCatalogTests: XCTestCase {
    func testAgentLayoutCatalogContainsAgentModelPickerShortcut() throws {
        let section = try agentLayoutSection()

        let binding = try XCTUnwrap(
            section.bindings.first(where: { $0.id == "agent-model-picker" })
        )

        XCTAssertEqual(binding.title, "Open Agent/Model picker")
        XCTAssertEqual(binding.name, KeyboardShortcuts.Name.showAgentModelPicker)
    }

    func testAgentLayoutCatalogContainsUnboundAgentEffortPickerShortcut() throws {
        let section = try agentLayoutSection()

        let binding = try XCTUnwrap(
            section.bindings.first(where: { $0.id == "agent-effort-picker" })
        )

        XCTAssertEqual(binding.title, "Open Agent effort picker")
        XCTAssertEqual(binding.name, KeyboardShortcuts.Name.showAgentEffortPicker)
        XCTAssertNil(binding.name.defaultShortcut)
    }

    private func agentLayoutSection() throws -> KeyboardShortcutCatalogSection {
        try XCTUnwrap(
            KeyboardShortcutCatalog.sections.first(where: { $0.id == "agent-layout" })
        )
    }
}
