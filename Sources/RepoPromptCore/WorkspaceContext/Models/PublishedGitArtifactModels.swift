import Foundation

package enum GitDiffArtifactPathPolicy {
    package static func isSafeRelativeArtifactPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !StandardizedPath.containsNUL(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }
    }

    package static func safeManifestPatchPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("diff/"), isSafeRelativeArtifactPath(trimmed) else { return nil }
        let lowercased = trimmed.lowercased()
        guard lowercased.hasSuffix(".patch") || lowercased.hasSuffix(".diff") else { return nil }
        return trimmed
    }
}

package enum GitDiffPublishedArtifactKind: Hashable { case manifest, map, allPatch, perFilePatch }
package enum GitDiffPublishedArtifactSelectionDisposition: Hashable { case authorizationDependency, primaryAutoSelect, advertisedSelectable }

package struct GitDiffPublishedArtifact: Hashable {
    package let kind: GitDiffPublishedArtifactKind
    package let absolutePath: String
    package let gitDataRelativePath: String
    package let clientAlias: String?
    package let selectionDisposition: GitDiffPublishedArtifactSelectionDisposition

    package init(kind: GitDiffPublishedArtifactKind, absolutePath: String, gitDataRelativePath: String, clientAlias: String?, selectionDisposition: GitDiffPublishedArtifactSelectionDisposition) {
        self.kind = kind
        self.absolutePath = StandardizedPath.absolute(absolutePath)
        self.gitDataRelativePath = gitDataRelativePath
        self.clientAlias = clientAlias
        self.selectionDisposition = selectionDisposition
    }
}

package struct WorkspacePublishedGitArtifactIngressRequest {
    package let root: WorkspaceRootRef
    package let artifacts: [GitDiffPublishedArtifact]
    package init(root: WorkspaceRootRef, artifacts: [GitDiffPublishedArtifact]) {
        self.root = root
        self.artifacts = artifacts
    }
}

package enum WorkspacePublishedGitArtifactIngressOutcomeStatus: Equatable {
    case cataloged(record: WorkspaceFileRecord)
    case missingOnDisk
    case ineligible(reason: CatalogRegularFileIneligibilityReason)
    case invalidRelativePath
    case outsideExpectedRoot
    case staleRoot
    case duplicateOf(path: String)
    case materializationFailed(reason: String)

    package var record: WorkspaceFileRecord? {
        if case let .cataloged(record) = self { record } else { nil }
    }
}

package struct WorkspacePublishedGitArtifactIngressOutcome: Equatable {
    package let artifact: GitDiffPublishedArtifact
    package let status: WorkspacePublishedGitArtifactIngressOutcomeStatus
    package init(artifact: GitDiffPublishedArtifact, status: WorkspacePublishedGitArtifactIngressOutcomeStatus) {
        self.artifact = artifact
        self.status = status
    }
}

package struct WorkspacePublishedGitArtifactIngressResult: Equatable {
    package let outcomes: [WorkspacePublishedGitArtifactIngressOutcome]
    package init(outcomes: [WorkspacePublishedGitArtifactIngressOutcome]) {
        self.outcomes = outcomes
    }

    package var recordsByAbsolutePath: [String: WorkspaceFileRecord] {
        Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome in outcome.status.record.map { (outcome.artifact.absolutePath, $0) } })
    }

    package var failuresByArtifact: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus] {
        let cataloged = Set(outcomes.compactMap { $0.status.record == nil ? nil : $0.artifact })
        var failures: [GitDiffPublishedArtifact: WorkspacePublishedGitArtifactIngressOutcomeStatus] = [:]
        for outcome in outcomes where outcome.status.record == nil && !cataloged.contains(outcome.artifact) {
            if failures[outcome.artifact] == nil { failures[outcome.artifact] = outcome.status }
        }
        return failures
    }
}
