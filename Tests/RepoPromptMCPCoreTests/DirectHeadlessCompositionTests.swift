import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import RepoPromptTestSupport
import RepoPromptVCS
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

    func testOverseerDescriptionsTeachBothModesWithoutRequiringRedundantCards() throws {
        // agent_session_link keeps its frozen, budgeted contract; the scope playbook lives on the
        // tools that request and exercise scopes.
        for name in [MCPWindowToolName.becomeOverseer, MCPWindowToolName.sessionAdmin, MCPWindowToolName.agentManage] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            XCTAssertTrue(definition.description.contains("Overseer full access"), name)
            XCTAssertTrue(definition.description.contains("ON"), name)
            XCTAssertTrue(definition.description.contains("OFF"), name)
            XCTAssertTrue(definition.description.contains("standing consent"), name)
        }
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

    func testCanonicalAgentControlDescriptionsExplainCompoundTaskRoles() throws {
        let selectionClauses = [
            "app-backed sessions", "compound model_id", "assigns no task role to a fresh session",
            "set that role's default"
        ]
        let childClauses = [
            "agent_explore requires an engineer, pair, or design task role",
            "start a child that will need Explore helpers with one of those role labels"
        ]
        let resumeClauses = [
            "parented MCP sub-agents cannot use create_session or resume_session, whatever their role",
            "matching MCP control context keeps its task role even if model_id is supplied",
            "otherwise a role label installs that role", "an omitted or compound model_id installs none"
        ]
        let pointerClauses = [
            "effective workspace or global role defaults", "compound model_id",
            "assigns no task role", "see the tool description"
        ]
        var cases: [(label: String, text: String, required: [String])] = []
        for toolName in [MCPWindowToolName.agentRun, MCPWindowToolName.agentManage] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let modelDescription = try XCTUnwrap(properties["model_id"]?.objectValue?["description"]?.stringValue)
            let required = selectionClauses + childClauses
                + (toolName == MCPWindowToolName.agentManage ? resumeClauses : ["effective workspace or global role defaults"])
            let manageSelectionClauses = toolName == MCPWindowToolName.agentManage
                ? ["on create_session, a compound model_id pins the exact target"] : []
            let managePointerClauses = toolName == MCPWindowToolName.agentManage
                ? [
                    "on create_session, a compound model_id assigns no task role",
                    "on resume_session, a matching MCP control context keeps its task role even if model_id is supplied",
                    "otherwise an omitted or compound model_id installs none"
                ] : []
            cases.append(("\(toolName) description", definition.description, required + manageSelectionClauses))
            cases.append(("\(toolName).model_id", modelDescription, pointerClauses + managePointerClauses))
        }
        for entry in cases {
            let text = entry.text.replacingOccurrences(of: "`", with: "").lowercased()
            XCTAssertFalse(text.contains("role-default mapping"), entry.label)
            let missing = entry.required.filter { !text.contains($0.lowercased()) }
            XCTAssertTrue(
                missing.isEmpty,
                "\(entry.label) is missing compound task-role guidance: \(missing.joined(separator: "; "))"
            )
        }
    }

    func testCanonicalOracleSendToolsAdvertiseImageAttachments() throws {
        for toolName in ["ask_oracle", "oracle_send"] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            XCTAssertTrue(definition.description.contains("`images`"), "\(toolName) description must document images")
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

    func testHeadlessGitRejectsNestedRepositorySelectorsForEveryRead() async throws {
        let fixture = try await makeHeadlessWorktreeFixture(loadNestedDirectory: true)
        for op in ["status", "diff", "log", "show", "blame"] {
            let outcome = try await Self.callTool(fixture.client, name: "git", arguments: [
                "op": .string(op), "repo_root": .string(fixture.loadedRoot.path), "path": .string("README.md")
            ])
            XCTAssertTrue(outcome.isError, "\(op): \(outcome.text)")
            XCTAssertTrue(outcome.text.contains("No authorized Git repository"), outcome.text)
        }
        // A syntactically present but invalid metadata directory must not let
        // worktree reads fall through to the enclosing linked checkout either.
        try FileManager.default.createDirectory(at: fixture.loadedRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for op in ["list", "show"] {
            let outcome = try await Self.callManageWorktree(fixture.client, arguments: ["op": .string(op)])
            XCTAssertTrue(outcome.isError, "\(op) adopted an enclosing repository: \(outcome.text)")
        }
    }

    func testHeadlessGitStillReadsRegisteredLinkedWorktree() async throws {
        let fixture = try await makeHeadlessWorktreeFixture(loadLinkedWorktree: true)
        let outcome = try await Self.callTool(fixture.client, name: "git", arguments: ["op": .string("status")])
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(outcome.text.contains(fixture.linkedWorktree.lastPathComponent), outcome.text)
    }

    func testHeadlessGitOwnershipProbeAllowsSuccessfulCommandWarnings() async throws {
        let fixture = try await makeHeadlessWorktreeFixture()
        try Self.runGit(["config", "core.bare", "true"], at: fixture.loadedRoot)
        try Self.runGit(["config", "core.worktree", ".."], at: fixture.loadedRoot)
        try Data("inside\n".utf8).write(to: fixture.loadedRoot.appendingPathComponent("inside-only.txt"))

        // Real Git accepts this checkout but warns during native discovery. Its
        // explicitly bound data command still reads the authorized working tree.
        let probe = try await DirectProcess.run(
            "/usr/bin/git", arguments: ["-C", fixture.loadedRoot.path, "rev-parse", "--absolute-git-dir"],
            isProvider: false
        )
        XCTAssertTrue(probe.contains("warning:"), probe)
        XCTAssertTrue(probe.contains(fixture.loadedRoot.appendingPathComponent(".git").path), probe)

        let outcome = try await Self.callTool(fixture.client, name: "git", arguments: ["op": .string("status")])
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(outcome.text.contains("inside-only.txt"), outcome.text)
    }

    func testHeadlessGitReadDoesNotFollowConfiguredExternalWorktree() async throws {
        let fixture = try await makeHeadlessWorktreeFixture(redirectWorktree: true)
        let outcome = try await Self.callTool(fixture.client, name: "git", arguments: ["op": .string("status")])
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertFalse(outcome.text.contains("outside-only.txt"), outcome.text)
    }

    func testHeadlessReadArgumentsPreserveGitOwnershipTrustForNormalAndLinkedCheckouts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headless-git-ownership-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let linked = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.runGit(["init", "--quiet"], at: root)
        try Self.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "Fixture"], at: root)
        try Self.runGit(["worktree", "add", "--quiet", "--detach", linked.path, "HEAD"], at: root)
        for checkout in [root, linked] {
            try Data("inside".utf8).write(to: checkout.appendingPathComponent("inside-only.txt"))
            let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: checkout, authorizedRoots: [checkout]))
            let binding = try GitReadRepositoryBinding(layout: layout)
            for trusted in [false, true] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = binding.ownershipProbeArguments
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
                environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                environment["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"
                environment["GIT_CONFIG_COUNT"] = "1"
                environment["GIT_CONFIG_KEY_0"] = "safe.directory"
                environment["GIT_CONFIG_VALUE_0"] = trusted ? checkout.resolvingSymlinksInPath().path : ""
                process.environment = binding.ownershipProbeEnvironment(environment)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if trusted {
                    XCTAssertEqual(process.terminationStatus, 0, output)
                    try binding.validateOwnershipProbe(output)
                    let status = Process()
                    status.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    status.arguments = binding.boundArguments(["status", "--porcelain"])
                    status.environment = environment
                    let statusPipe = Pipe()
                    status.standardOutput = statusPipe
                    status.standardError = statusPipe
                    try binding.revalidate()
                    try status.run()
                    let statusOutput = String(decoding: statusPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    status.waitUntilExit()
                    XCTAssertEqual(status.terminationStatus, 0, statusOutput)
                    XCTAssertTrue(statusOutput.contains("inside-only.txt"), statusOutput)
                } else {
                    XCTAssertNotEqual(process.terminationStatus, 0, output)
                    XCTAssertTrue(output.contains("dubious ownership"), output)
                }
            }
        }
    }

    func testReadSpawnFenceRejectsMissingMalformedAndReplacedMetadataWithoutAdoptingParent() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headless-git-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.runGit(["init", "--quiet"], at: base)
        try Data("outside".utf8).write(to: base.appendingPathComponent("outside-only.txt"))
        for replacement in ["missing", "malformed", "redirected", "replaced"] {
            let root = base.appendingPathComponent(replacement)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.runGit(["init", "--quiet"], at: root)
            let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            let binding = try GitReadRepositoryBinding(layout: layout)
            try FileManager.default.moveItem(at: root.appendingPathComponent(".git"), to: root.appendingPathComponent("saved-metadata"))
            switch replacement {
            case "malformed": try Data("not a gitfile".utf8).write(to: root.appendingPathComponent(".git"))
            case "redirected": try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: base.appendingPathComponent(".git"))
            case "replaced": try Self.runGit(["init", "--quiet"], at: root)
            default: break
            }
            XCTAssertThrowsError(try binding.revalidate(), replacement)
            for arguments in [binding.ownershipProbeArguments, binding.boundArguments(["status", "--porcelain"])] {
                do {
                    let output = try await DirectProcess.run("/usr/bin/git", arguments: arguments, isProvider: false, readBinding: binding)
                    XCTFail("\(replacement) spawned a stale read: \(output)")
                } catch {
                    // The production final-spawn fence rejects this before Git can
                    // discover the enclosing repository or read stale metadata.
                    XCTAssertFalse(error is MCPError, "expected the binding fence, not a Git subprocess error")
                }
            }
        }
    }

    func testOwnershipProbeCannotAdoptParentFromInvalidGitDirectoryAndColonParentFailsClosed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headless-git-ceiling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.runGit(["init", "--quiet"], at: base)
        let invalid = base.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalid.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let invalidLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: invalid, authorizedRoots: [invalid]))
        let invalidBinding = try GitReadRepositoryBinding(layout: invalidLayout)
        do {
            let output = try await DirectProcess.run("/usr/bin/git", arguments: invalidBinding.ownershipProbeArguments, isProvider: false, readBinding: invalidBinding)
            XCTFail("Invalid metadata adopted enclosing repo: \(output)")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not a git repository"), String(describing: error))
        }
        let colonParent = base.appendingPathComponent("parent:with-colon/child")
        try FileManager.default.createDirectory(at: colonParent, withIntermediateDirectories: true)
        try Self.runGit(["init", "--quiet"], at: colonParent)
        let unsupportedLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: colonParent, authorizedRoots: [colonParent]))
        XCTAssertThrowsError(try GitReadRepositoryBinding(layout: unsupportedLayout)) { error in
            XCTAssertTrue(error.localizedDescription.contains("canonical parent path contains ':'"))
        }
        let colonLeaf = base.appendingPathComponent("leaf:valid")
        try FileManager.default.createDirectory(at: colonLeaf, withIntermediateDirectories: true)
        try Self.runGit(["init", "--quiet"], at: colonLeaf)
        let supportedLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: colonLeaf, authorizedRoots: [colonLeaf]))
        let supportedBinding = try GitReadRepositoryBinding(layout: supportedLayout)
        let probe = try await DirectProcess.run("/usr/bin/git", arguments: supportedBinding.ownershipProbeArguments, isProvider: false, readBinding: supportedBinding)
        try supportedBinding.validateOwnershipProbe(probe)
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
        let loadedRoot: URL
    }

    private func makeHeadlessWorktreeFixture(loadNestedDirectory: Bool = false, loadLinkedWorktree: Bool = false, redirectWorktree: Bool = false) async throws -> HeadlessWorktreeFixture {
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

        if redirectWorktree {
            let outside = directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside.appendingPathComponent("outside-only.txt"))
            try Self.runGit(["config", "core.worktree", outside.path], at: repo)
        }
        let loadedRoot = loadNestedDirectory ? repo.appendingPathComponent("nested") : (loadLinkedWorktree ? linked : repo)
        try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)
        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "worktree-list-contract",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": loadedRoot.path,
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
        return HeadlessWorktreeFixture(client: client, linkedWorktree: linked, loadedRoot: loadedRoot)
    }

    /// Normalizes both wire shapes: an `isError` tool result and a thrown JSON-RPC error.
    private static func callManageWorktree(
        _ client: Client,
        arguments: [String: Value]
    ) async throws -> (isError: Bool, text: String) {
        try await callTool(client, name: "manage_worktree", arguments: arguments)
    }

    private static func callTool(
        _ client: Client,
        name: String,
        arguments: [String: Value]
    ) async throws -> (isError: Bool, text: String) {
        do {
            let result = try await client.callTool(name: name, arguments: arguments)
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
