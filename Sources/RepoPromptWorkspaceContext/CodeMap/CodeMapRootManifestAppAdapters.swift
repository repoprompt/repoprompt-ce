import RepoPromptCodeMapCore
import RepoPromptPersistence
import RepoPromptVCS

extension VerifiedGitBlobCodeMapLocatorAssociation {
    static func verify(
        source: CodeMapSourceSnapshot,
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        casHandle: CodeMapArtifactHandle
    ) throws -> Self {
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.sourceProvenanceMismatch
        }
        guard repositoryNamespace == identity.repositoryNamespace else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.repositoryNamespaceMismatch
        }
        guard blobOID.objectFormat == identity.objectFormat else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.objectFormatMismatch
        }
        guard blobOID == identity.blobOID,
              GitBlobOID.blob(bytes: source.rawBytes, objectFormat: blobOID.objectFormat) == blobOID
        else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.gitBlobOIDMismatch
        }
        guard UInt64(source.rawByteCount) == artifactKey.rawByteCount else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.rawByteCountMismatch
        }
        guard source.rawSHA256 == artifactKey.rawSHA256 else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.rawDigestMismatch
        }
        return try revalidatePersisted(identity: identity, artifactKey: artifactKey, casHandle: casHandle)
    }
}

/// Workspace capability validation stays at the app boundary; persistence receives values only.
extension CodeMapRootManifestNamespace {
    init(capability: GitCodemapRootCapability, pipelineIdentity: CodeMapPipelineIdentity) throws {
        try self.init(
            repositoryNamespace: capability.repositoryNamespace,
            worktreeIdentity: capability.worktreeID,
            repositoryRelativeLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix,
            objectFormat: capability.objectFormat,
            pipelineIdentity: pipelineIdentity,
            repositoryBindingEpoch: capability.repositoryAuthority.repositoryBindingEpoch,
            worktreeBindingEpoch: capability.repositoryAuthority.worktreeBindingEpoch
        )
    }
}

extension CodeMapRootManifestAuthority {
    init(namespace: CodeMapRootManifestNamespace, token: WorkspaceCodemapRepositoryAuthorityToken) throws {
        guard namespace.repositoryNamespace == token.repositoryNamespace,
              namespace.objectFormat == token.objectFormat,
              namespace.repositoryBindingEpoch == token.repositoryBindingEpoch,
              namespace.worktreeBindingEpoch == token.worktreeBindingEpoch
        else {
            throw CodeMapRootManifestModelError.invalidAuthority
        }
        try self.init(
            authorityGeneration: token.authorityGeneration,
            repositoryBindingEpoch: token.repositoryBindingEpoch,
            worktreeBindingEpoch: token.worktreeBindingEpoch,
            layoutGeneration: token.layoutGeneration,
            indexGeneration: token.indexGeneration,
            checkoutConfigurationGeneration: token.checkoutConfigurationGeneration,
            attributeGeneration: token.attributeGeneration,
            sparseGeneration: token.sparseGeneration,
            metadataGeneration: token.metadataGeneration
        )
    }
}
