import Foundation

/// Immutable Git inputs captured for one prompt-packaging request.
///
/// This value deliberately carries no live view-model references. Later packaging stages may
/// consume it, but must not reacquire repository, comparison, workspace, or tab identity.
struct FrozenPromptGitReviewContext: Equatable {
    let artifactCapability: SelectedGitArtifactCapability?
    let artifactDelegationConsumer: SelectedGitArtifactDelegationConsumer?
    let compareIntent: ReviewGitCompareIntent
    let displayContext: ReviewGitDisplayContext

    init(
        artifactCapability: SelectedGitArtifactCapability?,
        artifactDelegationConsumer: SelectedGitArtifactDelegationConsumer? = nil,
        compareIntent: ReviewGitCompareIntent,
        displayContext: ReviewGitDisplayContext
    ) {
        self.artifactCapability = artifactCapability
        self.artifactDelegationConsumer = artifactDelegationConsumer
        self.compareIntent = compareIntent
        self.displayContext = displayContext
    }
}

enum ReviewGitCompareIntent: Equatable {
    case uncommittedHEAD
    case uncommittedMergeBase(symbolicBase: String)

    init(base: String?) {
        let normalized = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.isEmpty || normalized.caseInsensitiveCompare("HEAD") == .orderedSame {
            self = .uncommittedHEAD
        } else {
            self = .uncommittedMergeBase(symbolicBase: normalized)
        }
    }
}

/// Exact, ephemeral authority to inspect already-selected files in one loaded workspace Git-data root.
///
/// The capability is never persisted and grants no root enumeration, search, tree, or raw filesystem
/// access. Authorization still validates every selected record and its manifest provenance.
struct SelectedGitArtifactCapability: Equatable {
    let workspaceID: UUID
    let workspaceDirectoryPath: String
    let gitDataRoot: WorkspaceRootRef
    let creatorTabID: UUID
    let sessionID: UUID?
    let boundCheckouts: [FrozenBoundCheckoutIdentity]
    let visibleRootCheckouts: [FrozenVisibleGitCheckoutIdentity]
    let canonicalWorkspaceRootPaths: [String]
    let access: SelectedGitArtifactAccess

    init(
        workspaceID: UUID,
        workspaceDirectoryPath: String,
        gitDataRoot: WorkspaceRootRef,
        creatorTabID: UUID,
        sessionID: UUID?,
        boundCheckouts: [FrozenBoundCheckoutIdentity],
        visibleRootCheckouts: [FrozenVisibleGitCheckoutIdentity] = [],
        canonicalWorkspaceRootPaths: [String],
        access: SelectedGitArtifactAccess = .direct
    ) {
        self.workspaceID = workspaceID
        self.workspaceDirectoryPath = StandardizedPath.absolute(
            (workspaceDirectoryPath as NSString).expandingTildeInPath
        )
        self.gitDataRoot = gitDataRoot
        self.creatorTabID = creatorTabID
        self.sessionID = sessionID
        self.boundCheckouts = boundCheckouts
        self.visibleRootCheckouts = visibleRootCheckouts
        self.canonicalWorkspaceRootPaths = canonicalWorkspaceRootPaths.map {
            StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
        }
        self.access = access
    }

    func delegated(_ delegation: SelectedGitArtifactDelegation) -> SelectedGitArtifactCapability {
        SelectedGitArtifactCapability(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspaceDirectoryPath,
            gitDataRoot: gitDataRoot,
            creatorTabID: creatorTabID,
            sessionID: sessionID,
            boundCheckouts: boundCheckouts,
            visibleRootCheckouts: visibleRootCheckouts,
            canonicalWorkspaceRootPaths: canonicalWorkspaceRootPaths,
            access: .delegated(delegation)
        )
    }
}

enum SelectedGitArtifactAccess: Equatable {
    case direct
    case delegated(SelectedGitArtifactDelegation)
}

/// Immutable, source-owned authority for one exact child Agent Mode run.
///
/// The allowlist contains only identities selected when the child was launched. The capability is
/// deliberately ephemeral and grants no root discovery or raw filesystem access.
struct SelectedGitArtifactDelegation: Equatable {
    let delegationID: UUID
    let sourceWorkspaceID: UUID
    let sourceTabID: UUID
    let sourceAgentSessionID: UUID?
    let sourceAgentRunID: UUID?
    let targetWorkspaceID: UUID
    let targetTabID: UUID
    let targetAgentSessionID: UUID
    let targetAgentRunID: UUID
    let exactSelectedArtifactPaths: Set<String>
    /// Immutable child-consumer lifetime snapshot; source manifest authority remains on the capability.
    let targetBoundCheckouts: [FrozenBoundCheckoutIdentity]

    init(
        delegationID: UUID,
        sourceWorkspaceID: UUID,
        sourceTabID: UUID,
        sourceAgentSessionID: UUID?,
        sourceAgentRunID: UUID?,
        targetWorkspaceID: UUID,
        targetTabID: UUID,
        targetAgentSessionID: UUID,
        targetAgentRunID: UUID,
        exactSelectedArtifactPaths: Set<String>,
        targetBoundCheckouts: [FrozenBoundCheckoutIdentity]
    ) {
        self.delegationID = delegationID
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceTabID = sourceTabID
        self.sourceAgentSessionID = sourceAgentSessionID
        self.sourceAgentRunID = sourceAgentRunID
        self.targetWorkspaceID = targetWorkspaceID
        self.targetTabID = targetTabID
        self.targetAgentSessionID = targetAgentSessionID
        self.targetAgentRunID = targetAgentRunID
        self.exactSelectedArtifactPaths = Set(exactSelectedArtifactPaths.compactMap(Self.normalizeIdentity))
        self.targetBoundCheckouts = targetBoundCheckouts
    }

    private static func normalizeIdentity(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !StandardizedPath.containsNUL(trimmed) else { return nil }
        return StandardizedPath.absolute((trimmed as NSString).expandingTildeInPath)
    }
}

/// Current consumer identity supplied by the exact child Agent Mode run at packaging time.
struct SelectedGitArtifactDelegationConsumer: Equatable {
    let workspaceID: UUID
    let tabID: UUID
    let agentSessionID: UUID
    let agentRunID: UUID
    let boundCheckouts: [FrozenBoundCheckoutIdentity]
}

struct FrozenBoundCheckoutIdentity: Equatable, Hashable {
    let logicalRootPath: String
    let logicalRootName: String
    let physicalWorktreeRootPath: String
    let repositoryID: String
    let worktreeID: String

    init(
        logicalRootPath: String,
        logicalRootName: String,
        physicalWorktreeRootPath: String,
        repositoryID: String,
        worktreeID: String
    ) {
        self.logicalRootPath = StandardizedPath.absolute(
            (logicalRootPath as NSString).expandingTildeInPath
        )
        self.logicalRootName = logicalRootName
        self.physicalWorktreeRootPath = StandardizedPath.absolute(
            (physicalWorktreeRootPath as NSString).expandingTildeInPath
        )
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
    }

    init(binding: AgentSessionWorktreeBinding) {
        self.init(
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName
                ?? (StandardizedPath.absolute(binding.logicalRootPath) as NSString).lastPathComponent,
            physicalWorktreeRootPath: binding.worktreeRootPath,
            repositoryID: binding.repositoryID,
            worktreeID: binding.worktreeID
        )
    }
}

/// Frozen logical labels for future multi-checkout rendering and diagnostics.
struct ReviewGitDisplayContext: Equatable {
    let roots: [ReviewGitDisplayRoot]
}

struct ReviewGitDisplayRoot: Equatable {
    let logicalRootPath: String
    let logicalRootName: String
    let physicalRootPath: String

    init(logicalRootPath: String, logicalRootName: String, physicalRootPath: String) {
        self.logicalRootPath = StandardizedPath.absolute(
            (logicalRootPath as NSString).expandingTildeInPath
        )
        self.logicalRootName = logicalRootName
        self.physicalRootPath = StandardizedPath.absolute(
            (physicalRootPath as NSString).expandingTildeInPath
        )
    }
}

extension FrozenPromptGitReviewContext {
    static func automaticOnly(
        base: String? = nil,
        workspaceRootPaths: [String] = [],
        bindings: [AgentSessionWorktreeBinding] = []
    ) -> FrozenPromptGitReviewContext {
        FrozenPromptGitReviewContext(
            artifactCapability: nil,
            compareIntent: ReviewGitCompareIntent(base: base),
            displayContext: makeDisplayContext(
                workspaceRootPaths: workspaceRootPaths,
                bindings: bindings
            )
        )
    }

    /// Derives an exact selected-artifact capability from already-frozen workspace/tab/binding
    /// identity. A missing cataloged Git-data root fails closed while preserving automatic review
    /// diff generation for ordinary selected files.
    static func make(
        workspaceID: UUID,
        workspaceDirectoryPath: String,
        workspaceRootPaths: [String],
        tabID: UUID,
        sessionID: UUID?,
        bindings: [AgentSessionWorktreeBinding],
        base: String?,
        store: WorkspaceFileContextStore
    ) async -> FrozenPromptGitReviewContext {
        let standardizedWorkspaceDirectory = StandardizedPath.absolute(
            (workspaceDirectoryPath as NSString).expandingTildeInPath
        )
        let gitDataPath = StandardizedPath.join(
            standardizedRoot: standardizedWorkspaceDirectory,
            standardizedRelativePath: "_git_data"
        )
        let gitDataRoot = await store.exactRootRef(path: gitDataPath, kind: .workspaceGitData)
        let boundCheckouts = bindings.map(FrozenBoundCheckoutIdentity.init(binding:))
        let visibleRootCheckouts = await FrozenVisibleGitCheckoutResolver().resolve(
            workspaceRootPaths: workspaceRootPaths,
            bindings: bindings,
            store: store
        )
        let capability = gitDataRoot.map {
            SelectedGitArtifactCapability(
                workspaceID: workspaceID,
                workspaceDirectoryPath: standardizedWorkspaceDirectory,
                gitDataRoot: $0,
                creatorTabID: tabID,
                sessionID: sessionID,
                boundCheckouts: boundCheckouts,
                visibleRootCheckouts: visibleRootCheckouts,
                canonicalWorkspaceRootPaths: workspaceRootPaths
            )
        }
        return FrozenPromptGitReviewContext(
            artifactCapability: capability,
            compareIntent: ReviewGitCompareIntent(base: base),
            displayContext: makeDisplayContext(
                workspaceRootPaths: workspaceRootPaths,
                bindings: bindings
            )
        )
    }

    private static func makeDisplayContext(
        workspaceRootPaths: [String],
        bindings: [AgentSessionWorktreeBinding]
    ) -> ReviewGitDisplayContext {
        let bindingByLogicalRoot = Dictionary(
            bindings.map { (StandardizedPath.absolute($0.logicalRootPath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var roots: [ReviewGitDisplayRoot] = []
        var seenPhysicalRoots = Set<String>()

        for rawRoot in workspaceRootPaths {
            let logicalRoot = StandardizedPath.absolute((rawRoot as NSString).expandingTildeInPath)
            let binding = bindingByLogicalRoot[logicalRoot]
            let physicalRoot = StandardizedPath.absolute(binding?.worktreeRootPath ?? logicalRoot)
            guard seenPhysicalRoots.insert(physicalRoot).inserted else { continue }
            roots.append(
                ReviewGitDisplayRoot(
                    logicalRootPath: logicalRoot,
                    logicalRootName: binding?.logicalRootName
                        ?? (logicalRoot as NSString).lastPathComponent,
                    physicalRootPath: physicalRoot
                )
            )
        }

        // Keep a binding whose logical root was absent from the persisted root list visible for
        // diagnostics without widening any lookup scope.
        for binding in bindings {
            let physicalRoot = StandardizedPath.absolute(binding.worktreeRootPath)
            guard seenPhysicalRoots.insert(physicalRoot).inserted else { continue }
            let logicalRoot = StandardizedPath.absolute(binding.logicalRootPath)
            roots.append(
                ReviewGitDisplayRoot(
                    logicalRootPath: logicalRoot,
                    logicalRootName: binding.logicalRootName
                        ?? (logicalRoot as NSString).lastPathComponent,
                    physicalRootPath: physicalRoot
                )
            )
        }

        return ReviewGitDisplayContext(roots: roots)
    }
}
