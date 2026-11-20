import Foundation
import RepoPromptVCS

package enum GitPrefixControlEvidenceCacheMode {
    case automatic
    case bypassReadAndAdmission
}

package struct GitLoadedRootTreeInventorySpool: @unchecked Sendable {
    package static let commandFormat = "git-ls-tree-recursive-full-tree-z-v1"

    package let rawOutput: GitRawOutputSpoolLease
    package let stdoutSHA256: Data
    package let treeOID: GitObjectID
    package let rootPrefix: GitRepositoryRelativeRootPrefix

    package init(rawOutput: GitRawOutputSpoolLease, stdoutSHA256: Data, treeOID: GitObjectID, rootPrefix: GitRepositoryRelativeRootPrefix) {
        self.rawOutput = rawOutput
        self.stdoutSHA256 = stdoutSHA256
        self.treeOID = treeOID
        self.rootPrefix = rootPrefix
    }
}

/// Workspace-owned Git observations and evidence, supplied by the host's existing Git actor.
/// Requirements deliberately have no defaults: callers preserve their existing resource policy.
package protocol WorkspaceGitClient: Sendable {
    /// Preserve concrete Git process error classification without exporting the host actor.
    func isGitProcessError(_ error: Error) -> Bool
    func retainRepositoryLayout(_ layout: GitRepositoryLayout) async
    func releaseRepositoryLayout(workTreeRoot: URL, expectedGitDirectory: URL) async
    func findGitRoot(from path: URL) async throws -> URL?
    func gitRepositoryKind(at path: URL) async throws -> GitRepositoryKind
    func generationFencedAuthoritySnapshot(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> GitWorkspaceAuthoritySnapshot
    func pendingInitializationAuthorityFence(
        layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence
    func releasePendingInitializationAuthorityFence(_ fence: GitWorkspacePendingInitializationAuthorityFence) async
    func recapturePublishedInitializationAuthorityFence(
        replacing fence: GitWorkspacePendingInitializationAuthorityFence
    ) async throws -> GitWorkspacePendingInitializationAuthorityFence
    func resolveGitBlobRepository(containing workspaceRoot: URL) async throws -> GitRepositoryLayout?
    func spoolLoadedRootTreeInventory(
        _ treeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        resourcePolicy: GitRawOutputSpoolResourcePolicy,
        priority: GitProcessAdmissionPriority
    ) async throws -> GitLoadedRootTreeInventorySpool
    func diffTrees(
        baseTreeOID: GitObjectID,
        targetTreeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        limits: GitWorktreeInitializationLimits,
        priority: GitProcessAdmissionPriority
    ) async throws -> [GitTreeDeltaRecord]
    func writeTreeDeltaEvidence(
        baseTreeOID: GitObjectID,
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy,
        pathPolicy: GitTargetEvidencePathPolicy,
        priority: GitProcessAdmissionPriority
    ) async throws -> GitTargetTreeDeltaEvidenceLease
    func writeIndexEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy,
        pathPolicy: GitTargetEvidencePathPolicy,
        priority: GitProcessAdmissionPriority
    ) async throws -> GitTargetIndexEvidenceLease
    func writeStatusEvidence(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        authorityFence: GitWorkspacePendingInitializationAuthorityFence,
        attemptID: UUID,
        suppliedCreationCutProvenanceBytes: Data?,
        store: GitTargetEvidenceManifestStore,
        includeUntracked: Bool,
        includeIgnored: Bool,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy,
        spoolResourcePolicy: GitRawOutputSpoolResourcePolicy,
        pathPolicy: GitTargetEvidencePathPolicy,
        priority: GitProcessAdmissionPriority
    ) async throws -> GitTargetStatusEvidenceLease
    func workspaceAuthoritySnapshot(
        in layout: GitRepositoryLayout,
        prefix: GitRepositoryRelativeRootPrefix,
        priority: GitProcessAdmissionPriority,
        cacheMode: GitPrefixControlEvidenceCacheMode
    ) async throws -> (metadata: GitWorkspaceAuthorityMetadata, snapshot: GitWorkspaceAuthoritySnapshot)
    func gitBlobObjectFormat(at repositoryRoot: URL) async throws -> GitObjectFormat
    func gitBlobObjectSize(in layout: GitRepositoryLayout, oid: GitBlobOID) async throws -> UInt64
    func gitBlobObjectBytes(in layout: GitRepositoryLayout, oid: GitBlobOID, expectedByteCount: Int) async throws -> Data
    func gitBlobIndexEntries(at repositoryRoot: URL, repositoryRelativePaths: [String]) async throws -> [GitBlobIndexEntry]
    func gitBlobStatusRecords(at repositoryRoot: URL, repositoryRelativePaths: [String]) async throws -> [GitPorcelainV2PathRecord]
    func gitBlobAttributes(at repositoryRoot: URL, repositoryRelativePaths: [String]) async throws -> [String: GitBlobPathAttributes]
    func gitBlobCheckoutConfiguration(at repositoryRoot: URL) async throws -> GitBlobCheckoutConfiguration
    func gitCodemapAuthorityConfiguration(at repositoryRoot: URL) async throws -> GitCodemapAuthorityConfiguration
}
