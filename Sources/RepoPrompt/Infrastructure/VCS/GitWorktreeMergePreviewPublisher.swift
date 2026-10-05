import Foundation
import RepoPromptVCS

actor GitWorktreeMergePreviewPublisher {
    static let shared = GitWorktreeMergePreviewPublisher()

    private let snapshotPublisher: GitDiffSnapshotPublisher
    private let store: GitDiffSnapshotStore

    init(
        snapshotPublisher: GitDiffSnapshotPublisher = .shared,
        store: GitDiffSnapshotStore = GitDiffSnapshotStore()
    ) {
        self.snapshotPublisher = snapshotPublisher
        self.store = store
    }

    func publish(
        request: GitWorktreeMergePreviewRequest,
        inspection: GitWorktreeMergeInspection,
        operationID: String
    ) async throws -> GitWorktreeMergePreviewArtifacts {
        let repo = GitRepoDescriptor(
            rootURL: request.target.url,
            rootPath: request.target.path,
            repoKey: request.target.repoKey,
            displayName: request.target.displayName
        )
        let compare = GitDiffCompareSpec.revspec("\(inspection.mergeBase)..\(inspection.sourceHead)")
        let manifest = try await snapshotPublisher.publish(
            workspaceDirectory: request.workspaceDirectory,
            repo: repo,
            mode: .standard,
            compareSpec: compare,
            compareDisplay: "merge-preview:\(inspection.mergeBase)..\(inspection.sourceHead)",
            compareInput: nil,
            scope: .all,
            selectedAbsolutePaths: [],
            contextLines: request.contextLines,
            detectRenames: request.detectRenames,
            snapshotIDOverride: request.snapshotIDOverride,
            tabID: request.tabID
        )

        let snapshotDir = store.snapshotDir(
            workspaceDirectory: request.workspaceDirectory,
            repoKey: repo.repoKey,
            snapshotID: manifest.snapshotID
        )
        let sidecarURL = snapshotDir.appendingPathComponent("merge_preview.json")
        let sidecar = MergePreviewSidecar(
            operationID: operationID,
            source: inspection.source,
            target: inspection.target,
            mergeBase: inspection.mergeBase,
            sourceHead: inspection.sourceHead,
            targetHead: inspection.targetHead,
            sourceFingerprint: inspection.sourceFingerprint,
            targetFingerprint: inspection.targetFingerprint,
            blockers: inspection.blockers,
            conflictPrediction: inspection.conflictPrediction,
            summary: inspection.summary,
            visualization: inspection.visualization,
            snapshotID: manifest.snapshotID,
            generatedAt: manifest.generatedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)

        return GitWorktreeMergePreviewArtifacts(
            snapshotID: manifest.snapshotID,
            snapshotDirectory: snapshotDir.path,
            manifestPath: snapshotDir.appendingPathComponent("manifest.json").path,
            mapPath: snapshotDir.appendingPathComponent("MAP.txt").path,
            allPatchPath: manifest.files.contains { $0.patchPath != nil }
                ? snapshotDir.appendingPathComponent("diff/all.patch").path
                : nil,
            sidecarPath: sidecarURL.path
        )
    }
}

private struct MergePreviewSidecar: Codable {
    let operationID: String
    let source: GitWorktreeMergeEndpoint
    let target: GitWorktreeMergeEndpoint
    let mergeBase: String
    let sourceHead: String
    let targetHead: String
    let sourceFingerprint: GitDiffFingerprint
    let targetFingerprint: GitDiffFingerprint
    let blockers: [GitWorktreeMergeBlocker]
    let conflictPrediction: GitWorktreeMergeConflictPrediction
    let summary: GitWorktreeMergeSummary
    let visualization: String
    let snapshotID: String
    let generatedAt: Date
}
