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
        XCTAssertEqual(snapshot.catalogFingerprint, "f836f0c329a17368c7ec744dc389adba3cf49ae0750f12e0c199665a87dcee35")

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
