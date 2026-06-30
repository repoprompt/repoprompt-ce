import Foundation
@testable import RepoPrompt

enum WorkspaceRootSeedTestSupport {
    static func oid(_ scalar: Character = "1") -> GitObjectID {
        try! GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: scalar, count: 40))
    }

    static func compatibilityKey(
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        committedIgnoreDigest: String = "ignore",
        canonicalizationDiagnostics: GitWorkspacePolicyCanonicalizationDiagnostics? = nil
    ) -> WorkspaceRootSeedCompatibilityKey {
        let root = URL(fileURLWithPath: "/tmp/workspace-root-seed-tests")
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let layout = GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: git,
            gitDir: git,
            commonDir: git,
            isWorktree: false
        )
        let policy = GitWorkspacePolicyIdentity(
            mandatoryIgnorePolicyIdentity: canonicalizationDiagnostics?.canonicalizationPolicyVersion
                ?? WorkspaceGitignorePolicyIdentity.current.rawValue,
            committedIgnoreControlDigest: canonicalizationDiagnostics?.canonicalIgnoreFooter.digest
                ?? committedIgnoreDigest,
            configuredIgnoreAuthorityDigest: canonicalizationDiagnostics?.configuredIgnorePolicyDigest
                ?? "configured-ignore",
            attributePolicyDigest: canonicalizationDiagnostics?.attributePolicyDigest ?? "attributes",
            sparsePolicyDigest: canonicalizationDiagnostics?.sparsePolicyDigest ?? "sparse-disabled",
            searchABI: .current,
            resolvedExcludesFileIdentity: nil,
            resolvedAttributesFileIdentity: nil,
            canonicalizationDiagnostics: canonicalizationDiagnostics
        )
        let authority = GitWorkspaceAuthoritySnapshot(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            repositoryNamespace: try! GitBlobRepositoryNamespace(rawValue: String(repeating: "a", count: 64)),
            objectFormat: .sha1,
            headCommitOID: oid("b"),
            treeOID: treeOID,
            repositoryRelativeRootPrefix: prefix,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            metadataGeneration: "metadata",
            policyIdentity: policy
        )
        return WorkspaceRootSeedCompatibilityKey(authority: authority)
    }

    static func canonicalizationDiagnostics(
        prunedRootCount: Int = 0,
        prunedRootSummarySHA256: String = String(repeating: "a", count: 64),
        completeness: GitWorkspacePolicyCanonicalizationDiagnostics.Completeness = .complete,
        committedControlCount: Int = 1,
        committedControlSummarySHA256: String = String(repeating: "b", count: 64)
    ) -> GitWorkspacePolicyCanonicalizationDiagnostics {
        func digest(_ scalar: Character) -> String {
            String(repeating: scalar, count: 64)
        }
        return GitWorkspacePolicyCanonicalizationDiagnostics(
            rootNeutralPolicyConfigByteCount: 0,
            rootNeutralPolicyConfigSHA256: digest("0"),
            commonInfoExclude: .init(state: .missing, digest: digest("1")),
            canonicalIgnoreFooter: .init(digest: digest("2"), recordCount: 4),
            externalExcludes: .init(state: .unset, identityDigest: digest("3"), byteCount: 0),
            configuredIgnorePolicyDigest: digest("4"),
            commonInfoAttributes: .init(state: .missing, digest: digest("5")),
            canonicalAttributeFooter: .init(digest: digest("6"), recordCount: 1),
            externalAttributes: .init(state: .unset, identityDigest: digest("7"), byteCount: 0),
            attributePolicyDigest: digest("8"),
            sparsePolicyDigest: digest("9"),
            canonicalizationPolicyVersion: WorkspaceGitignorePolicyIdentity.current.rawValue,
            prunedRootCount: prunedRootCount,
            prunedRootSummarySHA256: prunedRootSummarySHA256,
            completeness: completeness,
            committedControlCount: committedControlCount,
            committedControlSummarySHA256: committedControlSummarySHA256
        )
    }

    static func snapshot(
        paths: [(String, String)],
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        policyIgnoredPaths: Set<String> = [],
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults
    ) async throws -> WorkspaceRootReusableSnapshot {
        let compatibility = compatibilityKey(treeOID: treeOID, prefix: prefix)
        let store = try WorkspaceRootReusableInventoryManifestStore()
        let writer = try store.makeWriter(header: WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: WorkspaceRootReusableSnapshot.compatibilityDigest(compatibility),
            treeOID: treeOID,
            objectFormat: treeOID.objectFormat,
            repositoryRelativeRootPrefix: prefix,
            commandFormat: "test-fixture-v1",
            rawStandardOutputDigest: Data(repeating: 0, count: 32),
            catalogPolicyDigest: WorkspaceRootReusableSnapshot.catalogPolicyDigest(catalogPolicyIdentity)
        ))
        for (ordinal, value) in paths.enumerated() {
            try await writer.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePath: value.0,
                mode: value.1,
                kind: .blob,
                objectID: oid(Character(String((ordinal % 8) + 1))),
                catalogProjection: policyIgnoredPaths.contains(value.0)
                    ? .policyIgnoredRegularFile
                    : .searchableRegularFile
            ))
        }
        let manifest = try await writer.finish()
        let reader = try manifest.makeReader()
        var searchablePaths: [String] = []
        var ordinals: [Int] = []
        while let entry = try reader.next() {
            if entry.isSearchableFile {
                searchablePaths.append(entry.relativePath)
                ordinals.append(entry.ordinal)
            }
        }
        return WorkspaceRootReusableSnapshot(
            compatibilityKey: compatibility,
            inventoryManifest: manifest,
            searchBase: WorkspaceSearchRelativePathBase(
                relativePaths: searchablePaths,
                stableOrdinals: ordinals
            ),
            catalogPolicyIdentity: catalogPolicyIdentity,
            estimatedByteCount: searchablePaths.reduce(0) { $0 + $1.utf8.count + 96 }
        )
    }

    static func indexEntry(
        _ path: String,
        mode: String = "100644",
        stage: Int = 0,
        assumeUnchanged: Bool = false,
        skipWorktree: Bool = false
    ) -> GitIndexManifestEntry {
        GitIndexManifestEntry(
            mode: mode,
            objectID: oid("c"),
            stage: stage,
            repositoryRelativePath: path,
            assumeUnchanged: assumeUnchanged,
            skipWorktree: skipWorktree
        )
    }

    static func status(
        _ records: [GitPorcelainV2PathRecord]
    ) -> GitStatusPorcelainV2Snapshot {
        GitStatusPorcelainV2Snapshot(
            branch: nil,
            headID: nil,
            upstream: nil,
            ahead: nil,
            behind: nil,
            staged: [],
            modified: [],
            untracked: records.compactMap { $0.kind == .untracked ? $0.path : nil },
            pathRecords: records
        )
    }

    static func pathRecord(
        kind: GitPorcelainV2RecordKind,
        path: String,
        indexStatus: Character? = ".",
        workTreeStatus: Character? = ".",
        indexMode: String? = "100644",
        workTreeMode: String? = "100644",
        submoduleState: String? = "N..."
    ) -> GitPorcelainV2PathRecord {
        GitPorcelainV2PathRecord(
            kind: kind,
            path: path,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            submoduleState: submoduleState,
            headMode: "100644",
            indexMode: indexMode,
            workTreeMode: workTreeMode,
            headOID: oid("d").lowercaseHex,
            indexOID: oid("e").lowercaseHex,
            conflictStage1Mode: nil,
            conflictStage2Mode: nil,
            conflictStage3Mode: nil,
            conflictStage1OID: nil,
            conflictStage2OID: nil,
            conflictStage3OID: nil
        )
    }
}
