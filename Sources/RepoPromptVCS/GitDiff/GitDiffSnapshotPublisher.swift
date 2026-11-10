import Foundation
import RepoPromptFoundation

package actor GitDiffSnapshotPublisher {
    /// An admitted artifact write failed after publication began. The directory is retained for
    /// reconciliation; callers must not describe this as a side-effect-free admission refusal.
    package struct PartialPublication: LocalizedError {
        package let snapshotDirectory: URL
        // Completion acknowledgements, not no-effect claims: a failed step may have partially
        // written files or removed the old CURRENT pointer before its replacement failed.
        package let snapshotWriteCompleted: Bool
        package let currentPointerWriteCompleted: Bool
        package let detail: String

        package init(snapshotDirectory: URL, snapshotWriteCompleted: Bool, currentPointerWriteCompleted: Bool, detail: String) {
            self.snapshotDirectory = snapshotDirectory
            self.snapshotWriteCompleted = snapshotWriteCompleted
            self.currentPointerWriteCompleted = currentPointerWriteCompleted
            self.detail = detail
        }

        package var errorDescription: String? {
            "Artifact publication began at \(snapshotDirectory.path); snapshot write completed=\(snapshotWriteCompleted), current pointer write completed=\(currentPointerWriteCompleted). \(detail)"
        }
    }

    private let engine: GitDiffEngine
    private let store: GitDiffSnapshotStore
    private let vcsService: any VCSBackendResolving

    package init(engine: GitDiffEngine, store: GitDiffSnapshotStore = GitDiffSnapshotStore(), backendResolver: any VCSBackendResolving) {
        self.engine = engine
        self.store = store
        vcsService = backendResolver
    }

    // MARK: - Multi-root publish (repo-scoped storage)

    /// Publish a snapshot for a specific repo with repo-scoped storage.
    /// Always creates a fresh snapshot tagged with the provided tabID.
    package func publish(
        workspaceDirectory: URL,
        repo: GitRepoDescriptor,
        mode: GitDiffPublishMode,
        compareSpec: GitDiffCompareSpec,
        compareDisplay: String,
        compareInput: String?,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        pathspecs: [String]? = nil,
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID? = nil,
        beforeWrite: (@Sendable () async throws -> Void)? = nil
    ) async throws -> GitDiffSnapshotManifest {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)

        return try await publishNewSnapshot(
            workspaceDirectory: workspaceDirectory,
            repo: repo,
            mode: mode,
            compare: compareSpec,
            compareResolved: compareDisplay,
            compareInput: compareInput,
            scope: scope,
            selectedAbsolutePaths: normalizedSelected,
            pathspecs: pathspecs,
            contextLines: contextLines,
            detectRenames: detectRenames,
            snapshotIDOverride: snapshotIDOverride,
            tabID: tabID,
            beforeWrite: beforeWrite
        )
    }

    /// Repo-scoped snapshot publishing helper
    private func publishNewSnapshot(
        workspaceDirectory: URL,
        repo: GitRepoDescriptor,
        mode: GitDiffPublishMode,
        compare: GitDiffCompareSpec,
        compareResolved: String,
        compareInput: String?,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        pathspecs: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID?,
        beforeWrite: (@Sendable () async throws -> Void)?
    ) async throws -> GitDiffSnapshotManifest {
        let inputs: GitDiffEngine.GitDiffSnapshotBuildResult = if let pathspecs, !pathspecs.isEmpty {
            try await engine.buildSnapshotInputs(
                compare: compare,
                pathspecs: pathspecs,
                repoURL: repo.rootURL,
                contextLines: contextLines,
                detectRenames: detectRenames,
                generateDiffText: mode != .quick
            )
        } else {
            try await engine.buildSnapshotInputs(
                compare: compare,
                scope: scope,
                selectedAbsolutePaths: selectedAbsolutePaths,
                repoURL: repo.rootURL,
                contextLines: contextLines,
                detectRenames: detectRenames,
                includeUntrackedInUnstaged: true,
                generateDiffText: mode != .quick
            )
        }

        let backend = await vcsService.backend(forRepoRoot: repo.rootURL)
        let commitGraph = try await backend.getCommitGraph(maxLines: 20, at: repo.rootURL)
        try await beforeWrite?()
        // Allocate the ID only after the final suspension. Allocation and writes are synchronous
        // on this publisher, so another admitted publication cannot claim the same automatic ID.
        let snapshotID = resolveSnapshotID(
            override: snapshotIDOverride,
            workspaceDirectory: workspaceDirectory,
            repoKey: repo.repoKey
        )
        var snapshotWriteCompleted = false
        let manifest: GitDiffSnapshotManifest
        do {
            manifest = try store.writeSnapshot(
                workspaceDirectory: workspaceDirectory,
                repoKey: repo.repoKey,
                snapshotID: snapshotID,
                mode: mode,
                compareRaw: compareResolved,
                compareInput: compareInput,
                scope: inputs.scope,
                requestedPaths: inputs.requestedPaths,
                fingerprint: inputs.fingerprint,
                contextLines: contextLines,
                detectRenames: detectRenames,
                inputs: inputs,
                commitGraph: commitGraph,
                repoRoot: repo.rootPath,
                tabID: tabID
            )

            snapshotWriteCompleted = true
            try store.writeCurrentSnapshotID(snapshotID, workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey)
        } catch {
            guard beforeWrite != nil else { throw error }
            throw PartialPublication(
                snapshotDirectory: store.snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey, snapshotID: snapshotID),
                snapshotWriteCompleted: snapshotWriteCompleted,
                currentPointerWriteCompleted: false,
                detail: error.localizedDescription
            )
        }

        // Trigger retention enforcement after publishing
        await GitDiffDataMaintenance.shared.runAfterSnapshotPublish(
            workspaceDirectory: workspaceDirectory,
            repoKey: repo.repoKey,
            snapshotID: manifest.snapshotID,
            generatedAt: manifest.generatedAt
        )

        return manifest
    }

    /// Resolve snapshot ID for repo-scoped storage
    private func resolveSnapshotID(override: String?, workspaceDirectory: URL, repoKey: String) -> String {
        if let override, override.lowercased() != "auto" {
            return override
        }
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone.current
        timeFormatter.dateFormat = "HHmm"
        let datePart = dateFormatter.string(from: now)
        let timePart = timeFormatter.string(from: now)
        let baseID = "\(datePart)/\(timePart)"
        if !store.snapshotExists(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: baseID) {
            return baseID
        }
        var suffix = 2
        while true {
            let candidate = "\(baseID)-\(suffix)"
            if !store.snapshotExists(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    // MARK: - Legacy publish (single-repo, backward compatible)

    package func publish(
        workspaceDirectory: URL,
        repoURL: URL,
        mode: GitDiffPublishMode,
        compareSpec: GitDiffCompareSpec,
        compareDisplay: String,
        compareInput: String?,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        pathspecs: [String]? = nil,
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID? = nil,
        beforeWrite: (@Sendable () async throws -> Void)? = nil
    ) async throws -> GitDiffSnapshotManifest {
        let repo = GitRepoDescriptor(rootURL: repoURL)
        return try await publish(
            workspaceDirectory: workspaceDirectory,
            repo: repo,
            mode: mode,
            compareSpec: compareSpec,
            compareDisplay: compareDisplay,
            compareInput: compareInput,
            scope: scope,
            selectedAbsolutePaths: selectedAbsolutePaths,
            pathspecs: pathspecs,
            contextLines: contextLines,
            detectRenames: detectRenames,
            snapshotIDOverride: snapshotIDOverride,
            tabID: tabID,
            beforeWrite: beforeWrite
        )
    }

    private func normalizedAbsolutePaths(_ paths: [String]) -> [String] {
        GitDiffPathNormalization.normalizedAbsolutePaths(paths)
    }
}
