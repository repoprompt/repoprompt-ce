import CryptoKit
import Foundation
import MCP
import Ontology
@testable import RepoPrompt
import XCTest

@MainActor
final class SharedRuntimePhase0CharacterizationTests: XCTestCase {
    private static let appPublishedOverlapOrder = [
        "bind_context",
        "manage_workspaces",
        "manage_selection",
        "get_code_structure",
        "get_file_tree",
        "read_file",
        "file_search",
        "workspace_context",
        "prompt"
    ]

    func testAppPhase0CharacterizationSnapshot() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let registry = MCPServiceRegistry()
        let routing = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared,
            serviceRegistry: registry
        )

        do {
            let routingTools = try await Self.awaitRoutingTools(routing)
            let windowTools = await window.mcpServer.windowMCPTools
            let allTools = routingTools + windowTools
            let toolsByName = Dictionary(allTools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let overlappingTools = try Self.appPublishedOverlapOrder.map { name in
                try XCTUnwrap(toolsByName[name], "Missing app tool descriptor: \(name)")
            }

            let snapshot: [String: Any] = try [
                "format_version": 1,
                "runtime": "app-v1",
                "baseline_commit": "042a500b03b39d04237ec5544811696cf6b2f2f9",
                "tool_order": overlappingTools.map(\.name),
                "descriptors": overlappingTools.map(Self.descriptorRecord),
                "normalized_arguments": Self.normalizedArgumentRecords(),
                "responses": Self.responseRecords()
            ]

            registry.unregister(routing)
            await window.tearDown()
            try Self.assertOrRecord(snapshot, fixtureName: "app-characterization.json")
        } catch {
            registry.unregister(routing)
            await window.tearDown()
            throw error
        }
    }

    func testAppV1WorkspaceFixtureLoadsWithoutRewrite() async throws {
        let repositoryRoot = try RepoRoot.url()
        let source = repositoryRoot
            .appendingPathComponent("Tests/SharedRuntimeConvergenceFixtures/Phase0/App/WorkspaceV1", isDirectory: true)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRuntimePhase0-AppV1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: temporaryRoot)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporaryRoot) }

        let workspaceURL = temporaryRoot
            .appendingPathComponent("Workspace-Phase 0 App V1-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let indexURL = temporaryRoot.appendingPathComponent("workspacesIndex.json")
        let beforeWorkspace = try Data(contentsOf: workspaceURL)
        let beforeIndex = try Data(contentsOf: indexURL)

        let repository = WorkspaceRepository(rootProvider: { temporaryRoot })
        let workspaces = await repository.loadWorkspaceSnapshotFromDisk()
        let workspace = try XCTUnwrap(workspaces.only)
        let tab = try XCTUnwrap(workspace.composeTabs.only)

        XCTAssertEqual(workspace.id.uuidString, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        XCTAssertEqual(workspace.name, "Phase 0 App V1")
        XCTAssertEqual(workspace.repoPaths, ["__APP_FIXTURE_ROOT__"])
        XCTAssertEqual(workspace.activeComposeTabID?.uuidString, "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        XCTAssertEqual(tab.promptText, "phase zero app prompt")
        XCTAssertEqual(tab.selection.selectedPaths, [
            "__APP_FIXTURE_ROOT__/Sources/Full.swift",
            "__APP_FIXTURE_ROOT__/Sources/Sliced.swift"
        ])
        XCTAssertEqual(tab.selection.autoCodemapPaths, ["__APP_FIXTURE_ROOT__/Sources/Structure.swift"])
        XCTAssertEqual(tab.selection.slices["__APP_FIXTURE_ROOT__/Sources/Sliced.swift"], [
            LineRange(start: 2, end: 4, description: "phase zero slice")
        ])
        XCTAssertFalse(tab.selection.codemapAutoEnabled)
        XCTAssertFalse(workspace.normalizationRequiresSave)
        XCTAssertEqual(try Data(contentsOf: workspaceURL), beforeWorkspace)
        XCTAssertEqual(try Data(contentsOf: indexURL), beforeIndex)
    }

    private static func awaitRoutingTools(_ routing: WindowRoutingService) async throws -> [RepoPrompt.Tool] {
        for _ in 0 ..< 200 {
            let tools = await routing.tools.filter { ["bind_context", "manage_workspaces"].contains($0.name) }
            if tools.count == 2 { return tools }
            await Task.yield()
        }
        XCTFail("Timed out waiting for routing tool descriptors")
        return []
    }

    private static func descriptorRecord(_ tool: RepoPrompt.Tool) throws -> [String: Any] {
        let schema = try Value(tool.inputSchema)
        return try [
            "name": tool.name,
            "enabled_by_default": tool.isEnabledByDefault,
            "description": tool.description,
            "description_sha256": digest(tool.description),
            "input_schema": canonicalJSONString(schema),
            "schema_sha256": digest(canonicalJSONString(schema)),
            "annotations": [
                "title": optionalAny(tool.annotations.title),
                "read_only": optionalAny(tool.annotations.readOnlyHint),
                "destructive": optionalAny(tool.annotations.destructiveHint),
                "idempotent": optionalAny(tool.annotations.idempotentHint),
                "open_world": optionalAny(tool.annotations.openWorldHint)
            ]
        ]
    }

    private static func normalizedArgumentRecords() throws -> [[String: Any]] {
        let contextID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let payloads: [(String, [String: Value])] = [
            ("bind_context", ["op": .string("status"), "working_dirs": .string(" /tmp/a, /tmp/b ")]),
            ("manage_workspaces", ["action": .string("list")]),
            ("manage_selection", ["op": .string("get")]),
            ("workspace_context", ["op": .string("snapshot")]),
            ("get_file_tree", ["type": .string("roots")]),
            ("get_code_structure", ["scope": .string("selected")]),
            ("read_file", ["path": .string("Sources/App.swift")]),
            ("file_search", ["pattern": .string("needle"), "regex": .bool(false)]),
            ("prompt", ["op": .string("get")])
        ]

        return try payloads.map { toolName, innerPayload in
            var wrapped = innerPayload
            wrapped["context_id"] = .string(contextID)
            wrapped["_windowID"] = .string("41")
            wrapped["_rawJSON"] = .string("yes")
            let normalized = MCPToolArgsNormalizer.normalize(
                params: [toolName: .object(wrapped)],
                originalToolName: toolName,
                canonicalToolName: toolName
            )
            return try [
                "tool": toolName,
                "payload": canonicalJSONString(.object(normalized.payload)),
                "tab_id": optionalAny(normalized.tabID?.uuidString),
                "window_id": optionalAny(normalized.windowID),
                "context_id": optionalAny(normalized.contextID?.uuidString),
                "working_dirs": normalized.workingDirs,
                "raw_json": normalized.rawJSON,
                "warnings": normalized.warnings
            ]
        }
    }

    private static func responseRecords() throws -> [[String: Any]] {
        try appPublishedOverlapOrder.map { toolName in
            let args: [String: Value] = switch toolName {
            case "bind_context": ["op": .string("status")]
            case "manage_workspaces": ["action": .string("list")]
            case "manage_selection": ["op": .string("get")]
            case "workspace_context": ["op": .string("snapshot")]
            case "get_file_tree": ["type": .string("roots")]
            case "get_code_structure": ["scope": .string("selected")]
            case "read_file": ["path": .string("Sources/App.swift")]
            case "file_search": ["pattern": .string("needle")]
            case "prompt": ["op": .string("get")]
            default: [:]
            }
            let structured: Value = .object([
                "status": .string("ok"),
                "tool": .string(toolName),
                "items": .array([.string("phase0")])
            ])
            let formatted = ToolOutputFormatter.buildContentBlocks(
                toolName: toolName,
                args: args,
                result: structured,
                emitResources: false
            )
            let raw = ToolOutputFormatter.buildContentBlocks(
                toolName: toolName,
                args: ["_rawJSON": .bool(true)],
                result: structured,
                emitResources: false
            )
            return try [
                "tool": toolName,
                "source": "representative formatter-boundary fixture",
                "structured": canonicalJSONString(structured),
                "text": firstText(formatted),
                "raw_text": firstText(raw)
            ]
        }
    }

    private static func firstText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }

    private static func assertOrRecord(_ snapshot: [String: Any], fixtureName: String) throws {
        let fixtureURL = try RepoRoot.url()
            .appendingPathComponent("Tests/SharedRuntimeConvergenceFixtures/Phase0/App", isDirectory: true)
            .appendingPathComponent(fixtureName)
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let existing = try Data(contentsOf: fixtureURL)
        if ProcessInfo.processInfo.environment["RECORD_SHARED_RUNTIME_PHASE0"] == "1" {
            try data.write(to: fixtureURL, options: .atomic)
            return
        }
        let expected = try JSONSerialization.jsonObject(with: existing) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(actual, expected)
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private static func canonicalJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func optionalAny(_ value: (some Any)?) -> Any {
        if let value { return value }
        return NSNull()
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
