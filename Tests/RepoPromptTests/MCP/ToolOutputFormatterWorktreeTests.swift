import MCP
@testable import RepoPrompt
import XCTest

@MainActor
final class ToolOutputFormatterWorktreeTests: XCTestCase {
    func testGitWorktreeWarningsChooseMainSelectorsOrFullPathGuidance() {
        do {
            let caseLabel = "testGitWorktreeWarningRecommendsMainSelectorsOnlyWhenMainRootIsKnown"
            let warning = MCPGitToolProvider.worktreeWarning(from: .init(
                isWorktree: true,
                worktreeName: "feature",
                worktreeRoot: "/tmp/repo-feature",
                commonGitDir: "/tmp/repo/.git",
                mainWorktreeRoot: "/tmp/repo",
                worktreeBranch: "feature/demo",
                mainBranch: "main",
                worktreeHead: "abcdef1",
                mainHead: "1234567"
            ))

            XCTAssertTrue(warning?.contains("repo_root=\"@main\"") == true, caseLabel)
            XCTAssertTrue(warning?.contains("repo_root=\"@main:<branch>\"") == true, caseLabel)
            XCTAssertFalse(warning?.contains("could not be resolved") == true, caseLabel)
        }

        do {
            let caseLabel = "testGitWorktreeWarningUsesFullPathGuidanceWhenMainRootIsUnknown"
            let warning = MCPGitToolProvider.worktreeWarning(from: .init(
                isWorktree: true,
                worktreeName: "feature",
                worktreeRoot: "/tmp/repo-feature",
                commonGitDir: "/tmp/external-git-dir",
                mainWorktreeRoot: nil,
                worktreeBranch: "feature/demo",
                mainBranch: nil,
                worktreeHead: "abcdef1",
                mainHead: nil
            ))

            XCTAssertTrue(warning?.contains("primary checkout path could not be resolved") == true, caseLabel)
            XCTAssertTrue(warning?.contains("full path as repo_root") == true, caseLabel)
            XCTAssertFalse(warning?.contains("repo_root=\"@main\"") == true, caseLabel)
            XCTAssertFalse(warning?.contains("repo_root=\"@main:<branch>\"") == true, caseLabel)
        }
    }

    func testCreateOutputIncludesUsefulNextStepCommands() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "create",
            worktree: Self.worktreeDTO(),
            createdWorktree: Self.worktreeDTO()
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("### Created"))
        XCTAssertTrue(text.contains("### Next Steps"))
        XCTAssertTrue(text.contains("\"op\":\"show\""))
        XCTAssertTrue(text.contains("\"op\":\"bind\""))
        XCTAssertTrue(text.contains("\"op\":\"start\""))
        XCTAssertTrue(text.contains("\"worktree_id\":\"wt_feature\""))
    }

    func testCreateOutputShowsWorktreeIncludeWarning() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "create",
            worktree: Self.worktreeDTO(),
            createdWorktree: Self.worktreeDTO(),
            warning: "\n\n"
                + ".worktreeinclude copied 1 of 2 eligible file(s); some files were skipped or failed: destination already exists for .env.local\n"
                + "Worktree created but no session binding was applied."
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("> ⚠️ .worktreeinclude copied 1 of 2 eligible file(s)"), text)
        XCTAssertTrue(text.contains("destination already exists for .env.local"), text)
        XCTAssertTrue(text.contains("> Worktree created but no session binding was applied."), text)
    }

    func testBindOutputIncludesPreviousBindingAndNextStepCommands() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "bind",
            worktree: Self.worktreeDTO(),
            binding: Self.bindingDTO(id: "new", worktreeID: "wt_new"),
            previousBinding: Self.bindingDTO(id: "old", worktreeID: "wt_previous")
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("### Binding"))
        XCTAssertTrue(text.contains("wt_new"))
        XCTAssertTrue(text.contains("### Previous Binding"))
        XCTAssertTrue(text.contains("wt_previous"))
        XCTAssertTrue(text.contains("### Next Steps"))
        XCTAssertTrue(text.contains("agent_run"))
        XCTAssertTrue(text.contains("circle.fill"))
        XCTAssertTrue(text.contains("ring"))
        XCTAssertFalse(text.contains("<session_id>"), "A completed bind should not suggest rebinding with a placeholder session id.")
    }

    func testListOutputShowsVisualIdentityAndBoundedGraph() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "list",
            repository: .init(
                repositoryID: "gitrepo_123",
                repoKey: "repo-123",
                displayName: "Repo",
                rootPath: "/tmp/repo",
                commonGitDir: "/tmp/repo/.git",
                mainWorktreeRoot: "/tmp/repo"
            ),
            worktrees: [Self.listWorktreeDTO()],
            graph: .init(
                requested: true,
                limit: 12,
                lines: ["* abc1234 (HEAD -> feature/demo) Demo commit", "* def5678 Base commit"],
                source: "git log --graph --decorate --oneline --color=never -n 12"
            )
        )
        let blocks = try ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto))
        let text = try Self.onlyText(blocks)

        XCTAssertTrue(text.contains("## Manage Worktree List"))
        XCTAssertTrue(text.contains("Repo (`repo-123`)"))
        XCTAssertTrue(text.contains("`wt_123`"))
        XCTAssertTrue(text.contains("feature/demo"))
        XCTAssertTrue(text.contains("#2563EB"))
        XCTAssertTrue(text.contains("### Commit / Worktree Graph"))
        XCTAssertTrue(text.contains("bounded to 12 lines"))
        XCTAssertTrue(text.contains("* abc1234 (HEAD -> feature/demo) Demo commit"))
        XCTAssertFalse(text.contains("placeholder"))
    }

    func testGraphDTOEncodesInspectableMetadata() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "list",
            worktrees: [Self.worktreeDTO()],
            graph: .init(
                requested: true,
                limit: 2,
                lines: ["* abc1234 (HEAD -> feature/demo) Demo", "* def5678 main"],
                source: "git log --graph --decorate --oneline --color=never -n 2"
            )
        )

        let object = try XCTUnwrap(Self.value(dto).objectValue)
        let graph = try XCTUnwrap(object["graph"]?.objectValue)
        XCTAssertEqual(graph["limit"]?.intValue, 2)
        XCTAssertEqual(graph["line_count"]?.intValue, 2)
        XCTAssertEqual(graph["truncated"]?.boolValue, false)
        XCTAssertEqual(graph["source"]?.stringValue, "git log --graph --decorate --oneline --color=never -n 2")
        XCTAssertEqual(graph["lines"]?.arrayValue?.first?.stringValue, "* abc1234 (HEAD -> feature/demo) Demo")
    }

    func testMergePreviewOutputUsesManageWorktreeHeaderAndNestedMergeBlock() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "preview",
            merge: Self.mergeDTO(status: "preview")
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Manage Worktree Preview"), text)
        XCTAssertTrue(text.contains("### ASCII Visualization"), text)
        XCTAssertTrue(text.contains("### Preflight"), text)
        XCTAssertTrue(text.contains("### Artifacts"), text)
        XCTAssertTrue(text.contains("Apply after approval: manage_worktree"), text)
        XCTAssertFalse(text.contains("## Merge Worktree"), text)
    }

    func testMergeConflictOutputShowsConflictsAndContinueActions() throws {
        let dto = ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "apply",
            merge: Self.mergeDTO(
                status: "conflicted",
                conflictFiles: ["Sources/App.swift"],
                nextActions: [
                    "Continue after resolving: manage_worktree {\"op\":\"continue\",\"operation_id\":\"merge_123\",\"confirm\":true}",
                    "Abort if needed: manage_worktree {\"op\":\"abort\",\"operation_id\":\"merge_123\",\"confirm\":true}"
                ]
            )
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Manage Worktree Apply ⚠️"), text)
        XCTAssertTrue(text.contains("### Conflicts"), text)
        XCTAssertTrue(text.contains("Sources/App.swift"), text)
        XCTAssertTrue(text.contains("manage_worktree {\"op\":\"continue\""), text)
    }

    func testDiscoveryToolOutputsShowSessionBoundWorktreeScope() throws {
        let fileTree = ToolResultDTOs.FileTreeDTO(
            rootsCount: 1,
            usesLegend: false,
            tree: "Project\n└── Sources",
            worktreeScope: Self.scope()
        )
        let search = ToolResultDTOs.SearchResultDTO(
            totalMatches: 1,
            totalFiles: 1,
            contentMatches: 1,
            pathMatches: 0,
            limitHit: false,
            perFileCounts: [.init(path: "Sources/App.swift", count: 1)],
            pathMatchLines: [],
            contentMatchGroups: [],
            worktreeScope: Self.scope()
        )
        let readFile = ToolResultDTOs.ReadFileReply(
            content: "print(\"hi\")",
            totalLines: 1,
            firstLine: 1,
            lastLine: 1,
            displayPath: "Sources/App.swift",
            worktreeScope: Self.scope()
        )
        let cases = try [
            (
                "file tree",
                Self.onlyText(ToolOutputFormatter.formatFileTree(value: Self.value(fileTree))),
                ["Project\n└── Sources"]
            ),
            (
                "file search",
                Self.onlyText(ToolOutputFormatter.formatSearch(value: Self.value(search))),
                ["filesystem searches use"]
            ),
            (
                "read file",
                Self.onlyText(ToolOutputFormatter.formatReadFile(args: ["path": Self.value("Sources/App.swift")], value: Self.value(readFile))),
                ["filesystem reads use", "```swift"]
            )
        ]

        for (name, text, expectedSnippets) in cases {
            Self.assertScopeBlock(in: text)
            for snippet in expectedSnippets {
                XCTAssertTrue(text.contains(snippet), "\(name): missing \(snippet)\n\(text)")
            }
        }
    }

    func testCodeStructureOutputShowsTypedPendingIssueAndWorktreeScope() throws {
        let dto = ToolResultDTOs.CodeStructureReplyDTO(
            status: "pending",
            files: [],
            summary: .init(
                requestedSeeds: 1,
                resolvedSeeds: 0,
                returnedSeeds: 0,
                returnedRelated: 0,
                returnedFiles: 0,
                codemapContentTokens: 0,
                examinedEdges: 0
            ),
            issues: [
                .init(
                    code: "artifact_pending",
                    phase: "seed_demand",
                    path: "Project/Sources/App.swift",
                    retryable: true,
                    retryAfterMilliseconds: 50,
                    attempted: nil,
                    limit: nil,
                    message: "Codemap generation is still pending."
                )
            ],
            retry: .init(retryable: true, retryAfterMilliseconds: 50),
            worktreeScope: Self.scope()
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatCodeStructure(value: Self.value(dto)))

        XCTAssertTrue(text.contains("## Code Structure ⚠️"), text)
        XCTAssertTrue(text.contains("**Status**: `pending`"), text)
        XCTAssertTrue(text.contains("`artifact_pending`"), text)
        XCTAssertTrue(text.contains("`Project/Sources/App.swift`"), text)
        XCTAssertTrue(text.contains("codemap scans use"), text)
        XCTAssertTrue(text.contains("Displayed paths use logical/canonical roots"), text)
        XCTAssertTrue(text.contains("`Project` → session-bound worktree"), text)
        XCTAssertFalse(text.contains("/repo/project"), text)
        XCTAssertFalse(text.contains("/tmp/worktrees/project-agent"), text)
        XCTAssertTrue(text.contains("wt_123"), text)
        XCTAssertTrue(text.contains("branch `feature/demo`"), text)
        XCTAssertTrue(text.contains("label `Demo Worktree`"), text)
    }

    func testWorkspaceContextOutputHidesPhysicalRootInScopeBlocks() throws {
        let scope = Self.scope()
        let dto = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: nil,
            fileBlocks: nil,
            codeStructure: nil,
            fileTree: .init(
                rootsCount: 1,
                usesLegend: false,
                tree: "Project\n└── Sources",
                worktreeScope: scope
            ),
            tokenStats: nil,
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: nil,
            worktreeScope: scope
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatPromptState(value: Self.value(dto)))

        XCTAssertTrue(text.contains("Displayed paths use logical/canonical roots"), text)
        XCTAssertTrue(text.contains("`Project` → session-bound worktree"), text)
        XCTAssertFalse(text.contains("/repo/project"), text)
        XCTAssertFalse(text.contains("/tmp/worktrees/project-agent"), text)
        XCTAssertTrue(text.contains("wt_123"), text)
        XCTAssertTrue(text.contains("branch `feature/demo`"), text)
        XCTAssertTrue(text.contains("label `Demo Worktree`"), text)
        XCTAssertEqual(Self.occurrences(of: "session-bound worktree", in: text), 2, text)
        XCTAssertTrue(text.contains("### Selected File Tree"), text)
    }

    func testWorkspaceContextCodeMapsShowsPendingAndUnmappedWhenZeroFiles() throws {
        let scope = Self.scope()
        let dto = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: nil,
            fileBlocks: nil,
            codeStructure: .init(
                fileCount: 0,
                content: "",
                unmappedPaths: ["Project/README.md"],
                pendingPaths: ["Project/Sources/Pending.swift"]
            ),
            fileTree: nil,
            tokenStats: nil,
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: nil,
            worktreeScope: scope
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatPromptState(value: Self.value(dto)))

        XCTAssertTrue(text.contains("### Code Maps"), text)
        XCTAssertTrue(text.contains("- **Files with codemap**: 0"), text)
        XCTAssertTrue(text.contains("- **Pending codemaps**: 1"), text)
        XCTAssertTrue(text.contains("  - `Project/Sources/Pending.swift`"), text)
        XCTAssertTrue(text.contains("- **Unmapped codemap paths**: 1"), text)
        XCTAssertTrue(text.contains("  - `Project/README.md`"), text)
        XCTAssertFalse(text.contains("/repo/project"), text)
        XCTAssertFalse(text.contains("/tmp/worktrees/project-agent"), text)
    }

    func testManageSelectionCodeMapsShowsPendingAndUnmappedWhenZeroFiles() throws {
        let dto = ToolResultDTOs.SelectionReply(
            files: [],
            totalTokens: 0,
            status: "ok",
            codeStructure: .init(
                fileCount: 0,
                content: "",
                unmappedPaths: ["Project/README.md"],
                pendingPaths: ["Project/Sources/Pending.swift"]
            )
        )

        let text = try Self.onlyText(ToolOutputFormatter.formatManageSelection(args: [:], value: Self.value(dto)))

        XCTAssertTrue(text.contains("Code Maps: 0 files"), text)
        XCTAssertTrue(text.contains("Pending codemaps: 1"), text)
        XCTAssertTrue(text.contains("  - `Project/Sources/Pending.swift`"), text)
        XCTAssertTrue(text.contains("Unmapped codemap paths: 1"), text)
        XCTAssertTrue(text.contains("  - `Project/README.md`"), text)
    }

    func testAgentRunOutputShowsWorktreeSummaryAndUnavailableState() throws {
        let cases = [
            (
                "available",
                AgentRunSnapshot(
                    op: "start",
                    status: "running",
                    sessionID: "session-available",
                    runID: "11111111-1111-1111-1111-111111111111",
                    session: Session(name: "Available feature agent"),
                    worktreeBindings: [
                        WorktreeBinding(
                            worktreeID: "wt_test",
                            worktreeRootPath: "/tmp/repo-feature",
                            worktreeName: "repo-feature",
                            branch: "feature/available",
                            logicalRootName: "Repo",
                            logicalRootPath: "/tmp/repo",
                            visualLabel: "Feature WT",
                            visualColorHex: "#3366FF",
                            unavailable: false
                        )
                    ]
                ),
                ["- Run ID: `11111111-1111-1111-1111-111111111111`", "- Worktree: **Feature WT**", "branch `feature/available`", "`wt_test`", "path `/tmp/repo-feature`", "#3366FF"]
            ),
            (
                "unavailable",
                AgentRunSnapshot(
                    op: "start",
                    status: "failed",
                    sessionID: "session-unavailable",
                    runID: "22222222-2222-2222-2222-222222222222",
                    session: Session(name: "Feature agent"),
                    worktreeBindings: [
                        WorktreeBinding(
                            worktreeID: "wt_missing",
                            worktreeRootPath: "/tmp/repo-missing",
                            worktreeName: "repo-missing",
                            branch: "feature/demo",
                            logicalRootName: "Repo",
                            logicalRootPath: "/tmp/repo",
                            visualLabel: "demo",
                            visualColorHex: "#2563EB",
                            unavailable: true
                        )
                    ]
                ),
                ["- Run ID: `22222222-2222-2222-2222-222222222222`", "- Worktree: **demo**", "branch `feature/demo`", "`wt_missing`", "path `/tmp/repo-missing`", "⚠️ unavailable"]
            )
        ]

        for (name, snapshot, expectedSnippets) in cases {
            let text = try Self.onlyText(ToolOutputFormatter.formatAgentRun(args: ["op": Self.value("start")], value: Self.value(snapshot)))
            for snippet in expectedSnippets {
                XCTAssertTrue(text.contains(snippet), "\(name): missing \(snippet)\n\(text)")
            }
        }
    }

    private static func scope() -> ToolResultDTOs.WorktreeScopeDTO {
        ToolResultDTOs.WorktreeScopeDTO(
            kind: "session_bound_worktree",
            displayIdentity: "logical_canonical_root",
            effectiveIdentity: "bound_worktree_root",
            rootMappings: [
                .init(
                    logicalRootName: "Project",
                    logicalRootPath: "Project",
                    effectiveRootName: "project-agent",
                    effectiveRootPath: "session-bound",
                    worktreeID: "wt_123",
                    worktreeName: "project-agent",
                    branch: "feature/demo",
                    label: "Demo Worktree"
                )
            ]
        )
    }

    private static func assertScopeBlock(in text: String) {
        XCTAssertTrue(text.contains("session-bound worktree"), text)
        XCTAssertTrue(text.contains("Displayed paths use logical/canonical roots"), text)
        XCTAssertTrue(text.contains("`Project`"), text)
        XCTAssertFalse(text.contains("/repo/project"), text)
        XCTAssertFalse(text.contains("/tmp/worktrees/project-agent"), text)
        XCTAssertTrue(text.contains("wt_123"), text)
        XCTAssertTrue(text.contains("branch `feature/demo`"), text)
        XCTAssertTrue(text.contains("label `Demo Worktree`"), text)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func mergeDTO(
        status: String,
        conflictFiles: [String]? = nil,
        nextActions: [String]? = nil
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO {
        .init(
            status: status,
            operationID: "merge_123",
            sessionID: "session_123",
            source: mergeEndpointDTO(label: "feature", path: "/tmp/repo-feature", branch: "feature/demo"),
            target: mergeEndpointDTO(label: "main", path: "/tmp/repo-main", branch: "main"),
            mergeBase: "1111111",
            sourceHead: "2222222",
            targetHeadBefore: "3333333",
            visualization: .init(
                requested: true,
                limit: 24,
                text: "target main\nsource feature",
                lines: ["target main", "source feature"],
                sourceWorktreeID: "wt_feature",
                targetWorktreeID: "wt_main",
                source: "manage_worktree.preview"
            ),
            preflight: .init(
                blocked: false,
                blockers: [],
                conflictPrediction: .init(status: "clean", files: [], message: nil)
            ),
            summary: .init(commits: 2, files: 4, insertions: 20, deletions: 5),
            artifacts: .init(
                snapshotID: "snapshot_123",
                snapshotDirectory: "/tmp/snapshot",
                manifestPath: "/tmp/snapshot/MAP.txt",
                mapPath: "/tmp/snapshot/MAP.txt",
                allPatchPath: "/tmp/snapshot/all.patch",
                sidecarPath: "/tmp/snapshot/merge_preview.json"
            ),
            conflictFiles: conflictFiles,
            nextActions: nextActions ?? ["Apply after approval: manage_worktree {\"op\":\"apply\",\"operation_id\":\"merge_123\",\"confirm_preview\":true}"]
        )
    }

    private static func mergeEndpointDTO(
        label: String,
        path: String,
        branch: String?
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO {
        .init(
            worktreeID: "wt_\(label)",
            repoKey: "repo-123",
            path: path,
            name: label,
            branch: branch,
            head: "0000000000000000000000000000000000000000",
            shortHead: "0000000",
            isMain: label == "main",
            label: label
        )
    }

    private static func worktreeDTO() -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        .init(
            worktreeID: "wt_feature",
            specifier: "@id:wt_feature",
            path: "/tmp/repo-feature",
            gitDir: "/tmp/repo/.git/worktrees/repo-feature",
            name: "repo-feature",
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
            status: nil
        )
    }

    private static func listWorktreeDTO() -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
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
            worktreeRootPath: "/tmp/repo-feature",
            worktreeName: "repo-feature",
            branch: "feature/demo",
            head: "abcdef0",
            visualLabel: "demo",
            visualColorHex: "#2563EB",
            boundAt: "2026-05-22T00:00:00Z",
            source: "manage_worktree.bind"
        )
    }

    private static func value(_ value: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }

    private struct AgentRunSnapshot: Encodable {
        let op: String
        let status: String
        let sessionID: String
        let runID: String
        let session: Session
        let worktreeBindings: [WorktreeBinding]

        private enum CodingKeys: String, CodingKey {
            case op, status, session
            case sessionID = "session_id"
            case runID = "run_id"
            case worktreeBindings = "worktree_bindings"
        }
    }

    private struct Session: Encodable {
        let name: String
    }

    private struct WorktreeBinding: Encodable {
        let worktreeID: String
        let worktreeRootPath: String
        let worktreeName: String
        let branch: String
        let logicalRootName: String
        let logicalRootPath: String
        let visualLabel: String
        let visualColorHex: String
        let unavailable: Bool

        private enum CodingKeys: String, CodingKey {
            case branch, unavailable
            case worktreeID = "worktree_id"
            case worktreeRootPath = "worktree_root_path"
            case worktreeName = "worktree_name"
            case logicalRootName = "logical_root_name"
            case logicalRootPath = "logical_root_path"
            case visualLabel = "visual_label"
            case visualColorHex = "visual_color_hex"
        }
    }
}
