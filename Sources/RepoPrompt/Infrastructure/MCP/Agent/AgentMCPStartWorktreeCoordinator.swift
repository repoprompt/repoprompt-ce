import Foundation
import MCP

@MainActor
struct AgentMCPStartWorktreeCoordinator {
    struct Request {
        enum Mode: Equatable {
            case none
            case existing(selector: String)
            case create
        }

        static let argumentKeys: Set<String> = [
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

        let mode: Mode
        let repoRoot: String?
        let branch: String?
        let baseRef: String?
        let path: URL?
        let label: String?
        let color: String?
        let allowExternalPath: Bool
        let inheritParentWorktreeBindings: Bool

        var hasExplicitWorktreeArgs: Bool {
            switch mode {
            case .none:
                false
            case .existing, .create:
                true
            }
        }
    }

    private struct RepositoryContext {
        let repo: GitRepoDescriptor
        let allRepos: [GitRepoDescriptor]
        let visibleRoots: [WorkspaceRootRef]
        let logicalRoot: WorkspaceRootRef
    }

    let operationName: String
    let vcsService: VCSService
    let gitTargetResolver: GitRepoTargetResolver

    func containsArguments(_ args: [String: Value]) -> Bool {
        Request.argumentKeys.contains { args[$0] != nil }
    }

    func parseRequest(args: [String: Value]) throws -> Request {
        let worktree = AgentMCPToolHelpers.normalizedString(args["worktree"])
        let worktreeID = AgentMCPToolHelpers.normalizedString(args["worktree_id"])
        let create = AgentMCPToolHelpers.parseBool(args["worktree_create"]) ?? false
        if worktree != nil, worktreeID != nil {
            throw MCPError.invalidParams("worktree and worktree_id are mutually exclusive for \(operationName).")
        }
        if create, worktree != nil || worktreeID != nil {
            throw MCPError.invalidParams("worktree_create is mutually exclusive with worktree and worktree_id for \(operationName).")
        }
        let repoRoot = AgentMCPToolHelpers.normalizedString(args["worktree_repo_root"])
        let branch = AgentMCPToolHelpers.normalizedString(args["worktree_branch"])
        let baseRef = AgentMCPToolHelpers.normalizedString(args["worktree_base_ref"])
        let label = AgentMCPToolHelpers.normalizedString(args["worktree_label"])
        let color = AgentMCPToolHelpers.normalizedString(args["worktree_color"])
        let allowExternalPath = AgentMCPToolHelpers.parseBool(args["allow_external_worktree_path"]) ?? false
        let inheritParentWorktreeBindings = try parseOptionalBool(
            args["inherit_worktree"],
            name: "inherit_worktree"
        ) ?? true
        if let color, !GlobalSettingsStore.isValidWorktreeColorHex(color) {
            throw MCPError.invalidParams("worktree_color must be a valid #RRGGBB value.")
        }
        let path = try explicitWorktreePath(from: args["worktree_path"])
        let selector: String? = if let worktreeID {
            "@id:\(worktreeID)"
        } else {
            worktree
        }
        let mode: Request.Mode = if create {
            .create
        } else if let selector {
            .existing(selector: selector)
        } else {
            .none
        }
        if !create, path != nil {
            throw MCPError.invalidParams("worktree_path is only valid with worktree_create=true for \(operationName).")
        }
        if !create, branch != nil || baseRef != nil {
            throw MCPError.invalidParams("worktree_branch and worktree_base_ref are only valid with worktree_create=true for \(operationName).")
        }
        if !create, allowExternalPath {
            throw MCPError.invalidParams("allow_external_worktree_path is only valid with worktree_create=true for \(operationName).")
        }
        if case .none = mode,
           repoRoot != nil || label != nil || color != nil
        {
            throw MCPError.invalidParams("worktree_repo_root, worktree_label, and worktree_color require worktree, worktree_id, or worktree_create=true for \(operationName).")
        }
        return Request(
            mode: mode,
            repoRoot: repoRoot,
            branch: branch,
            baseRef: baseRef,
            path: path,
            label: label,
            color: color,
            allowExternalPath: allowExternalPath,
            inheritParentWorktreeBindings: inheritParentWorktreeBindings
        )
    }

    func prepare(
        request: Request,
        target: AgentModeViewModel.MCPSessionTarget,
        targetWindow: WindowState
    ) async throws {
        guard let targetSessionID = target.sessionID else {
            throw MCPError.internalError("\(operationName) target did not resolve a session ID for worktree binding.")
        }
        let agentModeVM = targetWindow.agentModeViewModel
        try Task.checkCancellation()
        if request.hasExplicitWorktreeArgs {
            do {
                let context = try await resolveRepositoryContext(
                    request: request,
                    targetWindow: targetWindow
                )
                try validateRuntimeRoot(context.logicalRoot, targetWindow: targetWindow)
                let worktree: GitWorktreeDescriptor
                switch request.mode {
                case .none:
                    throw MCPError.internalError("\(operationName) worktree preparation reached an unexpected empty worktree mode.")
                case let .existing(selector):
                    do {
                        worktree = try await gitTargetResolver.resolveWorktree(
                            selector: selector,
                            repo: context.repo,
                            allRepos: context.allRepos
                        )
                    } catch let error as GitRepoTargetResolverError {
                        throw MCPError.invalidParams(error.message)
                    }
                case .create:
                    worktree = try await createWorktree(
                        request: request,
                        context: context,
                        sessionID: targetSessionID
                    )
                }
                try Task.checkCancellation()
                let identity = try persistVisualIdentity(for: worktree, request: request)
                let binding = makeBinding(
                    worktree: worktree,
                    logicalRoot: context.logicalRoot,
                    visualIdentity: identity,
                    replacing: agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID).first {
                        standardizedPath($0.logicalRootPath) == standardizedPath(context.logicalRoot.standardizedFullPath)
                    }
                )
                _ = try agentModeVM.applyWorktreeBinding(binding, toSessionID: targetSessionID)
            } catch {
                throw preparationError(error)
            }
        }

        try Task.checkCancellation()
        let bindings = agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID, tabID: target.tabID)
        if !bindings.isEmpty {
            try await materializeRoots(
                bindings: bindings,
                sessionID: targetSessionID,
                targetWindow: targetWindow
            )
            try Task.checkCancellation()
        }
    }

    func providerStartError(
        _ error: Error,
        targetSessionID: UUID?,
        agentModeVM: AgentModeViewModel
    ) -> Error {
        if error is CancellationError { return error }
        guard let targetSessionID else { return error }
        let bindings = agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID)
        guard let binding = bindings.first else { return error }
        let label = binding.visualLabel ?? binding.worktreeName ?? binding.branch ?? binding.worktreeID
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return MCPError.invalidParams(
            "Agent provider start failed after binding worktree '\(label)' at \(binding.worktreeRootPath). The worktree was not removed; use manage_worktree list to inspect or recover it. Error: \(message)"
        )
    }

    private func parseOptionalBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        default:
            if let parsed = AgentMCPToolHelpers.parseBool(value) {
                return parsed
            }
            throw MCPError.invalidParams("\(name) must be a boolean.")
        }
    }

    private func materializeRoots(
        bindings: [AgentSessionWorktreeBinding],
        sessionID: UUID,
        targetWindow: WindowState
    ) async throws {
        let projection = await targetWindow.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: bindings
        )
        guard let projection, !projection.isEmpty else {
            throw MCPError.invalidParams("Failed to materialize the bound worktree root for \(operationName).")
        }
        let loadedRoots = await targetWindow.promptManager.workspaceFileContextStore.rootRefs(scope: projection.lookupRootScope)
        let loadedPaths = Set(loadedRoots.map { standardizedPath($0.standardizedFullPath) })
        let missing = projection.physicalRootRefs.filter {
            !loadedPaths.contains(standardizedPath($0.standardizedFullPath))
        }
        guard missing.isEmpty else {
            let paths = missing.map(\.standardizedFullPath).joined(separator: ", ")
            throw MCPError.invalidParams("Failed to load bound worktree root(s) for \(operationName): \(paths)")
        }
    }

    private func resolveRepositoryContext(
        request: Request,
        targetWindow: WindowState
    ) async throws -> RepositoryContext {
        let store = targetWindow.promptManager.workspaceFileContextStore
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        var repos: [GitRepoDescriptor] = []
        var seen = Set<String>()
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
                if seen.insert(descriptor.rootPath.lowercased()).inserted {
                    repos.append(descriptor)
                }
            }
        }
        guard let defaultRepo = repos.first else {
            throw MCPError.invalidParams("No Git repository found in loaded roots for \(operationName) worktree binding.")
        }
        let repo: GitRepoDescriptor
        var explicitLogicalRoot: WorkspaceRootRef?
        if let rawRepoRoot = request.repoRoot {
            if !rawRepoRoot.hasPrefix("@") {
                explicitLogicalRoot = explicitLogicalRootRef(for: rawRepoRoot, visibleRoots: visibleRoots)
            }
            do {
                repo = try await gitTargetResolver.resolveRepoRootToken(
                    rawRepoRoot,
                    allRepos: repos,
                    visibleRoots: visibleRoots,
                    defaultRepo: defaultRepo
                )
            } catch let error as GitRepoTargetResolverError {
                throw MCPError.invalidParams(error.message)
            }
        } else {
            repo = defaultRepo
        }
        let logicalRoot = try await logicalRoot(
            for: repo,
            explicitLogicalRoot: explicitLogicalRoot,
            visibleRoots: visibleRoots
        )
        return RepositoryContext(
            repo: repo,
            allRepos: repos,
            visibleRoots: visibleRoots,
            logicalRoot: logicalRoot
        )
    }

    private func validateRuntimeRoot(_ logicalRoot: WorkspaceRootRef, targetWindow: WindowState) throws {
        guard let primaryRoot = targetWindow.workspaceManager.activeWorkspace?.repoPaths.first else {
            return
        }
        let primary = standardizedPath((primaryRoot as NSString).expandingTildeInPath)
        guard standardizedPath(logicalRoot.standardizedFullPath) == primary else {
            throw MCPError.invalidParams(
                "\(operationName) worktree binding currently supports the primary workspace root only. Requested root '\(logicalRoot.name)' at \(logicalRoot.standardizedFullPath), but the provider runtime cwd resolves from primary root \(primary)."
            )
        }
    }

    private func createWorktree(
        request: Request,
        context: RepositoryContext,
        sessionID: UUID
    ) async throws -> GitWorktreeDescriptor {
        let existingWorktrees = try await vcsService.listGitWorktrees(at: context.repo.rootURL)
        let mainRootPath = existingWorktrees.first(where: \.isMain)?.path ?? context.repo.rootPath
        let plan = try GitWorktreeDefaultPathPlanner.plan(
            GitWorktreeDefaultPathPlanner.Request(
                mainWorktreeRoot: URL(fileURLWithPath: mainRootPath),
                existingWorktreeRoots: existingWorktrees.map { URL(fileURLWithPath: $0.path) },
                explicitPath: request.path,
                branch: request.branch,
                baseRef: request.baseRef,
                detach: false,
                force: false,
                allowExternalPath: request.allowExternalPath,
                purpose: .agentStart(sessionID: sessionID.uuidString)
            )
        )
        return try await vcsService.createGitWorktree(request: plan.createRequest, at: context.repo.rootURL)
    }

    private func persistVisualIdentity(
        for worktree: GitWorktreeDescriptor,
        request: Request
    ) throws -> WorktreeVisualIdentity {
        let label = request.label ?? fallbackLabel(for: worktree)
        do {
            return try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                repositoryID: worktree.repository.repositoryID,
                worktreeID: worktree.worktreeID,
                label: label,
                colorHex: request.color
            )
        } catch let error as GlobalSettingsStore.WorktreeVisualIdentityError {
            throw MCPError.invalidParams("Invalid worktree visual identity: \(error)")
        }
    }

    private func makeBinding(
        worktree: GitWorktreeDescriptor,
        logicalRoot: WorkspaceRootRef,
        visualIdentity: WorktreeVisualIdentity,
        replacing previous: AgentSessionWorktreeBinding?
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
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
            source: operationName
        )
    }

    private func preparationError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is MCPError { return error }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return MCPError.invalidParams("\(operationName) worktree preparation failed: \(message)")
    }

    private func logicalRoot(
        for repo: GitRepoDescriptor,
        explicitLogicalRoot: WorkspaceRootRef?,
        visibleRoots: [WorkspaceRootRef]
    ) async throws -> WorkspaceRootRef {
        if let explicitLogicalRoot {
            return explicitLogicalRoot
        }
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)),
               GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path) == GitRepoRootAuthorization.canonicalPath(repo.rootPath)
            {
                return root
            }
        }
        if let exact = visibleRoots.first(where: {
            standardizedPath($0.standardizedFullPath) == standardizedPath(repo.rootPath)
        }) {
            return exact
        }
        if let first = visibleRoots.first {
            return first
        }
        throw MCPError.invalidParams("No visible workspace root is available for \(operationName) worktree binding.")
    }

    private func explicitLogicalRootRef(
        for rawRepoRoot: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> WorkspaceRootRef? {
        let canonical = standardizedPath((rawRepoRoot as NSString).expandingTildeInPath)
        let lowered = rawRepoRoot.lowercased()
        return visibleRoots.first { root in
            root.name.lowercased() == lowered
                || standardizedPath(root.standardizedFullPath) == canonical
                || standardizedPath(root.fullPath) == canonical
        }
    }

    private func explicitWorktreePath(from value: Value?) throws -> URL? {
        guard let raw = AgentMCPToolHelpers.normalizedString(value) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            throw MCPError.invalidParams("worktree_path must be absolute or use ~/ for \(operationName).")
        }
        return URL(fileURLWithPath: standardized)
    }

    private func fallbackLabel(for worktree: GitWorktreeDescriptor) -> String? {
        if let name = worktree.name, !name.isEmpty { return name }
        if let branch = worktree.branch, !branch.isEmpty { return branch }
        return worktree.isMain ? "main" : nil
    }

    private func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
