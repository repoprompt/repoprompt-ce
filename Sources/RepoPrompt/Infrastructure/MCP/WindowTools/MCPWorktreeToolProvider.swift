import Foundation
import JSONSchema
import MCP

@MainActor
final class MCPWorktreeToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .git

    private let runtime: MCPWindowToolRuntime
    let dependencies: MCPWindowToolDependencies
    private let vcsService: VCSService
    private let resolver: GitRepoTargetResolver

    init(
        runtime: MCPWindowToolRuntime,
        dependencies: MCPWindowToolDependencies,
        vcsService: VCSService = .shared,
        resolver: GitRepoTargetResolver = GitRepoTargetResolver()
    ) {
        self.runtime = runtime
        self.dependencies = dependencies
        self.vcsService = vcsService
        self.resolver = resolver
    }

    func buildTools() -> [Tool] {
        [manageWorktreeTool()]
    }

    private func manageWorktreeTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.manageWorktree,
            freshnessPolicy: .providerManaged,
            description: """
            Manage Git worktrees, per-agent-session worktree bindings, and session-bound worktree merges.

            **Management ops**: list | show | create | bind | select | unbind
            **Merge ops**: preview | apply | status | continue | abort

            **Selectors**:
            - `repo_root`: Optional loaded root path/name, git-style specifier such as `@main`, or merge source-binding disambiguator.
            - `worktree`: Worktree selector (`@current`, `@main`, `@branch:<name>`, name, branch, path, or `@id:<worktree_id>`).
            - `worktree_id`: Durable worktree ID alternative to `worktree`.
            - `target`: Merge preview target selector; defaults to `@main`.
            - `target_worktree_id`: Durable merge target ID alternative to `target`.

            **Session binding and merge source**:
            - `bind` and `select` persist a binding for one Agent session.
            - Merge ops use the Agent session's bound source worktree; `repo_root` disambiguates when multiple bindings exist.
            - `session_id` is optional only when MCP routing resolves an active Agent session; otherwise provide it explicitly.
            - `create` can also bind with `bind=true`; `unbind` removes the selected root binding, or all bindings with `all=true`.

            **Merge safety**:
            - `preview` is non-mutating and publishes bounded artifacts by default.
            - `apply` requires `operation_id`; plain MCP callers must pass `confirm_preview=true`.
            - Routed Agent Mode apply calls without confirmation request user approval before mutation.
            - `continue` and `abort` require `confirm=true` outside routed UI flows.

            **Visual identity**:
            - `label`, `color`, `icon_name`, and `marker_style` are serialized with worktree identity on create/bind.
            - `color` must be `#RRGGBB`; `marker_style` is `dot`, `ring`, or `capsule`.

            **Output**:
            - Management op JSON includes repository/worktree IDs, visual identity, bindings, previous_binding on replacement, and graph placeholders.
            - Merge op JSON keeps merge details under the nested `merge` block.
            - Formatted output is compact and stable for humans.
            """,
            annotations: .repoPromptLocalDestructive,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Operation", enum: ["list", "show", "create", "bind", "select", "unbind", "preview", "apply", "status", "continue", "abort"]),
                    "repo_root": .string(description: "Optional loaded root path/name or repo/worktree specifier. Defaults to the first loaded Git repo."),
                    "repo_key": .string(description: "Optional repository key alternative to repo_root."),
                    "worktree": .string(description: "Worktree selector: @current, @main, @branch:<name>, branch/name/path, or @id:<worktree_id>."),
                    "worktree_id": .string(description: "Durable worktree ID alternative to worktree. Mutually exclusive with worktree."),
                    "session_id": .string(description: "Target Agent session for bind/select/unbind, or create with bind=true."),
                    "include_status": .boolean(description: "Include a compact dirty summary for each returned worktree. Default false."),
                    "persist_visuals": .boolean(description: "For list/show, persist fallback visual identities instead of returning deterministic fallbacks only."),
                    "branch": .string(description: "Create: branch name to create/check out."),
                    "base_ref": .string(description: "Create: optional base ref/commit for the new worktree."),
                    "path": .string(description: "Create: explicit absolute worktree path. External paths require allow_external_path=true."),
                    "detach": .boolean(description: "Create: create a detached worktree."),
                    "force": .boolean(description: "Create: pass --force to git worktree add."),
                    "allow_external_path": .boolean(description: "Create: allow explicit paths outside RepoPrompt's app-managed worktree container."),
                    "bind": .boolean(description: "Create: bind the created worktree to a target Agent session."),
                    "label": .string(description: "Create/bind: visual label to persist for this worktree."),
                    "color": .string(description: "Create/bind: visual color as #RRGGBB."),
                    "icon_name": .string(description: "Create/bind: SF Symbol name for future UI display."),
                    "marker_style": .string(description: "Create/bind: visual marker style", enum: ["dot", "ring", "capsule"]),
                    "all": .boolean(description: "Unbind: remove all worktree bindings for the session."),
                    "operation_id": .string(description: "Merge apply/status/continue/abort: operation ID returned by preview."),
                    "target": .string(description: "Merge preview: target worktree selector. Defaults to @main."),
                    "target_worktree_id": .string(description: "Merge preview: target worktree ID alternative to target."),
                    "commit_message": .string(description: "Merge apply/continue: optional merge commit message."),
                    "include_graph": .boolean(description: "Include bounded graph/visualization metadata. Merge ops default true; list/show default false."),
                    "graph_limit": .integer(description: "Graph/visualization line cap. Default 24; clamped to 1...200."),
                    "context_lines": .integer(description: "Merge preview: diff artifact context lines. Default 3; clamped to 0...20."),
                    "detect_renames": .boolean(description: "Merge preview: detect renames in preview artifacts. Default false."),
                    "publish_artifacts": .boolean(description: "Merge preview: publish preview artifacts. Default true."),
                    "confirm_preview": .boolean(description: "Merge apply: plain MCP confirmation. Required true outside routed Agent Mode approval flows."),
                    "confirm": .boolean(description: "Merge continue/abort: plain MCP confirmation. Required true outside routed UI flows.")
                ],
                required: ["op"]
            )
        ) { [self] _, args in
            try await Value(executeManageWorktree(args: args))
        }
    }

    // MARK: - Execution

    enum Operation: String {
        case list, show, create, bind, select, unbind
        case preview, apply, status, `continue`, abort
    }

    private func executeManageWorktree(args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        guard let opRaw = trimmedString(args["op"])?.lowercased() else {
            throw MCPError.invalidParams("op is required. Valid ops: list, show, create, bind, select, unbind, preview, apply, status, continue, abort")
        }
        guard let op = Operation(rawValue: opRaw) else {
            throw MCPError.invalidParams("Invalid op: \(opRaw). Valid ops: list, show, create, bind, select, unbind, preview, apply, status, continue, abort")
        }

        try validateArguments(args, for: op)
        try validateSelectorArguments(args)

        switch op {
        case .list:
            return try await executeList(args: args)
        case .show:
            return try await executeShow(args: args)
        case .create:
            return try await executeCreate(args: args)
        case .bind, .select:
            return try await executeBind(op: op, args: args)
        case .unbind:
            return try await executeUnbind(args: args)
        case .preview, .apply, .status, .continue, .abort:
            return try await executeMerge(op: op, args: args)
        }
    }

    private func executeList(args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let context = try await resolveRepositoryContext(args: args)
        let allWorktrees = try await vcsService.listGitWorktrees(at: context.repo.rootURL)
        // Stale (git-prunable) worktrees have a gitdir pointing to a non-existent location and are
        // not usable checkouts. Exclude them so a model never discovers/selects one; binding to a
        // stale worktree would crawl and search an empty or partial tree. They remain visible to
        // `git worktree list`/`prune` outside the tool.
        let worktrees = allWorktrees.filter { !$0.isPrunable }
        let omittedPrunableCount = allWorktrees.count - worktrees.count
        let includeStatus = parseBool(args["include_status"]) ?? false
        let persistVisuals = parseBool(args["persist_visuals"]) ?? false
        let dtos = try await worktrees.asyncMap { worktree in
            try await worktreeDTO(worktree, includeStatus: includeStatus, persistVisuals: persistVisuals)
        }
        let warning: String? = if dtos.isEmpty {
            "No worktrees found for repository."
        } else if omittedPrunableCount > 0 {
            "Omitted \(omittedPrunableCount) stale (prunable) worktree(s); run `git worktree prune` to remove them."
        } else {
            nil
        }
        return await ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "list",
            repository: repositoryDTO(
                from: worktrees.first?.repository ?? allWorktrees.first?.repository,
                fallback: context.repo
            ),
            worktrees: dtos,
            graph: graphDTOIfRequested(args: args, repoURL: context.repo.rootURL),
            warning: warning
        )
    }

    private func executeShow(args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let context = try await resolveRepositoryContext(args: args)
        let worktree = try await resolveWorktree(args: args, repo: context.repo, allRepos: context.allRepos, requireExplicit: false)
        let dto = try await worktreeDTO(
            worktree,
            includeStatus: parseBool(args["include_status"]) ?? false,
            persistVisuals: parseBool(args["persist_visuals"]) ?? false
        )
        return await ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "show",
            repository: repositoryDTO(from: worktree.repository, fallback: context.repo),
            worktree: dto,
            worktrees: [dto],
            graph: graphDTOIfRequested(args: args, repoURL: context.repo.rootURL)
        )
    }

    private func executeCreate(args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let context = try await resolveRepositoryContext(args: args)
        let bindAfterCreate = parseBool(args["bind"]) ?? false
        let sessionID = bindAfterCreate ? try await resolveBindingSessionID(args: args) : nil

        if let sessionID {
            try validateLiveSession(sessionID, in: dependencies.requireTargetWindow())
        }

        let existingWorktrees = try await vcsService.listGitWorktrees(at: context.repo.rootURL)
        let mainRootPath = existingWorktrees.first(where: \.isMain)?.path ?? context.repo.rootPath
        let explicitPath = try explicitCreatePath(from: args["path"])
        let plan = try GitWorktreeDefaultPathPlanner.plan(
            GitWorktreeDefaultPathPlanner.Request(
                mainWorktreeRoot: URL(fileURLWithPath: mainRootPath),
                existingWorktreeRoots: existingWorktrees.map { URL(fileURLWithPath: $0.path) },
                explicitPath: explicitPath,
                branch: trimmedString(args["branch"]),
                baseRef: trimmedString(args["base_ref"]),
                detach: parseBool(args["detach"]) ?? false,
                force: parseBool(args["force"]) ?? false,
                allowExternalPath: parseBool(args["allow_external_path"]) ?? false,
                purpose: .standaloneCreate(now: Date())
            )
        )

        let createResult = try await vcsService.createGitWorktreeWithResult(request: plan.createRequest, at: context.repo.rootURL)
        let created = createResult.descriptor
        let identity = try persistOrResolveVisualIdentity(
            for: created,
            args: args,
            persist: true
        )
        let createdDTO = try await worktreeDTO(created, visualIdentity: identity, includeStatus: parseBool(args["include_status"]) ?? false)

        var bindingDTO: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO?
        var previousDTO: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO?
        var bindingWarning: String?
        if let sessionID {
            do {
                let bindingResult = try await applyBinding(
                    sessionID: sessionID,
                    worktree: created,
                    context: context,
                    visualIdentity: identity,
                    args: args,
                    source: "manage_worktree.create"
                )
                bindingDTO = bindingResult.binding
                previousDTO = bindingResult.previous
            } catch {
                bindingWarning = "Worktree was created, but session binding failed: \(error.localizedDescription)"
            }
        }

        let includeCopyWarning = createResult.includeCopyResult?.warningText
        let fallbackBindingWarning = bindAfterCreate && bindingDTO == nil
            ? "Worktree created but no session binding was applied."
            : nil
        let warning = combinedWarnings([includeCopyWarning, bindingWarning, fallbackBindingWarning])

        return ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "create",
            repository: repositoryDTO(from: created.repository, fallback: context.repo),
            worktree: createdDTO,
            createdWorktree: createdDTO,
            binding: bindingDTO,
            previousBinding: previousDTO,
            warning: warning
        )
    }

    private func executeBind(op: Operation, args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let context = try await resolveRepositoryContext(args: args)
        let worktree = try await resolveWorktree(args: args, repo: context.repo, allRepos: context.allRepos, requireExplicit: true)
        let sessionID = try await resolveBindingSessionID(args: args)
        try validateLiveSession(sessionID, in: dependencies.requireTargetWindow())
        let identity = try persistOrResolveVisualIdentity(for: worktree, args: args, persist: true)
        let bindingResult = try await applyBinding(
            sessionID: sessionID,
            worktree: worktree,
            context: context,
            visualIdentity: identity,
            args: args,
            source: op == .select ? "manage_worktree.select" : "manage_worktree.bind"
        )
        let dto = try await worktreeDTO(worktree, visualIdentity: identity, includeStatus: parseBool(args["include_status"]) ?? false)
        return ToolResultDTOs.ManageWorktreeReplyDTO(
            op: op.rawValue,
            repository: repositoryDTO(from: worktree.repository, fallback: context.repo),
            worktree: dto,
            worktrees: [dto],
            binding: bindingResult.binding,
            previousBinding: bindingResult.previous
        )
    }

    private func executeUnbind(args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let sessionID = try await resolveBindingSessionID(args: args)
        let targetWindow = try dependencies.requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let existing = agentModeVM.worktreeBindings(forAgentSessionID: sessionID)
        let removeAll = parseBool(args["all"]) ?? false

        let remaining: [AgentSessionWorktreeBinding]
        let removed: [AgentSessionWorktreeBinding]
        if removeAll {
            remaining = []
            removed = existing
        } else if hasWorktreeSelector(args) {
            let context = try await resolveRepositoryContext(args: args)
            let worktree = try await resolveWorktree(args: args, repo: context.repo, allRepos: context.allRepos, requireExplicit: true)
            removed = existing.filter { $0.worktreeID == worktree.worktreeID }
            remaining = existing.filter { $0.worktreeID != worktree.worktreeID }
        } else {
            let context = try await resolveRepositoryContext(args: args)
            let logicalRoot = try await logicalRoot(for: context)
            let normalized = standardizedPath(logicalRoot.standardizedFullPath)
            removed = existing.filter { standardizedPath($0.logicalRootPath) == normalized }
            remaining = existing.filter { standardizedPath($0.logicalRootPath) != normalized }
        }

        _ = try await agentModeVM.transitionWorktreeBindings(
            remaining,
            forSessionID: sessionID,
            intent: .externalManagement
        )

        return ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "unbind",
            binding: removed.first.map(bindingDTO),
            bindings: removed.map(bindingDTO),
            warning: removed.isEmpty ? "No matching worktree binding was present for session \(sessionID.uuidString)." : nil
        )
    }

    // MARK: - Binding

    private func applyBinding(
        sessionID: UUID,
        worktree: GitWorktreeDescriptor,
        context: RepositoryContext,
        visualIdentity: WorktreeVisualIdentity,
        args: [String: Value],
        source: String
    ) async throws -> (binding: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO, previous: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO?) {
        let targetWindow = try dependencies.requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let logicalRoot = try await logicalRoot(for: context)
        let existing = agentModeVM.worktreeBindings(forAgentSessionID: sessionID)
        let normalizedRoot = standardizedPath(logicalRoot.standardizedFullPath)
        let previous = existing.first { standardizedPath($0.logicalRootPath) == normalizedRoot }

        if let previous,
           previous.worktreeID == worktree.worktreeID,
           trimmedString(args["label"]) == nil,
           trimmedString(args["color"]) == nil
        {
            return (bindingDTO(previous), nil)
        }

        let binding = AgentSessionWorktreeBinding(
            id: previous?.id ?? UUID().uuidString,
            repositoryID: worktree.repository.repositoryID,
            repoKey: worktree.repository.repoKey,
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktree.worktreeID,
            worktreeRootPath: worktree.path,
            worktreeName: worktree.name,
            branch: worktree.branch,
            head: worktree.head,
            visualLabel: visualIdentity.label,
            visualColorHex: visualIdentity.colorHex,
            boundAt: previous?.worktreeID == worktree.worktreeID ? previous?.boundAt ?? Date() : Date(),
            source: source
        )
        var desiredBindings = existing.filter { standardizedPath($0.logicalRootPath) != normalizedRoot }
        desiredBindings.append(binding)
        _ = try await agentModeVM.transitionWorktreeBindings(
            desiredBindings,
            forSessionID: sessionID,
            intent: .externalManagement
        )
        let previousDTO = previous.flatMap { $0.worktreeID == binding.worktreeID ? nil : bindingDTO($0) }
        return (bindingDTO(binding), previousDTO)
    }

    private func validateLiveSession(_ sessionID: UUID, in targetWindow: WindowState) throws {
        let agentModeVM = targetWindow.agentModeViewModel
        try agentModeVM.requireLiveAgentSession(sessionID)
    }

    private func resolveBindingSessionID(args: [String: Value]) async throws -> UUID {
        if let raw = trimmedString(args["session_id"]) {
            guard let uuid = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("session_id must be a UUID. Received: \(raw)")
            }
            return uuid
        }

        let metadata = await dependencies.captureRequestMetadata()
        let resolved = try dependencies.resolveTabContextSnapshot(
            metadata,
            MCPWindowToolName.manageWorktree,
            .allowLegacyImplicitRouting
        )
        guard let sessionID = resolved.snapshot.activeAgentSessionID else {
            throw MCPError.invalidParams("session_id is required because current MCP routing does not resolve an active Agent session.")
        }
        return sessionID
    }

    // MARK: - Repository and worktree resolution

    private struct RepositoryContext {
        let repo: GitRepoDescriptor
        let allRepos: [GitRepoDescriptor]
        let visibleRoots: [WorkspaceRootRef]
        let lookupContext: WorkspaceLookupContext
        let explicitLogicalRoot: WorkspaceRootRef?
    }

    private func resolveRepositoryContext(args: [String: Value]) async throws -> RepositoryContext {
        guard dependencies.workspaceManager?.activeWorkspace != nil else {
            throw MCPError.invalidParams("No active workspace in this window. Load a workspace before using manage_worktree.")
        }

        let metadata = await dependencies.captureRequestMetadata()
        let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: lookupContext.rootScope)
        let allRepos = try await discoverAllGitRepos(rootScope: lookupContext.rootScope)
        let defaultRepo = try await resolveDefaultGitRepo(rootScope: lookupContext.rootScope)
        let repo: GitRepoDescriptor
        var explicitLogicalRoot: WorkspaceRootRef?

        if let repoKey = trimmedString(args["repo_key"]) {
            guard let match = allRepos.first(where: { $0.repoKey == repoKey }) else {
                throw MCPError.invalidParams("repo_key not found: \(repoKey). Available: \(allRepos.map(\.repoKey).joined(separator: ", "))")
            }
            repo = match
        } else if let rawRepoRoot = trimmedString(args["repo_root"]) {
            if !rawRepoRoot.hasPrefix("@") {
                explicitLogicalRoot = explicitLogicalRootRef(for: rawRepoRoot, visibleRoots: visibleRoots, lookupContext: lookupContext)
            }
            let token = rawRepoRoot.hasPrefix("@") ? rawRepoRoot : lookupContext.translateInputPath(rawRepoRoot)
            do {
                repo = try await resolver.resolveRepoRootToken(
                    token,
                    allRepos: allRepos,
                    visibleRoots: visibleRoots,
                    defaultRepo: defaultRepo
                )
            } catch let error as GitRepoTargetResolverError {
                throw MCPError.invalidParams(error.message)
            }
        } else {
            repo = defaultRepo
        }

        return RepositoryContext(repo: repo, allRepos: allRepos, visibleRoots: visibleRoots, lookupContext: lookupContext, explicitLogicalRoot: explicitLogicalRoot)
    }

    private func resolveWorktree(
        args: [String: Value],
        repo: GitRepoDescriptor,
        allRepos: [GitRepoDescriptor],
        requireExplicit: Bool
    ) async throws -> GitWorktreeDescriptor {
        let selector = worktreeSelector(from: args)
        if requireExplicit, selector == nil {
            throw MCPError.invalidParams("worktree or worktree_id is required for this operation.")
        }
        do {
            return try await resolver.resolveWorktree(selector: selector, repo: repo, allRepos: allRepos)
        } catch let error as GitRepoTargetResolverError {
            throw MCPError.invalidParams(error.message)
        }
    }

    private func discoverAllGitRepos(rootScope: WorkspaceLookupRootScope) async throws -> [GitRepoDescriptor] {
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: rootScope)
        var repos: [GitRepoDescriptor] = []
        var seen = Set<String>()
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
                let key = descriptor.rootPath.lowercased()
                if seen.insert(key).inserted {
                    repos.append(descriptor)
                }
            }
        }
        return repos
    }

    private func resolveDefaultGitRepo(rootScope: WorkspaceLookupRootScope) async throws -> GitRepoDescriptor {
        let visibleRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(scope: rootScope)
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                return GitRepoDescriptor(rootURL: resolved.rootURL)
            }
        }
        throw MCPError.invalidParams("No Git repository found in loaded roots.")
    }

    private func explicitLogicalRootRef(
        for rawRepoRoot: String,
        visibleRoots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) -> WorkspaceRootRef? {
        let translated = lookupContext.translateInputPath(rawRepoRoot)
        let canonicalTranslated = standardizedPath(translated)
        let lowered = rawRepoRoot.lowercased()
        return visibleRoots.first { root in
            root.name.lowercased() == lowered
                || standardizedPath(root.standardizedFullPath) == canonicalTranslated
                || standardizedPath(root.fullPath) == canonicalTranslated
        }
    }

    private func logicalRoot(for context: RepositoryContext) async throws -> WorkspaceRootRef {
        if let explicitLogicalRoot = context.explicitLogicalRoot {
            return explicitLogicalRoot
        }
        for root in context.visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)),
               GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path) == GitRepoRootAuthorization.canonicalPath(context.repo.rootPath)
            {
                return root
            }
        }
        if let exact = context.visibleRoots.first(where: { standardizedPath($0.standardizedFullPath) == standardizedPath(context.repo.rootPath) }) {
            return exact
        }
        if let first = context.visibleRoots.first {
            return first
        }
        throw MCPError.invalidParams("No visible workspace root is available for session worktree binding.")
    }

    // MARK: - DTOs and visual identity

    private func repositoryDTO(
        from identity: GitWorktreeRepositoryIdentity?,
        fallback repo: GitRepoDescriptor
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO.RepositoryDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO.RepositoryDTO(
            repositoryID: identity?.repositoryID,
            repoKey: identity?.repoKey ?? repo.repoKey,
            displayName: identity?.displayName ?? repo.displayName,
            rootPath: repo.rootPath,
            commonGitDir: identity?.commonGitDir,
            mainWorktreeRoot: identity?.mainWorktreeRoot
        )
    }

    private func worktreeDTO(
        _ worktree: GitWorktreeDescriptor,
        includeStatus: Bool,
        persistVisuals: Bool
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        let visual = try persistOrResolveVisualIdentity(for: worktree, args: [:], persist: persistVisuals)
        return try await worktreeDTO(worktree, visualIdentity: visual, includeStatus: includeStatus)
    }

    private func worktreeDTO(
        _ worktree: GitWorktreeDescriptor,
        visualIdentity: WorktreeVisualIdentity,
        includeStatus: Bool
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO {
        let status = includeStatus ? try? await dirtyStatusDTO(for: worktree) : nil
        return ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO(
            worktreeID: worktree.worktreeID,
            specifier: "@id:\(worktree.worktreeID)",
            path: worktree.path,
            gitDir: worktree.gitDir,
            name: worktree.name,
            branch: worktree.branch,
            head: worktree.head,
            isMain: worktree.isMain,
            isCurrent: worktree.isCurrent,
            isDetached: worktree.isDetached,
            isLocked: worktree.isLocked,
            lockReason: worktree.lockReason,
            isPrunable: worktree.isPrunable,
            prunableReason: worktree.prunableReason,
            visual: visualDTO(visualIdentity),
            status: status
        )
    }

    private func dirtyStatusDTO(for worktree: GitWorktreeDescriptor) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO.StatusDTO {
        let status = try await vcsService.getWorkingStatus(at: URL(fileURLWithPath: worktree.path))
        return ToolResultDTOs.ManageWorktreeReplyDTO.StatusDTO(
            staged: status.staged.count,
            modified: status.modified.count,
            untracked: status.untracked.count,
            isDirty: !(status.staged.isEmpty && status.modified.isEmpty && status.untracked.isEmpty)
        )
    }

    private func persistOrResolveVisualIdentity(
        for worktree: GitWorktreeDescriptor,
        args: [String: Value],
        persist: Bool
    ) throws -> WorktreeVisualIdentity {
        let label = trimmedString(args["label"]) ?? fallbackLabel(for: worktree)
        let color = trimmedString(args["color"])
        let iconName = trimmedString(args["icon_name"])
        let markerStyle = try parseMarkerStyle(args["marker_style"])
        if persist {
            do {
                return try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                    repositoryID: worktree.repository.repositoryID,
                    worktreeID: worktree.worktreeID,
                    label: label,
                    colorHex: color,
                    iconName: iconName,
                    markerStyle: markerStyle
                )
            } catch let error as GlobalSettingsStore.WorktreeVisualIdentityError {
                throw MCPError.invalidParams("Invalid worktree visual identity: \(error)")
            }
        }
        return GlobalSettingsStore.shared.resolvedWorktreeVisualIdentity(
            repositoryID: worktree.repository.repositoryID,
            worktreeID: worktree.worktreeID,
            fallbackLabel: label,
            fallbackIconName: iconName,
            fallbackMarkerStyle: markerStyle
        )
    }

    private func visualDTO(_ identity: WorktreeVisualIdentity) -> ToolResultDTOs.ManageWorktreeReplyDTO.VisualIdentityDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO.VisualIdentityDTO(
            label: identity.label,
            colorHex: identity.colorHex,
            iconName: identity.iconName,
            markerStyle: identity.markerStyle.rawValue
        )
    }

    private func bindingDTO(_ binding: AgentSessionWorktreeBinding) -> ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            head: binding.head,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: ISO8601DateFormatter().string(from: binding.boundAt),
            source: binding.source
        )
    }

    private func graphDTOIfRequested(args: [String: Value], repoURL: URL) async -> ToolResultDTOs.ManageWorktreeReplyDTO.GraphDTO? {
        guard parseBool(args["include_graph"]) == true else { return nil }
        let limit = max(1, min(args["graph_limit"]?.intValue ?? 24, 200))
        let source = "git log --graph --decorate --oneline --color=never -n \(limit)"
        do {
            let graph = try await vcsService.getCommitGraph(maxLines: limit, at: repoURL)
            let lines = graph
                .split(whereSeparator: \.isNewline)
                .prefix(limit)
                .map(String.init)
            return ToolResultDTOs.ManageWorktreeReplyDTO.GraphDTO(
                requested: true,
                limit: limit,
                lines: lines.isEmpty ? ["(no commits)"] : lines,
                lineCount: lines.count,
                truncated: false,
                source: source
            )
        } catch {
            return ToolResultDTOs.ManageWorktreeReplyDTO.GraphDTO(
                requested: true,
                limit: limit,
                lines: ["(graph unavailable: \(error.localizedDescription))"],
                lineCount: 0,
                truncated: false,
                source: source
            )
        }
    }

    // MARK: - Validation and parsing

    private func validateArguments(_ args: [String: Value], for op: Operation) throws {
        let valid: Set<String> = switch op {
        case .list:
            ["op", "repo_root", "repo_key", "include_status", "include_graph", "graph_limit", "persist_visuals"]
        case .show:
            ["op", "repo_root", "repo_key", "worktree", "worktree_id", "include_status", "include_graph", "graph_limit", "persist_visuals"]
        case .create:
            ["op", "repo_root", "repo_key", "session_id", "include_status", "branch", "base_ref", "path", "detach", "force", "allow_external_path", "bind", "label", "color", "icon_name", "marker_style"]
        case .bind, .select:
            ["op", "repo_root", "repo_key", "worktree", "worktree_id", "session_id", "include_status", "label", "color", "icon_name", "marker_style"]
        case .unbind:
            ["op", "repo_root", "repo_key", "worktree", "worktree_id", "session_id", "all"]
        case .preview:
            ["op", "session_id", "repo_root", "target", "target_worktree_id", "include_graph", "graph_limit", "context_lines", "detect_renames", "publish_artifacts"]
        case .apply:
            ["op", "session_id", "operation_id", "commit_message", "include_graph", "graph_limit", "confirm_preview"]
        case .status:
            ["op", "session_id", "operation_id", "include_graph", "graph_limit"]
        case .continue:
            ["op", "session_id", "operation_id", "commit_message", "include_graph", "graph_limit", "confirm"]
        case .abort:
            ["op", "session_id", "operation_id", "include_graph", "graph_limit", "confirm"]
        }

        for key in args.keys where !key.hasPrefix("_") && !valid.contains(key) {
            throw MCPError.invalidParams("`\(key)` is not valid for op=\(op.rawValue).")
        }

        if trimmedString(args["target"]) != nil, trimmedString(args["target_worktree_id"]) != nil {
            throw MCPError.invalidParams("target and target_worktree_id are mutually exclusive.")
        }
    }

    private func validateSelectorArguments(_ args: [String: Value]) throws {
        if trimmedString(args["worktree"]) != nil, trimmedString(args["worktree_id"]) != nil {
            throw MCPError.invalidParams("worktree and worktree_id are mutually exclusive.")
        }
        _ = try parseMarkerStyle(args["marker_style"])
        if let color = trimmedString(args["color"]), !GlobalSettingsStore.isValidWorktreeColorHex(color) {
            throw MCPError.invalidParams("color must be a valid #RRGGBB value.")
        }
    }

    private func parseMarkerStyle(_ value: Value?) throws -> WorktreeVisualMarkerStyle? {
        guard let raw = trimmedString(value) else { return nil }
        guard let markerStyle = WorktreeVisualMarkerStyle(rawValue: raw.lowercased()) else {
            throw MCPError.invalidParams("marker_style must be one of: dot, ring, capsule.")
        }
        return markerStyle
    }

    private func explicitCreatePath(from value: Value?) throws -> URL? {
        guard let raw = trimmedString(value) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            throw MCPError.invalidParams("path must be absolute or use ~/ for manage_worktree.create.")
        }
        return URL(fileURLWithPath: standardized)
    }

    private func worktreeSelector(from args: [String: Value]) -> String? {
        if let worktreeID = trimmedString(args["worktree_id"]) {
            return "@id:\(worktreeID)"
        }
        return trimmedString(args["worktree"])
    }

    private func hasWorktreeSelector(_ args: [String: Value]) -> Bool {
        worktreeSelector(from: args) != nil
    }

    private func fallbackLabel(for worktree: GitWorktreeDescriptor) -> String? {
        if let name = worktree.name, !name.isEmpty { return name }
        if let branch = worktree.branch, !branch.isEmpty { return branch }
        return worktree.isMain ? "main" : nil
    }

    func trimmedString(_ value: Value?) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func parseBool(_ value: Value?) -> Bool? {
        value?.boolValue
    }

    private func combinedWarnings(_ warnings: [String?]) -> String? {
        let parts = warnings.compactMap { warning -> String? in
            guard let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty else {
                return nil
            }
            return warning
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
