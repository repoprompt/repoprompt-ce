import Darwin
import Dispatch
import Foundation
import RepoPromptFileSystem
import RepoPromptInstrumentation
import RepoPromptPersistence
import RepoPromptVCS
import RepoPromptWorkspaceCore

package struct GitWorkspaceAuthorityRepositoryKey: Hashable {
    package let standardizedCommonDirectoryPath: String
    package let standardizedGitDirectoryPath: String
    package let commonDirectoryDevice: UInt64?
    package let commonDirectoryInode: UInt64?

    package init(layout: GitRepositoryLayout) {
        standardizedCommonDirectoryPath = layout.commonDir.standardizedFileURL.path
        standardizedGitDirectoryPath = layout.gitDir.standardizedFileURL.path
        var value = stat()
        if lstat(layout.commonDir.path, &value) == 0 {
            commonDirectoryDevice = safeDeviceID(value.st_dev)
            commonDirectoryInode = UInt64(value.st_ino)
        } else {
            commonDirectoryDevice = nil
            commonDirectoryInode = nil
        }
    }
}

package struct GitWorkspaceSearchABIIdentity: Hashable {
    package let matcherSchemaVersion: Int
    package let projectedKeySchemaVersion: Int
    package let comparatorSchemaVersion: Int
    package let pathNormalizationSchemaVersion: Int

    package static let current = GitWorkspaceSearchABIIdentity(
        matcherSchemaVersion: 1,
        projectedKeySchemaVersion: 3,
        comparatorSchemaVersion: 1,
        pathNormalizationSchemaVersion: 1
    )
}

package struct GitWorkspacePolicyIdentity: Hashable {
    package let mandatoryIgnorePolicyIdentity: String
    package let committedIgnoreControlDigest: String
    package let configuredIgnoreAuthorityDigest: String
    package let attributePolicyDigest: String
    package let sparsePolicyDigest: String
    let searchABI: GitWorkspaceSearchABIIdentity
    let resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    let resolvedAttributesFileIdentity: GitWorkspaceAuthorityContentIdentity?
    #if DEBUG
        /// Non-identity, path-free evidence used only by DEBUG diagnostics.
        let canonicalizationDiagnostics: GitWorkspacePolicyCanonicalizationDiagnostics?
    #endif

    #if DEBUG
        package init(
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
        package init(
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
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mandatoryIgnorePolicyIdentity == rhs.mandatoryIgnorePolicyIdentity
            && lhs.committedIgnoreControlDigest == rhs.committedIgnoreControlDigest
            && lhs.configuredIgnoreAuthorityDigest == rhs.configuredIgnoreAuthorityDigest
            && lhs.attributePolicyDigest == rhs.attributePolicyDigest
            && lhs.sparsePolicyDigest == rhs.sparsePolicyDigest
            && lhs.searchABI == rhs.searchABI
            && lhs.resolvedExcludesFileIdentity == rhs.resolvedExcludesFileIdentity
            && lhs.resolvedAttributesFileIdentity == rhs.resolvedAttributesFileIdentity
    }

    package func hash(into hasher: inout Hasher) {
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

package struct GitWorkspaceAuthorityContentIdentity: Hashable {
    package let exists: Bool
    package let sha256: String
    package let byteCount: Int
    package init(
        exists: Bool,
        sha256: String,
        byteCount: Int
    ) {
        self.exists = exists
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

package enum GitWorkspacePrefixControlKind: String, Hashable {
    case gitignore
    case repoIgnore
    case cursorIgnore
    case gitAttributes
}

package struct GitWorkspacePrefixControlIdentity: Hashable {
    package let repositoryRelativePath: String
    package let kind: GitWorkspacePrefixControlKind
    package let content: GitWorkspaceAuthorityContentIdentity
    package init(
        repositoryRelativePath: String,
        kind: GitWorkspacePrefixControlKind,
        content: GitWorkspaceAuthorityContentIdentity
    ) {
        self.repositoryRelativePath = repositoryRelativePath
        self.kind = kind
        self.content = content
    }
}

package struct GitWorkspaceAuthorityMetadata {
    package let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    package let objectFormat: GitObjectFormat
    package let headCommitOID: GitObjectID
    package let treeOID: GitObjectID
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package let indexGeneration: String
    package let checkoutConfigurationGeneration: String
    package let ignoreAuthorityGeneration: String
    package let attributeAuthorityGeneration: String
    package let sparsePolicyGeneration: String
    package let metadataGeneration: String
    package let policyIdentity: GitWorkspacePolicyIdentity
    package let resolvedExternalAuthorityPaths: [URL]
    package init(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        objectFormat: GitObjectFormat,
        headCommitOID: GitObjectID,
        treeOID: GitObjectID,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        indexGeneration: String,
        checkoutConfigurationGeneration: String,
        ignoreAuthorityGeneration: String,
        attributeAuthorityGeneration: String,
        sparsePolicyGeneration: String,
        metadataGeneration: String,
        policyIdentity: GitWorkspacePolicyIdentity,
        resolvedExternalAuthorityPaths: [URL]
    ) {
        self.repositoryKey = repositoryKey
        self.objectFormat = objectFormat
        self.headCommitOID = headCommitOID
        self.treeOID = treeOID
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.indexGeneration = indexGeneration
        self.checkoutConfigurationGeneration = checkoutConfigurationGeneration
        self.ignoreAuthorityGeneration = ignoreAuthorityGeneration
        self.attributeAuthorityGeneration = attributeAuthorityGeneration
        self.sparsePolicyGeneration = sparsePolicyGeneration
        self.metadataGeneration = metadataGeneration
        self.policyIdentity = policyIdentity
        self.resolvedExternalAuthorityPaths = resolvedExternalAuthorityPaths
    }
}

package struct GitWorkspaceAuthorityScopeKey: Hashable {
    package let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package init(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    ) {
        self.repositoryKey = repositoryKey
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
    }
}

package struct GitWorkspaceAuthorityCaptureToken: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    package let invalidationGeneration: UInt64
    let scopePublicationGeneration: UInt64
    package let acceptedMetadataWatermark: UInt64
}

/// Immutable identity required before a later content-addressed root/search
/// snapshot may be considered compatible. Target-local generations, records,
/// caches, and watcher state are intentionally excluded.
package struct GitWorkspaceAuthoritySnapshot: Hashable {
    package let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    package let repositoryNamespace: GitBlobRepositoryNamespace
    package let objectFormat: GitObjectFormat
    package let headCommitOID: GitObjectID
    package let treeOID: GitObjectID
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package let repositoryBindingEpoch: String
    package let worktreeBindingEpoch: String
    package let layoutGeneration: String
    package let indexGeneration: String
    package let checkoutConfigurationGeneration: String
    package let metadataGeneration: String
    package let policyIdentity: GitWorkspacePolicyIdentity
    package init(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        repositoryNamespace: GitBlobRepositoryNamespace,
        objectFormat: GitObjectFormat,
        headCommitOID: GitObjectID,
        treeOID: GitObjectID,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        repositoryBindingEpoch: String,
        worktreeBindingEpoch: String,
        layoutGeneration: String,
        indexGeneration: String,
        checkoutConfigurationGeneration: String,
        metadataGeneration: String,
        policyIdentity: GitWorkspacePolicyIdentity
    ) {
        self.repositoryKey = repositoryKey
        self.repositoryNamespace = repositoryNamespace
        self.objectFormat = objectFormat
        self.headCommitOID = headCommitOID
        self.treeOID = treeOID
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.repositoryBindingEpoch = repositoryBindingEpoch
        self.worktreeBindingEpoch = worktreeBindingEpoch
        self.layoutGeneration = layoutGeneration
        self.indexGeneration = indexGeneration
        self.checkoutConfigurationGeneration = checkoutConfigurationGeneration
        self.metadataGeneration = metadataGeneration
        self.policyIdentity = policyIdentity
    }
}

package struct GitWorkspaceAuthorityLease: Hashable {
    let scopeKey: GitWorkspaceAuthorityScopeKey
    package let authorityGeneration: UInt64
    package let invalidationGeneration: UInt64
    package let acceptedMetadataWatermark: UInt64
    package let snapshot: GitWorkspaceAuthoritySnapshot

    package var repositoryKey: GitWorkspaceAuthorityRepositoryKey {
        scopeKey.repositoryKey
    }
}

/// Ephemeral authority retained while a diff-seeded root is private. Unlike
/// the immutable 8A authority snapshot, this value owns live metadata
/// observation and must be released on publication handoff, fallback, abort,
/// or supersession.
package struct GitWorkspacePendingInitializationAuthorityFence: Equatable {
    package let snapshot: GitWorkspaceAuthoritySnapshot
    package let lease: GitWorkspaceAuthorityLease
    package let metadataObservationToken: GitWorkspaceMetadataMonitor.RetainToken
    package let acceptedMetadataWatermark: UInt64
    package let targetLayout: GitRepositoryLayout
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package let additionalAuthorityPaths: [URL]
    package let revalidationUsed: Bool

    package var repositoryKey: GitWorkspaceAuthorityRepositoryKey {
        lease.repositoryKey
    }
}

/// A pending preparation performs no Git work while its retained evidence is
/// current. Accepted metadata events coalesce into one requested recapture;
/// instability after that single recapture fails closed.
package enum GitWorkspacePendingAuthorityFenceDecision: Equatable {
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
    package let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    package let invalidationGeneration: UInt64
    package let acceptedMetadataWatermark: UInt64
    package let kind: GitWorkspaceAuthorityInvalidationKind
}

package struct GitWorktreeInitializationContext: Equatable {
    package let agentSessionID: UUID
    package let correlationID: UUID
    package let standardizedLogicalRootPath: String
    package let expectedOwnerBindingGeneration: UInt64
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package let observeReceipt: Bool

    package init(
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
package struct GitWorktreeCreationWitnessCoverage: Equatable {
    static let maximumLifetime: Duration = .seconds(60)

    package let startedAtUptimeNanoseconds: UInt64
    package let endedAtUptimeNanoseconds: UInt64
    package let startEventID: UInt64
    package let endEventID: UInt64
    package let stableWatchRootAvailableBeforeMutation: Bool
    package let destinationWasAbsentBeforeMutation: Bool
    package let destinationWasStrictDescendant: Bool
    package let stableWatchRootUnchangedAfterInitialization: Bool
    package let streamCreationSucceeded: Bool
    package let streamStartedBeforeMutation: Bool
    package let activationFlushCompleted: Bool
    package let activationCallbackBarrierCompleted: Bool
    package let streamEndedAfterInitialization: Bool
    package let endingFlushCompleted: Bool
    package let endingCallbackBarrierCompleted: Bool
    package let startAcceptedCallbackWatermark: UInt64
    package let endAcceptedCallbackWatermark: UInt64
    package let acceptedCallbackCount: Int
    package let acceptedEventCount: Int
    package let acceptedDestinationEventCount: Int
    package let acceptedNonDestinationEventCount: Int
    package let mustScanSubDirs: Bool
    package let rootChanged: Bool
    package let userDropped: Bool
    package let kernelDropped: Bool
    package let eventIDsWrapped: Bool
    package let eventIDRegressed: Bool
    package let lifetimeExceeded: Bool
    package let hadGap: Bool
    package let hadDrop: Bool
    package let overflowed: Bool

    package var provesCreationInterval: Bool {
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

    package init(
        startedAtUptimeNanoseconds: UInt64,
        endedAtUptimeNanoseconds: UInt64,
        startEventID: UInt64,
        endEventID: UInt64,
        stableWatchRootAvailableBeforeMutation: Bool,
        destinationWasAbsentBeforeMutation: Bool,
        destinationWasStrictDescendant: Bool,
        stableWatchRootUnchangedAfterInitialization: Bool,
        streamCreationSucceeded: Bool,
        streamStartedBeforeMutation: Bool,
        activationFlushCompleted: Bool,
        activationCallbackBarrierCompleted: Bool,
        streamEndedAfterInitialization: Bool,
        endingFlushCompleted: Bool,
        endingCallbackBarrierCompleted: Bool,
        startAcceptedCallbackWatermark: UInt64,
        endAcceptedCallbackWatermark: UInt64,
        acceptedCallbackCount: Int,
        acceptedEventCount: Int,
        acceptedDestinationEventCount: Int,
        acceptedNonDestinationEventCount: Int,
        mustScanSubDirs: Bool,
        rootChanged: Bool,
        userDropped: Bool,
        kernelDropped: Bool,
        eventIDsWrapped: Bool,
        eventIDRegressed: Bool,
        lifetimeExceeded: Bool,
        hadGap: Bool,
        hadDrop: Bool,
        overflowed: Bool
    ) {
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        self.endedAtUptimeNanoseconds = endedAtUptimeNanoseconds
        self.startEventID = startEventID
        self.endEventID = endEventID
        self.stableWatchRootAvailableBeforeMutation = stableWatchRootAvailableBeforeMutation
        self.destinationWasAbsentBeforeMutation = destinationWasAbsentBeforeMutation
        self.destinationWasStrictDescendant = destinationWasStrictDescendant
        self.stableWatchRootUnchangedAfterInitialization = stableWatchRootUnchangedAfterInitialization
        self.streamCreationSucceeded = streamCreationSucceeded
        self.streamStartedBeforeMutation = streamStartedBeforeMutation
        self.activationFlushCompleted = activationFlushCompleted
        self.activationCallbackBarrierCompleted = activationCallbackBarrierCompleted
        self.streamEndedAfterInitialization = streamEndedAfterInitialization
        self.endingFlushCompleted = endingFlushCompleted
        self.endingCallbackBarrierCompleted = endingCallbackBarrierCompleted
        self.startAcceptedCallbackWatermark = startAcceptedCallbackWatermark
        self.endAcceptedCallbackWatermark = endAcceptedCallbackWatermark
        self.acceptedCallbackCount = acceptedCallbackCount
        self.acceptedEventCount = acceptedEventCount
        self.acceptedDestinationEventCount = acceptedDestinationEventCount
        self.acceptedNonDestinationEventCount = acceptedNonDestinationEventCount
        self.mustScanSubDirs = mustScanSubDirs
        self.rootChanged = rootChanged
        self.userDropped = userDropped
        self.kernelDropped = kernelDropped
        self.eventIDsWrapped = eventIDsWrapped
        self.eventIDRegressed = eventIDRegressed
        self.lifetimeExceeded = lifetimeExceeded
        self.hadGap = hadGap
        self.hadDrop = hadDrop
        self.overflowed = overflowed
    }
}

package struct GitWorktreeCreationReceipt: Equatable, @unchecked Sendable {
    package let id: UUID
    package let agentSessionID: UUID
    package let correlationID: UUID
    package let standardizedLogicalRootPath: String
    package let expectedOwnerBindingGeneration: UInt64
    package let mutationID: UUID
    package let parentSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity
    package let parentCompatibilityKey: WorkspaceRootSeedCompatibilityKey
    package let parentAuthorityBefore: GitWorkspaceAuthoritySnapshot
    package let targetAuthorityAfter: GitWorkspaceAuthoritySnapshot
    package let requestedBaseRef: String?
    package let resolvedBaseTreeOID: GitObjectID
    package let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    package let plannedTargetPath: String
    package let actualTargetPath: String
    package let exactCopiedRelativePaths: [String]
    package let includeCopyHadFailures: Bool
    package let includeCopyWasComplete: Bool
    package let destinationIsAppManaged: Bool
    package let worktree: GitWorktreeDescriptor
    package let targetLayout: GitRepositoryLayout
    package let witnessCoverage: GitWorktreeCreationWitnessCoverage
    package let expiresAtUptimeNanoseconds: UInt64

    package func fallbackReason(
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

    package init(
        id: UUID,
        agentSessionID: UUID,
        correlationID: UUID,
        standardizedLogicalRootPath: String,
        expectedOwnerBindingGeneration: UInt64,
        mutationID: UUID,
        parentSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity,
        parentCompatibilityKey: WorkspaceRootSeedCompatibilityKey,
        parentAuthorityBefore: GitWorkspaceAuthoritySnapshot,
        targetAuthorityAfter: GitWorkspaceAuthoritySnapshot,
        requestedBaseRef: String?,
        resolvedBaseTreeOID: GitObjectID,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        plannedTargetPath: String,
        actualTargetPath: String,
        exactCopiedRelativePaths: [String],
        includeCopyHadFailures: Bool,
        includeCopyWasComplete: Bool,
        destinationIsAppManaged: Bool,
        worktree: GitWorktreeDescriptor,
        targetLayout: GitRepositoryLayout,
        witnessCoverage: GitWorktreeCreationWitnessCoverage,
        expiresAtUptimeNanoseconds: UInt64
    ) {
        self.id = id
        self.agentSessionID = agentSessionID
        self.correlationID = correlationID
        self.standardizedLogicalRootPath = standardizedLogicalRootPath
        self.expectedOwnerBindingGeneration = expectedOwnerBindingGeneration
        self.mutationID = mutationID
        self.parentSnapshotIdentity = parentSnapshotIdentity
        self.parentCompatibilityKey = parentCompatibilityKey
        self.parentAuthorityBefore = parentAuthorityBefore
        self.targetAuthorityAfter = targetAuthorityAfter
        self.requestedBaseRef = requestedBaseRef
        self.resolvedBaseTreeOID = resolvedBaseTreeOID
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.plannedTargetPath = plannedTargetPath
        self.actualTargetPath = actualTargetPath
        self.exactCopiedRelativePaths = exactCopiedRelativePaths
        self.includeCopyHadFailures = includeCopyHadFailures
        self.includeCopyWasComplete = includeCopyWasComplete
        self.destinationIsAppManaged = destinationIsAppManaged
        self.worktree = worktree
        self.targetLayout = targetLayout
        self.witnessCoverage = witnessCoverage
        self.expiresAtUptimeNanoseconds = expiresAtUptimeNanoseconds
    }
}

package enum GitWorkspaceMutationKind: String, Hashable {
    case worktreeCreate
    case branchSwitch
    case fetch
    case mergeApply
    case mergeCommit
    case mergeContinue
    case mergeAbort
    case other
}

package enum GitWorkspaceMutationOutcome: String, Hashable {
    case succeeded
    case failed
    case cancelled
}

package struct GitWorkspaceMutationToken: Hashable {
    package let id: UUID
    package let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    let affectedRepositoryKeys: Set<GitWorkspaceAuthorityRepositoryKey>
    package let kind: GitWorkspaceMutationKind
    package let correlationID: UUID?
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

package enum GitWorkspaceAuthorityUnavailableReason: String, Error, Equatable {
    case noSnapshot
    case mutationInProgress
    case metadataEventPending
    case monitorCoverageUnavailable
    case superseded
    case invalidatedDuringCollection
    case collectionScopeMismatch
}
