import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore

extension WorkspaceRootCatalogPolicyIdentity {
    static let canonicalDefaults = WorkspaceRootCatalogPolicyIdentity(
        schemaVersion: currentSchemaVersion,
        mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
        globalIgnoreDefaultsDigest: IgnoreRulesManager.globalIgnoreDefaultsDigest(
            for: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        ),
        respectRepoIgnore: true,
        respectCursorignore: true,
        enableHierarchicalIgnores: true,
        skipSymlinks: true
    )
}

/// Required host-owned dependencies. The store does not synthesize authority or filesystem policy.
struct WorkspaceFileContextHost {
    let rootReusableSnapshotCoordinator: WorkspaceRootReusableSnapshotCoordinator
    let rootMaterializationHintEvaluator: WorkspaceRootMaterializationHintEvaluator
    let rootSeedPlanner: WorkspaceRootSeedPlanner
    let workspaceStateAuthority: GitWorkspaceStateAuthority
    let worktreeSeedGitService: any WorkspaceGitClient
    let fileSystemFactory: WorkspaceFileSystemServiceFactory
}

struct WorkspaceFileSystemServiceFactory {
    private let create: @Sendable (String, Bool, Bool, Bool, Bool) async throws -> FileSystemService

    init(create: @escaping @Sendable (String, Bool, Bool, Bool, Bool) async throws -> FileSystemService) {
        self.create = create
    }

    func callAsFunction(
        path: String,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> FileSystemService {
        try await create(path, respectRepoIgnore, respectCursorignore, skipSymlinks, enableHierarchicalIgnores)
    }
}
