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

/// Root authority identity shared by every Code Map serving path.
///
/// Git roots keep their existing repository authority payload verbatim so locator, manifest and
/// namespace consumers are unaffected. Filesystem roots carry only the compact generation the
/// capability actor issues; no Git namespace or object format is ever fabricated for them.
enum WorkspaceCodemapRootAuthorityToken: Hashable {
    case git(WorkspaceCodemapRepositoryAuthorityToken)
    case filesystem(rootEpoch: WorkspaceCodemapRootEpoch, authorityGeneration: UInt64)

    var gitAuthority: WorkspaceCodemapRepositoryAuthorityToken? {
        guard case let .git(token) = self else { return nil }
        return token
    }
}

enum WorkspaceCodemapRootTerminalUnavailableReason: String, Equatable {
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

enum WorkspaceCodemapRootTransientUnavailableReason: String, Equatable {
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

/// Filesystem root capability for a positively proven non-Git, non-bare loaded folder.
///
/// Like `GitCodemapRootCapability` this value is only ever issued by the capability actor, which
/// privately retains the full filesystem proof behind it. The proof never enters capability or
/// token equality; `authorityGeneration` is the compact stand-in used by serving comparisons.
struct WorkspaceCodemapFilesystemRootCapability: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let loadedRootURL: URL
    let authorityGeneration: UInt64
}

/// One eligible Code Map root, in exactly one of the two supported source modes.
enum WorkspaceCodemapRootCapability: Equatable {
    case git(GitCodemapRootCapability)
    case filesystem(WorkspaceCodemapFilesystemRootCapability)

    var rootEpoch: WorkspaceCodemapRootEpoch {
        switch self {
        case let .git(capability): capability.rootEpoch
        case let .filesystem(capability): capability.rootEpoch
        }
    }

    /// Git derives its loaded root from the retained worktree and repository-relative prefix rather
    /// than keeping a second mutable copy; callers still check it against root registration.
    var loadedRootURL: URL {
        switch self {
        case let .git(capability):
            let worktreePath = capability.repositoryLayout.workTreeRoot
                .resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = capability.repositoryRelativeLoadedRootPrefix
            return URL(
                fileURLWithPath: prefix.isEmpty ? worktreePath : worktreePath + "/" + prefix,
                isDirectory: true
            )
        case let .filesystem(capability):
            return capability.loadedRootURL
        }
    }

    var rootAuthority: WorkspaceCodemapRootAuthorityToken {
        switch self {
        case let .git(capability):
            .git(capability.repositoryAuthority)
        case let .filesystem(capability):
            .filesystem(
                rootEpoch: capability.rootEpoch,
                authorityGeneration: capability.authorityGeneration
            )
        }
    }

    var gitCapability: GitCodemapRootCapability? {
        guard case let .git(capability) = self else { return nil }
        return capability
    }
}

/// Admission evidence handed to the capability actor with a resolve request.
///
/// This is a revalidated hint, never a source token: the actor re-observes the proof and proves
/// readability itself before issuing any capability.
enum WorkspaceCodemapRootEligibilityEvidence: Equatable {
    case gitPreflightPassed
    case filesystem(WorkspaceCodemapNonGitFilesystemProof)

    var filesystemProof: WorkspaceCodemapNonGitFilesystemProof? {
        guard case let .filesystem(proof) = self else { return nil }
        return proof
    }
}

/// Result of re-checking that an already issued capability still describes the current root.
///
/// `.changed` means the binding moved and serving must be revoked; `.unavailable` distinguishes a
/// candidate or read failure that should be retried from a real authority change.
enum WorkspaceCodemapRootAuthorityValidation: Equatable {
    case current
    case changed
    case unavailable(WorkspaceCodemapRootTransientUnavailableReason)
}

/// Source and manifest mode of one eligible root, for truthful status and diagnostics output.
enum WorkspaceCodemapRootSourceKind: String, Hashable {
    case git
    case filesystem
}

enum WorkspaceCodemapRootManifestMode: String, Hashable {
    case git
    case notApplicable = "not_applicable"
}

struct WorkspaceCodemapRootSourceMode: Hashable {
    let sourceKind: WorkspaceCodemapRootSourceKind
    let manifestMode: WorkspaceCodemapRootManifestMode
}

enum WorkspaceCodemapRootCapabilityState: Equatable {
    case unresolved
    case resolving(generation: UInt64)
    case eligible(WorkspaceCodemapRootCapability)
    case transientUnavailable(reason: WorkspaceCodemapRootTransientUnavailableReason, retryGeneration: UInt64)
    case terminalUnavailable(WorkspaceCodemapRootTerminalUnavailableReason)
}

struct WorkspaceCodemapRootCapabilityRequest: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let loadedRootURL: URL

    init(rootID: UUID, rootLifetimeID: UUID, loadedRootURL: URL) {
        rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: rootLifetimeID)
        self.loadedRootURL = loadedRootURL.resolvingSymlinksInPath().standardizedFileURL
    }
}

enum WorkspaceCodemapGitEligibilityPreflightResult: Equatable {
    case eligible
    case terminalUnavailable(WorkspaceCodemapRootTerminalUnavailableReason)
    case transientUnavailable(WorkspaceCodemapRootTransientUnavailableReason)
}

struct WorkspaceCodemapGitEligibilityProbe {
    let resolve: @Sendable (URL) async -> WorkspaceCodemapGitEligibilityPreflightResult

    static func production(gitService: GitService = GitService()) -> Self {
        Self { rootURL in
            await WorkspaceCodemapRootCapabilityService.eligibilityPreflight(
                gitService: gitService,
                loadedRootURL: rootURL
            )
        }
    }
}
