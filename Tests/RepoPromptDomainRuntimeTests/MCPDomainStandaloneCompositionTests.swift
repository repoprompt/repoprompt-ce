import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainStandaloneCompositionTests: XCTestCase {
    func testStandaloneInstallerResolvesEveryCanonicalToolWithoutAppComposition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-domain-standalone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "test",
            storageDirectory: root.appendingPathComponent("Runtime", isDirectory: true),
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true),
        ))
        try await runtime.start()
        let scopeID = DomainStandaloneScopeID()
        let backend = StandaloneCapabilityProbe()
        let installation = try await MCPDomainStandaloneToolInstaller.install(
            runtime: runtime,
            scopeID: scopeID,
            backends: MCPDomainStandaloneCapabilityBackends(
                global: backend,
                workspace: backend,
                filesystem: backend,
                conversation: backend,
                versionControl: backend,
                agent: backend,
                history: backend
            )
        )
        let canonicalNames = MCPDomainCanonicalToolDefinitions.definitions.map(\.name)
        XCTAssertEqual(canonicalNames, MCPDomainToolCatalog.orderedToolNames)
        XCTAssertEqual(canonicalNames.count, 27)
        XCTAssertEqual(Set(canonicalNames).count, 27)

        for name in MCPGlobalToolName.orderedToolNames {
            let resolution = await runtime.toolRegistry.resolve(toolName: name, scope: .application)
            XCTAssertEqual(try XCTUnwrap(resolution).binding.definition.name, name)
        }
        for name in MCPWindowToolName.orderedToolNames {
            let resolution = await runtime.toolRegistry.resolve(toolName: name, scope: .standalone(id: scopeID))
            XCTAssertEqual(try XCTUnwrap(resolution).binding.definition.name, name)
        }

        let snapshot = await runtime.toolRegistry.snapshot()
        XCTAssertEqual(snapshot.fingerprintsByToolName.count, 27)
        XCTAssertEqual(Set(snapshot.fingerprintsByToolName.keys), Set(canonicalNames))
        XCTAssertEqual(snapshot.catalogFingerprint, "17774798002a5456bb064839fa1a1536a2525bdc6fdc4e85405bafa08f490e55")

        let protectedCandidate = await runtime.toolRegistry.resolve(
            toolName: MCPWindowToolName.manageSelection,
            scope: .standalone(id: scopeID)
        )
        let protectedResolution = try XCTUnwrap(protectedCandidate)
        do {
            _ = try await protectedResolution.binding(["op": .string("set"), "paths": .array([])])
            XCTFail("Standalone protected mutation must deny without an invocation principal")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .principalMissing)
        }

        await MCPDomainStandaloneToolInstaller.uninstall(installation, runtime: runtime)
        _ = await runtime.shutdown()
    }

    func testInstalledAskOracleBindingRoutesAndRejectsMalformedArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-domain-ask-oracle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPDomainRuntime(configuration: DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "test",
            storageDirectory: root.appendingPathComponent("Runtime", isDirectory: true),
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true)
        ))
        try await runtime.start()
        let scopeID = DomainStandaloneScopeID()
        let backend = StandaloneCapabilityProbe()
        let recorder = StandaloneConversationRecorder()
        let installation = try await MCPDomainStandaloneToolInstaller.install(
            runtime: runtime,
            scopeID: scopeID,
            backends: MCPDomainStandaloneCapabilityBackends(
                global: backend,
                workspace: backend,
                filesystem: backend,
                conversation: RecordingConversationProbe(recorder: recorder),
                versionControl: backend,
                agent: backend,
                history: backend
            )
        )
        let candidate = await runtime.toolRegistry.resolve(
            toolName: MCPWindowToolName.askOracle,
            scope: .standalone(id: scopeID)
        )
        let binding = try XCTUnwrap(candidate).binding
        let securityContext = standaloneAskOracleSecurityContext(identity: runtime.identity)

        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(securityContext) {
            try await binding(["message": .string("start")])
        }
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(securityContext) {
            try await binding(["message": .string("continue"), "chat_id": .string("chat-1")])
        }
        _ = try await MCPDomainInvocationSecurityContext.$current.withValue(securityContext) {
            try await binding([
                "message": .string("restart"),
                "chat_id": .string("chat-1"),
                "new_chat": .bool(true),
                "model": .string("override-model")
            ])
        }

        let validCalls = await recorder.snapshot()
        XCTAssertEqual(validCalls, [
            ConversationCall(route: .start, chatID: nil, newChat: nil, model: nil),
            ConversationCall(route: .continuation, chatID: "chat-1", newChat: nil, model: nil),
            ConversationCall(route: .start, chatID: "chat-1", newChat: true, model: "override-model")
        ])

        let malformedCases: [(String, [String: Value], String)] = [
            (
                "blank chat_id",
                ["message": .string("invalid"), "chat_id": .string("  ")],
                "Oracle public chat identifiers must be non-empty."
            ),
            (
                "model override on continuation",
                [
                    "message": .string("invalid"),
                    "chat_id": .string("chat-1"),
                    "model": .string("override-model")
                ],
                "Oracle model overrides are valid only when starting a new conversation."
            ),
            (
                "chat_id",
                ["message": .string("invalid"), "chat_id": .int(1)],
                "ask_oracle chat_id must be a string"
            ),
            (
                "new_chat",
                ["message": .string("invalid"), "new_chat": .string("true")],
                "ask_oracle new_chat must be a boolean"
            ),
            (
                "model",
                ["message": .string("invalid"), "model": .bool(true)],
                "ask_oracle model must be a string"
            )
        ]
        for (label, arguments, expectedMessage) in malformedCases {
            do {
                _ = try await MCPDomainInvocationSecurityContext.$current.withValue(securityContext) {
                    try await binding(arguments)
                }
                XCTFail("Expected invalid params for malformed \(label)")
            } catch let error as MCPError {
                XCTAssertEqual(error.code, -32602, label)
                guard case let .invalidParams(message) = error else {
                    XCTFail("Expected MCPError.invalidParams for \(label), got \(error)")
                    continue
                }
                XCTAssertEqual(message, expectedMessage, label)
            }
            let callsAfterFailure = await recorder.snapshot()
            XCTAssertEqual(callsAfterFailure.count, validCalls.count, label)
        }

        await MCPDomainStandaloneToolInstaller.uninstall(installation, runtime: runtime)
        _ = await runtime.shutdown()
    }

    func testCanonicalBindContextIsGlobalAndHasNoWindowSelector() throws {
        let definition = try XCTUnwrap(
            MCPDomainCanonicalToolDefinitions.definition(named: MCPGlobalToolName.bindContext)
        )
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertNotNil(properties["context_id"])
        XCTAssertNotNil(properties["working_dirs"])
        XCTAssertNil(properties["window_id"])
        XCTAssertTrue(MCPGlobalToolName.orderedToolNames.contains(definition.name))
        XCTAssertFalse(MCPWindowToolName.orderedToolNames.contains(definition.name))
    }
}

private struct ConversationCall: Equatable {
    enum Route: Equatable {
        case start
        case continuation
    }

    let route: Route
    let chatID: String?
    let newChat: Bool?
    let model: String?
}

private actor StandaloneConversationRecorder {
    private var calls: [ConversationCall] = []

    func record(_ call: ConversationCall) {
        calls.append(call)
    }

    func snapshot() -> [ConversationCall] {
        calls
    }
}

private struct RecordingConversationProbe: DomainConversationCapabilityBackend {
    let recorder: StandaloneConversationRecorder

    private func result() throws -> DomainPhysicalToolResult {
        try DomainPhysicalToolResult(["ok": true])
    }

    private func record(
        _ route: ConversationCall.Route,
        request: DomainPhysicalToolRequest
    ) async throws -> DomainPhysicalToolResult {
        let arguments = try JSONDecoder().decode([String: Value].self, from: request.argumentsJSON)
        await recorder.record(ConversationCall(
            route: route,
            chatID: arguments["chat_id"]?.stringValue,
            newChat: arguments["new_chat"]?.boolValue,
            model: arguments["model"]?.stringValue
        ))
        return try result()
    }

    func accessOracleUtilities(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try result()
    }

    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await record(.start, request: request)
    }

    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await record(.continuation, request: request)
    }

    func readOracleLog(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try result()
    }

    func buildContext(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try result()
    }

    func requestUserInput(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try result()
    }
}

private func standaloneAskOracleSecurityContext(
    identity: DomainRuntimeIdentity
) -> DomainToolInvocationSecurityContext {
    DomainToolInvocationSecurityContext(
        principal: .init(
            principalID: UUID(),
            stableKey: "standalone-composition-test",
            displayName: "Standalone Composition Test",
            kind: .runScoped,
            assurance: .verifiedProcess,
            processID: identity.processID,
            runID: UUID(),
            provider: "fixture",
            verifiedIdentityFingerprint: "fixture"
        ),
        connectionID: UUID(),
        connectionGeneration: 1,
        invocationID: UUID(),
        runtimeID: identity.runtimeID,
        runtimeGeneration: identity.lifecycleGeneration,
        hasAuthoritativeRoutingContext: true,
        ephemeralGrantedToolNames: [MCPWindowToolName.askOracle]
    )
}

private struct StandaloneCapabilityProbe: DomainGlobalControlBackend,
    DomainWorkspaceCapabilityBackend,
    DomainFilesystemMutationBackend,
    DomainConversationCapabilityBackend,
    DomainVersionControlCapabilityBackend,
    DomainAgentCapabilityBackend,
    DomainHistoryCapabilityBackend
{
    private func result() throws -> DomainPhysicalToolResult {
        try DomainPhysicalToolResult(["ok": true])
    }

    func accessSettings(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func routeContext(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func manageWorkspaceLifecycle(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func mutateSelection(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func inspectCodeStructure(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func renderFileTree(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func readFile(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func searchFiles(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func renderWorkspaceContext(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func accessPrompt(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func manageFiles(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func applyFileEdits(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func accessOracleUtilities(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func startOracleConversation(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func continueOracleConversation(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func readOracleLog(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func buildContext(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func requestUserInput(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func inspectGit(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
    func manageWorktree(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func explore(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func run(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func manage(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func shareThoughts(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func publishStatus(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func waitForInstruction(_: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult { try result() }
    func inspectHistory(_: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult { try result() }
}
