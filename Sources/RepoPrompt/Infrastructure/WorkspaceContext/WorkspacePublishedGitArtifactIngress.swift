import Foundation

struct WorkspacePublishedGitArtifactIngressRequest {
    let root: WorkspaceRootRef
    let artifacts: [GitDiffPublishedArtifact]
}

enum WorkspacePublishedGitArtifactIngressOutcomeStatus: Equatable {
    case cataloged(record: WorkspaceFileRecord)
    case missingOnDisk
    case ineligible(reason: CatalogRegularFileIneligibilityReason)
    case invalidRelativePath
    case outsideExpectedRoot
    case staleRoot
    case duplicateOf(path: String)
    case materializationFailed(reason: String)

    var record: WorkspaceFileRecord? {
        guard case let .cataloged(record) = self else { return nil }
        return record
    }
}

struct WorkspacePublishedGitArtifactIngressOutcome: Equatable {
    let artifact: GitDiffPublishedArtifact
    let status: WorkspacePublishedGitArtifactIngressOutcomeStatus
}

struct WorkspacePublishedGitArtifactReadinessFailure: Equatable {
    let artifact: GitDiffPublishedArtifact
    let status: WorkspacePublishedGitArtifactIngressOutcomeStatus
}

struct WorkspacePublishedGitArtifactReadinessAggregation: Equatable {
    let selectionReadyArtifacts: [GitDiffPublishedArtifact]
    let advertisementReadyArtifacts: [GitDiffPublishedArtifact]
    let selectionReadySnapshotDirectories: Set<String>
    let failuresBySnapshotDirectory: [String: [WorkspacePublishedGitArtifactReadinessFailure]]
}

struct WorkspacePublishedGitArtifactIngressResult: Equatable {
    let outcomes: [WorkspacePublishedGitArtifactIngressOutcome]
    let recordsByAbsolutePath: [String: WorkspaceFileRecord]
    let failuresByArtifact: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus]

    init(outcomes: [WorkspacePublishedGitArtifactIngressOutcome]) {
        self.outcomes = outcomes

        var records: [String: WorkspaceFileRecord] = [:]
        var catalogedArtifacts = Set<GitDiffPublishedArtifact>()
        var failures: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus] = [:]
        records.reserveCapacity(outcomes.count)
        failures.reserveCapacity(outcomes.count)

        for outcome in outcomes {
            if let record = outcome.status.record {
                records[outcome.artifact.absolutePath] = record
                catalogedArtifacts.insert(outcome.artifact)
                failures.removeValue(forKey: outcome.artifact)
            } else if !catalogedArtifacts.contains(outcome.artifact), failures[outcome.artifact] == nil {
                failures[outcome.artifact] = outcome.status
            }
        }

        recordsByAbsolutePath = records
        failuresByArtifact = failures
    }

    func selectionReadyArtifacts(
        for publishedArtifacts: GitDiffPublishedArtifactSet
    ) -> [GitDiffPublishedArtifact] {
        guard recordsByAbsolutePath[publishedArtifacts.manifest.absolutePath] != nil else { return [] }
        return publishedArtifacts.primarySelectionArtifacts.filter {
            recordsByAbsolutePath[$0.absolutePath] != nil
        }
    }

    func advertisementReadyArtifacts(
        for publishedArtifacts: GitDiffPublishedArtifactSet
    ) -> [GitDiffPublishedArtifact] {
        guard recordsByAbsolutePath[publishedArtifacts.manifest.absolutePath] != nil else { return [] }
        return publishedArtifacts.advertisedSelectionArtifacts.filter {
            recordsByAbsolutePath[$0.absolutePath] != nil
        }
    }

    /// Builds all publication readiness projections in published artifact order.
    /// The ingress indexes above are constructed once, so this is O(A) after the O(N) ingress pass.
    func aggregateReadiness(
        for publishedSets: [GitDiffPublishedArtifactSet]
    ) async throws -> WorkspacePublishedGitArtifactReadinessAggregation {
        try Task.checkCancellation()

        var selectionReady: [GitDiffPublishedArtifact] = []
        var advertisementReady: [GitDiffPublishedArtifact] = []
        var selectionReadySnapshotDirectories = Set<String>()
        var failuresBySnapshotDirectory: [String: [WorkspacePublishedGitArtifactReadinessFailure]] = [:]
        var processedArtifactCount = 0

        for published in publishedSets {
            let snapshotDirectory = published.snapshotRef.snapshotDirRel
            let manifestIsReady = recordsByAbsolutePath[published.manifest.absolutePath] != nil
            if manifestIsReady {
                let readyPrimary = published.primarySelectionArtifacts.filter {
                    recordsByAbsolutePath[$0.absolutePath] != nil
                }
                if !readyPrimary.isEmpty {
                    selectionReadySnapshotDirectories.insert(snapshotDirectory)
                    selectionReady.append(contentsOf: readyPrimary)
                }
                advertisementReady.append(contentsOf: published.advertisedSelectionArtifacts.filter {
                    recordsByAbsolutePath[$0.absolutePath] != nil
                })
            }

            for artifact in published.orderedArtifacts {
                if let status = failuresByArtifact[artifact] {
                    failuresBySnapshotDirectory[snapshotDirectory, default: []].append(
                        WorkspacePublishedGitArtifactReadinessFailure(artifact: artifact, status: status)
                    )
                }
                processedArtifactCount += 1
                if processedArtifactCount.isMultiple(of: 256) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
        }

        try Task.checkCancellation()
        return WorkspacePublishedGitArtifactReadinessAggregation(
            selectionReadyArtifacts: selectionReady,
            advertisementReadyArtifacts: advertisementReady,
            selectionReadySnapshotDirectories: selectionReadySnapshotDirectories,
            failuresBySnapshotDirectory: failuresBySnapshotDirectory
        )
    }
}
