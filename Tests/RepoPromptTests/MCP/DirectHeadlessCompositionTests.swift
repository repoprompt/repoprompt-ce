import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class DirectHeadlessCompositionTests: XCTestCase {
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

    func testNamedDirectContinuationStaysSingleLaneWithGroupedSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-direct-continuation-\(UUID().uuidString)", isDirectory: true)
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-direct-profile-\(UUID().uuidString)", isDirectory: true)
        let executable = profile.appendingPathComponent("codex-stub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: profile)
        }
        let script = """
        #!/bin/sh
        /bin/cat >/dev/null
        /usr/bin/printf '%s\\n' '{"type":"message","text":"ok"}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let service = DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_CODEX_COMMAND": executable.path,
                "REPOPROMPT_MCP_HEADLESS_PROFILE": "direct-continuation-\(UUID().uuidString)",
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.primarySettingKey,
            value: .string("lane-0")
        )
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(["lane-1"])
        )
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let security = DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: []
        )

        let plan = try await prepared.oracleAdapter.resolveChildLaunchPlan(
            toolName: "oracle_send",
            arguments: [
                "chat_id": .string(UUID().uuidString),
                "message": .string("continue direct")
            ],
            securityContext: security
        )

        XCTAssertNil(plan.oracleGroupID)
        XCTAssertNil(plan.oracleGroupClaimID)
        XCTAssertEqual(plan.lanes.count, 1)
        XCTAssertEqual(plan.lanes.first?.providerIdentifier, "codexExec")
        XCTAssertNil(plan.lanes.first?.oracleLaneID)
    }

    func testGroupedOracleChildPolicyIsStrictlyReadOnly() {
        let groupID = OracleGroupID()
        let restricted = DirectHeadlessMCPService.childRestrictedToolNames(
            base: [],
            oracleGroupID: groupID
        )
        let visible = Set(MCPDomainToolCatalog.orderedToolNames).subtracting(restricted)

        XCTAssertEqual(visible, DirectHeadlessMCPService.oracleGroupChildAllowedToolNames)
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
}
