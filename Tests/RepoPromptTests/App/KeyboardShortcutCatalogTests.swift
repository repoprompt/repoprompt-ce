import KeyboardShortcuts
@testable import RepoPrompt
import XCTest

final class KeyboardShortcutCatalogTests: XCTestCase {
    func testAgentLayoutCatalogContainsAgentModelPickerShortcut() throws {
        let section = try XCTUnwrap(
            KeyboardShortcutCatalog.sections.first(where: { $0.id == "agent-layout" })
        )

        let binding = try XCTUnwrap(
            section.bindings.first(where: { $0.id == "agent-model-picker" })
        )

        XCTAssertEqual(binding.title, "Open Agent/Model picker")
        XCTAssertEqual(binding.name, KeyboardShortcuts.Name.showAgentModelPicker)
    }
}
