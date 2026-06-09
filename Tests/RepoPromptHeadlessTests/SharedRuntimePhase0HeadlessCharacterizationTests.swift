import Foundation
@testable import RepoPromptHeadless
import XCTest

final class SharedRuntimePhase0HeadlessCharacterizationTests: XCTestCase {
    private static let overlappingToolNames = [
        "bind_context",
        "manage_workspaces",
        "manage_selection",
        "workspace_context",
        "get_file_tree",
        "get_code_structure",
        "read_file",
        "file_search",
        "prompt"
    ]

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testHeadlessPhase0CharacterizationSnapshot() async throws {
        let fixture = try makeServerFixture()
        let initializeAction = try await fixture.server.handle(frame: initializeRequest())
        var initialize = try resultObject(initializeAction)
        let replacements = [fixture.stateDirectory.path: "$STATE", fixture.rootDirectory.path: "$ROOT"]
        normalizePaths(in: &initialize, replacements: replacements)
        _ = try await fixture.server.handle(frame: notification("notifications/initialized"))

        let listAction = try await fixture.server.handle(frame: request("tools/list", id: 2))
        let listResult = try resultObject(listAction)
        let descriptors = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(descriptors.compactMap { $0["name"] as? String }, Self.overlappingToolNames)

        var responses: [[String: Any]] = []
        for (index, toolName) in Self.overlappingToolNames.enumerated() {
            let successAction = try await fixture.server.handle(frame: request(
                "tools/call",
                id: index + 10,
                params: ["name": toolName, "arguments": successArguments(for: toolName)]
            ))
            var success = try resultObject(successAction)
            normalizePaths(in: &success, replacements: replacements)
            if toolName == "file_search" {
                success = phase0FileSearchSnapshot(from: success)
            }

            let failureAction = try await fixture.server.handle(frame: request(
                "tools/call",
                id: index + 30,
                params: ["name": toolName, "arguments": failureArguments(for: toolName)]
            ))
            var failure = try resultObject(failureAction)
            normalizePaths(in: &failure, replacements: replacements)
            responses.append(["tool": toolName, "success": success, "failure": failure])
        }

        let snapshot: [String: Any] = [
            "format_version": 1,
            "runtime": "headless-v1",
            "baseline_commit": "487cd71d892dbc3104689cc42fdb39f6c038e8fb",
            "initialize": initialize,
            "tool_order": Self.overlappingToolNames,
            "descriptors": descriptors,
            "argument_coercion": argumentCoercionRecords(),
            "responses": responses
        ]
        try assertOrRecord(snapshot, fixtureName: "headless-characterization.json")
    }

    func testToolRegistryCapabilitiesAreExhaustiveAndDisjoint() {
        XCTAssertEqual(HeadlessToolRegistry.registrations.map(\.name), Self.overlappingToolNames)
        XCTAssertTrue(HeadlessToolRegistry.registrations.allSatisfy { $0.capability == .safeProfile })
        XCTAssertTrue(Set(HeadlessToolRegistry.registrations.map(\.name)).isDisjoint(with: HeadlessToolRegistry.blockedCapabilities.keys))
        XCTAssertEqual(
            Set(HeadlessToolRegistry.blockedCapabilities.keys),
            Set([
                "file_actions", "apply_edits", "git", "manage_worktree",
                "agent_run", "agent_explore", "agent_manage",
                "ask_oracle", "oracle_send", "oracle_chat_log", "context_builder", "ask_user",
                "share_thoughts", "set_status", "wait_for_next_user_instruction", "app_settings"
            ])
        )
    }

    func testDangerousToolsStayHiddenAndFailClosedWhenAllPermissionsAreEnabled() async throws {
        let directory = try makeTemporaryDirectory(prefix: "HeadlessToolCapabilities")
        let store = HeadlessConfigurationStore(paths: HeadlessStatePaths(rootDirectory: directory))
        _ = try store.update { document in
            document.permissions = HeadlessPermissions(
                writeFiles: true,
                vcsWrite: true,
                launchAgents: true,
                exportOutsideStateDirectory: true
            )
        }
        let registry = HeadlessToolRegistry(
            host: HeadlessHost(configurationStore: store),
            configurationStore: store
        )

        XCTAssertEqual(
            registry.listDescriptors().compactMap { $0["name"] as? String },
            Self.overlappingToolNames
        )
        for (toolName, capability) in HeadlessToolRegistry.blockedCapabilities {
            let response = await registry.call(name: toolName, arguments: [:])
            XCTAssertEqual(response["isError"] as? Bool, true, toolName)
            let content = try XCTUnwrap(response["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            XCTAssertTrue(text.contains("Required capability: \(capability.rawValue)"), toolName)
            XCTAssertTrue(text.contains("fails closed"), toolName)
        }
    }

    func testHeadlessV1WorkspaceFixtureLoadsWithoutRewrite() throws {
        let repositoryRoot = try HeadlessTestRepoRoot.url()
        let source = repositoryRoot
            .appendingPathComponent("Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless/ProfileV1", isDirectory: true)
        let directory = try makeTemporaryDirectory(prefix: "SharedRuntimePhase0-HeadlessV1")
        let stateDirectory = directory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: stateDirectory)

        let rootDirectory = directory.appendingPathComponent("FixtureRoot", isDirectory: true)
        let sourcesDirectory = rootDirectory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try "struct Full {}\n".write(to: sourcesDirectory.appendingPathComponent("Full.swift"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\nfour\n".write(to: sourcesDirectory.appendingPathComponent("Sliced.swift"), atomically: true, encoding: .utf8)
        try "struct Structure { func run() {} }\n".write(to: sourcesDirectory.appendingPathComponent("Structure.swift"), atomically: true, encoding: .utf8)

        let configURL = stateDirectory.appendingPathComponent("config.json")
        var configText = try String(contentsOf: configURL, encoding: .utf8)
        configText = configText
            .replacingOccurrences(of: "__FIXTURE_ROOT_PATH__", with: rootDirectory.path)
            .replacingOccurrences(
                of: "__FIXTURE_ROOT_RESOLVED_PATH__",
                with: rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            )
        try configText.write(to: configURL, atomically: true, encoding: .utf8)

        let workspaceID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let workspaceURL = stateDirectory
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString).json")
        let beforeConfig = try Data(contentsOf: configURL)
        let beforeWorkspace = try Data(contentsOf: workspaceURL)

        let paths = HeadlessStatePaths(rootDirectory: stateDirectory)
        let configuration = try HeadlessConfigurationStore(paths: paths).loadOrCreate()
        let workspace = try XCTUnwrap(HeadlessWorkspaceStore(paths: paths).loadWorkspace(id: workspaceID))

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.activeWorkspaceID, workspaceID)
        XCTAssertEqual(configuration.allowedRoots.only?.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(configuration.allowedRoots.only?.path, rootDirectory.path)
        XCTAssertEqual(workspace.schemaVersion, 1)
        XCTAssertEqual(workspace.name, "Phase 0 Headless V1")
        XCTAssertEqual(workspace.promptText, "phase zero headless prompt\nsecond line")
        XCTAssertEqual(workspace.selection.map(\.mode), [.full, .slices, .codemapOnly])
        XCTAssertEqual(workspace.selection[1].ranges, [
            HeadlessLineRange(startLine: 2, endLine: 4, description: "phase zero slice")
        ])
        XCTAssertEqual(try Data(contentsOf: configURL), beforeConfig)
        XCTAssertEqual(try Data(contentsOf: workspaceURL), beforeWorkspace)
    }

    private func argumentCoercionRecords() -> [[String: Any]] {
        [
            ["tool": "bind_context", "input": ["workspace": 7], "observed": optionalAny(HeadlessToolArguments.string(["workspace": 7], key: "workspace"))],
            ["tool": "manage_workspaces", "input": ["roots": "Phase0Root"], "observed": HeadlessToolArguments.stringArray(["roots": "Phase0Root"], key: "roots") ?? []],
            ["tool": "manage_selection", "input": ["paths": ["a", 7, "b"]], "observed": HeadlessToolArguments.stringArray(["paths": ["a", 7, "b"]], key: "paths") ?? []],
            ["tool": "workspace_context", "input": ["include": "prompt"], "observed": HeadlessToolArguments.stringArray(["include": "prompt"], key: "include") ?? []],
            ["tool": "get_file_tree", "input": ["max_depth": "3"], "observed": optionalAny(HeadlessToolArguments.int(["max_depth": "3"], key: "max_depth"))],
            ["tool": "get_code_structure", "input": ["max_results": NSNumber(value: 4)], "observed": optionalAny(HeadlessToolArguments.int(["max_results": NSNumber(value: 4)], key: "max_results"))],
            ["tool": "read_file", "input": ["start_line": "2"], "observed": optionalAny(HeadlessToolArguments.int(["start_line": "2"], key: "start_line"))],
            ["tool": "file_search", "input": ["regex": "yes"], "observed": optionalAny(HeadlessToolArguments.bool(["regex": "yes"], key: "regex"))],
            ["tool": "prompt", "input": ["text": 7], "observed": optionalAny(HeadlessToolArguments.string(["text": 7], key: "text"))]
        ]
    }

    private func makeServerFixture() throws -> ServerFixture {
        let directory = try makeTemporaryDirectory(prefix: "SharedRuntimePhase0-HeadlessServer")
        let stateDirectory = directory.appendingPathComponent("State", isDirectory: true)
        let rootDirectory = directory.appendingPathComponent("FixtureRoot", isDirectory: true)
        let source = try HeadlessTestRepoRoot.url()
            .appendingPathComponent("Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless/ProfileV1", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: stateDirectory)
        let sourcesDirectory = rootDirectory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try "struct Full {}\n".write(to: sourcesDirectory.appendingPathComponent("Full.swift"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\nfour\n".write(to: sourcesDirectory.appendingPathComponent("Sliced.swift"), atomically: true, encoding: .utf8)
        try "struct Structure { func run() {} }\n".write(to: sourcesDirectory.appendingPathComponent("Structure.swift"), atomically: true, encoding: .utf8)
        let configURL = stateDirectory.appendingPathComponent("config.json")
        var configText = try String(contentsOf: configURL, encoding: .utf8)
        configText = configText
            .replacingOccurrences(of: "__FIXTURE_ROOT_PATH__", with: rootDirectory.path)
            .replacingOccurrences(
                of: "__FIXTURE_ROOT_RESOLVED_PATH__",
                with: rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            )
        try configText.write(to: configURL, atomically: true, encoding: .utf8)
        let store = HeadlessConfigurationStore(paths: HeadlessStatePaths(rootDirectory: stateDirectory))
        return ServerFixture(
            stateDirectory: stateDirectory,
            rootDirectory: rootDirectory,
            server: HeadlessMCPServer(configurationStore: store)
        )
    }

    private func successArguments(for toolName: String) -> [String: Any] {
        switch toolName {
        case "bind_context": ["op": "status"]
        case "manage_workspaces": ["op": "list"]
        case "manage_selection": ["op": "get"]
        case "workspace_context": ["op": "snapshot", "include": ["prompt", "selection"]]
        case "get_file_tree": ["type": "roots"]
        case "get_code_structure": ["scope": "paths", "paths": ["Sources/Structure.swift"]]
        case "read_file": ["path": "Sources/Full.swift"]
        case "file_search": ["pattern": "struct Full", "mode": "content", "regex": false]
        case "prompt": ["op": "get"]
        default: [:]
        }
    }

    private func failureArguments(for toolName: String) -> [String: Any] {
        switch toolName {
        case "bind_context", "manage_workspaces", "manage_selection", "workspace_context", "prompt":
            ["op": "phase0_invalid"]
        case "get_file_tree": ["path": "Missing"]
        case "get_code_structure": ["scope": "phase0_invalid"]
        case "read_file": [:]
        case "file_search": [:]
        default: [:]
        }
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func request(_ method: String, id: Any, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func notification(_ method: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
    }

    private func initializeRequest() throws -> Data {
        try request(
            "initialize",
            id: 1,
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "phase0-characterization", "version": "1"]
            ]
        )
    }

    private func resultObject(_ action: HeadlessRPCAction) throws -> [String: Any] {
        let data = try XCTUnwrap(action.responseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func normalizePaths(in object: inout [String: Any], replacements: [String: String]) {
        object = Self.normalizedValue(object, replacements: replacements) as? [String: Any] ?? object
    }

    private static func normalizedValue(_ value: Any, replacements: [String: String]) -> Any {
        if let string = value as? String {
            if string.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
                options: .regularExpression
            ) != nil {
                return "$TIMESTAMP"
            }
            return replacements.reduce(string) { result, replacement in
                result.replacingOccurrences(of: replacement.key, with: replacement.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { normalizedValue($0, replacements: replacements) }
        }
        if let object = value as? [String: Any] {
            return object.mapValues { normalizedValue($0, replacements: replacements) }
        }
        return value
    }

    private func phase0FileSearchSnapshot(from response: [String: Any]) -> [String: Any] {
        var response = response
        if var content = response["content"] as? [[String: Any]],
           !content.isEmpty,
           let text = content[0]["text"] as? String
        {
            let currentOnlyPrefixes = [
                "- **Catalog entries processed**:",
                "- **Content files read**:",
                "- **Content bytes read**:",
                "- **Matcher work bytes**:",
                "- **Elapsed budget**:"
            ]
            content[0]["text"] = text
                .components(separatedBy: .newlines)
                .filter { line in !currentOnlyPrefixes.contains(where: line.hasPrefix) }
                .joined(separator: "\n")
            response["content"] = content
        }
        if var structured = response["structuredContent"] as? [String: Any] {
            for key in [
                "catalog_entries_processed",
                "content_files_attempted",
                "content_file_limit",
                "content_bytes_scanned",
                "content_bytes_considered",
                "content_byte_limit",
                "matcher_work_bytes",
                "matcher_work_byte_limit",
                "regex_subject_byte_limit",
                "elapsed_milliseconds",
                "elapsed_time_limit_milliseconds",
                "budget_exhausted",
                "budget_exhaustion_reason"
            ] {
                structured.removeValue(forKey: key)
            }
            response["structuredContent"] = structured
        }
        return response
    }

    private func assertOrRecord(_ snapshot: [String: Any], fixtureName: String) throws {
        let fixtureURL = try HeadlessTestRepoRoot.url()
            .appendingPathComponent("Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless", isDirectory: true)
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

    private func optionalAny(_ value: (some Any)?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private struct ServerFixture {
        let stateDirectory: URL
        let rootDirectory: URL
        let server: HeadlessMCPServer
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
