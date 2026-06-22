import MCP
@testable import RepoPrompt
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

    func testManageWorktreeSwitchReplySupportsReplacementAndCanonicalMainWithoutBinding() throws {
        let replacement = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "switch",
            worktree: Self.worktreeDTO(),
            binding: Self.bindingDTO(id: "stable", worktreeID: "wt_new"),
            previousBinding: Self.bindingDTO(id: "stable", worktreeID: "wt_old")
        )
        let replacementObject = try XCTUnwrap(Self.value(replacement).objectValue)
        XCTAssertEqual(replacementObject["op"]?.stringValue, "switch")
        XCTAssertEqual(replacementObject["binding"]?.objectValue?["worktree_id"]?.stringValue, "wt_new")
        XCTAssertEqual(replacementObject["previous_binding"]?.objectValue?["worktree_id"]?.stringValue, "wt_old")

        let canonicalMain = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "switch",
            worktree: Self.worktreeDTO(isMain: true),
            previousBinding: Self.bindingDTO(id: "stable", worktreeID: "wt_old")
        )
        let canonicalObject = try XCTUnwrap(Self.value(canonicalMain).objectValue)
        XCTAssertNil(canonicalObject["binding"])
        XCTAssertEqual(canonicalObject["worktree"]?.objectValue?["is_main"]?.boolValue, true)
        XCTAssertEqual(canonicalObject["previous_binding"]?.objectValue?["worktree_id"]?.stringValue, "wt_old")
    }

    private static func worktreeDTO(isMain: Bool = false) -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        .init(
            worktreeID: "wt_123",
            specifier: "@id:wt_123",
            path: "/tmp/repo-wt",
            gitDir: "/tmp/repo/.git/worktrees/repo-wt",
            name: "repo-wt",
            branch: "feature/demo",
            head: "abcdef0",
            isMain: isMain,
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
