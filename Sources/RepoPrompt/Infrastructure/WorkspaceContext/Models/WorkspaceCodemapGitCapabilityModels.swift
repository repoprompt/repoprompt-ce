import Foundation

struct WorkspaceCodemapRootEpoch: Hashable {
    let rootID: UUID
    let rootLifetimeID: UUID
}

struct WorkspaceCodemapRepositoryAuthorityToken: Hashable {
    let authorityGeneration: UInt64
    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let repositoryBindingEpoch: String
    let worktreeBindingEpoch: String
    let layoutGeneration: String
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let attributeGeneration: String
    let sparseGeneration: String
    let metadataGeneration: String
}

enum WorkspaceCodemapGitTerminalUnavailableReason: String, Equatable {
    case nonGit
    case bareRepository
    case unsupportedObjectFormat
    case unsupportedGit
    case invalidLayout
    case invalidLoadedRootContainment
    case namespaceUnavailable
    case rootEpochBindingMismatch
    case releasedRootEpoch
}

enum WorkspaceCodemapGitTransientUnavailableReason: String, Equatable {
    case gitProcessUnavailable
    case repositoryChanging
    case permissionFailure
    case runtimeUnavailable
}

struct GitCodemapRootCapability: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryLayout: GitRepositoryLayout
    let repositoryIdentity: GitWorktreeRepositoryIdentity
    let worktreeID: String
    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let repositoryRelativeLoadedRootPrefix: String
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
}

enum WorkspaceCodemapGitCapabilityState: Equatable {
    case unresolved
    case resolving(generation: UInt64)
    case eligible(GitCodemapRootCapability)
    case transientUnavailable(reason: WorkspaceCodemapGitTransientUnavailableReason, retryGeneration: UInt64)
    case terminalUnavailable(WorkspaceCodemapGitTerminalUnavailableReason)
}

struct WorkspaceCodemapGitCapabilityRequest: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let loadedRootURL: URL

    init(rootID: UUID, rootLifetimeID: UUID, loadedRootURL: URL) {
        rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: rootLifetimeID)
        self.loadedRootURL = loadedRootURL.resolvingSymlinksInPath().standardizedFileURL
    }
}

enum WorkspaceCodemapGitEligibilityPreflightResult: Equatable {
    case eligible
    case terminalUnavailable(WorkspaceCodemapGitTerminalUnavailableReason)
    case transientUnavailable(WorkspaceCodemapGitTransientUnavailableReason)
}

struct WorkspaceCodemapGitEligibilityProbe {
    let resolve: @Sendable (URL) async -> WorkspaceCodemapGitEligibilityPreflightResult

    static func production(gitService: GitService = GitService()) -> Self {
        Self { rootURL in
            await WorkspaceCodemapGitCapabilityService.eligibilityPreflight(
                gitService: gitService,
                loadedRootURL: rootURL
            )
        }
    }
}
