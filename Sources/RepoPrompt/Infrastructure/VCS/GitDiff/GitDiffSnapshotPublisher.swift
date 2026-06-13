import Foundation

actor GitDiffSnapshotPublisher {
    static let shared = GitDiffSnapshotPublisher()

    private let engine: GitDiffEngine
    private let store: GitDiffSnapshotStore
    private let vcsService: VCSService

    init(engine: GitDiffEngine = .shared, store: GitDiffSnapshotStore = GitDiffSnapshotStore(), vcsService: VCSService = .shared) {
        self.engine = engine
        self.store = store
        self.vcsService = vcsService
    }

    // MARK: - Multi-root publish (repo-scoped storage)

    /// Publish a snapshot for a specific repo with repo-scoped storage.
    /// Always creates a fresh snapshot tagged with the provided tabID.
    func publish(
        workspaceDirectory: URL,
        repo: GitRepoDescriptor,
        mode: GitDiffPublishMode,
        compareSpec: GitDiffCompareSpec,
        compareDisplay: String,
        compareInput: String?,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID? = nil
    ) async throws -> GitDiffSnapshotManifest {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let requestedPaths: [String]? = {
            guard scope == .selected else { return nil }
            let gitPaths = gitRelativePaths(from: normalizedSelected, repoRootPath: repo.rootPath)
            return normalizeRequestedPaths(gitPaths)
        }()

        return try await publishNewSnapshot(
            workspaceDirectory: workspaceDirectory,
            repo: repo,
            mode: mode,
            compare: compareSpec,
            compareResolved: compareDisplay,
            compareInput: compareInput,
            scope: scope,
            requestedPaths: requestedPaths,
            selectedAbsolutePaths: normalizedSelected,
            contextLines: contextLines,
            detectRenames: detectRenames,
            snapshotIDOverride: snapshotIDOverride,
            tabID: tabID
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
        requestedPaths: [String]?,
        selectedAbsolutePaths: [String],
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID?
    ) async throws -> GitDiffSnapshotManifest {
        let inputs = try await engine.buildSnapshotInputs(
            compare: compare,
            scope: scope,
            selectedAbsolutePaths: selectedAbsolutePaths,
            repoURL: repo.rootURL,
            contextLines: contextLines,
            detectRenames: detectRenames,
            includeUntrackedInUnstaged: true,
            generateDiffText: mode != .quick
        )

        let snapshotID = resolveSnapshotID(
            override: snapshotIDOverride,
            workspaceDirectory: workspaceDirectory,
            repoKey: repo.repoKey
        )

        let backend = await vcsService.backend(forRepoRoot: repo.rootURL)
        let commitGraph = try await backend.getCommitGraph(maxLines: 20, at: repo.rootURL)

        let manifest = try store.writeSnapshot(
            workspaceDirectory: workspaceDirectory,
            repoKey: repo.repoKey,
            snapshotID: snapshotID,
            mode: mode,
            compareRaw: compareResolved,
            compareInput: compareInput,
            scope: scope,
            requestedPaths: inputs.requestedPaths,
            fingerprint: inputs.fingerprint,
            contextLines: contextLines,
            detectRenames: detectRenames,
            inputs: inputs,
            commitGraph: commitGraph,
            repoRoot: repo.rootPath,
            tabID: tabID
        )

        try store.writeCurrentSnapshotID(snapshotID, workspaceDirectory: workspaceDirectory, repoKey: repo.repoKey)

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

    func publish(
        workspaceDirectory: URL,
        repoURL: URL,
        mode: GitDiffPublishMode,
        compareSpec: GitDiffCompareSpec,
        compareDisplay: String,
        compareInput: String?,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        contextLines: Int,
        detectRenames: Bool,
        snapshotIDOverride: String?,
        tabID: UUID? = nil
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
            contextLines: contextLines,
            detectRenames: detectRenames,
            snapshotIDOverride: snapshotIDOverride,
            tabID: tabID
        )
    }

    private func normalizedAbsolutePaths(_ paths: [String]) -> [String] {
        GitDiffPathNormalization.normalizedAbsolutePaths(paths)
    }

    private func gitRelativePaths(from absolutePaths: [String], repoRootPath: String) -> [String] {
        GitDiffPathNormalization.gitRelativePaths(from: absolutePaths, repoRootPath: repoRootPath)
    }

    private func normalizeRequestedPaths(_ paths: [String]?) -> [String]? {
        guard let paths else { return nil }
        let cleaned = Set(
            paths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !cleaned.isEmpty else { return nil }
        return cleaned.sorted()
    }
}
