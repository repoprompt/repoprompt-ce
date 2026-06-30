import Darwin
import Dispatch
import Foundation

struct GitWorkspaceAuthorityRepositoryKey: Hashable {
    let standardizedCommonDirectoryPath: String
    let standardizedGitDirectoryPath: String
    let commonDirectoryDevice: UInt64?
    let commonDirectoryInode: UInt64?

    init(layout: GitRepositoryLayout) {
        standardizedCommonDirectoryPath = layout.commonDir.standardizedFileURL.path
        standardizedGitDirectoryPath = layout.gitDir.standardizedFileURL.path
        var value = stat()
        if lstat(layout.commonDir.path, &value) == 0 {
            commonDirectoryDevice = UInt64(value.st_dev)
            commonDirectoryInode = UInt64(value.st_ino)
        } else {
            commonDirectoryDevice = nil
            commonDirectoryInode = nil
        }
    }
}

struct GitWorkspaceSearchABIIdentity: Hashable {
    let matcherSchemaVersion: Int
    let projectedKeySchemaVersion: Int
    let comparatorSchemaVersion: Int
    let pathNormalizationSchemaVersion: Int

    static let current = GitWorkspaceSearchABIIdentity(
        matcherSchemaVersion: 1,
        projectedKeySchemaVersion: 3,
        comparatorSchemaVersion: 1,
        pathNormalizationSchemaVersion: 1
    )
}

struct GitWorkspacePolicyIdentity: Hashable {
    let mandatoryIgnorePolicyIdentity: String
    let committedIgnoreControlDigest: String
    let configuredIgnoreAuthorityDigest: String
    let attributePolicyDigest: String
    let sparsePolicyDigest: String
    let searchABI: GitWorkspaceSearchABIIdentity
    let resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    let resolvedAttributesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    #if DEBUG
        /// Non-identity, path-free evidence used only by DEBUG diagnostics.
        let canonicalizationDiagnostics: GitWorkspacePolicyCanonicalizationDiagnostics?
    #endif

    #if DEBUG
        init(
            mandatoryIgnorePolicyIdentity: String,
            committedIgnoreControlDigest: String,
            configuredIgnoreAuthorityDigest: String,
            attributePolicyDigest: String,
            sparsePolicyDigest: String,
            searchABI: GitWorkspaceSearchABIIdentity,
            resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity?,
            resolvedAttributesFileIdentity: GitWorkspaceAuthorityContentIdentity?,
            canonicalizationDiagnostics: GitWorkspacePolicyCanonicalizationDiagnostics? = nil
        ) {
            self.mandatoryIgnorePolicyIdentity = mandatoryIgnorePolicyIdentity
            self.committedIgnoreControlDigest = committedIgnoreControlDigest
            self.configuredIgnoreAuthorityDigest = configuredIgnoreAuthorityDigest
            self.attributePolicyDigest = attributePolicyDigest
            self.sparsePolicyDigest = sparsePolicyDigest
            self.searchABI = searchABI
            self.resolvedExcludesFileIdentity = resolvedExcludesFileIdentity
            self.resolvedAttributesFileIdentity = resolvedAttributesFileIdentity
            self.canonicalizationDiagnostics = canonicalizationDiagnostics
        }
    #else
        init(
            mandatoryIgnorePolicyIdentity: String,
            committedIgnoreControlDigest: String,
            configuredIgnoreAuthorityDigest: String,
            attributePolicyDigest: String,
            sparsePolicyDigest: String,
            searchABI: GitWorkspaceSearchABIIdentity,
            resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity?,
            resolvedAttributesFileIdentity: GitWorkspaceAuthorityContentIdentity?
        ) {
            self.mandatoryIgnorePolicyIdentity = mandatoryIgnorePolicyIdentity
            self.committedIgnoreControlDigest = committedIgnoreControlDigest
            self.configuredIgnoreAuthorityDigest = configuredIgnoreAuthorityDigest
            self.attributePolicyDigest = attributePolicyDigest
            self.sparsePolicyDigest = sparsePolicyDigest
            self.searchABI = searchABI
            self.resolvedExcludesFileIdentity = resolvedExcludesFileIdentity
            self.resolvedAttributesFileIdentity = resolvedAttributesFileIdentity
        }
    #endif

    // Diagnostics are deliberately excluded from semantic identity.
    // swiftformat:disable:next redundantEquatable
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mandatoryIgnorePolicyIdentity == rhs.mandatoryIgnorePolicyIdentity
            && lhs.committedIgnoreControlDigest == rhs.committedIgnoreControlDigest
            && lhs.configuredIgnoreAuthorityDigest == rhs.configuredIgnoreAuthorityDigest
            && lhs.attributePolicyDigest == rhs.attributePolicyDigest
            && lhs.sparsePolicyDigest == rhs.sparsePolicyDigest
            && lhs.searchABI == rhs.searchABI
            && lhs.resolvedExcludesFileIdentity == rhs.resolvedExcludesFileIdentity
            && lhs.resolvedAttributesFileIdentity == rhs.resolvedAttributesFileIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(mandatoryIgnorePolicyIdentity)
        hasher.combine(committedIgnoreControlDigest)
        hasher.combine(configuredIgnoreAuthorityDigest)
        hasher.combine(attributePolicyDigest)
        hasher.combine(sparsePolicyDigest)
        hasher.combine(searchABI)
        hasher.combine(resolvedExcludesFileIdentity)
        hasher.combine(resolvedAttributesFileIdentity)
    }
}

struct GitWorkspaceAuthorityContentIdentity: Hashable {
    let exists: Bool
    let sha256: String
    let byteCount: Int
}

enum GitWorkspacePrefixControlKind: String, Hashable {
    case gitignore
    case repoIgnore
    case cursorIgnore
    case gitAttributes
}

struct GitWorkspacePrefixControlIdentity: Hashable {
    let repositoryRelativePath: String
    let kind: GitWorkspacePrefixControlKind
    let content: GitWorkspaceAuthorityContentIdentity
}

struct GitWorkspaceAuthorityMetadata {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let objectFormat: GitObjectFormat
    let headCommitOID: GitObjectID
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let ignoreAuthorityGeneration: String
    let attributeAuthorityGeneration: String
    let sparsePolicyGeneration: String
    let metadataGeneration: String
    let policyIdentity: GitWorkspacePolicyIdentity
    let resolvedExternalAuthorityPaths: [URL]
}

struct GitWorkspaceAuthorityScopeKey: Hashable {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
}

struct GitWorkspaceAuthorityCaptureToken: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    let invalidationGeneration: UInt64
    let scopePublicationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
}

/// Immutable identity required before a later content-addressed root/search
/// snapshot may be considered compatible. Target-local generations, records,
/// caches, and watcher state are intentionally excluded.
struct GitWorkspaceAuthoritySnapshot: Hashable {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let repositoryNamespace: GitBlobRepositoryNamespace
    let objectFormat: GitObjectFormat
    let headCommitOID: GitObjectID
    let treeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let repositoryBindingEpoch: String
    let worktreeBindingEpoch: String
    let layoutGeneration: String
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let metadataGeneration: String
    let policyIdentity: GitWorkspacePolicyIdentity
}

struct GitWorkspaceAuthorityLease: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    let authorityGeneration: UInt64
    let invalidationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
    let snapshot: GitWorkspaceAuthoritySnapshot

    var repositoryKey: GitWorkspaceAuthorityRepositoryKey {
        scopeKey.repositoryKey
    }
}

/// Ephemeral authority retained while a diff-seeded root is private. Unlike
/// the immutable 8A authority snapshot, this value owns live metadata
/// observation and must be released on publication handoff, fallback, abort,
/// or supersession.
struct GitWorkspacePendingInitializationAuthorityFence: Equatable {
    let snapshot: GitWorkspaceAuthoritySnapshot
    let lease: GitWorkspaceAuthorityLease
    let metadataObservationToken: GitWorkspaceMetadataMonitor.RetainToken
    let acceptedMetadataWatermark: UInt64
    let targetLayout: GitRepositoryLayout
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let additionalAuthorityPaths: [URL]
    let revalidationUsed: Bool

    var repositoryKey: GitWorkspaceAuthorityRepositoryKey {
        lease.repositoryKey
    }
}

/// A pending preparation performs no Git work while its retained evidence is
/// current. Accepted metadata events coalesce into one requested recapture;
/// instability after that single recapture fails closed.
enum GitWorkspacePendingAuthorityFenceDecision: Equatable {
    case current
    case revalidationRequired(latestAcceptedMetadataWatermark: UInt64)
    case fallback
}

enum GitWorkspaceAuthorityInvalidationKind: Equatable {
    case metadata(Set<GitWorkspaceMetadataEventKind>)
    case mutationBegan(GitWorkspaceMutationKind)
    case mutationCompleted(GitWorkspaceMutationKind, GitWorkspaceMutationOutcome)
}

/// Path-free notification used to trigger targeted authority reconciliation.
/// It is only a wakeup signal; consumers must prove currentness from a lease
/// and accepted metadata watermark rather than treating delivery as evidence.
struct GitWorkspaceAuthorityInvalidationEvent: Equatable {
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let invalidationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
    let kind: GitWorkspaceAuthorityInvalidationKind
}

struct GitWorktreeInitializationContext: Equatable {
    let agentSessionID: UUID
    let correlationID: UUID
    let standardizedLogicalRootPath: String
    let expectedOwnerBindingGeneration: UInt64
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let observeReceipt: Bool

    init(
        agentSessionID: UUID,
        correlationID: UUID,
        logicalRootPath: String,
        expectedOwnerBindingGeneration: UInt64,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        observeReceipt: Bool
    ) {
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        standardizedLogicalRootPath = StandardizedPath.absolute(logicalRootPath)
        self.expectedOwnerBindingGeneration = expectedOwnerBindingGeneration
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.observeReceipt = observeReceipt
    }
}

/// Scalar-only proof that the creation interval was continuously observed.
/// Creation contents come from final Git/index/status authority and exact
/// include-copy inventory; post-cut mutations replay from `endEventID`.
struct GitWorktreeCreationWitnessCoverage: Equatable {
    static let maximumLifetime: Duration = .seconds(60)

    let startedAtUptimeNanoseconds: UInt64
    let endedAtUptimeNanoseconds: UInt64
    let startEventID: UInt64
    let endEventID: UInt64
    let stableWatchRootAvailableBeforeMutation: Bool
    let destinationWasAbsentBeforeMutation: Bool
    let destinationWasStrictDescendant: Bool
    let stableWatchRootUnchangedAfterInitialization: Bool
    let streamCreationSucceeded: Bool
    let streamStartedBeforeMutation: Bool
    let activationFlushCompleted: Bool
    let activationCallbackBarrierCompleted: Bool
    let streamEndedAfterInitialization: Bool
    let endingFlushCompleted: Bool
    let endingCallbackBarrierCompleted: Bool
    let startAcceptedCallbackWatermark: UInt64
    let endAcceptedCallbackWatermark: UInt64
    let acceptedCallbackCount: Int
    let acceptedEventCount: Int
    let acceptedDestinationEventCount: Int
    let acceptedNonDestinationEventCount: Int
    let mustScanSubDirs: Bool
    let rootChanged: Bool
    let userDropped: Bool
    let kernelDropped: Bool
    let eventIDsWrapped: Bool
    let eventIDRegressed: Bool
    let lifetimeExceeded: Bool
    let hadGap: Bool
    let hadDrop: Bool
    let overflowed: Bool

    var provesCreationInterval: Bool {
        stableWatchRootAvailableBeforeMutation
            && destinationWasAbsentBeforeMutation
            && destinationWasStrictDescendant
            && stableWatchRootUnchangedAfterInitialization
            && streamCreationSucceeded
            && streamStartedBeforeMutation
            && activationFlushCompleted
            && activationCallbackBarrierCompleted
            && streamEndedAfterInitialization
            && endingFlushCompleted
            && endingCallbackBarrierCompleted
            && startEventID > 0
            && endEventID > 0
            && startEventID != UInt64.max
            && endEventID != UInt64.max
            && endAcceptedCallbackWatermark >= startAcceptedCallbackWatermark
            && !mustScanSubDirs
            && !rootChanged
            && !userDropped
            && !kernelDropped
            && !eventIDsWrapped
            && !eventIDRegressed
            && !lifetimeExceeded
            && !hadGap
            && !hadDrop
            && !overflowed
            && endedAtUptimeNanoseconds >= startedAtUptimeNanoseconds
            && endEventID >= startEventID
    }
}

struct GitWorktreeCreationReceipt: Equatable, @unchecked Sendable {
    let id: UUID
    let agentSessionID: UUID
    let correlationID: UUID
    let standardizedLogicalRootPath: String
    let expectedOwnerBindingGeneration: UInt64
    let mutationID: UUID
    let parentSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    let parentCompatibilityKey: WorkspaceRootSeedCompatibilityKey
    let parentAuthorityBefore: GitWorkspaceAuthoritySnapshot
    let targetAuthorityAfter: GitWorkspaceAuthoritySnapshot
    let requestedBaseRef: String?
    let resolvedBaseTreeOID: GitObjectID
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let plannedTargetPath: String
    let actualTargetPath: String
    let exactCopiedRelativePaths: [String]
    let includeCopyHadFailures: Bool
    let includeCopyWasComplete: Bool
    let destinationIsAppManaged: Bool
    let worktree: GitWorktreeDescriptor
    let targetLayout: GitRepositoryLayout
    let witnessCoverage: GitWorktreeCreationWitnessCoverage
    let expiresAtUptimeNanoseconds: UInt64

    func fallbackReason(
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> WorkspaceRootSeedFallbackReason? {
        guard nowUptimeNanoseconds <= expiresAtUptimeNanoseconds else { return .expiredReceipt }
        guard witnessCoverage.provesCreationInterval else {
            if witnessCoverage.overflowed { return .witnessOverflow }
            if witnessCoverage.hadDrop { return .witnessDrop }
            return .witnessGap
        }
        guard destinationIsAppManaged else { return .unsupportedDestination }
        guard includeCopyWasComplete,
              !includeCopyHadFailures
        else { return .includeCopyFailure }
        guard parentCompatibilityKey.searchABI == .current else { return .compatibilityMismatch }
        guard parentCompatibilityKey.treeOID == parentAuthorityBefore.treeOID,
              targetAuthorityAfter.treeOID == resolvedBaseTreeOID,
              parentCompatibilityKey.repositoryNamespace == targetAuthorityAfter.repositoryNamespace,
              parentCompatibilityKey.repositoryRelativeRootPrefix == repositoryRelativeRootPrefix,
              targetAuthorityAfter.repositoryRelativeRootPrefix == repositoryRelativeRootPrefix
        else { return .compatibilityMismatch }
        guard StandardizedPath.absolute(plannedTargetPath) == actualTargetPath,
              worktree.path == actualTargetPath,
              targetLayout.workTreeRoot.standardizedFileURL.path == actualTargetPath
        else { return .unsupportedDestination }
        return nil
    }
}

enum GitWorkspaceMutationKind: String, Hashable {
    case worktreeCreate
    case branchSwitch
    case fetch
    case mergeApply
    case mergeCommit
    case mergeContinue
    case mergeAbort
    case other
}

enum GitWorkspaceMutationOutcome: String, Hashable {
    case succeeded
    case failed
    case cancelled
}

struct GitWorkspaceMutationToken: Hashable {
    let id: UUID
    let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let affectedRepositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    let kind: GitWorkspaceMutationKind
    let correlationID: UUID?
}

enum GitWorkspaceMetadataEventKind: String, CaseIterable, Hashable {
    case dotGit
    case head
    case index
    case symbolicReference
    case packedReferences
    case references
    case configuration
    case ignoreAuthority
    case attributeAuthority
    case sparseCheckout
    case monitorGap
}

enum GitWorkspaceAuthorityUnavailableReason: String, Error, Equatable {
    case noSnapshot
    case mutationInProgress
    case metadataEventPending
    case monitorCoverageUnavailable
    case superseded
    case invalidatedDuringCollection
    case collectionScopeMismatch
}
