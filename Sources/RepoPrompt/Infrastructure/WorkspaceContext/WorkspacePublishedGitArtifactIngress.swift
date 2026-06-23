import Foundation

extension WorkspacePublishedGitArtifactIngressResult {
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
