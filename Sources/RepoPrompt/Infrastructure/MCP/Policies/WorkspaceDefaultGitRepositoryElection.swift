import Foundation
import RepoPromptVCS
import RepoPromptWorkspaceCore

/// Default Git repository for calls that do not identify one: the session's sole applicable worktree
/// binding, otherwise the workspace's declared PRIMARY root (its first declared root, Git or not). Two or
/// more bindings have no default. Root installation order is never consulted: hydration installs roots
/// concurrently, so actor order carries no intent.
///
/// Stateless app policy shared by the MCP adapters. Adapters keep discovery order, explicit-selector
/// resolution, leases, and freshness checks; they elect only after resolution asks for a default, then
/// revalidate their capture before using the selection.
@MainActor
struct WorkspaceDefaultGitRepositoryElection {
    /// Immutable copies an adapter captures before discovery awaits. Owns no window, session, or store.
    struct Snapshot {
        struct DeclaredRoot: Equatable {
            /// Standardized like `WorkspaceRootRef.standardizedFullPath`.
            let path: String
            /// The workspace's own spelling, for messages.
            let displayPath: String
        }

        let workspaceID: UUID?
        /// Declared roots in order with identical paths collapsed; the first is PRIMARY.
        let declaredRoots: [DeclaredRoot]
        /// Routed binding authority, or nil when it could not be captured.
        let bindingSource: AgentWorkspaceLookupContextSource?
        let lookupContext: WorkspaceLookupContext
        /// Canonical (logical) roots visible to the lookup.
        let logicalRoots: [WorkspaceRootRef]
        /// Admitted lookup roots; bound physical checkouts replace their logical roots.
        let lookupRoots: [WorkspaceRootRef]

        init(
            workspaceID: UUID?,
            declaredRepoPaths: [String],
            bindingSource: AgentWorkspaceLookupContextSource?,
            lookupContext: WorkspaceLookupContext,
            lookupRoots: [WorkspaceRootRef]
        ) {
            self.workspaceID = workspaceID
            declaredRoots = Self.declaredRoots(declaredRepoPaths)
            self.bindingSource = bindingSource
            self.lookupContext = lookupContext
            self.lookupRoots = lookupRoots
            logicalRoots = lookupContext.bindingProjection?.visibleLogicalRootRefs ?? lookupRoots
        }

        static func declaredRoots(_ repoPaths: [String]) -> [DeclaredRoot] {
            var seen = Set<String>()
            return repoPaths.compactMap { raw in
                guard let path = standardizedPath(raw), seen.insert(path).inserted else { return nil }
                return DeclaredRoot(path: path, displayPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        /// Trims, expands `~`, and standardizes with the lexical rules of loaded root references.
        static func standardizedPath(_ raw: String) -> String? {
            WorkspaceExactRootPath(raw).map { StandardizedPath.absolute($0.normalizedPath) }
        }

        /// Declared order (PRIMARY moves on reorder) and binding authority still match this capture.
        func isCurrent(declaredRepoPaths: [String]?, bindingSource current: AgentWorkspaceLookupContextSource?) -> Bool {
            guard let declaredRepoPaths, Self.declaredRoots(declaredRepoPaths) == declaredRoots else { return false }
            return current?.identity == bindingSource?.identity
        }

        /// Binding authority for an adapter routed by request metadata, matching its file-tool lookup: a
        /// routed tab supplies the session; without one, ordinary calls have no session and Agent Mode runs
        /// fail closed.
        static func bindingSource(
            routed: MCPResolvedTabContextSnapshot?,
            runPurpose: MCPRunPurpose?
        ) -> AgentWorkspaceLookupContextSource? {
            if let snapshot = routed?.snapshot {
                return AgentWorkspaceLookupContextSource(
                    activeAgentSessionID: snapshot.activeAgentSessionID,
                    worktreeBindingState: snapshot.worktreeBindingState
                )
            }
            guard runPurpose != .agentModeRun else { return nil }
            return AgentWorkspaceLookupContextSource(activeAgentSessionID: nil, worktreeBindingState: .notApplicable)
        }
    }

    enum Origin: Equatable {
        case declaredPrimary
        case soleBinding(bindingID: String)
    }

    struct Selection {
        /// Physical checkout where Git executes.
        let repository: GitRepoDescriptor
        /// Declared logical root that authorizes the default and receives binding attribution.
        let logicalRoot: WorkspaceRootRef
        let origin: Origin
    }

    /// Selection refusals. Authority failures (unknown hydration, unavailable or stale projection) keep the
    /// existing `WorkspaceLookupContextResolutionError`.
    enum Failure: LocalizedError, Equatable {
        enum Subject: Equatable {
            case declaredPrimary(path: String)
            case soleBinding(logicalPath: String, checkoutPath: String)
        }

        struct Binding: Equatable {
            let logicalPath: String
            let checkoutPath: String
        }

        case noDeclaredRoots
        case notLoaded(Subject)
        case notGitRepository(Subject)
        case bindingOutsideDeclaredRoots(Binding)
        case multipleBindings([Binding])
        case superseded

        private static let identify = "pass repo_root (a repository path or name) or repo_key to identify a repository"

        var errorDescription: String? {
            switch self {
            case .noDeclaredRoots:
                "The workspace declares no roots, so there is no default Git repository. Add a workspace root, or \(Self.identify)."
            case let .notLoaded(subject):
                "\(Self.describe(subject)) is not loaded, so there is no default Git repository. \(Self.recovery(subject, waitForLoading: true))"
            case let .notGitRepository(subject):
                "\(Self.describe(subject)) is not inside a Git repository, so there is no default Git repository. \(Self.recovery(subject, waitForLoading: false))"
            case let .bindingOutsideDeclaredRoots(binding):
                "The session's worktree binding for \(binding.logicalPath) (checkout \(binding.checkoutPath)) is not a declared workspace root, so no default Git repository can be chosen. Repair the binding, or remove it with manage_worktree op=unbind."
            case let .multipleBindings(bindings):
                """
                This session has \(bindings.count) worktree bindings, so there is no default Git repository:
                \(bindings.map { "- \($0.logicalPath) → checkout \($0.checkoutPath)" }.joined(separator: "\n"))
                Pass repo_root (a repository path or name) or repo_key, or an identifying worktree selector (@id:<worktree_id>, @branch:<branch>, or a worktree path). Bare @main, @current, and @wt are relative to a default repository and do not choose one.
                """
            case .superseded:
                "Workspace roots or session worktree bindings changed while the default Git repository was being chosen. Retry the request."
            }
        }

        private static func describe(_ subject: Subject) -> String {
            switch subject {
            case let .declaredPrimary(path):
                "Declared PRIMARY root \(path)"
            case let .soleBinding(logicalPath, checkoutPath):
                "The session's sole worktree binding for \(logicalPath) (checkout \(checkoutPath))"
            }
        }

        private static func recovery(_ subject: Subject, waitForLoading: Bool) -> String {
            switch subject {
            case .declaredPrimary:
                "The default never falls back to another root; \(waitForLoading ? "wait for the workspace roots to load, or " : "")\(identify)."
            case .soleBinding:
                "Repair or unbind it with manage_worktree, or \(identify)."
            }
        }
    }

    private let vcsService: VCSService

    init(vcsService: VCSService) {
        self.vcsService = vcsService
    }

    func elect(in snapshot: Snapshot) async throws -> Selection {
        try Task.checkCancellation()
        let bindings = try applicableBindings(in: snapshot)
        let selection: Selection
        switch bindings.count {
        case 0:
            selection = try await electDeclaredPrimary(in: snapshot)
        case 1:
            selection = try await electSoleBinding(bindings[0], in: snapshot)
        default:
            throw Failure.multipleBindings(bindings.map {
                Failure.Binding(logicalPath: $0.logicalRootPath, checkoutPath: $0.worktreeRootPath)
            })
        }
        try Task.checkCancellation()
        return selection
    }

    /// Every captured row, in declared order. The lookup context must be the validated projection of exactly
    /// these rows: `AgentWorkspaceLookupContextResolver.requiredLookupContext` already refuses duplicates,
    /// unavailable identities, and logical-equals-physical rows. Election adds declared-root membership.
    private func applicableBindings(in snapshot: Snapshot) throws -> [WorkspaceSessionWorktreeBinding] {
        guard let source = snapshot.bindingSource else {
            throw WorkspaceLookupContextResolutionError.unknownBindingState
        }
        let lookupContext = snapshot.lookupContext
        guard lookupContext != AgentWorkspaceLookupContextResolver.failClosedLookupContext else {
            throw WorkspaceLookupContextResolutionError.unavailableProjection
        }
        var bindings: [WorkspaceSessionWorktreeBinding] = []
        if source.activeAgentSessionID != nil {
            guard case let .hydrated(hydrated) = source.worktreeBindingState else {
                throw WorkspaceLookupContextResolutionError.unknownBindingState
            }
            bindings = hydrated
        }
        if bindings.isEmpty {
            guard lookupContext.bindingProjection == nil else {
                throw WorkspaceLookupContextResolutionError.unavailableProjection
            }
            return []
        }
        guard let projection = lookupContext.bindingProjection,
              projection.sessionID == source.activeAgentSessionID,
              projection.isFullyMaterialized,
              AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(projection.boundRootsForMetadata.map(\.binding))
              == AgentWorkspaceLookupContextSource.worktreeBindingFingerprint(bindings)
        else {
            throw WorkspaceLookupContextResolutionError.unavailableProjection
        }

        let declaredIndex = Dictionary(
            snapshot.declaredRoots.enumerated().map { ($1.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let indexed = try bindings.map { binding -> (index: Int, binding: WorkspaceSessionWorktreeBinding) in
            guard let logicalPath = Snapshot.standardizedPath(binding.logicalRootPath),
                  let index = declaredIndex[logicalPath]
            else {
                throw Failure.bindingOutsideDeclaredRoots(
                    .init(logicalPath: binding.logicalRootPath, checkoutPath: binding.worktreeRootPath)
                )
            }
            return (index, binding)
        }
        return indexed.sorted { $0.index < $1.index }.map(\.binding)
    }

    private func electDeclaredPrimary(in snapshot: Snapshot) async throws -> Selection {
        guard let primary = snapshot.declaredRoots.first else {
            throw Failure.noDeclaredRoots
        }
        let subject = Failure.Subject.declaredPrimary(path: primary.displayPath)
        // Exact declared path, never actor position. Without bindings the lookup roots are canonical.
        guard let logicalRoot = snapshot.logicalRoots.first(where: { $0.standardizedFullPath == primary.path }),
              let lookupRoot = snapshot.lookupRoots.first(where: { $0.standardizedFullPath == primary.path })
        else {
            throw Failure.notLoaded(subject)
        }
        let authorizedRoots = snapshot.lookupRoots.map { URL(fileURLWithPath: $0.standardizedFullPath) }
        // Exact-root bounded discovery never searches arbitrary parents. A nested PRIMARY may use an
        // enclosing checkout only when that enclosing root is independently declared and loaded too.
        let declaredPaths = Set(snapshot.declaredRoots.map(\.path))
        let enclosingRoots = snapshot.lookupRoots.filter {
            $0.standardizedFullPath != lookupRoot.standardizedFullPath
                && declaredPaths.contains($0.standardizedFullPath)
                && GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
                    lookupRoot.standardizedFullPath, roots: [$0.standardizedFullPath]
                )
        }.sorted {
            let left = GitRepoRootAuthorization.canonicalPath($0.standardizedFullPath)
            let right = GitRepoRootAuthorization.canonicalPath($1.standardizedFullPath)
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            return leftDepth == rightDepth
                ? $0.standardizedFullPath < $1.standardizedFullPath
                : leftDepth > rightDepth
        }
        for candidate in [lookupRoot] + enclosingRoots {
            if let resolved = await vcsService.resolveRepoForRead(
                at: URL(fileURLWithPath: candidate.standardizedFullPath), authorizedRoots: authorizedRoots
            ) {
                return Selection(
                    repository: GitRepoDescriptor(rootURL: resolved.rootURL),
                    logicalRoot: logicalRoot,
                    origin: .declaredPrimary
                )
            }
        }
        throw Failure.notGitRepository(subject)
    }

    private func electSoleBinding(
        _ binding: WorkspaceSessionWorktreeBinding,
        in snapshot: Snapshot
    ) async throws -> Selection {
        let subject = Failure.Subject.soleBinding(
            logicalPath: binding.logicalRootPath,
            checkoutPath: binding.worktreeRootPath
        )
        guard let logicalPath = Snapshot.standardizedPath(binding.logicalRootPath),
              let logicalRoot = snapshot.logicalRoots.first(where: { $0.standardizedFullPath == logicalPath }),
              let boundRoot = snapshot.lookupContext.bindingProjection?.replacementsByLogicalRootPath[logicalPath],
              let physicalRoot = snapshot.lookupRoots.first(where: {
                  $0.standardizedFullPath == boundRoot.physicalRoot.standardizedFullPath
              })
        else {
            throw Failure.notLoaded(subject)
        }
        guard let resolved = await vcsService.resolveRepoForRead(
            at: URL(fileURLWithPath: physicalRoot.standardizedFullPath),
            authorizedRoots: snapshot.lookupRoots.map { URL(fileURLWithPath: $0.standardizedFullPath) }
        ) else {
            throw Failure.notGitRepository(subject)
        }
        let repository = GitRepoDescriptor(rootURL: resolved.rootURL)
        // The bound checkout itself with the binding's identity, never an enclosing repository.
        guard GitRepoRootAuthorization.canonicalPath(repository.rootPath)
            == GitRepoRootAuthorization.canonicalPath(physicalRoot.standardizedFullPath),
            repository.worktreeIdentity?.worktreeID == binding.worktreeID
        else {
            throw WorkspaceLookupContextResolutionError.unavailableProjection
        }
        return Selection(repository: repository, logicalRoot: logicalRoot, origin: .soleBinding(bindingID: binding.id))
    }
}
