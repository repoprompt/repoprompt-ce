import CryptoKit
import Foundation
@testable import RepoPrompt

enum WorkspaceRootTargetSeedPlanTestSupport {
    struct Fixture {
        let namespace: WorkspaceRootNamespaceManifestLease
        let evidence: GitTargetEvidenceBundleLease
        let plan: WorkspaceRootTargetSeedPlanManifestLease
        let handle: WorkspaceRootTargetSeedPlanHandle
    }

    static func makeFixture(
        root: URL,
        storeRoot: URL,
        snapshot: WorkspaceRootReusableSnapshot,
        namespaceRecords: [WorkspaceRootNamespaceRecord],
        deltaRecords: [GitTargetTreeDeltaEvidenceRecord] = [],
        indexRecords: [GitTargetIndexEvidenceRecord],
        statusRecords: [GitTargetStatusEvidenceRecord] = [],
        sparseCheckoutEnabled: Bool = false,
        targetTreeOID: GitObjectID? = nil
    ) async throws -> Fixture {
        let targetTreeOID = targetTreeOID ?? snapshot.compatibilityKey.treeOID
        let namespaceStore = try WorkspaceRootNamespaceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("namespace-\(UUID().uuidString)", isDirectory: true)
        )
        let namespaceWriter = try namespaceStore.makeWriter(
            identity: WorkspaceRootNamespaceManifestIdentity(
                root: WorkspaceRootNamespaceRootIdentity(rootURL: root),
                catalogPolicy: snapshot.catalogPolicyIdentity
            ),
            resourcePolicy: namespacePolicy
        )
        for record in namespaceRecords {
            try await namespaceWriter.append(record)
        }
        let namespace = try await namespaceWriter.finish()

        let evidenceStore = try GitTargetEvidenceManifestStore(
            directoryURL: storeRoot.appendingPathComponent("evidence-\(UUID().uuidString)", isDirectory: true)
        )
        let attemptID = UUID()
        let treeWriter = try evidenceStore.makeTreeDeltaWriter(
            identity: evidenceIdentity(
                root: root,
                family: .treeDelta,
                snapshot: snapshot,
                targetTreeOID: targetTreeOID,
                attemptID: attemptID,
                sparseCheckoutEnabled: nil
            ),
            resourcePolicy: evidencePolicy
        )
        for record in deltaRecords {
            try await treeWriter.append(record)
        }
        let tree = try await treeWriter.finish()

        let indexWriter = try evidenceStore.makeIndexWriter(
            identity: evidenceIdentity(
                root: root,
                family: .index,
                snapshot: snapshot,
                targetTreeOID: targetTreeOID,
                attemptID: attemptID,
                sparseCheckoutEnabled: sparseCheckoutEnabled
            ),
            resourcePolicy: evidencePolicy
        )
        for record in indexRecords {
            try await indexWriter.append(record)
        }
        let index = try await indexWriter.finish()

        let statusWriter = try evidenceStore.makeStatusWriter(
            identity: evidenceIdentity(
                root: root,
                family: .porcelainV2Status,
                snapshot: snapshot,
                targetTreeOID: targetTreeOID,
                attemptID: attemptID,
                sparseCheckoutEnabled: nil
            ),
            resourcePolicy: evidencePolicy
        )
        for record in statusRecords {
            try await statusWriter.append(record)
        }
        let status = try await statusWriter.finish()
        let evidence = try GitTargetEvidenceBundleLease(treeDelta: tree, index: index, status: status)

        let planStore = try WorkspaceRootTargetSeedPlanManifestStore(
            directoryURL: storeRoot.appendingPathComponent("plan-\(UUID().uuidString)", isDirectory: true)
        )
        let plan = try await WorkspaceRootSeedPlanner.reconcile(
            snapshot: snapshot,
            targetTreeOID: targetTreeOID,
            prefix: snapshot.compatibilityKey.repositoryRelativeRootPrefix,
            namespace: namespace,
            evidence: evidence,
            planStore: planStore,
            resourcePolicy: planPolicy
        )
        return try Fixture(
            namespace: namespace,
            evidence: evidence,
            plan: plan,
            handle: WorkspaceRootTargetSeedPlanHandle(
                snapshot: snapshot,
                namespaceManifest: namespace,
                gitEvidence: evidence,
                planManifest: plan
            )
        )
    }

    static func indexRecord(
        path: String,
        objectID: GitObjectID,
        mode: String = "100644",
        stage: UInt8 = 0,
        assumeUnchanged: Bool = false,
        skipWorktree: Bool = false
    ) -> GitTargetIndexEvidenceRecord {
        GitTargetIndexEvidenceRecord(
            modeBytes: Data(mode.utf8),
            objectIDBytes: Data(objectID.lowercaseHex.utf8),
            stage: stage,
            repositoryRelativePathBytes: Data(path.utf8),
            assumeUnchanged: assumeUnchanged,
            skipWorktree: skipWorktree
        )
    }

    static func statusRecord(
        kind: GitTargetStatusEvidenceKind,
        path: String,
        indexStatus: UInt8? = nil,
        workTreeStatus: UInt8? = nil,
        isDirectoryMarker: Bool = false,
        submoduleState: String? = nil
    ) -> GitTargetStatusEvidenceRecord {
        GitTargetStatusEvidenceRecord(
            kind: kind,
            repositoryRelativePathBytes: Data(path.utf8),
            isDirectoryMarker: isDirectoryMarker,
            indexStatus: indexStatus,
            workTreeStatus: workTreeStatus,
            submoduleStateBytes: kind == .ordinary
                ? Data((submoduleState ?? "N...").utf8)
                : submoduleState.map { Data($0.utf8) },
            headModeBytes: kind == .ordinary ? Data("100644".utf8) : nil,
            indexModeBytes: kind == .ordinary ? Data("100644".utf8) : nil,
            workTreeModeBytes: kind == .ordinary ? Data("100644".utf8) : nil,
            headObjectIDBytes: kind == .ordinary ? oid("a") : nil,
            indexObjectIDBytes: kind == .ordinary ? oid("a") : nil
        )
    }

    static func readAll(
        _ handle: WorkspaceRootTargetSeedPlanHandle
    ) throws -> [WorkspaceRootTargetSeedPlanRecord] {
        let reader = try handle.makeReader()
        var records: [WorkspaceRootTargetSeedPlanRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        precondition(reader.validationState == .verified)
        return records
    }

    static let namespacePolicy = WorkspaceRootNamespaceManifestResourcePolicy(
        maximumBufferedRecordBytes: 4096,
        maximumRecordsPerBatch: 32,
        maximumRecordByteCount: 2048,
        maximumOpenRuns: 4,
        minimumFreeDiskBytes: 0
    )
    static let evidencePolicy = GitTargetEvidenceResourcePolicy(
        maximumBufferedRecordBytes: 4096,
        maximumRecordsPerBatch: 32,
        maximumRecordByteCount: 2048,
        maximumOpenRuns: 4,
        minimumFreeDiskBytes: 0
    )
    static let planPolicy = WorkspaceRootTargetSeedPlanResourcePolicy(
        maximumBufferedRecordBytes: 4096,
        maximumRecordsPerBatch: 32,
        maximumRecordByteCount: 2048,
        maximumOpenRuns: 4,
        minimumFreeDiskBytes: 0
    )

    private static func evidenceIdentity(
        root: URL,
        family: GitTargetEvidenceFamily,
        snapshot: WorkspaceRootReusableSnapshot,
        targetTreeOID: GitObjectID,
        attemptID: UUID,
        sparseCheckoutEnabled: Bool?
    ) throws -> GitTargetEvidenceArtifactIdentity {
        let fileSystemIdentity = try GitTargetEvidenceFileSystemIdentity(url: root)
        let prefix = snapshot.compatibilityKey.repositoryRelativeRootPrefix
        return GitTargetEvidenceArtifactIdentity(
            physicalWorktree: fileSystemIdentity,
            repositoryCommonDirectory: fileSystemIdentity,
            repositoryGitDirectory: fileSystemIdentity,
            authority: GitTargetEvidenceAuthorityIdentity(
                authorityGeneration: 1,
                invalidationGeneration: 0,
                acceptedMetadataWatermark: 0,
                attemptID: attemptID,
                snapshotDigestBytes: Data(SHA256.hash(data: Data("authority".utf8)))
            ),
            commandArguments: [Data("git".utf8), Data(String(describing: family).utf8)],
            commandFormatBytes: Data(String(describing: family).utf8),
            environmentIdentityBytes: Data(SHA256.hash(data: Data("environment".utf8))),
            commandOutputDigestBytes: Data(SHA256.hash(data: Data(String(describing: family).utf8))),
            repositoryRelativeRootPrefixBytes: Data(prefix.value.utf8),
            objectFormatBytes: Data(targetTreeOID.objectFormat.rawValue.utf8),
            baseObjectIDBytes: family == .treeDelta
                ? Data(snapshot.compatibilityKey.treeOID.lowercaseHex.utf8)
                : nil,
            targetObjectIDBytes: Data(targetTreeOID.lowercaseHex.utf8),
            suppliedCreationCutProvenanceBytes: Data("cut".utf8),
            sparseCheckoutEnabled: sparseCheckoutEnabled
        )
    }

    private static func oid(_ scalar: Character) -> Data {
        Data(String(repeating: String(scalar), count: 40).utf8)
    }
}
