import CryptoKit
import Darwin
import Foundation
import MCP
import Ontology
@testable import RepoPrompt
import RepoPromptShared
import XCTest

@MainActor
final class ToolCatalogSnapshotTests: XCTestCase {
    func testWindowToolCatalogSignatureMatchesGolden() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let signatures = try Self.signatures(for: tools)

        XCTAssertEqual(
            tools.map(\.name),
            MCPWindowToolGroup.orderedToolNames,
            "Window catalog order should follow MCPWindowToolGroup."
        )
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count, "Window catalog should not contain duplicate tool names.")
        XCTAssertTrue(
            tools.allSatisfy { MCPToolExecutionContractCatalog.contract(for: $0.name) != nil },
            "Every live window tool must have an explicit execution contract."
        )
        XCTAssertEqual(
            MCPWindowToolGroup.git.orderedToolNames,
            [MCPWindowToolName.git, MCPWindowToolName.manageWorktree],
            ".git group should reserve deterministic provider order for git-related tools."
        )
        XCTAssertEqual(
            tools.map(\.name).filter { MCPWindowToolGroup.git.orderedToolNames.contains($0) },
            MCPWindowToolGroup.git.orderedToolNames,
            "Window catalog should keep .git providers ordered as git, manage_worktree."
        )

        if ProcessInfo.processInfo.environment["RECORD_MCP_WINDOW_TOOL_CATALOG"] == "1" {
            print(Self.renderGolden(signatures))
        }

        XCTAssertEqual(signatures, Self.expectedSignatures)
    }

    func testAgentLifecycleSchemasAdvertiseTwoMinuteDefaultsWithoutMaximumClamp() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore })
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })

        let exploreTimeout = try XCTUnwrap(
            Self.schemaProperties(for: agentExplore)["timeout"]?.objectValue?["description"]?.stringValue
        )
        let runProperties = try Self.schemaProperties(for: agentRun)
        let runTimeout = try XCTUnwrap(runProperties["timeout"]?.objectValue?["description"]?.stringValue)
        let steerTimeout = try XCTUnwrap(runProperties["timeout_seconds"]?.objectValue?["description"]?.stringValue)

        let defaultText = "Default \(Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds))."
        for description in [exploreTimeout, runTimeout, steerTimeout] {
            XCTAssertTrue(description.contains(defaultText), description)
            XCTAssertFalse(description.lowercased().contains("maximum"), description)
        }
    }

    func testInteractiveLifecycleSchemasPreserveConfigurableWaitsWithoutMaximumClamp() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let askUser = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.askUser })
        let waitForNextInstruction = try XCTUnwrap(
            tools.first { $0.name == MCPWindowToolName.waitForNextInstruction }
        )

        let askUserTimeout = try XCTUnwrap(
            Self.schemaProperties(for: askUser)["timeout_seconds"]?.objectValue?["description"]?.stringValue
        )
        let instructionTimeout = try XCTUnwrap(
            Self.schemaProperties(for: waitForNextInstruction)["timeout_seconds"]?.objectValue?["description"]?.stringValue
        )

        XCTAssertTrue(askUserTimeout.contains("workspace question-timeout setting"), askUserTimeout)
        XCTAssertTrue(
            instructionTimeout.contains(
                "Default \(Int(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds))."
            ),
            instructionTimeout
        )
        XCTAssertFalse(askUserTimeout.lowercased().contains("maximum"), askUserTimeout)
        XCTAssertFalse(instructionTimeout.lowercased().contains("maximum"), instructionTimeout)
    }

    func testCanonicalReadOnlyAnnotationsRemainTruthfulOutsideCodexProjection() async {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let canonicalReadOnlyTools = tools.filter { $0.annotations.readOnlyHint == true }

        XCTAssertFalse(canonicalReadOnlyTools.isEmpty)
        XCTAssertTrue(canonicalReadOnlyTools.allSatisfy { $0.annotations.readOnlyHint == true })
        XCTAssertTrue(
            canonicalReadOnlyTools.allSatisfy {
                CodexMCPToolAnnotationProjection.project(
                    $0.annotations,
                    clientIdentifier: "generic-mcp-client"
                ) == $0.annotations
            }
        )
    }

    func testCodexProjectionClearsOnlyReadOnlyHintForPositiveCodexIdentity() {
        let canonical = MCP.Tool.Annotations(
            title: "Read workspace",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
        let codexIdentities: [String?] = [
            "codex-mcp-client",
            "Codex MCP Client",
            "codex-mcp-client/1.2.3",
            "codex-mcp-client-v2"
        ]

        for identity in codexIdentities {
            let projected = CodexMCPToolAnnotationProjection.project(
                canonical,
                clientIdentifier: identity
            )
            XCTAssertNil(projected.readOnlyHint, identity ?? "nil")
            XCTAssertEqual(projected.title, canonical.title, identity ?? "nil")
            XCTAssertEqual(projected.destructiveHint, canonical.destructiveHint, identity ?? "nil")
            XCTAssertEqual(projected.idempotentHint, canonical.idempotentHint, identity ?? "nil")
            XCTAssertEqual(projected.openWorldHint, canonical.openWorldHint, identity ?? "nil")
        }

        for readOnlyHint in [false, nil] as [Bool?] {
            let annotations = MCP.Tool.Annotations(
                title: canonical.title,
                readOnlyHint: readOnlyHint,
                destructiveHint: canonical.destructiveHint,
                idempotentHint: canonical.idempotentHint,
                openWorldHint: canonical.openWorldHint
            )
            XCTAssertNil(
                CodexMCPToolAnnotationProjection.project(
                    annotations,
                    clientIdentifier: "codex-mcp-client"
                ).readOnlyHint
            )
        }

        XCTAssertEqual(canonical.readOnlyHint, true, "Projection must not mutate canonical catalog metadata.")
    }

    func testCodexProjectionPreservesMetadataForMissingAmbiguousAndNonCodexIdentities() {
        let canonical = MCP.Tool.Annotations(
            title: "Read workspace",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
        let identities: [String?] = [
            nil,
            "",
            "codex",
            "codex-client",
            "codex-wrapper-beta",
            "claude-code",
            "repoprompt-cli"
        ]

        for identity in identities {
            XCTAssertEqual(
                CodexMCPToolAnnotationProjection.project(
                    canonical,
                    clientIdentifier: identity
                ),
                canonical,
                identity ?? "nil"
            )
        }
    }

    func testProductionRegistrationUsesCatalogServiceNotViewModel() async throws {
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let window = Self.makeWindowWithoutAutoStart()
                let catalogService = window.mcpServer.windowMCPToolCatalogService

                try await Self.withIsolatedBootstrapSocketNamespace(window: window, catalogService: catalogService) { socketURL in
                    await window.mcpServer.ensureServerReadyForAgentBootstrap()
                    XCTAssertTrue(ServiceRegistry.services.contains { service in
                        (service as AnyObject) === (catalogService as AnyObject)
                    })
                    XCTAssertFalse(ServiceRegistry.services.contains { service in
                        (service as AnyObject) === (window.mcpServer as AnyObject)
                    })

                    let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
                    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)

                    await Self.assertBootstrapSocketOverrideError(.managerNotFullyStopped) {
                        try await ServerNetworkManager.shared.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
                    }
                }
            }
        #else
            throw XCTSkip("Bootstrap socket URL override seam is DEBUG-only")
        #endif
    }

    func testWorktreePublicAPISchemaFieldsRemainAdvertised() async throws {
        let window = Self.makeWindowWithoutAutoStart()
        let tools = await window.mcpServer.windowMCPTools
        let manageWorktree = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.manageWorktree })
        let agentExplore = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentExplore })
        let agentRun = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentRun })

        let manageProperties = try Self.schemaProperties(for: manageWorktree)
        for field in [
            "include_graph",
            "graph_limit",
            "worktree",
            "worktree_id",
            "session_id",
            "persist_visuals",
            "marker_style",
            "bind"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise property \(field)")
        }
        let manageOpEnum = manageProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(manageOpEnum.contains("list"))
        XCTAssertTrue(manageOpEnum.contains("create"))
        XCTAssertTrue(manageOpEnum.contains("bind"))

        for field in [
            "operation_id",
            "target",
            "target_worktree_id",
            "confirm_preview",
            "confirm",
            "publish_artifacts",
            "context_lines",
            "detect_renames"
        ] {
            XCTAssertNotNil(manageProperties[field], "manage_worktree schema should advertise merge property \(field)")
        }
        XCTAssertTrue(manageOpEnum.contains("preview"))
        XCTAssertTrue(manageOpEnum.contains("apply"))
        XCTAssertTrue(manageOpEnum.contains("status"))
        XCTAssertTrue(manageOpEnum.contains("continue"))
        XCTAssertTrue(manageOpEnum.contains("abort"))

        let agentExploreProperties = try Self.schemaProperties(for: agentExplore)
        let agentRunProperties = try Self.schemaProperties(for: agentRun)
        let worktreeFields = [
            "worktree",
            "worktree_id",
            "worktree_create",
            "worktree_repo_root",
            "worktree_branch",
            "worktree_base_ref",
            "worktree_path",
            "worktree_label",
            "worktree_color",
            "allow_external_worktree_path",
            "inherit_worktree"
        ]
        for field in worktreeFields {
            XCTAssertNotNil(agentRunProperties[field], "agent_run schema should advertise property \(field)")
            XCTAssertNotNil(agentExploreProperties[field], "agent_explore schema should advertise property \(field)")
        }

        let exploreOpEnum = agentExploreProperties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(exploreOpEnum, ["start", "poll", "wait", "cancel"])
        for field in [
            "model_id",
            "workflow_id",
            "workflow_name",
            "session_name",
            "wait",
            "timeout_seconds",
            "interaction_id",
            "response",
            "answers",
            "content",
            "meta",
            "amendment"
        ] {
            XCTAssertNil(agentExploreProperties[field], "agent_explore schema must not advertise run-only property \(field)")
        }
    }

    private static func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    #if DEBUG
        private struct BootstrapSocketNamespaceFixture {
            let directoryURL: URL
            let socketURL: URL

            static func make() throws -> Self {
                let directoryURL = URL(
                    fileURLWithPath: "/tmp/rpce-xctest-bs-\(getpid())-\(UUID().uuidString)",
                    isDirectory: true
                )
                let socketURL = directoryURL.appendingPathComponent("bootstrap.sock")
                XCTAssertLessThan(socketURL.path.utf8CString.count, MemoryLayout<sockaddr_un>.size)
                XCTAssertNotEqual(socketURL.standardizedFileURL, MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL)
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return .init(directoryURL: directoryURL, socketURL: socketURL)
            }

            func removeOwnedDirectory() {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }

        private static func withIsolatedBootstrapSocketNamespace(
            window: WindowState,
            catalogService: MCPWindowToolCatalogService,
            operation: (URL) async throws -> Void
        ) async throws {
            let fixture = try BootstrapSocketNamespaceFixture.make()
            let manager = ServerNetworkManager.shared
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let defaultSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(defaultSocketURL, productionSocketURL)
            let previousEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()

            await assertBootstrapSocketOverrideError(.productionSocketURLRejected) {
                try await manager.debugInstallBootstrapSocketURLOverride(productionSocketURL)
            }

            do {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            } catch {
                fixture.removeOwnedDirectory()
                throw error
            }

            await assertBootstrapSocketOverrideError(.overrideAlreadyInstalled) {
                try await manager.debugInstallBootstrapSocketURLOverride(fixture.socketURL)
            }

            do {
                try await operation(fixture.socketURL)
            } catch {
                do {
                    try await cleanupIsolatedBootstrapSocketNamespace(
                        window: window,
                        catalogService: catalogService,
                        fixture: fixture,
                        previousEnabledState: previousEnabledState
                    )
                } catch {
                    XCTFail("Failed to clean isolated bootstrap socket namespace: \(error)")
                }
                throw error
            }

            try await cleanupIsolatedBootstrapSocketNamespace(
                window: window,
                catalogService: catalogService,
                fixture: fixture,
                previousEnabledState: previousEnabledState
            )
        }

        private static func cleanupIsolatedBootstrapSocketNamespace(
            window: WindowState,
            catalogService: MCPWindowToolCatalogService,
            fixture: BootstrapSocketNamespaceFixture,
            previousEnabledState: Bool
        ) async throws {
            await window.mcpServer.stopServer()
            ServiceRegistry.unregister(catalogService)
            await window.mcpServer.shutdownListener()

            let manager = ServerNetworkManager.shared
            let runningAfterShutdown = await manager.isRunning()
            XCTAssertFalse(runningAfterShutdown)
            let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
            let resolvedSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURL, fixture.socketURL.standardizedFileURL)
            try await manager.debugRestoreBootstrapSocketURLOverride(expected: fixture.socketURL)
            let restoredSocketURL = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(restoredSocketURL, productionSocketURL)
            await manager.setEnabled(previousEnabledState)
            let restoredEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()
            XCTAssertEqual(restoredEnabledState, previousEnabledState)
            let runningAfterEnabledRestore = await manager.isRunning()
            XCTAssertFalse(runningAfterEnabledRestore)
            let resolvedSocketURLAfterEnabledRestore = await manager.debugResolvedBootstrapSocketURL()
            XCTAssertEqual(resolvedSocketURLAfterEnabledRestore, productionSocketURL)
            fixture.removeOwnedDirectory()
        }

        private static func assertBootstrapSocketOverrideError(
            _ expectedError: ServerNetworkManager.DebugBootstrapSocketURLOverrideError,
            operation: () async throws -> Void
        ) async {
            do {
                try await operation()
                XCTFail("Expected bootstrap socket URL override error: \(expectedError)")
            } catch let error as ServerNetworkManager.DebugBootstrapSocketURLOverrideError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("Unexpected bootstrap socket URL override error: \(error)")
            }
        }
    #endif

    private static func schemaProperties(for tool: RepoPrompt.Tool) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        return try XCTUnwrap(schema["properties"]?.objectValue)
    }

    private static let expectedSignatures: [String] = [
        "0|manage_selection|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=586c45be3d3a4ade60e29ccbbdce01b050be03860a67eee41a3eac95d441d7d9|schema=4b7a043e8e48130ee84cc6bbf7b9fd597b495aef238d44f17df6600088a2bb6f",
        "1|file_actions|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=81230c22d826458cae079855b133d59da34c4a66ae4a68252727e564931335b8|schema=d4ed12eee8ed779610016aa46a6f3686ed7635436517c0de0a16efc8b0d0d1fe",
        "2|get_code_structure|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=616a8669bc14e69afaad4cfec4e4da2b1f5dcb7142030fb615857175b2146cb4|schema=f9bbf57f060e5cf70b8104a4b800100459376fb4438bfa80ef8f388aedf7c913",
        "3|get_file_tree|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=9bf648121646b463554d58373f61c2dcede04640482994e0cf1533d21ae77093|schema=91972027e030989cf242fed03377bdc5056c6317cc77d351d3fa5348dd1767a0",
        "4|read_file|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=f5ccd98a8fc0956c4ebcff540ffc8c0eaf0aaeb654b2f8edc0495c059fcf2807|schema=d023edb446167481751886bebeac7dc8896e2b3f57c12b18591761f846618bb1",
        "5|file_search|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=f2c9e16ca780c4e94f795b6c9489658856052e6d159aa467a64c906ee48a3fe4|schema=08904f5e241c06414ff476b80b81338a5798961a69d93227d7ed098694546b99",
        "6|workspace_context|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=fb968e72d430d354b03a0dfdb5251d95bbdea2a38cddcd58fe402f6bcb4f1035|schema=d41b9e8db1ccb1ce385d2d20619485a211bda4a8474270ef0c08fc77647e8376",
        "7|prompt|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=e1377f12a6495829c0ade3e37b9325f7a07dc2065288b16bb810d01a4df9e55d|schema=8c8ea22a39bbb9e10c364ad483527faf109a52e1eb9c45c0c939f569ecf144d1",
        "8|apply_edits|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=d33efa75e3e29e1e4e1cfe90d0e9d621337c397e5329aee02f4a261726d790fa|schema=2eabab77e3cdea6af1e1a509d77b9e8a3211049c1ccd11ec9b64f79149abdbbb",
        "9|oracle_utils|enabled=true|ann=title=nil,readOnly=nil,destructive=nil,idempotent=nil,openWorld=nil|desc=af161abbd2edf82b9cf502e1cf794bc48366b816b3ddc0ec2034b154ecc35c3a|schema=7d3c55c22f02f8825008521e4c20cd304a7c12f3679743b34f5a2bf315d19d7b",
        "10|ask_oracle|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=7a4771154006b3dcf158003d04b2b78da91fe4cc63d1acb5942f64f8a3e04e98|schema=03968f76ace268ccd7128c088ecc2544ca5ec77f47100d03e38a29a155cf81eb",
        "11|oracle_send|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=4608413a45189586669c6cc3339af4d467939a2477036545ef5d879b676b51fb|schema=6f940dcd0a0d39789189120217abdb60cd0f520b85f862beb81349f98bc1b19c",
        "12|oracle_chat_log|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=5acbb74a0fcf76bd3717faac8fc355f582f13523685d3bfebf11fda7241958b1|schema=50db94327abe785e20d3628135efa29cf184d18272d5af5b94a43d7246a4a201",
        "13|git|enabled=true|ann=title=nil,readOnly=true,destructive=false,idempotent=true,openWorld=false|desc=60cfcfd61921d3e828c0f49551672db392b928456b3c375e9e3cc819ee126e2b|schema=ebc134daddcab2321f0b9c20c76d0dd660eab1c0b78a54bfb8c83817da24ba77",
        "14|manage_worktree|enabled=true|ann=title=nil,readOnly=false,destructive=true,idempotent=nil,openWorld=false|desc=857ab8975667e3d2e5b35a09c7415e07ca0ab2f0ff16de6895170d4d1b47a820|schema=9263f9f047982b3709d92040f749804d69928d222ce46038a4171ded34d12bc6",
        "15|context_builder|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=d83348b6b803b303965401075041ddc5d7dcea3512020afa3f352c04413750fb|schema=2da87e6e171809a1e0eb0614fa8f7db2f91311f655f8427745060be80755da1f",
        "16|ask_user|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=6b3870ae4848eb01c73de9fbbdf2ed1782487db150260469853757f799257ee0|schema=080446bb7697cf5f4cd31f07b42ecff8ab29edc8501ee0e84e61426748569156",
        "17|agent_explore|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=698ab006db47713a51f394bfe3f832ada8637440d8acb4715be5430ec380cef8|schema=7b3c869b0c959c1c162dfadfd4ea578b05ed0834b2e930d177a8c38f96c31a4b",
        "18|agent_run|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=52ef9e56d0aa35f1523bb6700ce9ced3512749401b4ea409d0de8cf3d007855b|schema=e2b5bce34fa512aca293fffec7eaa46a9639feb4e840546c12d3554b8a2d514b",
        "19|agent_manage|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=03e16bee789cb9343f6b1b16cb4d472aedd3d811a43f6f95ad8ea5e8f69dc28d|schema=f5bc6b05cf0683ef3acb7a82ee4a14b75fadf26f32c56b0314be1424688a2ba5",
        "20|share_thoughts|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=b1ac755b39a4ac2d8a621e78801a258c5d95ec2ff4e063f600081fa27891a852|schema=a5dea0c92fd4da06a15f991e1e8a287235ca681ae381cef1b594bc7c07e538d7",
        "21|set_status|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=19bbfd6fc47639e02295de4e9289ea77f25c6a91ad150998726768b84c266783|schema=0854d727c81f1eb8fa0a14edb9d6ab8bb58974d919cc53150bd72473f1ae0196",
        "22|wait_for_next_user_instruction|enabled=true|ann=title=nil,readOnly=false,destructive=false,idempotent=nil,openWorld=false|desc=3a59a13a0026414ae04dd21d730a7144b91c67146dce77340fe730c865bea3d7|schema=15335c3bbadf042948d0a1ba52f0fcb01125428dda4952dbda418051904d82ef"
    ]

    private static func signatures(for tools: [RepoPrompt.Tool]) throws -> [String] {
        try tools.enumerated().map { index, tool in
            let schemaValue = try Value(tool.inputSchema)
            let schemaDigest = try digest(canonicalJSONString(schemaValue))
            let annotations = annotationSignature(tool.annotations)
            let descriptionDigest = digest(tool.description)
            return "\(index)|\(tool.name)|enabled=\(tool.isEnabledByDefault)|ann=\(annotations)|desc=\(descriptionDigest)|schema=\(schemaDigest)"
        }
    }

    private static func annotationSignature(_ annotations: MCP.Tool.Annotations) -> String {
        [
            "title=\(annotations.title ?? "nil")",
            "readOnly=\(optionalBool(annotations.readOnlyHint))",
            "destructive=\(optionalBool(annotations.destructiveHint))",
            "idempotent=\(optionalBool(annotations.idempotentHint))",
            "openWorld=\(optionalBool(annotations.openWorldHint))"
        ].joined(separator: ",")
    }

    private static func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "nil"
    }

    private static func canonicalJSONString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func digest(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func renderGolden(_ signatures: [String]) -> String {
        let body = signatures
            .map { "        \"\($0)\"" }
            .joined(separator: ",\n")
        return "\n        private static let expectedSignatures: [String] = [\n"
            + body
            + "\n        ]\n"
    }
}
