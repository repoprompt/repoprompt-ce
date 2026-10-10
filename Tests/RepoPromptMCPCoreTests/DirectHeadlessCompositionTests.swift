import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import RepoPromptTestSupport
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
    func testDirectProviderProcessRefusesBeforeSpawnAndOrdinaryToolStillRuns() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            _ = try await DirectProcess.run(
                "/bin/sh", arguments: ["-c", "touch \"$1\"", "fixture", marker.path], isProvider: true
            )
            XCTFail("Direct provider processes must fail closed under XCTest")
        } catch {
            XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let output = try await DirectProcess.run("/usr/bin/printf", arguments: ["tool-ok"], isProvider: false)
        XCTAssertEqual(output, "tool-ok")
    }

    func testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot() throws {
        let root = try RepoRoot.url()
        let snapshotURL = root.appendingPathComponent("docs/spec/mcp-domain-canonical-tool-definitions.generated.json")
        let updateMarker = root.appendingPathComponent(".build/update-mcp-domain-schema-review-snapshot")
        let generated = try MCPDomainCanonicalToolDefinitions.reviewSnapshotData()
        if FileManager.default.fileExists(atPath: updateMarker.path) {
            try generated.write(to: snapshotURL, options: .atomic)
            try FileManager.default.removeItem(at: updateMarker)
        }
        XCTAssertEqual(try Data(contentsOf: snapshotURL), generated)
    }

    func testCanonicalAgentControlWaitDescriptionsUseConfiguredSubagentWaitPhrase() throws {
        let phrase = MCPTimeoutPolicy.configuredSubagentWaitDiscoveryPhrase
        for toolName in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            XCTAssertTrue(definition.description.contains(phrase), toolName)
            XCTAssertFalse(definition.description.localizedCaseInsensitiveContains("default 120"), toolName)
            XCTAssertFalse(definition.description.localizedCaseInsensitiveContains("default 300"), toolName)

            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let timeoutDescription = try XCTUnwrap(properties["timeout"]?.objectValue?["description"]?.stringValue)
            XCTAssertEqual(timeoutDescription, MCPTimeoutPolicy.agentControlTimeoutPropertyDescription)
        }

        let runDefinition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentRun))
        let runSchema = try XCTUnwrap(runDefinition.inputSchema.objectValue)
        let runProperties = try XCTUnwrap(runSchema["properties"]?.objectValue)
        let steerTimeoutDescription = try XCTUnwrap(runProperties["timeout_seconds"]?.objectValue?["description"]?.stringValue)
        XCTAssertEqual(steerTimeoutDescription, MCPTimeoutPolicy.agentControlSteerTimeoutPropertyDescription)
    }

    func testCanonicalizeAgentControlWaitSemanticsIsIdempotent() throws {
        for toolName in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            let current = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let once = MCPDomainCanonicalToolDefinitions.test_canonicalizeAgentControlWaitSemantics(current)
            let twice = MCPDomainCanonicalToolDefinitions.test_canonicalizeAgentControlWaitSemantics(once)
            XCTAssertEqual(once, twice, toolName)
        }
    }

    func testCanonicalAgentSchemasAdvertiseCursorModelParameterInputs() throws {
        for toolName in ["agent_run", "agent_manage"] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let parameters = try XCTUnwrap(properties["model_parameters"]?.objectValue, toolName)
            XCTAssertEqual(parameters["type"], .string("array"))
            let items = try XCTUnwrap(parameters["items"]?.objectValue)
            XCTAssertEqual(items["required"], .array([.string("config_id"), .string("value")]))
            let itemProperties = try XCTUnwrap(items["properties"]?.objectValue)
            XCTAssertEqual(itemProperties["config_id"]?.objectValue?["type"], .string("string"))
            XCTAssertEqual(itemProperties["value"]?.objectValue?["type"], .string("string"))
            XCTAssertTrue(definition.description.contains("model_parameters"), toolName)
        }
    }

    func testCanonicalAskOracleAdvertisesImageAttachments() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "ask_oracle"))
        XCTAssertTrue(definition.description.contains("`images`"), "ask_oracle description must document images")
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let images = try XCTUnwrap(properties["images"]?.objectValue)
        XCTAssertEqual(images["type"], .string("array"))
        XCTAssertEqual(images["maxItems"], .int(OracleImageAttachmentLimits.production.maxCount))
        let items = try XCTUnwrap(images["items"]?.objectValue)
        XCTAssertEqual(items["required"], .array([.string("path")]))
        let itemProperties = try XCTUnwrap(items["properties"]?.objectValue)
        XCTAssertEqual(itemProperties["path"]?.objectValue?["type"], .string("string"))
        XCTAssertEqual(itemProperties["title"]?.objectValue?["type"], .string("string"))
    }

    func testHeadlessLaunchRejectsUnsupportedModelParametersBeforeProviderStartup() throws {
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string("Reply OK"),
            "model_parameters": .array([
                .object(["config_id": .string("effort"), "value": .string("low")])
            ])
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("app-backed Cursor"))
        }
    }

    func testHeadlessAgentManageSchemaAdvertisesListWorkflows() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "agent_manage"))
        let encoded = try JSONEncoder().encode(definition.inputSchema)
        let schema = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(schema.contains("\"list_workflows\""), schema)
    }

    func testHeadlessWorkflowSelectionAppliesCanonicalPromptAndRejectsInvalidReferences() throws {
        let message = "Implement the bounded change."
        XCTAssertEqual(
            try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: ["message": .string(message)]),
            message
        )

        for workflow in RepoPromptBuiltInAgentWorkflow.allCases {
            let expected = workflow.wrapUserText(message)
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string(workflow.rawValue)
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_id": .string("builtin-\(workflow.rawValue)")
                ]),
                expected
            )
            XCTAssertEqual(
                try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
                    "message": .string(message),
                    "workflow_name": .string(workflow.metadata.displayName)
                ]),
                expected
            )
        }

        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_id": .string("build"),
            "workflow_name": .string("Plan & Build")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("either workflow_id or workflow_name"))
        }
        XCTAssertThrowsError(try DirectHeadlessProviderCoordinator.resolvedLaunchMessage(args: [
            "message": .string(message),
            "workflow_name": .string("missing-workflow")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("was not found"))
        }
    }

    func testHeadlessCodexExecUsesWorkspaceWriteWithoutRemovedFullAutoFlag() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .agent)

        XCTAssertFalse(arguments.contains("--full-auto"))
        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        )
    }

    func testDirectHeadlessOracleCodexExecUsesWorkspaceWriteSandbox() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .directOracle)

        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        )
    }

    func testGroupedHeadlessOracleCodexExecUsesReadOnlySandbox() {
        let arguments = DirectHeadlessProviderCoordinator.codexExecArguments(model: nil, purpose: .oracleGroup)

        XCTAssertEqual(
            Array(arguments.suffix(5)),
            ["--skip-git-repo-check", "--sandbox", "read-only", "--json", "-"]
        )
    }

    func testGroupedOracleChildPolicyIsStrictlyReadOnly() {
        let groupID = OracleGroupID()
        let restricted = DirectHeadlessMCPService.childRestrictedToolNames(
            base: [],
            oracleGroupID: groupID
        )
        let visible = Set(MCPDomainToolCatalog.orderedToolNames).subtracting(restricted)

        XCTAssertEqual(visible, DirectHeadlessMCPService.oracleGroupChildAllowedToolNames)
        let allowedCapabilities = Set(visible.compactMap { MCPDomainToolCatalog.entry(named: $0)?.capability })
        XCTAssertEqual(
            allowedCapabilities,
            [.structuralExplore, .fileRead, .fileSearch, .gitRead]
        )
        XCTAssertEqual(MCPDomainToolCatalog.entry(named: MCPWindowToolName.git)?.capability, .gitRead)
        XCTAssertTrue(restricted.contains(MCPGlobalToolName.appSettings))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.agentExplore))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.agentRun))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.contextBuilder))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.applyEdits))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.fileActions))
        XCTAssertTrue(restricted.contains(MCPWindowToolName.manageWorktree))

        let inherited = Set([MCPWindowToolName.readFile])
        XCTAssertTrue(DirectHeadlessMCPService.childRestrictedToolNames(
            base: inherited,
            oracleGroupID: groupID
        ).contains(MCPWindowToolName.readFile))
        XCTAssertEqual(
            DirectHeadlessMCPService.childRestrictedToolNames(
                base: inherited,
                oracleGroupID: nil
            ),
            inherited
        )
    }

    func testChildBridgeWriteTimeoutIsBoundedWhenDestinationStalls() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        defer {
            if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }

        let payload = Data(repeating: 0x41, count: 1_000_000)
        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertThrowsError(
            try DirectHeadlessChildBridge.writeAll(
                payload,
                to: descriptors[1],
                stallTimeout: 0.05
            )
        ) { error in
            guard case DirectHeadlessChildBridge.BridgeError.writeTimeout = error else {
                return XCTFail("Expected writeTimeout, got \(error)")
            }
        }
        XCTAssertTrue(started.duration(to: clock.now) < .seconds(2))
    }

    func testManageWorktreeFencesAbsoluteSelectorsToBoundWorkspaceRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-worktree-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("rp-headless-foreign-worktree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = try DirectHeadlessVersionControlBackend.authorizeWorktreePath(root, roots: [root])
        XCTAssertEqual(allowed.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.authorizeWorktreePath(outside, roots: [root])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), error.localizedDescription)
        }
    }

    func testHeadlessResolverRejectsEscapedJSONNULWithoutWritingPrefix() throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("rp-headless-nul-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("authorized-root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let prefix = root.appendingPathComponent("prefix")
        let original = Data("original bytes\n".utf8)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try original.write(to: prefix)
        defer { try? fileManager.removeItem(at: container) }

        let rawPath = "prefix\0/created.txt"
        let encoded = try JSONEncoder().encode([
            "action": Value.string("create"),
            "path": Value.string(rawPath),
            "content": Value.string("must not be written")
        ])
        let decoded = try JSONDecoder().decode([String: Value].self, from: encoded)
        let decodedPath = try XCTUnwrap(decoded["path"]?.stringValue)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)?.contains("\\u0000") == true)
        XCTAssertEqual(
            try DirectHeadlessDomainContext.resolvePath("prefix", roots: [root]).path,
            prefix.path
        )

        do {
            let resolved = try DirectHeadlessDomainContext.resolvePath(
                decodedPath,
                roots: [root],
                allowMissingLeaf: true
            )
            try Data("must not be written".utf8).write(to: resolved)
            XCTFail("embedded NUL path must be rejected before any write")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the bound workspace roots"), String(describing: error))
        }

        XCTAssertEqual(try Data(contentsOf: prefix), original)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("created.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: outside.appendingPathComponent("created.txt").path))
    }

    func testHeadlessMergeMutationRejectsPreviewEndpointMovedOutsideViaSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-fence-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-merge-outside-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.revalidateMergeEndpointPaths(
                sourceRoot: root,
                targetRoot: target,
                roots: [root],
                listedWorktrees: [root, target]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("outside the bound workspace roots"),
                error.localizedDescription
            )
        }
    }

    func testHeadlessMergeMutationRejectsSameRepositorySameHeadWorktreeSwap() throws {
        let repositoryIdentity = "/tmp/headless-repo/.git"
        let head = String(repeating: "a", count: 40)
        let expectedWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/target"
        let currentWorktreeIdentity = "/tmp/headless-repo/.git/worktrees/other"

        XCTAssertThrowsError(
            try DirectHeadlessVersionControlBackend.validateMergeEndpointIdentity(
                expectedHead: head,
                currentHead: head,
                expectedRepositoryIdentity: repositoryIdentity,
                currentRepositoryIdentity: repositoryIdentity,
                expectedWorktreeIdentity: expectedWorktreeIdentity,
                currentWorktreeIdentity: currentWorktreeIdentity
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("endpoint identity changed"), String(describing: error))
        }
    }

    // MARK: - manage_worktree list page controls are app-backed only (#1091)

    func testHeadlessManageWorktreeListRejectsAppOnlyPageControls() async throws {
        let fixture = try await makeHeadlessWorktreeFixture()
        for arguments: [String: Value] in [
            ["op": .string("list"), "limit": .int(1), "offset": .int(1)],
            ["op": .string("list"), "limit": .int(1)],
            ["limit": .int(1)],
            ["op": .string("list"), "offset": .int(1)]
        ] {
            let outcome = try await Self.callManageWorktree(fixture.client, arguments: arguments)
            XCTAssertTrue(outcome.isError, "page controls must not silently succeed: \(arguments)")
            XCTAssertTrue(
                outcome.text.contains(MCPWorktreeListPagination.headlessUnsupportedMessage),
                "expected explicit unsupported error, got: \(outcome.text)"
            )
        }
    }

    func testHeadlessManageWorktreeListWithoutPageControlsStillListsWorktrees() async throws {
        let fixture = try await makeHeadlessWorktreeFixture()
        let outcome = try await Self.callManageWorktree(fixture.client, arguments: ["op": .string("list")])
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(outcome.text.contains("worktree "), outcome.text)
        XCTAssertTrue(outcome.text.contains(fixture.linkedWorktree.lastPathComponent), outcome.text)
    }

    func testHeadlessGitShowRejectsOptionsAndPreservesValidRevision() async throws {
        let fixture = try await makeHeadlessWorktreeFixture()
        let marker = fixture.linkedWorktree.deletingLastPathComponent().appendingPathComponent("show-output")
        let original = Data("preserved\n".utf8)
        try original.write(to: marker)
        for ref in ["--output=\(marker.path)", "-p", "--", "HEAD\0tail"] {
            do {
                let result = try await fixture.client.callTool(name: "git", arguments: ["op": .string("show"), "ref": .string(ref)])
                XCTAssertEqual(result.isError, true)
                let text = result.content.compactMap { content -> String? in
                    guard case let .text(value, _, _) = content else { return nil }
                    return value
                }.joined()
                XCTAssertTrue(text.contains("Invalid Git revision operand"), text)
            } catch {
                XCTAssertTrue(String(describing: error).contains("Invalid Git revision operand"), String(describing: error))
            }
            XCTAssertEqual(try Data(contentsOf: marker), original)
        }
        let result = try await fixture.client.callTool(name: "git", arguments: ["op": .string("show"), "ref": .string("HEAD")])
        XCTAssertFalse(result.isError == true)
        let text = result.content.compactMap { content -> String? in
            guard case let .text(value, _, _) = content else { return nil }
            return value
        }.joined()
        XCTAssertTrue(text.contains("Fixture"), text)
        XCTAssertEqual(try Data(contentsOf: marker), original)
    }

    private struct HeadlessWorktreeFixture {
        let client: Client
        let linkedWorktree: URL
    }

    private func makeHeadlessWorktreeFixture() async throws -> HeadlessWorktreeFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-worktree-list-\(UUID().uuidString)", isDirectory: true)
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        let linked = directory.appendingPathComponent("linked-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try Self.runGit(["init", "--quiet"], at: repo)
        try Self.runGit(["add", "README.md"], at: repo)
        try Self.runGit(
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Fixture"],
            at: repo
        )
        try Self.runGit(["worktree", "add", "--quiet", "--detach", linked.path, "HEAD"], at: repo)

        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-list-contract",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": repo.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ], currentDirectory: repo)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Headless worktree test", version: "1", capabilities: .init(tools: .init()))
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [], ephemeralGrantedOperations: DirectHeadlessMCPService.topLevelDefaultMutationOperations
        ))
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Headless worktree client", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        return HeadlessWorktreeFixture(client: client, linkedWorktree: linked)
    }

    /// Normalizes both wire shapes: an `isError` tool result and a thrown JSON-RPC error.
    private static func callManageWorktree(
        _ client: Client,
        arguments: [String: Value]
    ) async throws -> (isError: Bool, text: String) {
        do {
            let result = try await client.callTool(name: "manage_worktree", arguments: arguments)
            let text = result.content.compactMap { content -> String? in
                guard case let .text(value, _, _) = content else { return nil }
                return value
            }.joined(separator: "\n")
            return (result.isError == true, text)
        } catch {
            return (true, String(describing: error))
        }
    }

    private static func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"
            ])
        }
    }
}
