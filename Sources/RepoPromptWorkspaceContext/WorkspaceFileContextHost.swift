import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore

package extension WorkspaceRootCatalogPolicyIdentity {
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
package struct WorkspaceFileContextHost {
    package let rootReusableSnapshotCoordinator: WorkspaceRootReusableSnapshotCoordinator
    package let rootMaterializationHintEvaluator: WorkspaceRootMaterializationHintEvaluator
    package let rootSeedPlanner: WorkspaceRootSeedPlanner
    package let workspaceStateAuthority: GitWorkspaceStateAuthority
    package let worktreeSeedGitService: any WorkspaceGitClient
    package let fileSystemFactory: WorkspaceFileSystemServiceFactory

    package init(
        rootReusableSnapshotCoordinator: WorkspaceRootReusableSnapshotCoordinator,
        rootMaterializationHintEvaluator: WorkspaceRootMaterializationHintEvaluator,
        rootSeedPlanner: WorkspaceRootSeedPlanner,
        workspaceStateAuthority: GitWorkspaceStateAuthority,
        worktreeSeedGitService: any WorkspaceGitClient,
        fileSystemFactory: WorkspaceFileSystemServiceFactory
    ) {
        self.rootReusableSnapshotCoordinator = rootReusableSnapshotCoordinator
        self.rootMaterializationHintEvaluator = rootMaterializationHintEvaluator
        self.rootSeedPlanner = rootSeedPlanner
        self.workspaceStateAuthority = workspaceStateAuthority
        self.worktreeSeedGitService = worktreeSeedGitService
        self.fileSystemFactory = fileSystemFactory
    }
}

package struct WorkspaceFileSystemServiceFactory {
    private let create: @Sendable (String, Bool, Bool, Bool, Bool) async throws -> FileSystemService

    package init(create: @escaping @Sendable (String, Bool, Bool, Bool, Bool) async throws -> FileSystemService) {
        self.create = create
    }

    package func callAsFunction(
        path: String,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> FileSystemService {
        try await create(path, respectRepoIgnore, respectCursorignore, skipSymlinks, enableHierarchicalIgnores)
    }
}
