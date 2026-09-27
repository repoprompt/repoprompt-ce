import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

enum CodemapGraphIndexHarnessError: Error {
    case timedOut
    case missingLedger
    case unexpectedDisposition(String)
}

struct CodemapGraphIndexHarnessFile {
    let fileID: UUID
    let path: String
    let pending: WorkspaceCodemapGraphSlot
    let contributed: WorkspaceCodemapGraphSlot
}

/// Suspends a selection graph's candidate build until opened, for cancellation interleavings.
actor CodemapGraphIndexGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int {
        waiters.count
    }

    func close() {
        isOpen = false
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Drives one overlay root and one selection graph directly, emulating the engine's pull loop.
final class CodemapGraphIndexHarness {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogToken: WorkspaceCodemapGraphIndexCatalogToken
    let overlay: WorkspaceCodemapLiveOverlay
    let graph: WorkspaceCodemapSelectionGraph
    let pipeline: CodeMapPipelineIdentity
    let capability: GitCodemapRootCapability
    private let seed: UInt8

    /// Registers a synthetic root. Pass `overlay` to share one overlay between several roots and
    /// `capability` to register a capability issued by a real `WorkspaceCodemapGitCapabilityService`.
    init(
        seed: UInt8,
        mode: WorkspaceCodemapGraphReconcileMode = .incremental,
        overlay sharedOverlay: WorkspaceCodemapLiveOverlay? = nil,
        capability suppliedCapability: GitCodemapRootCapability? = nil,
        graphPolicy: WorkspaceCodemapGraphPolicy = .initial,
        gate: CodemapGraphIndexGate? = nil
    ) async throws {
        self.seed = seed
        pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        if let suppliedCapability {
            capability = suppliedCapability
        } else {
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
                rootLifetimeID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
            )
            let namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "cd", count: 32))
            let authority = WorkspaceCodemapRepositoryAuthorityToken(
                authorityGeneration: 1,
                repositoryNamespace: namespace,
                objectFormat: .sha1,
                repositoryBindingEpoch: "repository",
                worktreeBindingEpoch: "worktree",
                layoutGeneration: "layout",
                indexGeneration: "index",
                checkoutConfigurationGeneration: "checkout",
                attributeGeneration: "attributes",
                sparseGeneration: "sparse",
                metadataGeneration: "metadata"
            )
            let root = URL(fileURLWithPath: "/workspace")
            let git = root.appendingPathComponent(".git", isDirectory: true)
            capability = GitCodemapRootCapability(
                rootEpoch: rootEpoch,
                repositoryLayout: GitRepositoryLayout(
                    workTreeRoot: root,
                    dotGitPath: git,
                    gitDir: git,
                    commonDir: git,
                    isWorktree: false
                ),
                repositoryIdentity: GitWorktreeRepositoryIdentity(
                    repositoryID: "repository",
                    repoKey: "repository",
                    displayName: "workspace",
                    commonGitDir: git.path,
                    mainWorktreeRoot: root.path
                ),
                worktreeID: "worktree",
                repositoryNamespace: namespace,
                objectFormat: .sha1,
                repositoryRelativeLoadedRootPrefix: "",
                repositoryAuthority: authority
            )
        }
        rootEpoch = capability.rootEpoch
        catalogToken = WorkspaceCodemapGraphIndexCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 2,
            catalogGeneration: 3,
            ingressGeneration: 4,
            graphIndexInvalidationGeneration: 5
        )
        overlay = sharedOverlay ?? WorkspaceCodemapLiveOverlay(graphPolicy: graphPolicy, graphReconcileMode: mode)
        graph = WorkspaceCodemapSelectionGraph(
            rootEpoch: rootEpoch,
            graphPolicy: graphPolicy,
            applyBuildHook: { await gate?.pass() }
        )
        let registration = await overlay.register(capability: .eligible(capability), catalogGeneration: 3)
        guard case .registered = registration else {
            throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(registration)")
        }
    }

    var rootPath: String {
        capability.repositoryLayout.workTreeRoot.path
    }

    /// Files reference their successor, a hub type defined by file 0, a name with a handful of
    /// early definers (ambiguous edges), and a never-defined name (unresolved evidence).
    func makeFiles(count: Int, prefix: String = "Sources") throws -> [CodemapGraphIndexHarnessFile] {
        try (0 ..< count).map { index in
            let fileID = fileID(index)
            let path = "\(prefix)/Module\(index % 16)/File\(index).swift"
            var definitions = ["Type\(index)"]
            if index < 8 { definitions.append("Shared") }
            let references = ["Type\((index + 1) % count)", "Type0", "Shared", "Missing\(index % 5)"]
            let pending = try makeSlot(fileID: fileID, path: path, state: .pending)
            let contributed = try makeSlot(
                fileID: fileID,
                path: path,
                definitions: definitions,
                references: references
            )
            return CodemapGraphIndexHarnessFile(fileID: fileID, path: path, pending: pending, contributed: contributed)
        }
    }

    func makeSlot(
        fileID: UUID,
        path: String,
        definitions: [String],
        references: [String],
        requestGeneration: UInt64 = 1,
        pathGeneration: UInt64 = 1
    ) throws -> WorkspaceCodemapGraphSlot {
        let digest = Data(SHA256.hash(data: Data((fileID.uuidString + path).utf8)))
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: digest),
                rawByteCount: UInt64(path.utf8.count),
                pipelineIdentity: pipeline
            ),
            definitions: definitions,
            references: references
        )
        return try makeSlot(
            fileID: fileID,
            path: path,
            state: .contributed(contribution),
            requestGeneration: requestGeneration,
            pathGeneration: pathGeneration
        )
    }

    func makeSlot(
        fileID: UUID,
        path: String,
        state: WorkspaceCodemapGraphSlotState,
        requestGeneration: UInt64 = 1,
        pathGeneration: UInt64 = 1
    ) throws -> WorkspaceCodemapGraphSlot {
        let identity = try makeIdentity(fileID: fileID, path: path)
        let digest: CodeMapSHA256Digest? = switch state {
        case let .contributed(value), let .empty(value): value.contributionDigest
        case .pending, .terminalArtifact, .terminalExcluded: nil
        }
        return try WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: identity,
            requestGeneration: requestGeneration,
            pathGeneration: pathGeneration,
            pipelineIdentity: pipeline,
            state: state,
            diagnostics: WorkspaceCodemapGraphSlotDiagnostics(contributionDigest: digest, source: .graphIndex)
        ).get()
    }

    func makeIdentity(fileID: UUID, path: String) throws -> WorkspaceCodemapArtifactBindingIdentity {
        guard let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: rootPath,
            standardizedRelativePath: path,
            standardizedFullPath: rootPath + "/" + path
        ) else { throw CodemapGraphIndexHarnessError.unexpectedDisposition("identity \(path)") }
        return identity
    }

    func fileID(_ index: Int, lane: UInt8 = 0x10) -> UUID {
        let value = UInt32(index)
        return UUID(uuid: (
            seed, lane, 0, 0,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
            0, 0, 0, 0, 0, 0, 0, 0
        ))
    }

    /// Publishes like the engine: destructive fences go to this harness's graph.
    @discardableResult
    func publish(
        _ slots: [WorkspaceCodemapGraphSlot],
        projectedTotal: UInt64? = nil,
        enumerationFinished: Bool = false
    ) async -> Bool {
        let graph = graph
        return await overlay.publishGraphIndexSlots(
            rootEpoch: rootEpoch,
            catalogToken: catalogToken,
            slots: slots,
            projectedSupportedCandidateTotal: projectedTotal,
            catalogSealed: true,
            enumerationFinished: enumerationFinished,
            reconciliationFence: { fileIDs, reason in
                await graph.fenceFiles(fileIDs: fileIDs, reason: reason)
            }
        )
    }

    func ledger() async throws -> WorkspaceCodemapGraphLedgerAccounting {
        guard let ledger = await overlay.graphLedgerAccounting(rootEpoch: rootEpoch) else {
            throw CodemapGraphIndexHarnessError.missingLedger
        }
        return ledger
    }

    func checkpoint() async throws -> WorkspaceCodemapGraphCheckpoint {
        switch await overlay.graphCheckpoint(rootEpoch: rootEpoch) {
        case let .checkpoint(checkpoint): return checkpoint
        case let .revoked(reason): throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(reason)")
        }
    }

    /// One iteration of the engine's pull loop for `consumer` (defaults to this harness's graph).
    /// Only the primary consumer acknowledges, matching the engine's single-consumer contract.
    @discardableResult
    func pull(
        into consumer: WorkspaceCodemapSelectionGraph? = nil,
        acknowledge: Bool = true
    ) async -> WorkspaceCodemapGraphApplyDisposition? {
        let target = consumer ?? graph
        let accounting = await target.incrementalAccounting()
        if acknowledge {
            await overlay.acknowledgeGraphChanges(rootEpoch: rootEpoch, through: accounting.appliedGeneration)
        }
        let changes = await overlay.graphChanges(rootEpoch: rootEpoch, since: accounting.appliedGeneration)
        if case .unchanged = changes { return nil }
        return await target.apply(changes)
    }

    func latestSnapshot(
        _ consumer: WorkspaceCodemapSelectionGraph? = nil
    ) async throws -> WorkspaceCodemapGraphCommittedSnapshot {
        switch await (consumer ?? graph).latestSnapshot() {
        case let .ready(pinned): return pinned.snapshot
        case .pending: throw CodemapGraphIndexHarnessError.unexpectedDisposition("pending snapshot")
        case let .revoked(reason): throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(reason)")
        }
    }

    func rebuiltFromCheckpoint() async throws -> WorkspaceCodemapGraphCommittedSnapshot {
        let checkpoint = try await checkpoint()
        let rebuilt = WorkspaceCodemapSelectionGraph(rootEpoch: rootEpoch)
        let disposition = await rebuilt.apply(.resync(checkpoint: checkpoint, generation: checkpoint.generation))
        guard case .committed = disposition else {
            throw CodemapGraphIndexHarnessError.unexpectedDisposition("\(disposition)")
        }
        return try await latestSnapshot(rebuilt)
    }
}

/// Plain-dictionary materialization of a snapshot, independent of persistent storage sharing.
struct CodemapMaterializedGraph: Equatable {
    let slots: [UUID: WorkspaceCodemapGraphSlot]
    let nodes: [UUID: WorkspaceCodemapGraphSnapshotNode]
    let definitions: [String: Set<UUID>]
    let references: [String: Set<UUID>]
    let outgoing: [UUID: [WorkspaceCodemapGraphEdgeEvidence]]
    let reverse: [UUID: [UUID: WorkspaceCodemapGraphEdgeEvidence]]
    let unresolved: [UUID: [WorkspaceCodemapGraphUnresolvedRecord]]
    let size: WorkspaceCodemapGraphSizeAccounting

    init(_ snapshot: WorkspaceCodemapGraphCommittedSnapshot) {
        slots = Dictionary(uniqueKeysWithValues: snapshot.slotsByFileID.map { ($0.key, $0.value) })
        nodes = Dictionary(uniqueKeysWithValues: snapshot.nodesByFileID.map { ($0.key, $0.value) })
        definitions = Dictionary(uniqueKeysWithValues: snapshot.definitionPostings.map { ($0.key, Set($0.value)) })
        references = Dictionary(uniqueKeysWithValues: snapshot.referencePostings.map { ($0.key, Set($0.value)) })
        outgoing = Dictionary(uniqueKeysWithValues: snapshot.outgoingEdgesBySource.map { ($0.key, $0.value) })
        reverse = Dictionary(uniqueKeysWithValues: snapshot.reverseEdgesByTarget.map { target, bySource in
            (target, Dictionary(uniqueKeysWithValues: bySource.map { ($0.key, $0.value) }))
        })
        unresolved = Dictionary(uniqueKeysWithValues: snapshot.unresolvedBySource.map { ($0.key, $0.value) })
        size = snapshot.sizeAccounting
    }

    /// Entries a copy-everything commit would duplicate for this snapshot: every resident map
    /// entry plus every posting and reverse-adjacency member.
    var fullCopyEntryCount: Int {
        slots.count + nodes.count + outgoing.count + unresolved.count +
            definitions.count + definitions.values.reduce(0) { $0 + $1.count } +
            references.count + references.values.reduce(0) { $0 + $1.count } +
            reverse.count + reverse.values.reduce(0) { $0 + $1.count }
    }
}

func assertSameGraph(
    _ lhs: WorkspaceCodemapGraphCommittedSnapshot,
    _ rhs: WorkspaceCodemapGraphCommittedSnapshot,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.rootEpoch, rhs.rootEpoch, message(), file: file, line: line)
    XCTAssertEqual(lhs.repositoryAuthority, rhs.repositoryAuthority, message(), file: file, line: line)
    XCTAssertEqual(lhs.catalogWatermark, rhs.catalogWatermark, message(), file: file, line: line)
    XCTAssertEqual(lhs.schemaVersion, rhs.schemaVersion, message(), file: file, line: line)
    XCTAssertEqual(lhs.policyVersion, rhs.policyVersion, message(), file: file, line: line)
    XCTAssertEqual(lhs.coverage, rhs.coverage, message(), file: file, line: line)
    XCTAssertEqual(lhs.appliedGeneration, rhs.appliedGeneration, message(), file: file, line: line)
    XCTAssertEqual(CodemapMaterializedGraph(lhs), CodemapMaterializedGraph(rhs), message(), file: file, line: line)
}
