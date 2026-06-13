import Foundation
import JSONSchema
import MCP
import Ontology

@MainActor
private final class MCPGitRequestContext {
    typealias WorktreeDTO = ToolResultDTOs.GitToolReplyDTO.WorktreeDTO

    let rootRefs: [WorkspaceRootRef]

    private let vcsService: VCSService
    private var discoveredRepos: [GitRepoDescriptor]?
    private var backendsByPath: [String: any VCSBackend] = [:]
    private var resolvedBranchPaths: Set<String> = []
    private var branchesByPath: [String: String] = [:]
    private var resolvedHeadPaths: Set<String> = []
    private var headsByPath: [String: String] = [:]
    private var resolvedWorktreePaths: Set<String> = []
    private var worktreesByPath: [String: WorktreeDTO] = [:]
    private var resolvedMainBranchPaths: Set<String> = []
    private var mainBranchesByPath: [String: String] = [:]

    init(rootRefs: [WorkspaceRootRef], vcsService: VCSService) {
        self.rootRefs = rootRefs
        self.vcsService = vcsService
    }

    func allRepos() async -> [GitRepoDescriptor] {
        if let discoveredRepos { return discoveredRepos }

        var seenRoots = Set<String>()
        var seenRepos = Set<String>()
        var repos: [GitRepoDescriptor] = []
        for root in rootRefs {
            let standardized = root.standardizedFullPath
            let rootKey = standardized.lowercased()
            guard seenRoots.insert(rootKey).inserted else { continue }
            guard let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: standardized)) else { continue }
            let repo = GitRepoDescriptor(rootURL: resolved.rootURL)
            guard seenRepos.insert(repo.rootPath.lowercased()).inserted else { continue }
            repos.append(repo)
        }
        discoveredRepos = repos
        return repos
    }

    func backend(for repoURL: URL) async -> any VCSBackend {
        let key = pathKey(repoURL)
        if let backend = backendsByPath[key] { return backend }
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        backendsByPath[key] = backend
        return backend
    }

    func currentBranch(for repoURL: URL) async -> String? {
        let key = pathKey(repoURL)
        if resolvedBranchPaths.contains(key) { return branchesByPath[key] }
        let backend = await backend(for: repoURL)
        let branch = try? await backend.getCurrentBranch(at: repoURL)
        resolvedBranchPaths.insert(key)
        branchesByPath[key] = branch
        return branch
    }

    func repositoryStatus(for repoURL: URL) async throws -> VCSRepositoryStatus {
        let backend = await backend(for: repoURL)
        let status = try await backend.getRepositoryStatus(at: repoURL)
        let key = pathKey(repoURL)
        resolvedBranchPaths.insert(key)
        branchesByPath[key] = status.branch
        if let headID = status.headID {
            resolvedHeadPaths.insert(key)
            headsByPath[key] = headID
        }
        return status
    }

    func headID(for repoURL: URL) async -> String? {
        let key = pathKey(repoURL)
        if resolvedHeadPaths.contains(key) { return headsByPath[key] }
        let backend = await backend(for: repoURL)
        let head = try? await backend.getHeadID(at: repoURL)
        resolvedHeadPaths.insert(key)
        headsByPath[key] = head
        return head
    }

    func normalizeCompareSpec(_ spec: GitDiffCompareSpec, at repoURL: URL) async -> NormalizedCompareResult {
        let backend = await backend(for: repoURL)
        if let withWarnings = backend as? VCSBackendWithWarnings {
            return withWarnings.normalizeCompareSpecWithWarning(spec)
        }
        return NormalizedCompareResult(spec: backend.normalizeCompareSpec(spec), warning: nil)
    }

    func mainBranchRef(for repoURL: URL) async -> String? {
        let key = pathKey(repoURL)
        if resolvedMainBranchPaths.contains(key) { return mainBranchesByPath[key] }

        let backend = await backend(for: repoURL)
        let remoteBranches = await (try? backend.getRemoteBranches(at: repoURL, limit: 200).map(\.name)) ?? []
        let localBranches = await (try? backend.getLocalBranches(at: repoURL, limit: 200).map(\.name)) ?? []

        func pick(_ candidates: [String], in list: [String]) -> String? {
            candidates.first(where: list.contains)
        }

        var branch = pick(["origin/main", "upstream/main"], in: remoteBranches)
            ?? pick(["main"], in: localBranches)
            ?? pick(["origin/master", "upstream/master"], in: remoteBranches)
            ?? pick(["master"], in: localBranches)
        if branch == nil, let upstream = try? await backend.getUpstreamRef(at: repoURL), !upstream.isEmpty {
            branch = upstream
        }
        resolvedMainBranchPaths.insert(key)
        mainBranchesByPath[key] = branch
        return branch
    }

    func worktreeDTO(for repoURL: URL) async -> WorktreeDTO? {
        let key = pathKey(repoURL)
        if resolvedWorktreePaths.contains(key) { return worktreesByPath[key] }
        resolvedWorktreePaths.insert(key)

        let backend = await backend(for: repoURL)
        guard backend.kind == .git else { return nil }
        guard let layout = await vcsService.gitRepositoryLayout(forRepoRoot: repoURL), layout.isLinkedWorktree else { return nil }

        let listedMainRoot = try? await vcsService.listGitWorktrees(at: repoURL)
            .first(where: \.isMain)
            .map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        let mainRoot = listedMainRoot ?? GitRepoTargetResolver.resolveMainWorktreeRoot(for: layout)
        let worktreeBranch = await currentBranch(for: repoURL)
        let worktreeHead = await (headID(for: repoURL)).map { String($0.prefix(7)) }
        var mainBranch: String?
        var mainHead: String?
        if let mainRoot {
            mainBranch = await currentBranch(for: mainRoot)
            mainHead = await (headID(for: mainRoot)).map { String($0.prefix(7)) }
        }
        let worktree = WorktreeDTO(
            isWorktree: true,
            worktreeName: layout.gitDir.lastPathComponent.isEmpty ? nil : layout.gitDir.lastPathComponent,
            worktreeRoot: layout.workTreeRoot.path,
            commonGitDir: layout.commonDir.path,
            mainWorktreeRoot: mainRoot?.path,
            worktreeBranch: worktreeBranch,
            mainBranch: mainBranch,
            worktreeHead: worktreeHead,
            mainHead: mainHead
        )
        worktreesByPath[key] = worktree
        return worktree
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}

private struct MCPGitArtifactRepoOutcome {
    typealias Reply = ToolResultDTOs.GitToolReplyDTO

    let result: Reply.RepoResultDTO
    let diff: Reply.DiffDTO?
    let manifest: GitDiffSnapshotManifest?
    let snapshotDir: String?
    let publishedSnapshotPath: String?
    let primaryArtifactCandidates: [String]
}

private struct MCPGitDiffRepoOutcome {
    typealias Reply = ToolResultDTOs.GitToolReplyDTO

    let result: Reply.RepoResultDTO
    let diff: Reply.DiffDTO?
}

@MainActor
final class MCPGitToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .git

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    private nonisolated static let maxConcurrentRepositories = 3

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

    nonisolated static func makeStatusDTO(
        _ status: VCSRepositoryStatus
    ) -> ToolResultDTOs.GitToolReplyDTO.StatusDTO {
        var parts: [String] = []
        if let branch = status.branch { parts.append(branch) }
        if let ahead = status.ahead, let behind = status.behind {
            parts.append("+\(ahead) -\(behind)")
        }
        let workingStatus = status.workingStatus
        let counts = [
            workingStatus.staged.isEmpty ? nil : "\(workingStatus.staged.count) staged",
            workingStatus.modified.isEmpty ? nil : "\(workingStatus.modified.count) modified",
            workingStatus.untracked.isEmpty ? nil : "\(workingStatus.untracked.count) untracked"
        ].compactMap(\.self)
        if !counts.isEmpty {
            parts.append(counts.joined(separator: ", "))
        }
        return ToolResultDTOs.GitToolReplyDTO.StatusDTO(
            branch: status.branch,
            upstream: status.upstream,
            ahead: status.ahead,
            behind: status.behind,
            staged: workingStatus.staged,
            modified: workingStatus.modified,
            untracked: workingStatus.untracked,
            summary: parts.joined(separator: " | ")
        )
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
            let reply = try await executeGitTool(args: args, connectionID: connectionID)
            return try await MCPProviderProjectionWorker.encode(
                reply,
                toolName: MCPWindowToolName.git
            )
        }
    }

    private func executeGitTool(args: [String: Value], connectionID: UUID?) async throws -> ToolResultDTOs.GitToolReplyDTO {
        let operation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "status"
        return try await MCPToolWorkCountDiagnostics.withGitInvocation(operation: operation) { [self] in
            try await executeGitToolBody(args: args, connectionID: connectionID)
        }
    }

    private func executeGitToolBody(args: [String: Value], connectionID: UUID?) async throws -> ToolResultDTOs.GitToolReplyDTO {
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
        let requestContext = MCPGitRequestContext(rootRefs: visibleRoots, vcsService: vcsService)
        let allRepos = await requestContext.allRepos()
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
            guard let defaultRepo = allRepos.first else {
                throw MCPError.invalidParams("No VCS repository found in loaded roots.")
            }
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

        // Tool-level admission is keyed by every repository touched by this request. WI-9's
        // lower-level global/per-repository subprocess controller remains independently active.
        let gitAdmissionLease = try await MCPGitToolAdmissionController.shared.acquire(
            repositoryRoots: repos.map(\.rootURL)
        )
        defer { MCPGitToolAdmissionController.shared.release(gitAdmissionLease) }

        // For now, use primary repo for single-repo operations
        // Multi-root execution will be implemented for operations that benefit from it (status, diff)
        MCPToolWorkCountDiagnostics.setGitRepositories(repos.map(\.repoKey))
        let primaryRepo = repos[0]
        let repoURL = primaryRepo.rootURL
        let isMultiRepo = repos.count > 1
        func buildWorktreeWarning(from worktree: Reply.WorktreeDTO?) -> String? {
            Self.worktreeWarning(from: worktree)
        }

        func combineWarnings(_ warnings: [String?]) -> String? {
            let merged = warnings.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return merged.isEmpty ? nil : merged.joined(separator: "\n")
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

        @Sendable func looksLikeSnapshotID(_ value: String) -> Bool {
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

        @Sendable func resolveCompareSpec(_ compareRaw: String) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
            try await resolveCompareSpec(compareRaw, for: primaryRepo)
        }

        @Sendable func resolveCompareSpec(_ compareRaw: String, for repo: GitRepoDescriptor) async throws -> (spec: GitDiffCompareSpec, resolved: String, input: String?) {
            let trimmed = compareRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawInput = trimmed.isEmpty ? "uncommitted" : trimmed
            let lowered = rawInput.lowercased()

            if lowered == "main" || lowered == "trunk" {
                guard let mainRef = await requestContext.mainBranchRef(for: repo.rootURL) else {
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
                        guard let mainRef = await requestContext.mainBranchRef(for: repo.rootURL) else {
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
            if isMultiRepo {
                let perRepoResults = await BoundedOrderedConcurrentMap.map(
                    repos,
                    maxConcurrent: Self.maxConcurrentRepositories
                ) { repo in
                    do {
                        let status = try await requestContext.repositoryStatus(for: repo.rootURL)
                        let repoWorktree = await requestContext.worktreeDTO(for: repo.rootURL)
                        return Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            status: Self.makeStatusDTO(status),
                            worktree: repoWorktree
                        )
                    } catch {
                        return Reply.RepoResultDTO(
                            repoRoot: repo.rootPath,
                            repoKey: repo.repoKey,
                            repoName: repo.displayName,
                            error: error.localizedDescription
                        )
                    }
                }
                return Reply(op: "status", repos: perRepoResults)
            }

            let status = try await requestContext.repositoryStatus(for: repoURL)
            let primaryWorktree = await requestContext.worktreeDTO(for: repoURL)
            return Reply(
                op: "status",
                status: Self.makeStatusDTO(status),
                diff: nil, log: nil, show: nil, blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: buildWorktreeWarning(from: primaryWorktree),
                emptyReason: nil, error: nil
            )

        // MARK: - Log

        case .log:
            let count = args["count"]?.intValue ?? 10
            let path = args["path"]?.stringValue.map { lookupContext.translateInputPath($0) }
            let logBackend = await requestContext.backend(for: repoURL)
            let commits = try await logBackend.getLogSummaries(count: count, path: path, at: repoURL)
            let logDTO = try await MCPGitToolProjection.makeLogDTO(commits)
            // Warn if multiple repos detected but log only runs on primary
            let primaryWorktree = await requestContext.worktreeDTO(for: repoURL)
            let logWarning: String? = isMultiRepo ? "Multiple repos detected; op 'log' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
            let combinedWarning = combineWarnings([logWarning, buildWorktreeWarning(from: primaryWorktree)])
            return Reply(
                op: "log",
                status: nil,
                diff: nil,
                log: logDTO,
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
            let showBackend = await requestContext.backend(for: repoURL)
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

            let diffText: String? = if detail == "full" {
                try await showBackend.getDiffText(
                    compare: .revspec(revspec),
                    paths: nil,
                    contextLines: contextLines,
                    detectRenames: detectRenames,
                    at: repoURL
                )
            } else {
                nil
            }
            let showDTO = try await MCPGitToolProjection.makeShowDTO(
                commitInfo: commitInfo,
                changedFiles: changedFiles,
                detail: detail,
                diffText: diffText
            )

            // Warn if multiple repos detected but show only runs on primary
            let primaryWorktree = await requestContext.worktreeDTO(for: repoURL)
            let showWarning: String? = isMultiRepo ? "Multiple repos detected; op 'show' ran against \(primaryRepo.displayName). Provide repo_root to target a specific repo." : nil
            let combinedWarning = combineWarnings([showWarning, buildWorktreeWarning(from: primaryWorktree)])
            return Reply(
                op: "show",
                status: nil, diff: nil, log: nil,
                show: showDTO,
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

            let blameBackend = await requestContext.backend(for: targetRepoURL)
            let blameLines = try await blameBackend.blame(path: path, lineRange: lineRange, at: targetRepoURL)
            let blameWorktree = await requestContext.worktreeDTO(for: targetRepoURL)
            let combinedWarning = combineWarnings([blameWarning, buildWorktreeWarning(from: blameWorktree)])
            let blameDTO = try await MCPGitToolProjection.makeBlameDTO(path: path, lines: blameLines)
            return Reply(
                op: "blame",
                status: nil, diff: nil, log: nil, show: nil,
                blame: blameDTO,
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
                    let tabID = dependencies.boundTabID(connectionID)

                    // Group selection paths by repo
                    let pathsByRepo = scope == .selected ? groupAbsolutePathsByRepo(paths: allSelectedAbsolutePaths, repos: repos) : [:]
                    let outcomes = await BoundedOrderedConcurrentMap.map(
                        repos,
                        maxConcurrent: Self.maxConcurrentRepositories
                    ) { repo in
                        do {
                            let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
                            let repoWorktree = await requestContext.worktreeDTO(for: repo.rootURL)
                            let repoSelectedPaths = scope == .selected ? (pathsByRepo[repo] ?? []) : []
                            if scope == .selected, repoSelectedPaths.isEmpty {
                                return MCPGitArtifactRepoOutcome(
                                    result: Reply.RepoResultDTO(
                                        repoRoot: repo.rootPath,
                                        repoKey: repo.repoKey,
                                        repoName: repo.displayName,
                                        worktree: repoWorktree,
                                        emptyReason: "No selected paths in this repo"
                                    ),
                                    diff: nil,
                                    manifest: nil,
                                    snapshotDir: nil,
                                    publishedSnapshotPath: nil,
                                    primaryArtifactCandidates: []
                                )
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
                            let snapshotDirURL = store.snapshotDir(
                                workspaceDirectory: workspaceDirectory,
                                repoKey: repo.repoKey,
                                snapshotID: snapshotID
                            )
                            let snapshotDirRel = store.snapshotRelativePath(repoKey: repo.repoKey, snapshotID: snapshotID)
                            let projection = try await MCPGitToolProjection.makeArtifactProjection(
                                snapshotDirURL: snapshotDirURL,
                                snapshotDir: snapshotDirRel,
                                manifest: manifest,
                                compareDisplay: repoCompare.resolved,
                                mode: mode,
                                inlineMap: inlineMap,
                                inlineMode: inlineMode,
                                inlineMaxLines: inlineMaxLines
                            )
                            return MCPGitArtifactRepoOutcome(
                                result: Reply.RepoResultDTO(
                                    repoRoot: repo.rootPath,
                                    repoKey: repo.repoKey,
                                    repoName: repo.displayName,
                                    diff: projection.diff,
                                    worktree: repoWorktree,
                                    snapshotId: snapshotID,
                                    snapshotDir: snapshotDirRel,
                                    artifacts: projection.artifacts,
                                    summary: projection.summary,
                                    oneliner: projection.oneliner,
                                    inputs: projection.inputs,
                                    modeDetails: projection.modeDetails,
                                    inline: projection.inline,
                                    emptyReason: projection.emptyReason
                                ),
                                diff: projection.diff,
                                manifest: manifest,
                                snapshotDir: snapshotDirRel,
                                publishedSnapshotPath: snapshotDirURL.path,
                                primaryArtifactCandidates: projection.primaryArtifactCandidates
                            )
                        } catch {
                            return MCPGitArtifactRepoOutcome(
                                result: Reply.RepoResultDTO(
                                    repoRoot: repo.rootPath,
                                    repoKey: repo.repoKey,
                                    repoName: repo.displayName,
                                    error: error.localizedDescription
                                ),
                                diff: nil,
                                manifest: nil,
                                snapshotDir: nil,
                                publishedSnapshotPath: nil,
                                primaryArtifactCandidates: []
                            )
                        }
                    }

                    let perRepoResults = outcomes.map(\.result)
                    let collectedDiffs = outcomes.compactMap(\.diff)
                    let publishedSnapshotPaths = outcomes.compactMap(\.publishedSnapshotPath)
                    let primaryArtifactCandidates = outcomes.flatMap(\.primaryArtifactCandidates)
                    var manifestsBySnapshotDir: [String: GitDiffSnapshotManifest] = [:]
                    for outcome in outcomes {
                        if let snapshotDir = outcome.snapshotDir, let manifest = outcome.manifest {
                            manifestsBySnapshotDir[snapshotDir] = manifest
                        }
                    }

                    await dependencies.ensureGitDataRootLoaded(workspace, workspaceManager)
                    if let publishedSnapshotPath = publishedSnapshotPaths.first {
                        _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                            userPath: publishedSnapshotPath,
                            fallbackScope: .visibleWorkspacePlusGitData
                        )
                    }
                    let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(paths: primaryArtifactCandidates)
                    let decoratedRepoResults = try await MCPGitToolProjection.decorateArtifactRepoResults(
                        perRepoResults,
                        manifestsBySnapshotDir: manifestsBySnapshotDir,
                        autoSelectedPaths: autoSelectedPrimaryArtifacts
                    )
                    let aggregate = try await MCPGitToolProjection.makeAggregateDTO(
                        from: collectedDiffs,
                        repoCount: repos.count
                    )
                    return Reply(op: "diff", repos: decoratedRepoResults, aggregate: aggregate)
                }

                // Single repo artifact diff (legacy behavior)
                let compare = try await resolveCompareSpec(compareRaw)

                // Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
                let normalizedResult = await requestContext.normalizeCompareSpec(compare.spec, at: repoURL)
                let artifactDiffWarning = normalizedResult.warning

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

                let snapshotID = manifest.snapshotID
                let snapshotDirURL = store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
                await dependencies.ensureGitDataRootLoaded(workspace, workspaceManager)
                _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                    userPath: snapshotDirURL.path,
                    fallbackScope: .visibleWorkspacePlusGitData
                )
                let snapshotDirRel = store.snapshotRelativePath(repoKey: primaryRepo.repoKey, snapshotID: snapshotID)
                let projection = try await MCPGitToolProjection.makeArtifactProjection(
                    snapshotDirURL: snapshotDirURL,
                    snapshotDir: snapshotDirRel,
                    manifest: manifest,
                    compareDisplay: compare.resolved,
                    mode: mode,
                    inlineMap: inlineMap,
                    inlineMode: inlineMode,
                    inlineMaxLines: inlineMaxLines
                )
                let autoSelectedPrimaryArtifacts = await autoSelectPrimaryGitDiffArtifacts(
                    paths: projection.primaryArtifactCandidates
                )
                let primaryArtifacts = try await MCPGitToolProjection.makePrimaryArtifactsDTO(
                    snapshotDir: snapshotDirRel,
                    artifacts: projection.artifacts,
                    manifest: manifest,
                    autoSelectedPaths: autoSelectedPrimaryArtifacts
                )
                let primaryWorktree = await requestContext.worktreeDTO(for: repoURL)
                let combinedWarning = combineWarnings([artifactDiffWarning, buildWorktreeWarning(from: primaryWorktree)])

                return Reply(
                    op: "diff",
                    status: nil,
                    diff: projection.diff,
                    log: nil, show: nil, blame: nil,
                    worktree: primaryWorktree,
                    snapshotId: snapshotID,
                    snapshotDir: snapshotDirRel,
                    artifacts: projection.artifacts,
                    primaryArtifacts: primaryArtifacts,
                    summary: projection.summary,
                    oneliner: projection.oneliner,
                    inputs: projection.inputs,
                    modeDetails: projection.modeDetails,
                    inline: projection.inline,
                    warning: combinedWarning,
                    emptyReason: projection.emptyReason,
                    error: nil
                )
            }

            // Non-artifact diff
            let engine = GitDiffEngine.shared
            let includesHunks = effectiveDetail == "patches" || effectiveDetail == "full"

            // Multi-root non-artifact diff
            if isMultiRepo {
                let outcomes = await BoundedOrderedConcurrentMap.map(
                    repos,
                    maxConcurrent: Self.maxConcurrentRepositories
                ) { repo in
                    do {
                        let repoCompare = try await resolveCompareSpec(compareRaw, for: repo)
                        let repoWorktree = await requestContext.worktreeDTO(for: repo.rootURL)
                        let buildResult = try await engine.buildSnapshotInputs(
                            compare: repoCompare.spec,
                            pathspecs: pathspecs,
                            repoURL: repo.rootURL,
                            contextLines: contextLines,
                            detectRenames: detectRenames,
                            generateDiffText: includesHunks
                        )
                        let diffDTO = try await MCPGitToolProjection.makeDiffDTO(
                            compare: repoCompare.resolved,
                            detail: effectiveDetail,
                            changedFiles: buildResult.changedFiles,
                            perFilePatches: includesHunks ? buildResult.perFile : nil,
                            maxLinesForPatches: maxLinesForPatches
                        )
                        return MCPGitDiffRepoOutcome(
                            result: Reply.RepoResultDTO(
                                repoRoot: repo.rootPath,
                                repoKey: repo.repoKey,
                                repoName: repo.displayName,
                                diff: diffDTO,
                                worktree: repoWorktree
                            ),
                            diff: diffDTO
                        )
                    } catch {
                        return MCPGitDiffRepoOutcome(
                            result: Reply.RepoResultDTO(
                                repoRoot: repo.rootPath,
                                repoKey: repo.repoKey,
                                repoName: repo.displayName,
                                error: error.localizedDescription
                            ),
                            diff: nil
                        )
                    }
                }
                let perRepoResults = outcomes.map(\.result)
                let collectedDiffs = outcomes.compactMap(\.diff)

                let aggregate = try await MCPGitToolProjection.makeAggregateDTO(
                    from: collectedDiffs,
                    repoCount: repos.count
                )
                return Reply(op: "diff", repos: perRepoResults, aggregate: aggregate)
            }

            // Single repo non-artifact diff (legacy behavior)
            let compare = try await resolveCompareSpec(compareRaw)

            // Get normalization warning (e.g., staged/unstaged degraded to uncommitted for jj)
            let normalizedResult = await requestContext.normalizeCompareSpec(compare.spec, at: repoURL)
            let diffWarning = normalizedResult.warning

            let buildResult = try await engine.buildSnapshotInputs(
                compare: compare.spec,
                pathspecs: pathspecs,
                repoURL: repoURL,
                contextLines: contextLines,
                detectRenames: detectRenames,
                generateDiffText: includesHunks
            )

            let primaryWorktree = await requestContext.worktreeDTO(for: repoURL)
            let combinedWarning = combineWarnings([diffWarning, buildWorktreeWarning(from: primaryWorktree)])
            let diffDTO = try await MCPGitToolProjection.makeDiffDTO(
                compare: compare.resolved,
                detail: effectiveDetail,
                changedFiles: buildResult.changedFiles,
                perFilePatches: includesHunks ? buildResult.perFile : nil,
                maxLinesForPatches: maxLinesForPatches
            )

            return Reply(
                op: "diff",
                status: nil,
                diff: diffDTO,
                log: nil, show: nil, blame: nil,
                worktree: primaryWorktree,
                snapshotId: nil, snapshotDir: nil,
                artifacts: nil, summary: nil, oneliner: nil, inputs: nil, modeDetails: nil, inline: nil,
                warning: combinedWarning, emptyReason: nil, error: nil
            )
        }
    }

    // MARK: - Multi-root git helpers

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
