import MCP
@testable import RepoPrompt
import XCTest

final class MCPToolLifetimeCatalogTests: XCTestCase {
    func testCatalogExhaustivelyClassifiesEveryAdvertisedToolWithoutDefault() {
        let canonical = Set(MCPToolExecutionContractCatalog.orderedAdvertisedToolNames)
        XCTAssertEqual(canonical.count, 26)
        XCTAssertEqual(MCPToolLifetimeCatalog.classifiedToolNames, canonical)
        XCTAssertNil(MCPToolLifetimeCatalog.classification(forCanonicalToolName: "future_tool", arguments: [:]))
    }

    func testOperationVariantsFailClosedAndPreserveRequiredLifetimeBoundaries() {
        assertClass(.runtimeCapable, MCPGlobalToolName.bindContext, ["op": .string("list")])
        assertClass(.runtimeCapable, MCPGlobalToolName.bindContext, ["op": .string("status")])
        assertClass(.mixed, MCPGlobalToolName.bindContext, ["op": .string("bind")])
        XCTAssertNil(MCPToolLifetimeCatalog.classification(
            forCanonicalToolName: MCPGlobalToolName.bindContext,
            arguments: ["op": .string("future")]
        ))

        assertClass(.runtimeCapable, MCPGlobalToolName.manageWorkspaces, ["action": .string("list")])
        for action in [
            "switch", "create", "hide", "unhide", "delete", "add_folder", "remove_folder",
            "list_tabs", "select_tab", "create_tab", "close_tab"
        ] {
            assertClass(.mixed, MCPGlobalToolName.manageWorkspaces, ["action": .string(action)])
        }
        XCTAssertNil(MCPToolLifetimeCatalog.classification(
            forCanonicalToolName: MCPGlobalToolName.manageWorkspaces,
            arguments: ["action": .string("future")]
        ))
        assertClass(.runtimeCapable, MCPWindowToolName.getCodeStructure, ["scope": .string("paths")])
        assertClass(.mixed, MCPWindowToolName.getCodeStructure, ["scope": .string("selected")])
        assertClass(.runtimeCapable, MCPWindowToolName.getFileTree, ["mode": .string("full")])
        assertClass(.mixed, MCPWindowToolName.getFileTree, ["mode": .string("selected")])
        assertClass(.mixed, MCPWindowToolName.workspaceContext, [:])
        assertClass(.mixed, MCPWindowToolName.workspaceContext, ["op": .string("snapshot")])
        assertClass(.mixed, MCPWindowToolName.workspaceContext, ["op": .string("export")])
        assertClass(.uiRequired, MCPWindowToolName.workspaceContext, ["op": .string("list_presets")])
        assertClass(.uiRequired, MCPWindowToolName.workspaceContext, ["op": .string("select_preset")])
        XCTAssertNil(MCPToolLifetimeCatalog.classification(
            forCanonicalToolName: MCPWindowToolName.workspaceContext,
            arguments: ["op": .string("future")]
        ))
    }

    func testWholeToolClassesMatchPhaseSevenContract() {
        for tool in [
            MCPWindowToolName.fileActions,
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.git,
            MCPWindowToolName.manageWorktree,
            MCPWindowToolName.contextBuilder,
            MCPWindowToolName.askUser,
            MCPWindowToolName.agentExplore,
            MCPWindowToolName.agentRun,
            MCPWindowToolName.agentManage
        ] {
            assertClass(.uiRequired, tool, [:])
        }
        for tool in [
            MCPWindowToolName.manageSelection,
            MCPWindowToolName.readFile,
            MCPWindowToolName.search
        ] {
            assertClass(.mixed, tool, [:])
        }
    }

    private func assertClass(
        _ expected: MCPToolLifetimeClass,
        _ tool: String,
        _ arguments: [String: Value],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            MCPToolLifetimeCatalog.classification(forCanonicalToolName: tool, arguments: arguments),
            expected,
            file: file,
            line: line
        )
    }
}
