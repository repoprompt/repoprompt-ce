import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

final class DirectHeadlessExperimentProfileTests: XCTestCase {
    func testEngineerProfileEditsOnlyItsFixtureThroughRealMCPDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engineer-mcp-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("private-test.txt")
        try Data("sealed expected answer".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "engineer-test",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
            "REPOPROMPT_MCP_WORKING_DIRS": workspace.path,
            PromptExperimentAgentProfile.environmentKey: PromptExperimentAgentProfile.identifier
        ], currentDirectory: workspace)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        XCTAssertTrue(prepared.isPromptExperiment)
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Engineer tools", version: "1", capabilities: .init(tools: .init()))
        let connection = await service.topLevelConnection(prepared)
        await service.installHandlers(server: server, prepared: prepared, connection: connection)
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Engineer fixture", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        let advertised = try await client.listTools()
        XCTAssertEqual(Set(advertised.tools.map(\.name)), PromptExperimentAgentProfile.toolNames)
        let target = workspace.appendingPathComponent("task.py")
        let edit = try await client.callTool(name: "apply_edits", arguments: [
            "path": .string(target.path), "rewrite": .string("def answer():\n    return 42\n"), "on_missing": .string("create")
        ])
        XCTAssertNotEqual(edit.isError, true)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "def answer():\n    return 42\n")
        let privateRead = try await client.callTool(name: "read_file", arguments: ["path": .string(outside.path)])
        XCTAssertEqual(privateRead.isError, true)
        let privateWrite = try await client.callTool(name: "apply_edits", arguments: [
            "path": .string(outside.path), "rewrite": .string("tampered")
        ])
        XCTAssertEqual(privateWrite.isError, true)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "sealed expected answer")
        let workspaceChange = try await client.callTool(name: "manage_workspaces", arguments: ["action": .string("list")])
        XCTAssertEqual(workspaceChange.isError, true)
        let delegate = try await client.callTool(name: "agent_run", arguments: ["op": .string("start")])
        XCTAssertEqual(delegate.isError, true)
    }

    func testExperimentProfileRejectsMissingOrEditableProfileAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func locations(explicit: Bool, profile: URL) -> DirectHeadlessRuntimeLocations {
            .init(
                profileIdentifier: "engineer-test", storageDirectory: profile,
                workspaceStorageDirectory: profile, eventDirectory: profile, temporaryDirectory: profile,
                workingDirectories: [root], usesExplicitProfileDirectory: explicit
            )
        }
        let environment = [PromptExperimentAgentProfile.environmentKey: PromptExperimentAgentProfile.identifier]
        XCTAssertThrowsError(try DirectHeadlessExperimentProfile.isEnabled(
            environment: environment, locations: locations(explicit: false, profile: root.deletingLastPathComponent())
        ))
        XCTAssertThrowsError(try DirectHeadlessExperimentProfile.isEnabled(
            environment: environment, locations: locations(explicit: true, profile: root.appendingPathComponent("profile"))
        ))
        XCTAssertThrowsError(try DirectHeadlessExperimentProfile.isEnabled(
            environment: [PromptExperimentAgentProfile.environmentKey: "arbitrary"],
            locations: locations(explicit: true, profile: root.deletingLastPathComponent())
        ))
    }
}
