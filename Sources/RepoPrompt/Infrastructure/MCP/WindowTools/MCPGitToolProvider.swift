import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
final class MCPGitToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .git

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    nonisolated static func worktreeWarning(from worktree: ToolResultDTOs.GitToolReplyDTO.WorktreeDTO?) -> String? {
        guard let worktree, worktree.isWorktree else { return nil }
        var parts: [String] = []
        parts.append("[Worktree] Git operations are scoped to this checkout.")
        if let branch = worktree.worktreeBranch {
            let head = worktree.worktreeHead.map { "@\($0)" } ?? ""
            parts.append("This: \(branch)\(head).")
        }
        if let mainRoot = worktree.mainWorktreeRoot {
            var mainLabel = "Main: \(mainRoot)"
            if let mainBranch = worktree.mainBranch {
                let head = worktree.mainHead.map { "@\($0)" } ?? ""
                mainLabel += " (\(mainBranch)\(head))"
            }
            parts.append(mainLabel + ".")
            parts.append("Use repo_root=\"@main\" for main checkout, repo_root=\"@main:<branch>\" to target a worktree by branch, or compare=\"main\" for trunk diff.")
        } else {
            parts.append("The primary checkout path could not be resolved. Pass its full path as repo_root to target it; compare=\"main\" still selects the trunk comparison base.")
        }
        return parts.joined(separator: " ")
    }

    func buildTools() -> [Tool] {
        [gitTool()]
    }

    private func gitTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.git,
            freshnessPolicy: .providerManaged,
            description: """
            Safe, read-only git operations.

            **Operations**: status | diff | log | show | blame

            **Compare specs** (for diff/show):
            | Spec | Meaning |
            |------|--------|
            | `uncommitted` | Working dir vs HEAD (default) |
            | `staged` | Staged changes vs HEAD |
            | `unstaged` | Working dir vs staged |
            | `back:N` | HEAD~N..HEAD |
            | `mergebase:X` | Working dir vs merge-base with X |
            | `main` | Working dir vs merge-base with trunk branch (auto-detected) |
            | `uncommitted:main` | Uncommitted vs merge-base with trunk branch |
            | `staged:main` | Staged vs merge-base with trunk branch |
            | `trunk` | Alias for `main` |
            | `last` | vs CURRENT snapshot |
            | `<snapshot_id>` | vs specific snapshot |
            | `<revspec>` | Any git revspec |

            **Detail levels** (for diff/show):
            - `summary` (default): Totals only
            - `files`: File list with stats
            - `patches`: Patch hunks, truncated for safety (~300 lines)
            - `full`: Patch hunks, untruncated (may be large)

            **Publishing artifacts** (`artifacts=true`):
            Writes snapshot files to disk for persistent reference. **Required for ask_oracle review mode** to include git diff context.
            - Creates MAP.txt, files.tsv, and optional patches
            - Primary review artifacts are auto-selected into context when possible
            - `mode`: "quick" | "standard" | "deep" (default: "standard")
            - `scope`: "all" | "selected" — filter to selected files only

            **Repo targeting**:
            - Defaults to first loaded root's repo
            - `repo_root`: Target specific repo (path or name)
            - `repo_roots`: Array for multi-repo operations (status, diff)
            - Tree specifiers: append `@wt` (explicit worktree), `@main` (main checkout), or `@main:<branch>` to target a worktree by branch (local branch name)

            **Safety**: --no-ext-diff, --no-textconv, --color=never, GIT_TERMINAL_PROMPT=0

            **Examples**:
            - Status: `{"op":"status"}`
            - Main checkout status: `{"op":"status","repo_root":"@main"}`
            - Worktree by branch: `{"op":"status","repo_root":"@main:main"}`
            - Diff vs trunk: `{"op":"diff","compare":"main"}`
            - Quick diff: `{"op":"diff","detail":"files"}`
            - Inline patches: `{"op":"diff","detail":"patches"}`
            - Full untruncated diff: `{"op":"diff","detail":"full"}`
            - Publish for review: `{"op":"diff","artifacts":true,"scope":"selected"}`
            - Recent commits: `{"op":"log","count":5}`

            Note: log/show/blame run on primary repo only with multi-root.
            """,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Operation", enum: ["status", "diff", "log", "show", "blame"]),
                    "repo_root": .string(description: "Repository root path inside a loaded root, or loaded root name (defaults to first loaded root). Supports @wt, @main, or @main:<branch> suffixes."),
                    "repo_roots": .array(description: "Multiple repository root paths inside loaded roots, or root names (for multi-root operations). Supports @wt, @main, or @main:<branch> suffixes.", items: .string()),
                    "repo_key": .string(description: "Repository key (optional alternative to repo_root)"),
                    "compare": .string(description: "Compare spec for diff/show (supports main/trunk aliases)"),
                    "detail": .string(description: "Detail level for diff/show", enum: ["summary", "files", "patches", "full"]),
                    "mode": .string(description: "Artifact mode for diff", enum: ["quick", "standard", "deep"]),
                    "scope": .string(description: "Diff scope", enum: ["all", "selected"]),
                    "path": .string(description: "Single pathspec"),
                    "paths": .array(description: "Multiple pathspecs", items: .string()),
                    "context_lines": .integer(description: "Diff context lines"),
                    "detect_renames": .boolean(description: "Enable rename detection"),
                    "artifacts": .boolean(description: "Write snapshot artifacts (diff only); primary review artifacts are auto-selected into context when possible"),
                    "inline": .object(
                        properties: [
                            "map": .boolean(description: "Include MAP excerpt"),
                            "mode": .string(description: "Inline mode", enum: ["brief", "full"]),
                            "max_lines": .integer(description: "Max MAP lines")
                        ],
                        required: []
                    ),
                    "ref": .string(description: "Ref for show operation"),
                    "count": .integer(description: "Number of commits for log"),
                    "lines": .string(description: "Line range for blame (e.g., \"45-60\")")
                ],
                required: ["op"]
            )
        ) { [self] _, args in
            let connectionID = ServerNetworkManager.currentConnectionID
            return try await Value(executeGitTool(args: args, connectionID: connectionID))
        }
    }

    private func executeGitTool(args: [String: Value], connectionID: UUID?) async throws -> ToolResultDTOs.GitToolReplyDTO {
        typealias Reply = ToolResultDTOs.GitToolReplyDTO

        enum GitOp: String {
            case status, diff, log, show, blame
        }

        let opRaw = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "status"
        guard let op = GitOp(rawValue: opRaw) else {
            throw MCPError.invalidParams("Invalid op: \(opRaw). Valid ops: status, diff, log, show, blame")
        }

        guard let workspaceManager = dependencies.workspaceManager else {
            throw MCPError.invalidParams("Workspace manager unavailable for git tool.")
        }
        guard let workspace = workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        let workspaceDirectory = workspaceManager.workspaceDirectory(for: workspace)
        let store = GitDiffSnapshotStore()
        let vcsService = VCSService.shared

        // Resolve repo roots (defaults to first loaded root, projected for bound sessions)
        let metadata = await dependencies.captureRequestMetadata()
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: lookupContext.rootScope)
        let allRepos = try await discoverAllGitRepos(rootScope: lookupContext.rootScope)
        let defaultRepo = try await resolveDefaultGitRepo(rootScope: lookupContext.rootScope)
        let explicitTokens = parseExplicitRepoRoots(from: args).map { tokens in
            tokens.map { token in
                token.hasPrefix("@") ? token : lookupContext.translateInputPath(token)
            }
        }

        var repos: [GitRepoDescriptor]

        // repo_key takes precedence - search all repos
        if let repoKey = args["repo_key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !repoKey.isEmpty {
            guard let match = allRepos.first(where: { $0.repoKey == repoKey }) else {
                let available = allRepos.map(\.repoKey).joined(separator: ", ")
                throw MCPError.invalidParams("repo_key not found: \(repoKey). Available: \(available)")
            }
            repos = [match]
        } else {
            let resolver = GitRepoTargetResolver()
            do {
                repos = try await resolver.resolveRepoRoots(
                    explicitRootTokens: explicitTokens,
                    allRepos: allRepos,
                    visibleRoots: visibleRoots,
                    defaultRepo: defaultRepo
                )
            } catch let error as GitRepoTargetResolverError {
                throw MCPError.invalidParams(error.message)
            }
        }

        // For now, use primary repo for single-repo operations
        // Multi-root execution will be implemented for operations that benefit from it (status, diff)
        let primaryRepo = repos[0]
        let repoURL = primaryRepo.rootURL
        let isMultiRepo = repos.count > 1
        let primaryWorktree = await buildWorktreeDTO(for: repoURL)
        let worktreeWarning = buildWorktreeWarning(from: primaryWorktree)

        // Helper: Build status breakdown from changed files
        func statusBreakdown(from files: [VCSUncommittedFile]) -> [String: Int]? {
            var counts: [String: Int] = [:]
            for file in files {
                counts[file.status, default: 0] += 1
            }
            return counts.isEmpty ? nil : counts
        }

        func statusBreakdownFromManifest(from files: [GitDiffSnapshotManifest.FileEntry]) -> [String: Int]? {
            var counts: [String: Int] = [:]
            for entry in files {
                guard let status = entry.status, !status.isEmpty else { continue }
                counts[status, default: 0] += 1
            }
            return counts.isEmpty ? nil : counts
        }

        func summaryDTO(summary: GitDiffSnapshotManifest.Summary, files: [GitDiffSnapshotManifest.FileEntry]) -> Reply.SummaryDTO {
            Reply.SummaryDTO(
                files: summary.files,
                insertions: summary.insertions,
                deletions: summary.deletions,
                byStatus: statusBreakdownFromManifest(from: files)
            )
        }

        func oneliner(files: Int, insertions: Int, deletions: Int) -> String {
            "\(files) files (+\(insertions) -\(deletions))"
        }

        func hunkDTOs(from hunks: [GitDiffPatchParsing.ParsedHunk], nilWhenEmpty: Bool) -> [Reply.DiffHunkDTO]? {
            if nilWhenEmpty, hunks.isEmpty { return nil }
            var dtos: [Reply.DiffHunkDTO] = []
            dtos.reserveCapacity(hunks.count)
            for hunk in hunks {
                dtos.append(Reply.DiffHunkDTO(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, patch: hunk.content))
            }
            return dtos
        }

        func diffFileDTOsWithoutHunks(from changedFiles: [VCSUncommittedFile]) -> [Reply.DiffFileDTO] {
            var files: [Reply.DiffFileDTO] = []
            files.reserveCapacity(changedFiles.count)
            for file in changedFiles {
                files.append(Reply.DiffFileDTO(path: file.path, status: file.status, insertions: file.additions, deletions: file.deletions, hunks: nil))
            }
            return files
        }

        func parsedFileHunks(from changedFiles: [VCSUncommittedFile], perFilePatches: [String: String]) -> [GitDiffPatchParsing.ParsedFileHunks] {
            let state = EditFlowPerf.begin(
                EditFlowPerf.Stage.Git.hunkParsing,
                EditFlowPerf.Dimensions(lineCount: changedFiles.count)
            )
            var parsedFiles: [GitDiffPatchParsing.ParsedFileHunks] = []
            parsedFiles.reserveCapacity(changedFiles.count)
            var patchBytes = 0
            var hunkCount = 0

            for file in changedFiles {
                guard let patchText = perFilePatches[file.path] else { continue }
                if state != nil {
                    patchBytes += patchText.utf8.count
                }
                let hunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
                hunkCount += hunks.count
                parsedFiles.append(GitDiffPatchParsing.ParsedFileHunks(
                    path: file.path,
                    status: file.status,
                    insertions: file.additions ?? 0,
                    deletions: file.deletions ?? 0,
                    hunks: hunks
                ))
            }

            EditFlowPerf.end(
                EditFlowPerf.Stage.Git.hunkParsing,
                state,
                EditFlowPerf.Dimensions(fileBytes: patchBytes, lineCount: changedFiles.count, chunkCount: hunkCount)
            )
            return parsedFiles
        }

        func buildWorktreeDTO(for repoURL: URL) async -> Reply.WorktreeDTO? {
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            guard backend.kind == .git else { return nil }
            guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repoURL), layout.isLinkedWorktree else { return nil }

            let worktreeRoot = layout.workTreeRoot.path
            let worktreeName = layout.gitDir.lastPathComponent.isEmpty ? nil : layout.gitDir.lastPathComponent
            let commonGitDir = layout.commonDir.path
            let listedMainRoot = try? await vcsService.listGitWorktrees(at: repoURL)
                .first(where: \.isMain)
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL }
            let mainRoot = listedMainRoot ?? GitRepoTargetResolver.resolveMainWorktreeRoot(for: layout)

            let wtBranch = try? await backend.getCurrentBranch(at: repoURL)
            let wtHead = await (try? backend.getHeadID(at: repoURL)).map { String($0.prefix(7)) }

            var mainBranch: String?
            var mainHead: String?
            if let mainRoot {
                let mainBackend = await vcsService.backend(forRepoRoot: mainRoot)
                mainBranch = try? await mainBackend.getCurrentBranch(at: mainRoot)
                mainHead = await (try? mainBackend.getHeadID(at: mainRoot)).map { String($0.prefix(7)) }
            }

            return Reply.WorktreeDTO(
                isWorktree: true,
                worktreeName: worktreeName,
                worktreeRoot: worktreeRoot,
                commonGitDir: commonGitDir,
                mainWorktreeRoot: mainRoot?.path,
                worktreeBranch: wtBranch,
                mainBranch: mainBranch,
                worktreeHead: wtHead,
                mainHead: mainHead
            )
        }

        func buildWorktreeWarning(from worktree: Reply.WorktreeDTO?) -> String? {
            Self.worktreeWarning(from: worktree)
        }

        func combineWarnings(_ warnings: [String?]) -> String? {
            let merged = warnings.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return merged.isEmpty ? nil : merged.joined(separator: "\n")
        }

        // MARK: Multi-root aggregate helpers

        /// Merge multiple byStatus dictionaries into one
        func mergeByStatus(_ dicts: [[String: Int]?]) -> [String: Int]? {
            var result: [String: Int] = [:]
            for dict in dicts.compactMap(\.self) {
                for (status, count) in dict {
                    result[status, default: 0] += count
                }
            }
            return result.isEmpty ? nil : result
        }

        /// Compute aggregate totals from per-repo diff DTOs
        func aggregateTotals(from diffs: [Reply.DiffDTO]) -> Reply.TotalsDTO {
            var files = 0, insertions = 0, deletions = 0
            for diff in diffs {
                let t = diff.totals
                files += t.files
                insertions += t.insertions
                deletions += t.deletions
            }
            return Reply.TotalsDTO(files: files, insertions: insertions, deletions: deletions)
        }

        /// Build aggregate DTO from per-repo results
        func aggregateDTO(from repoDiffs: [Reply.DiffDTO], repoCount: Int) -> Reply.AggregateDTO {
            let totals = aggregateTotals(from: repoDiffs)
            let byStatus = mergeByStatus(repoDiffs.map(\.byStatus))
            let onelinerStr = "\(repoCount) repos: \(totals.files) files (+\(totals.insertions) -\(totals.deletions))"
            return Reply.AggregateDTO(
                totals: totals,
                byStatus: byStatus,
                oneliner: onelinerStr,
                repoCount: repoCount
            )
        }

        func artifactsDTO(snapshotDirURL: URL, manifest: GitDiffSnapshotManifest) -> Reply.ArtifactsDTO {
            let fm = FileManager.default
            let changedLinesURL = snapshotDirURL.appendingPathComponent("index/changed_lines.tsv")
            let allPatchURL = snapshotDirURL.appendingPathComponent("diff/all.patch")
            let deepHunksURL = snapshotDirURL.appendingPathComponent("deep/hunks.jsonl")
            let deepChangedLinesURL = snapshotDirURL.appendingPathComponent("deep/changed_lines.tsv")
            return Reply.ArtifactsDTO(
                manifest: "manifest.json",
                map: "MAP.txt",
                filesTsv: "index/files.tsv",
                changedLines: fm.fileExists(atPath: changedLinesURL.path) ? "index/changed_lines.tsv" : nil,
                tree: "index/files.tree.txt",
                selectionPaths: manifest.requestedPaths == nil ? nil : "index/selection.paths.txt",
                allPatch: fm.fileExists(atPath: allPatchURL.path) ? "diff/all.patch" : nil,
                deepHunks: fm.fileExists(atPath: deepHunksURL.path) ? "deep/hunks.jsonl" : nil,
                deepChangedLines: fm.fileExists(atPath: deepChangedLinesURL.path) ? "deep/changed_lines.tsv" : nil
            )
        }

        func primaryArtifactsDTO(
            snapshotDir: String,
            artifacts: Reply.ArtifactsDTO,
            manifest: GitDiffSnapshotManifest,
            autoSelectedPaths: [String]
        ) -> Reply.PrimaryArtifactsDTO {
            let primary = GitDiffSnapshotStore.primaryArtifacts(
                snapshotDir: snapshotDir,
                mapRelativePath: artifacts.map,
                allPatchRelativePath: artifacts.allPatch
            )
            let autoSelected = primary.selectionCandidates.filter { autoSelectedPaths.contains($0) }
            let perFilePatches = GitDiffSnapshotStore.perFilePatchArtifacts(snapshotDir: snapshotDir, files: manifest.files)
                .map {
                    Reply.PrimaryArtifactsDTO.PerFilePatchDTO(
                        jumpIndex: $0.jumpIndex,
                        gitPath: $0.gitPath,
                        selectionPath: $0.selectionPath,
                        status: $0.status,
                        additions: $0.additions,
                        deletions: $0.deletions
                    )
                }
            return Reply.PrimaryArtifactsDTO(
                map: primary.map,
                allPatch: primary.allPatch,
                autoSelected: autoSelected.isEmpty ? nil : autoSelected,
                perFilePatches: perFilePatches.isEmpty ? nil : perFilePatches
            )
        }

        func autoSelectPrimaryGitDiffArtifacts(paths: [String]) async -> [String] {
            guard !paths.isEmpty else { return [] }
            do {
                let context = try await dependencies.requireCurrentTabContext(MCPWindowToolName.git)
                let result = await dependencies.addPrimaryGitDiffArtifactsToSelection(context.selection, paths)
                if result.selection != context.selection {
                    try await dependencies.updateCurrentTabContext(MCPWindowToolName.git) { current in
                        current.selection = result.selection
                    }
                }
                return result.autoSelectedPaths
            } catch {
                dependencies.logDebug("Auto-select git artifacts skipped: \(error.localizedDescription)")
                return []
            }
        }

        func inlineDTO(snapshotDirURL: URL, inlineMap: Bool, inlineMode: String, inlineMaxLines: Int) -> Reply.InlineDTO? {
            guard inlineMap else { return nil }
            let mapURL = snapshotDirURL.appendingPathComponent("MAP.txt")
            guard let mapText = try? String(contentsOf: mapURL, encoding: .utf8) else { return nil }
            let sections: [String]? = (inlineMode == "brief") ? ["SNAPSHOT_META", "CHANGED_FILE_TREE"] : nil
            let excerpt = GitDiffMapBuilder.inlineExcerpt(from: mapText, maxLines: inlineMaxLines, sections: sections)
            return Reply.InlineDTO(
                mapExcerpt: excerpt.excerpt,
                truncated: excerpt.truncated,
                totalLines: excerpt.totalLines,
                returnedLines: excerpt.returnedLines
            )
        }

        typealias SnapshotRef = GitDiffSnapshotStore.GitDiffSnapshotRef

        func resolveCurrentSnapshotRef(for repo: GitRepoDescriptor) throws -> SnapshotRef {
            if let currentID = store.readCurrentSnapshotID(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, fallbackToLegacy: false) {
                return SnapshotRef(repoKey: repo.repoKey, snapshotID: currentID)
            }
            throw MCPError.invalidParams("No CURRENT snapshot available for repo: \(repo.displayName).")
        }

        func resolveSnapshotRefArgument(
            snapshotIDRaw: String?,
            snapshotDirRaw: String?,
            preferredRepo: GitRepoDescriptor?
        ) throws -> SnapshotRef {
            if let snapshotDirRaw, !snapshotDirRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = snapshotDirRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("repos/") else {
                    throw MCPError.invalidParams("snapshot_dir must be repo-scoped (repos/<repoKey>/<snapshotID>).")
                }
                guard let ref = store.parseSnapshotRef(trimmed) else {
                    throw MCPError.invalidParams("Invalid snapshot_dir: \(snapshotDirRaw)")
                }
                return ref
            }
            guard let snapshotIDRaw else {
                throw MCPError.invalidParams("snapshot_id is required for op: \(opRaw)")
            }
            let trimmed = snapshotIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw MCPError.invalidParams("snapshot_id is required for op: \(opRaw)")
            }
            if trimmed.lowercased() == "current" {
                guard let preferredRepo else {
                    throw MCPError.invalidParams("snapshot_id 'current' requires repo_root/repo_key or a single repo context.")
                }
                return try resolveCurrentSnapshotRef(for: preferredRepo)
            }
            guard let normalized = GitDiffSnapshotStore.normalizeSnapshotID(trimmed) else {
                throw MCPError.invalidParams("Invalid snapshot_id: \(trimmed)")
            }
            if let preferredRepo {
                if (try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: preferredRepo.repoKey, snapshotID: normalized)) != nil {
                    return SnapshotRef(repoKey: preferredRepo.repoKey, snapshotID: normalized)
                }
                throw MCPError.invalidParams("Snapshot not found: \(trimmed) in repo: \(preferredRepo.displayName)")
            }
            let refs = store.locateRepoScopedSnapshotRefs(workspaceDirectory: workspaceDirectory, snapshotID: normalized)
            if refs.count == 1 {
                return refs[0]
            }
            if refs.isEmpty {
                throw MCPError.invalidParams("Snapshot not found: \(trimmed)")
            }
            throw MCPError.invalidParams("Ambiguous snapshot_id: \(trimmed). Use snapshot_dir or repo_root/repo_key to disambiguate.")
        }

        func looksLikeSnapshotID(_ value: String) -> Bool {
            let parts = value.split(separator: "/")
            guard parts.count == 2 else { return false }
            let datePart = parts[0]
            let timePart = parts[1]
            guard datePart.count == 10 else { return false }
            let dateChars = Array(datePart)
            guard dateChars.indices.contains(4), dateChars.indices.contains(7) else { return false }
            if dateChars[4] != "-" || dateChars[7] != "-" { return false }
            let dateDigits = dateChars.enumerated().allSatisfy { idx, ch in
                if idx == 4 || idx == 7 { return true }
                return ch.isNumber
            }
            guard dateDigits else { return false }
            let timeParts = timePart.split(separator: "-", maxSplits: 1).map(String.init)
            guard let timeDigits = timeParts.first, timeDigits.count == 4, timeDigits.allSatisfy(\.isNumber) else { return false }
            if timeParts.count == 2 {
                guard let suffix = timeParts.last, !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return false }
            }
            return true
        }

        func detectMainBranchRef(repoURL: URL) async -> String? {
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let remoteBranches = await (try? backend.getRemoteBranches(at: repoURL, limit: 200).map(\.name)) ?? []
            let localBranches = await (try? backend.getLocalBranches(at: repoURL, limit: 200).map(\.name)) ?? []

            func pick(_ candidates: [String], in list: [String]) -> String? {
                for candidate in candidates where list.contains(candidate) {
                    return candidate
                }
                return nil
            }

            if let ref = pick(["origin/main", "upstream/main"], in: remoteBranches) { return ref }
            if let ref = pick(["main"], in: localBranches) { return ref }
            if let ref = pick(["origin/master", "upstream/master"], in: remoteBranches) { return ref }
            if let ref = pick(["master"], in: localBranches) { return ref }
            if let upstream = try? await backend.getUpstreamRef(at: repoURL), !upstream.isEmpty {
                return upstream
            }

            return nil
        }

        func resolveCompareSpec(_ compareRaw: String) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
            try await resolveCompareSpec(compareRaw, for: primaryRepo)
        }

        func resolveCompareSpec(_ compareRaw: String, for repo: GitRepoDescriptor) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
            let trimmed = compareRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawInput = trimmed.isEmpty ? "uncommitted" : trimmed
            let lowered = rawInput.lowercased()

            if lowered == "main" || lowered == "trunk" {
                guard let mainRef = await detectMainBranchRef(repoURL: repo.rootURL) else {
                    throw MCPError.invalidParams("compare=\"\(rawInput)\" could not be resolved. Try compare=\"origin/main\" or compare=\"mergebase:origin/main\".")
                }
                let spec = GitDiffCompareSpec.uncommittedMergeBase(base: mainRef)
                return (spec, spec.displayString, rawInput)
            }

            if lowered.hasPrefix("uncommitted:") || lowered.hasPrefix("staged:") {
                let parts = rawInput.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let mode = parts[0].lowercased()
                    let base = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let baseLowered = base.lowercased()
                    if baseLowered == "main" || baseLowered == "trunk" {
                        guard let mainRef = await detectMainBranchRef(repoURL: repo.rootURL) else {
                            throw MCPError.invalidParams("compare=\"\(rawInput)\" could not be resolved. Try compare=\"\(mode):origin/main\".")
                        }
                        let spec: GitDiffCompareSpec = (mode == "staged") ? .stagedMergeBase(base: mainRef) : .uncommittedMergeBase(base: mainRef)
                        return (spec, spec.displayString, rawInput)
                    }
                }
            }

            if lowered == "last" {
                // Try repo-scoped CURRENT only
                guard let currentID = store.readCurrentSnapshotID(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, fallbackToLegacy: false) else {
                    throw MCPError.invalidParams("No CURRENT snapshot available for compare: \"last\" in repo: \(repo.displayName)")
                }
                guard let manifest = try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: currentID) else {
                    throw MCPError.invalidParams("Unable to read CURRENT snapshot manifest for repo: \(repo.displayName)")
                }
                let spec = GitDiffCompareSpec.uncommitted(base: manifest.fingerprint.headSHA)
                return (spec, spec.displayString, rawInput)
            }

            // Try to resolve as snapshot ID (repo-scoped only)
            if let normalized = GitDiffSnapshotStore.normalizeSnapshotID(rawInput) {
                if let manifest = try? store.readManifest(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: normalized) {
                    let spec = GitDiffCompareSpec.uncommitted(base: manifest.fingerprint.headSHA)
                    return (spec, spec.displayString, rawInput)
                }
                if looksLikeSnapshotID(normalized) {
                    throw MCPError.invalidParams("Snapshot not found for compare: \(rawInput) in repo: \(repo.displayName)")
                }
            }

            let spec = GitDiffCompareSpec.parse(rawInput)
            let resolved = spec.displayString
            let input = (resolved == rawInput) ? nil : rawInput
            return (spec, resolved, input)
        }

        /// Collect pathspecs from path/paths args
        func collectPathspecs() -> [String]? {
            var pathspecs: [String] = []
            if let single = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
                pathspecs.append(lookupContext.translateInputPath(single))
            }
            if let arr = args["paths"]?.arrayValue {
                for item in arr {
                    if let p = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                        pathspecs.append(lookupContext.translateInputPath(p))
                    }
                }
            }
            return pathspecs.isEmpty ? nil : pathspecs
        }

        switch op {
        // MARK: - Status

        case .status:
            // Multi-root: run status for each repo
            if isMultiRepo {
                var perRepoResults: [Reply.RepoResultDTO] = []
                for repo in repos {
                    do {
                        let backend = await vcsService.backend(forRepoRoot: repo.rootURL)
                        let branch = try? await backend.getCurrentBranch(at: repo.rootURL)
                        let upstream = try? await backend.getUpstreamRef(at: repo.rootURL)
                        var ahead: Int?
                        var behind: Int?
                        if let upstream {
                            if let ab = try? await backend.getAheadBehind(vs: upstream, at: repo.rootURL) {
                                ahead = ab.ahead
                                behind = ab.behind
                            }
                        }
                        let workingStatus = try await backend.getWorkingStatus(at: repo.rootURL)
                        let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)
                        let summaryStr: String = {
                            var parts: [String] = []
                            if let b = branch { parts.append(b) }
                            if let a = ahead, let b = behind {
                                parts.append("+\(a) -\(b)")
                            }
                            let counts = [
                                workingStatus.staged.count > 0 ? "\(workingStatus.staged.count) staged" : nil,
                                workingStatus.modified.count > 0 ? "\(workingStatus.modified.count) modified" : nil,
                                workingStatus.untracked.count > 0 ? "\(workingStatus.untracked.count) untracked" : nil
                            ].compactMap(\.self)
                            if !counts.isEmpty {
                                parts.append(counts.joined(separator: ", "))
                            }
                            return parts.joined(separator: " | ")
                        }()

                        perRepoResults.append(Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            status: Reply.StatusDTO(
                                branch: branch,
                                upstream: upstream,
                                ahead: ahead,
                                behind: behind,
                                staged: workingStatus.staged,
                                modified: workingStatus.modified,
                                untracked: workingStatus.untracked,
                                summary: summaryStr
                            ),
                            worktree: repoWorktree
                        ))
                    } catch {
                        perRepoResults.append(Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            error: error.localizedDescription
                        ))
                    }
                }
                return Reply(op: "status", repos: perRepoResults)
            }

            // Single repo: legacy behavior
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let branch = try? await backend.getCurrentBranch(at: repoURL)
            let upstream = try? await backend.getUpstreamRef(at: repoURL)
            var ahead: Int?
            var behind: Int?
            if let upstream {
                if let ab = try? await backend.getAheadBehind(vs: upstream, at: repoURL) {
                    ahead = ab.ahead
                    behind = ab.behind
                }
            }
            let workingStatus = try await backend.getWorkingStatus(at: repoURL)
            let summaryStr: String = {
                var parts: [String] = []
                if let b = branch { parts.append(b) }
                if let a = ahead, let b = behind {
                    parts.append("+\(a) -\(b)")
                }
                let counts = [
                    workingStatus.staged.count > 0 ? "\(workingStatus.staged.count) staged" : nil,
                    workingStatus.modified.count > 0 ? "\(workingStatus.modified.count) modified" : nil,
                    workingStatus.untracked.count > 0 ? "\(workingStatus.untracked.count) untracked" : nil
                ].compactMap(\.self)
                if !counts.isEmpty {
                    parts.append(counts.joined(separator: ", "))
                }
                return parts.joined(separator: " | ")
            }()

            return Reply(
                op: "status",
                status: Reply.StatusDTO(
                    branch: branch,
                    upstream: upstream,
                    ahead: ahead,
                    behind: behind,
                    staged: workingStatus.staged,
                    modified: workingStatus.modified,
                    untracked: workingStatus.untracked,
                    summary: summaryStr
                ),
                diff: nil, log: nil, show: nil, blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: worktreeWarning,
                emptyReason: nil, error: nil
            )

        // MARK: - Log

        case .log:
            let count = args["count"]?.intValue ?? 10
            let path = args["path"]?.stringValue.map { lookupContext.translateInputPath($0) }
            let logBackend = await vcsService.backend(forRepoRoot: repoURL)
            let commits = try await logBackend.getLogSummaries(count: count, path: path, at: repoURL)
            let commitDTOs = commits.map { c in
                Reply.CommitSummaryDTO(
                    sha: c.id,
                    shortSha: c.shortID,
                    author: c.author,
                    date: c.dateISO,
                    message: c.message,
                    filesChanged: c.filesChanged,
                    insertions: c.insertions,
                    deletions: c.deletions
                )
            }
            // Warn if multiple repos detected but log only runs on primary
            let logWarning: String? = isMultiRepo ? "Multiple repos detected; op 'log' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
            let combinedWarning = combineWarnings([logWarning, worktreeWarning])
            return Reply(
                op: "log",
                status: nil,
                diff: nil,
                log: Reply.LogDTO(commits: commitDTOs),
                show: nil, blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: combinedWarning, emptyReason: nil, error: nil
            )

        // MARK: - Show

        case .show:
            guard let ref = args["ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else {
                throw MCPError.invalidParams("ref is required for op: show")
            }
            let rawShowDetail = args["detail"]?.stringValue?.lowercased() ?? "summary"
            // For show, "patches" behaves the same as "full" (single commit, no truncation needed)
            let detail = rawShowDetail == "patches" ? "full" : rawShowDetail
            let showBackend = await vcsService.backend(forRepoRoot: repoURL)
            let commitInfo = try await showBackend.commitInfo(ref: ref, at: repoURL)

            // Get diff for this commit
            let revspec = "\(ref)^!"
            let contextLines = args["context_lines"]?.intValue ?? 3
            let detectRenames = args["detect_renames"]?.boolValue ?? false
            let changedFiles = try await showBackend.getChangedFilesStats(
                compare: .revspec(revspec),
                includeUntrackedWhenApplicable: false,
                detectRenames: detectRenames,
                at: repoURL
            )

            let totalFiles = changedFiles.count
            let totalInsertions = changedFiles.reduce(0) { $0 + ($1.additions ?? 0) }
            let totalDeletions = changedFiles.reduce(0) { $0 + ($1.deletions ?? 0) }

            var files: [Reply.DiffFileDTO]?

            if detail == "files" || detail == "full" {
                files = diffFileDTOsWithoutHunks(from: changedFiles)
            }

            if detail == "full" {
                let diffText = try await showBackend.getDiffText(
                    compare: .revspec(revspec),
                    paths: nil,
                    contextLines: contextLines,
                    detectRenames: detectRenames,
                    at: repoURL
                )
                // Split multi-file diff into per-file patches, then parse hunks per file
                let perFilePatches = GitService.splitUnifiedDiffByFile(diffText)

                // Rebuild files array with hunks attached to each file
                let state = EditFlowPerf.begin(
                    EditFlowPerf.Stage.Git.hunkParsing,
                    EditFlowPerf.Dimensions(lineCount: changedFiles.count)
                )
                var parsedPatchBytes = 0
                var parsedHunkCount = 0
                var filesWithHunks: [Reply.DiffFileDTO] = []
                filesWithHunks.reserveCapacity(changedFiles.count)
                for file in changedFiles {
                    let patchText = perFilePatches[file.path] ?? ""
                    if state != nil {
                        parsedPatchBytes += patchText.utf8.count
                    }
                    let parsedHunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
                    parsedHunkCount += parsedHunks.count
                    filesWithHunks.append(Reply.DiffFileDTO(
                        path: file.path,
                        status: file.status,
                        insertions: file.additions,
                        deletions: file.deletions,
                        hunks: hunkDTOs(from: parsedHunks, nilWhenEmpty: true)
                    ))
                }
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Git.hunkParsing,
                    state,
                    EditFlowPerf.Dimensions(fileBytes: parsedPatchBytes, lineCount: changedFiles.count, chunkCount: parsedHunkCount)
                )
                files = filesWithHunks
                // hunks is now nil at top level since hunks are attached to individual files
            }

            // Warn if multiple repos detected but show only runs on primary
            let showWarning: String? = isMultiRepo ? "Multiple repos detected; op 'show' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
            let combinedWarning = combineWarnings([showWarning, worktreeWarning])
            return Reply(
                op: "show",
                status: nil, diff: nil, log: nil,
                show: Reply.ShowDTO(
                    sha: commitInfo.id,
                    shortSha: commitInfo.shortID,
                    author: commitInfo.author,
                    date: commitInfo.dateISO,
                    message: commitInfo.message,
                    files: files,
                    totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
                    hunks: nil
                ),
                blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: combinedWarning, emptyReason: nil, error: nil
            )

        // MARK: - Blame

        case .blame:
            guard let rawPath = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
                throw MCPError.invalidParams("path is required for op: blame")
            }
            let path = lookupContext.translateInputPath(rawPath)
            var lineRange: ClosedRange<Int>?
            if let linesStr = args["lines"]?.stringValue {
                let parts = linesStr.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, let start = parts[0], let end = parts[1], start <= end {
                    lineRange = start ... end
                }
            }

            // If path is absolute, route to owning repo; otherwise use primary
            var targetRepoURL = repoURL
            var blameWarning: String? = nil
            if path.hasPrefix("/") {
                // Find owning repo by longest-prefix match
                let standardized = (path as NSString).standardizingPath
                if let owningRepo = owningRepo(forAbsolutePath: standardized, repos: repos) {
                    targetRepoURL = owningRepo.rootURL
                    if isMultiRepo, owningRepo.repoKey != primaryRepo.repoKey {
                        blameWarning = "Path routed to repo: \(owningRepo.displayName)"
                    }
                }
            } else if isMultiRepo {
                blameWarning = "Multiple repos detected; op 'blame' ran against \(primaryRepo.displayName). Provide repo_root or absolute path to target a specific repo."
            }

            let blameBackend = await vcsService.backend(forRepoRoot: targetRepoURL)
            let blameLines = try await blameBackend.blame(path: path, lineRange: lineRange, at: targetRepoURL)
            let blameWorktree = await buildWorktreeDTO(for: targetRepoURL)
            let combinedWarning = combineWarnings([blameWarning, buildWorktreeWarning(from: blameWorktree)])
            let lineDTOs = blameLines.map { l in
                Reply.BlameLineDTO(num: l.line, sha: l.id, author: l.author, date: l.dateISO, content: l.content)
            }
            return Reply(
                op: "blame",
                status: nil, diff: nil, log: nil, show: nil,
                blame: Reply.BlameDTO(path: path, lines: lineDTOs),
                worktree: blameWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: combinedWarning, emptyReason: nil, error: nil
            )

        // MARK: - Diff

        case .diff:
            let compareRaw = args["compare"]?.stringValue ?? "uncommitted"
            let detail = args["detail"]?.stringValue?.lowercased() ?? "summary"
            let artifacts = args["artifacts"]?.boolValue ?? false
            let pathspecs = collectPathspecs()
            let contextLines = args["context_lines"]?.intValue ?? 3
            let detectRenames = args["detect_renames"]?.boolValue ?? false

            // For multi-root, don't auto-upgrade to full detail (could explode output)
            let effectiveDetail: String = if pathspecs?.count == 1, detail == "summary", !isMultiRepo {
                "patches"
            } else {
                detail
            }

            // detail="patches" is truncated (~300 lines); detail="full" is untruncated.
            let maxLinesForPatches: Int = effectiveDetail == "full" ? Int.max : 300

            // If artifacts requested, use the publisher
            if artifacts {
                let modeRaw = args["mode"]?.stringValue?.lowercased() ?? "standard"
                guard let mode = GitDiffPublishMode(rawValue: modeRaw) else {
                    throw MCPError.invalidParams("Invalid mode: \(modeRaw)")
                }
                let scopeRaw = args["scope"]?.stringValue?.lowercased() ?? "all"
                guard let scope = GitDiffScope(rawValue: scopeRaw) else {
                    throw MCPError.invalidParams("Invalid scope: \(scopeRaw)")
                }
                let snapshotIDOverride: String? = {
                    guard let raw = args["snapshot_id"]?.stringValue else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.lowercased() == "auto" { return nil }
                    return GitDiffSnapshotStore.normalizeSnapshotID(trimmed)
                }()

                let inlineObj = args["inline"]?.objectValue
                let inlineMap = inlineObj?["map"]?.boolValue ?? true
                let inlineMode = inlineObj?["mode"]?.stringValue?.lowercased() ?? "brief"
                let inlineMaxLines = max(1, inlineObj?["max_lines"]?.intValue ?? 120)

                // Resolve selected paths using current exec context (bound tab or active tab fallback)
                // For scope .all, no selection is needed
                let allSelectedAbsolutePaths: [String]
                if scope == .selected {
                    let selectedFiles = try await dependencies.selectedRecordsForCurrentTabContext()
                    allSelectedAbsolutePaths = selectedFiles.map(\.standardizedFullPath)
                } else {
                    allSelectedAbsolutePaths = []
                }

                let publisher = GitDiffSnapshotPublisher.shared

                // Multi-root artifact diff
                if isMultiRepo {
                    var perRepoResults: [Reply.RepoResultDTO] = []
                    var collectedDiffs: [Reply.DiffDTO] = []
                    var manifestsBySnapshotDir: [String: GitDiffSnapshotManifest] = [:]
                    let tabID = dependencies.boundTabID(connectionID)

                    // Group selection paths by repo
                    let pathsByRepo = scope == .selected ? groupAbsolutePathsByRepo(paths: allSelectedAbsolutePaths, repos: repos) : [:]

                    for repo in repos {
                        do {
                            let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
                            let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)
                            let repoSelectedPaths = scope == .selected ? (pathsByRepo[repo] ?? []) : []
                            if scope == .selected, repoSelectedPaths.isEmpty {
                                perRepoResults.append(Reply.RepoResultDTO(
                                    repoRoot: repo.rootPath,
                                    repoKey: repo.repoKey,
                                    repoName: repo.displayName,
                                    worktree: repoWorktree,
                                    emptyReason: "No selected paths in this repo"
                                ))
                                continue
                            }

                            let manifest = try await publisher.publish(
                                workspaceDirectory: workspaceDirectory,
                                repo: repo,
                                mode: mode,
                                compareSpec: repoCompare.spec,
                                compareDisplay: repoCompare.resolved,
                                compareInput: repoCompare.input,
                                scope: scope,
                                selectedAbsolutePaths: repoSelectedPaths,
                                contextLines: contextLines,
                                detectRenames: detectRenames,
                                snapshotIDOverride: snapshotIDOverride,
                                tabID: tabID
                            )
                            let snapshotID = manifest.snapshotID
                            let snapshotDirURL = store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: snapshotID)
                            let snapshotDirRel = store.snapshotRelativePath(repoKey: repo.repoKey, snapshotID: snapshotID)
                            let summary = summaryDTO(summary: manifest.summary, files: manifest.files)
                            let emptyReason = GitDiffMapBuilder.emptyReason(
                                summary: manifest.summary,
                                scope: manifest.scope,
                                requestedPaths: manifest.requestedPaths,
                                compareRaw: manifest.compare
                            )

                            let diffDTO = Reply.DiffDTO(
                                compare: repoCompare.resolved,
                                detail: nil,
                                files: nil,
                                totals: Reply.TotalsDTO(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
                                byStatus: summary.byStatus,
                                oneliner: oneliner(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
                                truncated: nil,
                                truncationNote: nil
                            )
                            collectedDiffs.append(diffDTO)

                            let artifacts = artifactsDTO(snapshotDirURL: snapshotDirURL, manifest: manifest)
                            manifestsBySnapshotDir[snapshotDirRel] = manifest
                            perRepoResults.append(Reply.RepoResultDTO(
                                repoRoot: repo.rootPath,
                                repoKey: repo.repoKey,
                                repoName: repo.displayName,
                                diff: diffDTO,
                                worktree: repoWorktree,
                                snapshotId: snapshotID,
                                snapshotDir: snapshotDirRel,
                                artifacts: artifacts,
                                summary: summary,
                                oneliner: "\(summary.files) files (+\(summary.insertions) -\(summary.deletions)) | \(snapshotDirRel)",
                                inputs: Reply.DiffInputsDTO(
                                    compare: manifest.compare,
                                    compareInput: manifest.compareInput,
                                    scope: manifest.scope.rawValue,
                                    requestedPathsCount: manifest.requestedPaths?.count,
                                    contextLines: manifest.contextLines,
                                    detectRenames: manifest.detectRenames
                                ),
                                modeDetails: GitDiffMapBuilder.modeDetails(for: mode),
                                inline: inlineDTO(snapshotDirURL: snapshotDirURL, inlineMap: inlineMap, inlineMode: inlineMode, inlineMaxLines: inlineMaxLines),
                                emptyReason: emptyReason
                            ))
                        } catch {
                            perRepoResults.append(Reply.RepoResultDTO(
                                repoRoot: repo.rootPath,
                                repoKey: repo.repoKey,
                                repoName: repo.displayName,
                                error: error.localizedDescription
                            ))
                        }
                    }

                    await dependencies.ensureGitDataRootLoaded(workspace, workspaceManager)
                    _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: .visibleWorkspacePlusGitData)
                    let primaryArtifactCandidates = perRepoResults.flatMap { repoResult -> [String] in
                        guard let snapshotDir = repoResult.snapshotDir,
                              let artifacts = repoResult.artifacts
                        else {
                            return []
                        }
                        return GitDiffSnapshotStore.primaryArtifacts(
                            snapshotDir: snapshotDir,
                            mapRelativePath: artifacts.map,
                            allPatchRelativePath: artifacts.allPatch
                        ).selectionCandidates
                    }
                    let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(paths: primaryArtifactCandidates)
                    let decoratedRepoResults = perRepoResults.map { repoResult in
                        guard let snapshotDir = repoResult.snapshotDir,
                              let artifacts = repoResult.artifacts,
                              let manifest = manifestsBySnapshotDir[snapshotDir]
                        else {
                            return repoResult
                        }
                        return Reply.RepoResultDTO(
                            repoRoot: repoResult.repoRoot,
                            repoKey: repoResult.repoKey,
                            repoName: repoResult.repoName,
                            status: repoResult.status,
                            diff: repoResult.diff,
                            log: repoResult.log,
                            show: repoResult.show,
                            blame: repoResult.blame,
                            worktree: repoResult.worktree,
                            snapshotId: repoResult.snapshotId,
                            snapshotDir: snapshotDir,
                            artifacts: artifacts,
                            primaryArtifacts: primaryArtifactsDTO(snapshotDir: snapshotDir, artifacts: artifacts, manifest: manifest, autoSelectedPaths: autoSelectedPrimaryArtifacts),
                            summary: repoResult.summary,
                            oneliner: repoResult.oneliner,
                            inputs: repoResult.inputs,
                            modeDetails: repoResult.modeDetails,
                            inline: repoResult.inline,
                            warning: repoResult.warning,
                            emptyReason: repoResult.emptyReason,
                            error: repoResult.error
                        )
                    }

                    let aggregate = aggregateDTO(from: collectedDiffs, repoCount: repos.count)
                    return Reply(op: "diff", repos: decoratedRepoResults, aggregate: aggregate)
                }

                // Single repo artifact diff (legacy behavior)
                let compare = try await resolveCompareSpec(compareRaw)

                // Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
                let normalizedResult = await vcsService.normalizeCompareSpec(compare.spec, at: repoURL)
                let artifactDiffWarning = normalizedResult.warning
                let combinedWarning = combineWarnings([artifactDiffWarning, worktreeWarning])

                let tabID = dependencies.boundTabID(connectionID)
                let manifest = try await publisher.publish(
                    workspaceDirectory: workspaceDirectory,
                    repo: primaryRepo,
                    mode: mode,
                    compareSpec: compare.spec,
                    compareDisplay: compare.resolved,
                    compareInput: compare.input,
                    scope: scope,
                    selectedAbsolutePaths: allSelectedAbsolutePaths,
                    contextLines: contextLines,
                    detectRenames: detectRenames,
                    snapshotIDOverride: snapshotIDOverride,
                    tabID: tabID
                )

                await dependencies.ensureGitDataRootLoaded(workspace, workspaceManager)
                _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: .visibleWorkspacePlusGitData)
                let snapshotID = manifest.snapshotID
                let snapshotDirURL = store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
                let snapshotDirRel = store.snapshotRelativePath(repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
                let artifacts = artifactsDTO(snapshotDirURL: snapshotDirURL, manifest: manifest)
                let primaryArtifacts = GitDiffSnapshotStore.primaryArtifacts(
                    snapshotDir: snapshotDirRel,
                    mapRelativePath: artifacts.map,
                    allPatchRelativePath: artifacts.allPatch
                )
                let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(paths: primaryArtifacts.selectionCandidates)
                let summary = summaryDTO(summary: manifest.summary, files: manifest.files)
                let emptyReason = GitDiffMapBuilder.emptyReason(
                    summary: manifest.summary,
                    scope: manifest.scope,
                    requestedPaths: manifest.requestedPaths,
                    compareRaw: manifest.compare
                )

                return Reply(
                    op: "diff",
                    status: nil,
                    diff: Reply.DiffDTO(
                        compare: compare.resolved,
                        detail: nil,
                        files: nil,
                        totals: Reply.TotalsDTO(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
                        byStatus: summary.byStatus,
                        oneliner: oneliner(files: summary.files, insertions: summary.insertions, deletions: summary.deletions),
                        truncated: nil,
                        truncationNote: nil
                    ),
                    log: nil, show: nil, blame: nil,
                    worktree: primaryWorktree,
                    snapshotId: snapshotID,
                    snapshotDir: snapshotDirRel,
                    artifacts: artifacts,
                    primaryArtifacts: primaryArtifactsDTO(snapshotDir: snapshotDirRel, artifacts: artifacts, manifest: manifest, autoSelectedPaths: autoSelectedPrimaryArtifacts),
                    summary: summary,
                    oneliner: "\(summary.files) files (+\(summary.insertions) -\(summary.deletions)) | \(snapshotDirRel)",
                    inputs: Reply.DiffInputsDTO(
                        compare: manifest.compare,
                        compareInput: manifest.compareInput,
                        scope: manifest.scope.rawValue,
                        requestedPathsCount: manifest.requestedPaths?.count,
                        contextLines: manifest.contextLines,
                        detectRenames: manifest.detectRenames
                    ),
                    modeDetails: GitDiffMapBuilder.modeDetails(for: mode),
                    inline: inlineDTO(snapshotDirURL: snapshotDirURL, inlineMap: inlineMap, inlineMode: inlineMode, inlineMaxLines: inlineMaxLines),
                    warning: combinedWarning,
                    emptyReason: emptyReason,
                    error: nil
                )
            }

            // Non-artifact diff
            let engine = GitDiffEngine.shared
            let includesHunks = effectiveDetail == "patches" || effectiveDetail == "full"

            // Multi-root non-artifact diff
            if isMultiRepo {
                var perRepoResults: [Reply.RepoResultDTO] = []
                var collectedDiffs: [Reply.DiffDTO] = []

                for repo in repos {
                    do {
                        let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
                        let repoWorktree = await buildWorktreeDTO(for: repo.rootURL)

                        let buildResult = try await engine.buildSnapshotInputs(
                            compare: repoCompare.spec,
                            pathspecs: pathspecs,
                            repoURL: repo.rootURL,
                            contextLines: contextLines,
                            detectRenames: detectRenames,
                            generateDiffText: includesHunks
                        )

                        let totalFiles = buildResult.summary.files
                        let totalInsertions = buildResult.summary.insertions
                        let totalDeletions = buildResult.summary.deletions
                        let byStatus = statusBreakdown(from: buildResult.changedFiles)

                        var files: [Reply.DiffFileDTO]?
                        var truncated: Bool?
                        var truncationNote: String?

                        if effectiveDetail == "files" || includesHunks {
                            files = diffFileDTOsWithoutHunks(from: buildResult.changedFiles)
                        }

                        if includesHunks, let _ = buildResult.diffText {
                            let perFile = buildResult.perFile ?? [:]
                            let parsedFiles = parsedFileHunks(from: buildResult.changedFiles, perFilePatches: perFile)

                            let truncResult = GitDiffPatchParsing.truncatePatches(files: parsedFiles, maxLines: maxLinesForPatches)
                            truncated = truncResult.truncated
                            truncationNote = truncResult.note

                            var truncatedFiles: [Reply.DiffFileDTO] = []
                            truncatedFiles.reserveCapacity(truncResult.files.count)
                            for file in truncResult.files {
                                truncatedFiles.append(Reply.DiffFileDTO(
                                    path: file.path,
                                    status: file.status,
                                    insertions: file.insertions,
                                    deletions: file.deletions,
                                    hunks: hunkDTOs(from: file.hunks, nilWhenEmpty: false)
                                ))
                            }
                            files = truncatedFiles
                        }

                        let diffDTO = Reply.DiffDTO(
                            compare: repoCompare.resolved,
                            detail: effectiveDetail,
                            files: files,
                            totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
                            byStatus: byStatus,
                            oneliner: oneliner(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
                            truncated: truncated,
                            truncationNote: truncationNote
                        )
                        collectedDiffs.append(diffDTO)

                        perRepoResults.append(Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            diff: diffDTO,
                            worktree: repoWorktree
                        ))
                    } catch {
                        perRepoResults.append(Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            error: error.localizedDescription
                        ))
                    }
                }

                let aggregate = aggregateDTO(from: collectedDiffs, repoCount: repos.count)
                return Reply(op: "diff", repos: perRepoResults, aggregate: aggregate)
            }

            // Single repo non-artifact diff (legacy behavior)
            let compare = try await resolveCompareSpec(compareRaw)

            // Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
            let normalizedResult = await vcsService.normalizeCompareSpec(compare.spec, at: repoURL)
            let diffWarning = normalizedResult.warning
            let combinedWarning = combineWarnings([diffWarning, worktreeWarning])

            let buildResult = try await engine.buildSnapshotInputs(
                compare: compare.spec,
                pathspecs: pathspecs,
                repoURL: repoURL,
                contextLines: contextLines,
                detectRenames: detectRenames,
                generateDiffText: includesHunks
            )

            let totalFiles = buildResult.summary.files
            let totalInsertions = buildResult.summary.insertions
            let totalDeletions = buildResult.summary.deletions
            let byStatus = statusBreakdown(from: buildResult.changedFiles)

            var files: [Reply.DiffFileDTO]?
            var truncated: Bool?
            var truncationNote: String?

            if effectiveDetail == "files" || includesHunks {
                files = diffFileDTOsWithoutHunks(from: buildResult.changedFiles)
            }

            if includesHunks, buildResult.diffText != nil {
                let perFile = buildResult.perFile ?? [:]
                let parsedFiles = parsedFileHunks(from: buildResult.changedFiles, perFilePatches: perFile)

                let truncResult = GitDiffPatchParsing.truncatePatches(files: parsedFiles, maxLines: maxLinesForPatches)
                truncated = truncResult.truncated
                truncationNote = truncResult.note

                var truncatedFiles: [Reply.DiffFileDTO] = []
                truncatedFiles.reserveCapacity(truncResult.files.count)
                for file in truncResult.files {
                    truncatedFiles.append(Reply.DiffFileDTO(
                        path: file.path,
                        status: file.status,
                        insertions: file.insertions,
                        deletions: file.deletions,
                        hunks: hunkDTOs(from: file.hunks, nilWhenEmpty: false)
                    ))
                }
                files = truncatedFiles
            }

            return Reply(
                op: "diff",
                status: nil,
                diff: Reply.DiffDTO(
                    compare: compare.resolved,
                    detail: effectiveDetail,
                    files: files,
                    totals: Reply.TotalsDTO(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
                    byStatus: byStatus,
                    oneliner: oneliner(files: totalFiles, insertions: totalInsertions, deletions: totalDeletions),
                    truncated: truncated,
                    truncationNote: truncationNote
                ),
                log: nil, show: nil, blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: combinedWarning, emptyReason: nil, error: nil
            )
        }
    }

    private func relativePath(from base: URL, to url: URL) -> String {
        let basePath = (base.path as NSString).standardizingPath
        let targetPath = (url.path as NSString).standardizingPath
        if targetPath.hasPrefix(basePath) {
            var rel = String(targetPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.path
    }

    private func resolveGitRepoURL(preferredRootPath: String?) async throws -> URL {
        let vcsService = VCSService.shared
        var candidates: [String] = []
        if let preferredRootPath, !preferredRootPath.isEmpty {
            candidates.append(preferredRootPath)
        }
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace).map(\.standardizedFullPath)
        candidates.append(contentsOf: visibleRoots)
        var seen = Set<String>()
        for path in candidates {
            let standardized = (path as NSString).standardizingPath
            let key = standardized.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
                return resolved.rootURL
            }
        }
        throw MCPError.invalidParams("No VCS repository found in loaded roots.")
    }

    // MARK: - Multi-root git helpers

    /// Discover all git repos from visible root folders.
    /// - Returns: Array of GitRepoDescriptor for all discovered repos
    private func discoverAllGitRepos(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async throws -> [GitRepoDescriptor] {
        let vcsService = VCSService.shared
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: rootScope)

        var seenPaths = Set<String>()
        var repos: [GitRepoDescriptor] = []

        for folder in visibleRoots {
            let standardized = folder.standardizedFullPath
            let key = standardized.lowercased()
            guard seenPaths.insert(key).inserted else { continue }

            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
                let repoPath = (resolved.rootURL.path as NSString).standardizingPath
                let repoKey = repoPath.lowercased()
                // Only add if we haven't seen this repo root yet
                if !repos.contains(where: { $0.rootPath.lowercased() == repoKey }) {
                    repos.append(GitRepoDescriptor(rootURL: resolved.rootURL))
                }
            }
        }

        return repos
    }

    /// Resolve the default git repo (first loaded root's repo).
    /// - Returns: The first git repo found from visible roots in order
    private func resolveDefaultGitRepo(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async throws -> GitRepoDescriptor {
        let vcsService = VCSService.shared
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: rootScope)
        // Return the first visible root that is inside a VCS repo
        for folder in visibleRoots {
            let standardized = folder.standardizedFullPath
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) {
                return GitRepoDescriptor(rootURL: resolved.rootURL)
            }
        }

        throw MCPError.invalidParams("No VCS repository found in loaded roots.")
    }

    /// Group absolute paths by their owning repo
    /// - Parameters:
    ///   - paths: Absolute file paths to group
    ///   - repos: Available repo descriptors
    /// - Returns: Dictionary mapping repo to its paths
    private func groupAbsolutePathsByRepo(
        paths: [String],
        repos: [GitRepoDescriptor]
    ) -> [GitRepoDescriptor: [String]] {
        var result: [GitRepoDescriptor: [String]] = [:]
        for repo in repos {
            result[repo] = []
        }

        for path in paths {
            let standardized = (path as NSString).standardizingPath
            // Find the repo with the longest matching prefix
            var bestMatch: GitRepoDescriptor?
            var bestLength = 0
            for repo in repos {
                if repo.contains(absolutePath: standardized) {
                    if repo.rootPath.count > bestLength {
                        bestMatch = repo
                        bestLength = repo.rootPath.count
                    }
                }
            }
            if let match = bestMatch {
                result[match, default: []].append(standardized)
            }
        }

        return result
    }

    private func owningRepo(forAbsolutePath path: String, repos: [GitRepoDescriptor]) -> GitRepoDescriptor? {
        var bestMatch: GitRepoDescriptor?
        var bestLength = 0
        for repo in repos {
            if repo.contains(absolutePath: path), repo.rootPath.count > bestLength {
                bestMatch = repo
                bestLength = repo.rootPath.count
            }
        }
        return bestMatch
    }

    /// Parse repo_root and repo_roots args into explicit root paths
    private func parseExplicitRepoRoots(from args: [String: Value]) -> [String]? {
        var roots: [String] = []

        // Single repo_root
        if let single = args["repo_root"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty
        {
            roots.append(single)
        }

        // Array of repo_roots
        if let arr = args["repo_roots"]?.arrayValue {
            for item in arr {
                if let path = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty
                {
                    roots.append(path)
                }
            }
        }

        return roots.isEmpty ? nil : roots
    }
}
