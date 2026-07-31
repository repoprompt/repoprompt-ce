import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class ManageWorktreeToolServiceTests: XCTestCase {
    func testWorktreeManageCapabilityRoutingAndRemovedAliasPolicy() {
        XCTAssertEqual(MCPWindowToolName.manageWorktree, "manage_worktree")
        XCTAssertTrue(MCPToolCapabilities.capabilities(for: MCPWindowToolName.manageWorktree).contains(.worktreeManage))
        XCTAssertFalse(MCPToolCapabilities.capabilities(for: MCPWindowToolName.manageWorktree).contains(.gitRead))
        XCTAssertTrue(MCPToolCapabilities.toolNames(for: [.worktreeManage]).contains(MCPWindowToolName.manageWorktree))
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.manageWorktree))
        XCTAssertFalse(ServerNetworkManager.shouldUseGenericTabBindingCompatibility(for: MCPWindowToolName.manageWorktree))
        XCTAssertFalse(ServerNetworkManager.shouldInjectLegacyTabIDForCompatibility(for: MCPWindowToolName.manageWorktree))
        XCTAssertFalse(MCPWindowToolGroup.orderedToolNames.contains("merge_worktree"))
        XCTAssertTrue(MCPToolCapabilities.capabilities(for: "merge_worktree").isEmpty)
    }

    func testRetirementRequiresDedicatedCapabilityAndActivationGate() {
        let ordinary = ["op": Value.string("list")]
        let retirement = ["op": Value.string("retire")]

        XCTAssertEqual(
            MCPToolActionContractCatalog.contract(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: ordinary
            )?.capability,
            .worktreeManage
        )
        XCTAssertEqual(
            MCPToolActionContractCatalog.contract(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: retirement
            ),
            MCPToolActionContract(
                capability: .irreversibleWorktreeRetirement,
                admissionClass: .exclusive,
                approval: .explicitTwoStage,
                requiresActivationGate: true
            )
        )
        XCTAssertFalse(
            MCPToolActionContractCatalog.isAuthorized(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: retirement,
                grantedCapabilities: [.worktreeManage],
                activationEnabled: true
            )
        )
        XCTAssertFalse(
            MCPToolActionContractCatalog.isAuthorized(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: retirement,
                grantedCapabilities: [.irreversibleWorktreeRetirement],
                activationEnabled: false
            )
        )
        XCTAssertTrue(
            MCPToolActionContractCatalog.isAuthorized(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: retirement,
                grantedCapabilities: [.irreversibleWorktreeRetirement],
                activationEnabled: true
            )
        )
    }

    func testProductionDispatchDeniesRetirementWithoutIrreversibleActionGrant() {
        let arguments = ["op": Value.string("retire"), "confirm": Value.bool(true)]
        XCTAssertNotNil(
            MCPToolActionContractCatalog.dispatchAuthorizationError(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: arguments,
                additionalGrants: []
            )
        )
        XCTAssertNil(
            MCPToolActionContractCatalog.dispatchAuthorizationError(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: arguments,
                additionalGrants: [MCPToolActionContractCatalog.irreversibleRetirementDispatchGrant]
            )
        )
        XCTAssertNil(
            MCPToolActionContractCatalog.dispatchAuthorizationError(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: ["op": .string("create")],
                additionalGrants: []
            )
        )
        XCTAssertTrue(
            AgentModeMCPToolPolicy.codexNativeGrantedTools.contains(
                MCPToolActionContractCatalog.irreversibleRetirementDispatchGrant
            )
        )
        XCTAssertNil(
            MCPToolActionContractCatalog.dispatchAuthorizationError(
                toolName: MCPWindowToolName.manageWorktree,
                arguments: arguments,
                additionalGrants: AgentModeMCPToolPolicy.codexNativeGrantedTools
            )
        )
    }

    func testManageWorktreeReplyEncodesSnakeCaseVisualBindingFields() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "bind",
            repository: .init(
                repositoryID: "gitrepo_123",
                repoKey: "repo-123",
                displayName: "Repo",
                rootPath: "/tmp/repo",
                commonGitDir: "/tmp/repo/.git",
                mainWorktreeRoot: "/tmp/repo"
            ),
            worktree: Self.worktreeDTO(),
            binding: Self.bindingDTO(id: "new", worktreeID: "wt_new"),
            previousBinding: Self.bindingDTO(id: "old", worktreeID: "wt_old")
        )

        let value = try Self.value(dto)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertNotNil(object["previous_binding"])
        XCTAssertNil(object["previousBinding"])

        let repository = try XCTUnwrap(object["repository"]?.objectValue)
        XCTAssertEqual(repository["repository_id"]?.stringValue, "gitrepo_123")
        XCTAssertEqual(repository["common_git_dir"]?.stringValue, "/tmp/repo/.git")
        XCTAssertEqual(repository["main_worktree_root"]?.stringValue, "/tmp/repo")

        let worktree = try XCTUnwrap(object["worktree"]?.objectValue)
        XCTAssertEqual(worktree["worktree_id"]?.stringValue, "wt_123")
        XCTAssertEqual(worktree["is_main"]?.boolValue, false)
        XCTAssertEqual(worktree["is_current"]?.boolValue, true)
        XCTAssertEqual(worktree["is_detached"]?.boolValue, false)
        let visual = try XCTUnwrap(worktree["visual"]?.objectValue)
        XCTAssertEqual(visual["color_hex"]?.stringValue, "#2563EB")
        XCTAssertEqual(visual["icon_name"]?.stringValue, "circle.fill")
        XCTAssertEqual(visual["marker_style"]?.stringValue, "ring")

        let previous = try XCTUnwrap(object["previous_binding"]?.objectValue)
        XCTAssertEqual(previous["worktree_id"]?.stringValue, "wt_old")
        XCTAssertEqual(previous["logical_root_path"]?.stringValue, "/tmp/repo")
        XCTAssertEqual(previous["visual_color_hex"]?.stringValue, "#7C3AED")
    }

    func testRetirementReplyEncodesHonestBoundaryAndSingleUseTokenFields() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "retire",
            retirement: .init(
                state: "authorized",
                authorizationToken: "retire_test",
                worktreeID: "wt_123",
                path: "/tmp/repo-wt",
                drainedSessionIDs: ["session-1"],
                gitAbsent: nil,
                pathAbsent: nil,
                authorityBoundary: "RepoPrompt-controlled operations only; external processes are excluded.",
                evidence: .init(
                    evidenceID: nil,
                    state: "authorized",
                    reason: nil,
                    authorityScope: "RepoPrompt-controlled operations only; external processes are excluded.",
                    appVersion: "test",
                    operationVersion: 2,
                    generation: 7,
                    repositoryID: "gitrepo_test",
                    repositoryRoot: "/tmp/repo",
                    worktreeID: "wt_123",
                    targetDigest: "target-digest",
                    manifestDigest: "manifest-digest",
                    consumedAuthorizationDigest: "authorization-digest",
                    drain: .init(
                        drainedSessionIDs: ["session-1"],
                        activeAdmissionsBefore: 1,
                        activeAdmissionsAfter: 0,
                        liveBindingsRemaining: 0,
                        workspaceClaimsRemaining: 0,
                        watchersRemaining: 0,
                        pendingPublicationsRemaining: 0
                    ),
                    mutation: .init(
                        serializedExecutor: false,
                        authorizationConsumedAt: nil,
                        gitRemoveExitCode: nil
                    ),
                    postconditions: .init(
                        gitRegistrationAbsent: false,
                        pathAbsent: false,
                        verifiedAt: nil
                    )
                )
            )
        )

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        let retirement = try XCTUnwrap(object["retirement"]?.objectValue)
        XCTAssertEqual(retirement["authorization_token"]?.stringValue, "retire_test")
        XCTAssertEqual(retirement["worktree_id"]?.stringValue, "wt_123")
        XCTAssertEqual(retirement["drained_session_ids"]?.arrayValue?.compactMap(\.stringValue), ["session-1"])
        XCTAssertTrue(retirement["authority_boundary"]?.stringValue?.contains("external processes") == true)
        XCTAssertNil(retirement["git_absent"])
        let evidence = try XCTUnwrap(retirement["evidence"]?.objectValue)
        XCTAssertEqual(evidence["generation"]?.intValue, 7)
        XCTAssertEqual(evidence["manifest_digest"]?.stringValue, "manifest-digest")
    }

    private static func worktreeDTO() -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        .init(
            worktreeID: "wt_123",
            specifier: "@id:wt_123",
            path: "/tmp/repo-wt",
            gitDir: "/tmp/repo/.git/worktrees/repo-wt",
            name: "repo-wt",
            branch: "feature/demo",
            head: "abcdef0",
            isMain: false,
            isCurrent: true,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil,
            visual: .init(label: "demo", colorHex: "#2563EB", iconName: "circle.fill", markerStyle: "ring"),
            status: .init(staged: 1, modified: 2, untracked: 3, isDirty: true)
        )
    }

    private static func bindingDTO(id: String, worktreeID: String) -> ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO {
        .init(
            id: id,
            repositoryID: "gitrepo_123",
            repoKey: "repo-123",
            logicalRootPath: "/tmp/repo",
            logicalRootName: "Repo",
            worktreeID: worktreeID,
            worktreeRootPath: "/tmp/repo-wt",
            worktreeName: "repo-wt",
            branch: "feature/demo",
            head: "abcdef0",
            visualLabel: "demo",
            visualColorHex: "#7C3AED",
            boundAt: "2026-05-22T00:00:00Z",
            source: "manage_worktree.bind"
        )
    }

    private static func value(_ dto: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(dto)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
