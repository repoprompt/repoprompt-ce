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

struct WorkspacePublishedGitArtifactIngressResult: Equatable {
    let outcomes: [WorkspacePublishedGitArtifactIngressOutcome]

    var recordsByAbsolutePath: [String: WorkspaceFileRecord] {
        Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome in
            outcome.status.record.map { (outcome.artifact.absolutePath, $0) }
        })
    }

    var failuresByArtifact: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus] {
        let catalogedArtifacts = Set(outcomes.compactMap { outcome in
            outcome.status.record == nil ? nil : outcome.artifact
        })
        var failures: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus] = [:]
        for outcome in outcomes where outcome.status.record == nil {
            guard !catalogedArtifacts.contains(outcome.artifact) else { continue }
            if failures[outcome.artifact] == nil {
                failures[outcome.artifact] = outcome.status
            }
        }
        return failures
    }

    func selectionReadyArtifacts(
        for publishedArtifacts: GitDiffPublishedArtifactSet
    ) -> [GitDiffPublishedArtifact] {
        let records = recordsByAbsolutePath
        guard records[publishedArtifacts.manifest.absolutePath] != nil else { return [] }
        return publishedArtifacts.primarySelectionArtifacts.filter {
            records[$0.absolutePath] != nil
        }
    }

    func advertisementReadyArtifacts(
        for publishedArtifacts: GitDiffPublishedArtifactSet
    ) -> [GitDiffPublishedArtifact] {
        let records = recordsByAbsolutePath
        guard records[publishedArtifacts.manifest.absolutePath] != nil else { return [] }
        return publishedArtifacts.advertisedSelectionArtifacts.filter {
            records[$0.absolutePath] != nil
        }
    }
}
