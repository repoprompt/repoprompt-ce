import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class DirectHeadlessContextBuilderContractTests: XCTestCase {
    func testWireAdvertisementDescribesOnlyImplementedContextBuilder() async throws {
        let fixture = try await makeFixture()
        let listed = try await fixture.client.listTools()
        let tool = try XCTUnwrap(listed.tools.first { $0.name == "context_builder" })
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"]
        else { return XCTFail("Expected Context Builder schema") }
        XCTAssertEqual(Set(properties.keys), ["instructions", "context_pack_ref", "response_type", "model"])
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(
            properties["response_type"]?.objectValue?["enum"],
            .array([.string("question"), .string("plan"), .string("review")])
        )
        XCTAssertTrue(tool.description?.contains("does not discover files") == true)
        XCTAssertTrue(tool.description?.contains("does not export") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.callLog.path))
    }

    func testGroupedRawInstructionsHaveActionableWireErrorWithoutProviderWork() async throws {
        let fixture = try await makeFixture(grouped: true)
        try await assertWireError(
            fixture,
            arguments: ["instructions": .string("review this")],
            prefix: "context_pack_required:"
        )
    }

    func testSingletonSuppliedPackIsUnsupportedNotMissingOnWire() async throws {
        let fixture = try await makeFixture()
        try await assertWireError(
            fixture,
            arguments: ["context_pack_ref": .string(Self.missingPack)],
            prefix: "context_pack_requires_oracle_group:"
        )
    }

    func testUnsupportedDiscoveryExportAndMalformedInputsRejectBeforeProviderWork() async throws {
        let fixture = try await makeFixture()
        let cases: [([String: Value], String)] = [
            (["instructions": .string("review this"), "export_response": .bool(true)], "context_builder_unsupported_argument:"),
            (["instructions": .string("review this"), "response_type": .string("clarify")], "context_builder_discovery_unsupported:"),
            (["instructions": .string("review this"), "response_type": .string("typo")], "context_builder_invalid_response_type:"),
            (["instructions": .int(42)], "context_builder_invalid_arguments:"),
            (["instructions": .null], "context_builder_invalid_arguments:"),
            (["instructions": .string("review this"), "response_type": .int(42)], "context_builder_invalid_arguments:"),
            (["instructions": .string("review this"), "model": .bool(true)], "context_builder_invalid_arguments:"),
            (["instructions": .string("review this"), "model": .string(" ")], "context_builder_invalid_arguments:"),
            (["instructions": .string("review this"), "unexpected": .string("value")], "context_builder_unsupported_argument:"),
            (["instructions": .string(" ")], "context_builder_invalid_arguments:"),
            (["instructions": .string("review this"), "context_pack_ref": .string(Self.missingPack)], "context_builder_invalid_arguments:")
        ]
        for (arguments, prefix) in cases {
            try await assertWireError(fixture, arguments: arguments, prefix: prefix)
        }
    }

    func testGroupedPackFailuresHaveDistinctWireDiagnosticsBeforeProviderWork() async throws {
        let fixture = try await makeFixture(grouped: true)
        try await assertWireError(
            fixture,
            arguments: ["context_pack_ref": .string("file:///tmp/pack")],
            prefix: "context_pack_invalid_reference:"
        )
        try await assertWireError(
            fixture,
            arguments: ["context_pack_ref": .string(Self.missingPack)],
            prefix: "context_pack_unavailable:"
        )
        let invalidID = try await fixture.prepared.oracleStore.storeArtifact(Data("not a canonical pack".utf8))
        let invalid = try OracleFrozenPackReference(artifactID: invalidID)
        try await assertWireError(
            fixture,
            arguments: ["context_pack_ref": .string(invalid.rawValue)],
            prefix: "context_pack_invalid:"
        )
        let pack = try OracleFrozenContextPack(mode: .review, content: "frozen review context")
        let packID = try await fixture.prepared.oracleStore.storeArtifact(pack.canonicalData())
        let reference = try OracleFrozenPackReference(artifactID: packID)
        try await assertWireError(
            fixture,
            arguments: [
                "context_pack_ref": .string(reference.rawValue),
                "response_type": .string("plan")
            ],
            prefix: "context_pack_mode_mismatch:"
        )
    }

    func testSingleOracleDefaultsAndModesAreOneShotCallerPromptWithoutDiscovery() async throws {
        let fixture = try await makeFixture(successfulProvider: true)
        let before = try await fixture.prepared.context.snapshot(connectionID: fixture.prepared.connectionID)
        for mode in [nil, "question", "plan", "review"] as [String?] {
            var arguments: [String: Value] = ["instructions": .string("caller chooses the output")]
            if let mode { arguments["response_type"] = .string(mode) }
            let result = try await fixture.client.callTool(name: "context_builder", arguments: arguments)
            XCTAssertEqual(result.isError, false)
            guard case let .text(text, _, _)? = result.content.first,
                  let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return XCTFail("Expected encoded Context Builder response") }
            XCTAssertEqual(object["response"] as? String, "one-shot-response")
            XCTAssertEqual(object["backend"] as? String, "headless")
            XCTAssertNil(object["oracle_export_path"])
            XCTAssertNil(object["selection"])
        }
        let after = try await fixture.prepared.context.snapshot(connectionID: fixture.prepared.connectionID)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.prompt, before.prompt)
        XCTAssertEqual(after.workspace.revisions.workingRevision, before.workspace.revisions.workingRevision)
        let deliveredPrompts = try String(contentsOf: fixture.callLog, encoding: .utf8)
        XCTAssertEqual(deliveredPrompts, String(repeating: "caller chooses the output", count: 4))
    }

    private static let missingPack = "oracle-pack:sha256:" + String(repeating: "0", count: 64)

    private func assertWireError(
        _ fixture: Fixture,
        arguments: [String: Value],
        prefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await fixture.client.callTool(name: "context_builder", arguments: arguments)
        XCTAssertEqual(result.isError, true, file: file, line: line)
        let text = result.content.compactMap { content -> String? in
            guard case let .text(value, _, _) = content else { return nil }
            return value
        }.joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix(prefix), "Expected \(prefix), received \(text)", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.callLog.path),
            "Rejected input must not launch a provider",
            file: file,
            line: line
        )
    }

    private struct Fixture {
        let client: Client
        let prepared: DirectHeadlessMCPService.PreparedRuntime
        let callLog: URL
    }

    private func makeFixture(grouped: Bool = false, successfulProvider: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-context-builder-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let callLog = directory.appendingPathComponent("provider-called")
        let executable = directory.appendingPathComponent("codex-stub")
        // A safe tripwire: even broken preflight never invokes a real/paid provider.
        let script = successfulProvider
            ? "#!/bin/sh\n/bin/cat >> '\(callLog.path)'\n/usr/bin/printf '%s\\n' '{\"type\":\"message\",\"text\":\"one-shot-response\"}'\n"
            : "#!/bin/sh\n/usr/bin/touch '\(callLog.path)'\nexit 7\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_CODEX_COMMAND": executable.path,
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "wire-contract",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": directory.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ], currentDirectory: directory, allowsProviderProcessLaunchForTesting: true)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        _ = try await prepared.settingsStore.set(key: OracleRosterContract.primarySettingKey, value: .string("lane-0"))
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(grouped ? ["lane-1"] : [])
        )
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Headless contract test", version: "1", capabilities: .init(tools: .init()))
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [], ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations.union([
                "context_builder.ai_cost", "context_builder.external_process"
            ])
        ))
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Headless wire contract client", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        return Fixture(client: client, prepared: prepared, callLog: callLog)
    }
}
