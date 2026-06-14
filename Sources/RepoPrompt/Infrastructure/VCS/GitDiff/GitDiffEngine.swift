import CryptoKit
import Foundation

actor GitDiffEngine {
    struct DiffTextResult {
        let fingerprint: GitDiffFingerprint
        let text: String
        let perFile: [String: String]?
    }

    struct GitDiffSnapshotBuildResult {
        let fingerprint: GitDiffFingerprint
        let compare: GitDiffCompareSpec
        let scope: GitDiffScope
        let requestedPaths: [String]?
        let diffText: String?
        let perFile: [String: String]?
        let changedFiles: [VCSUncommittedFile]
        let summary: (files: Int, insertions: Int, deletions: Int)
    }

    static let shared = GitDiffEngine()

    private let vcsService: VCSService
    private let gitService: GitService // Kept for diff text generation (specific formats)
    private var cache: [CacheKey: DiffTextResult] = [:]

    private struct CacheKey: Hashable {
        let repoPath: String
        let targetKey: String
        let scope: GitDiffScope
        let selectedPathsKey: String
        let statusHash: String
        let backendKind: VCSBackendKind
    }

    init(vcsService: VCSService = .shared, gitService: GitService = GitService()) {
        self.vcsService = vcsService
        self.gitService = gitService
    }

    func statusFingerprint(baseRef: String, repoURL: URL) async throws -> GitDiffFingerprint {
        try await vcsService.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }

    func fingerprint(for compare: GitDiffCompareSpec, repoURL: URL) async throws -> GitDiffFingerprint {
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)

        switch normalizedCompare {
        case let .uncommitted(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .uncommittedMergeBase(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .staged(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .stagedMergeBase(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case .unstaged:
            // For git, compute fingerprint from porcelain status (jj normalizes this to .uncommitted)
            let headID = try await backend.getHeadID(at: repoURL)
            let statusData = try await gitService.getStatusPorcelainZ(at: repoURL)
            let statusHash = sha256Hex(statusData)
            return GitDiffFingerprint(
                headSHA: headID,
                baseRef: "INDEX",
                statusHash: "index:\(statusHash)",
                generatedAt: Date()
            )
        case let .revspec(revspec):
            let headID = try await backend.getHeadID(at: repoURL)
            return GitDiffFingerprint(
                headSHA: headID,
                baseRef: revspec,
                statusHash: "revspec:\(revspec)",
                generatedAt: Date()
            )
        }
    }

    /// Build snapshot inputs with explicit pathspecs (Git-relative or absolute paths under the checkout).
    /// Pathspecs override scope - if provided, only files matching the pathspecs are included.
    /// Directory pathspecs (ending with `/`) match all files under that directory.
    func buildSnapshotInputs(
        compare: GitDiffCompareSpec,
        pathspecs: [String]?,
        repoURL: URL,
        contextLines: Int,
        detectRenames: Bool,
        generateDiffText: Bool
    ) async throws -> GitDiffSnapshotBuildResult {
        let hasPathspecs = !(pathspecs?.isEmpty ?? true)
        let normalizedPathspecs = pathspecs.map {
            GitDiffPathNormalization.gitPathspecs(from: $0, repoRootPath: repoURL.path)
        }
        let scope: GitDiffScope = hasPathspecs ? .selected : .all
        let requestedPaths = hasPathspecs ? normalizedPathspecs : nil

        let fingerprint = try await fingerprint(for: compare, repoURL: repoURL)

        let includeUntracked = switch compare {
        case .uncommitted, .uncommittedMergeBase, .unstaged:
            true
        case .staged, .stagedMergeBase, .revspec:
            false
        }

        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)
        let changedFiles = try await backend.getChangedFilesStats(
            compare: normalizedCompare,
            includeUntrackedWhenApplicable: includeUntracked,
            detectRenames: detectRenames,
            at: repoURL
        )

        // Filter by pathspecs if provided
        let filtered: [VCSUncommittedFile] = if let normalizedPathspecs, !normalizedPathspecs.isEmpty {
            filterByPathspecs(changedFiles, pathspecs: normalizedPathspecs)
        } else {
            changedFiles
        }

        let summaryFiles = filtered.count
        let summaryInsertions = filtered.reduce(0) { $0 + ($1.additions ?? 0) }
        let summaryDeletions = filtered.reduce(0) { $0 + ($1.deletions ?? 0) }

        var diffText: String?
        var perFile: [String: String]?
        if generateDiffText, !filtered.isEmpty {
            let pathFilter = normalizedPathspecs

            // Get diff text via backend (handles normalization for jj)
            let trackedDiff = try await backend.getDiffText(
                compare: normalizedCompare,
                paths: pathFilter,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )

            // Get untracked diff (for git; jj returns empty as it has no untracked concept)
            let untrackedPaths = filtered.filter { $0.status == "??" }.map(\.path)
            let untrackedDiff: String = if !untrackedPaths.isEmpty {
                try await backend.getUntrackedDiff(for: untrackedPaths, contextLines: contextLines, at: repoURL)
            } else {
                ""
            }

            let combined = [trackedDiff, untrackedDiff]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            if !combined.isEmpty {
                diffText = combined
                perFile = GitService.splitUnifiedDiffByFile(combined)
            }
        }

        return GitDiffSnapshotBuildResult(
            fingerprint: fingerprint,
            compare: compare,
            scope: scope,
            requestedPaths: requestedPaths,
            diffText: diffText,
            perFile: perFile,
            changedFiles: filtered,
            summary: (files: summaryFiles, insertions: summaryInsertions, deletions: summaryDeletions)
        )
    }

    /// Filter changed files by pathspecs.
    /// Pathspecs ending with `/` are treated as directory prefixes.
    private func filterByPathspecs(
        _ files: [VCSUncommittedFile],
        pathspecs: [String]
    ) -> [VCSUncommittedFile] {
        guard !pathspecs.isEmpty else { return files }

        return files.filter { file in
            for spec in pathspecs {
                if spec.hasSuffix("/") {
                    // Directory prefix match
                    if file.path.hasPrefix(spec) || file.path == String(spec.dropLast()) {
                        return true
                    }
                } else {
                    // Exact match or the spec is a directory containing the file
                    if file.path == spec || file.path.hasPrefix(spec + "/") {
                        return true
                    }
                }
            }
            return false
        }
    }

    func buildSnapshotInputs(
        compare: GitDiffCompareSpec,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        contextLines: Int,
        detectRenames: Bool,
        includeUntrackedInUnstaged: Bool = true,
        generateDiffText: Bool
    ) async throws -> GitDiffSnapshotBuildResult {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let requestedPaths: [String]?
        if scope == .selected {
            let gitPaths = gitRelativePaths(from: normalizedSelected, repoRootPath: repoURL.path)
            let cleaned = Array(Set(gitPaths)).sorted()
            requestedPaths = cleaned.isEmpty ? nil : cleaned
        } else {
            requestedPaths = nil
        }

        let fingerprint = try await fingerprint(for: compare, repoURL: repoURL)

        let includeUntracked = switch compare {
        case .uncommitted, .uncommittedMergeBase:
            true
        case .unstaged:
            includeUntrackedInUnstaged
        case .staged, .stagedMergeBase, .revspec:
            false
        }

        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)
        let changedFiles = try await backend.getChangedFilesStats(
            compare: normalizedCompare,
            includeUntrackedWhenApplicable: includeUntracked,
            detectRenames: detectRenames,
            at: repoURL
        )
        let filtered = filterChangedFiles(
            changedFiles,
            scope: scope,
            selectedAbsolutePaths: normalizedSelected,
            repoRootPath: repoURL.path
        )

        let summaryFiles = filtered.count
        let summaryInsertions = filtered.reduce(0) { $0 + ($1.additions ?? 0) }
        let summaryDeletions = filtered.reduce(0) { $0 + ($1.deletions ?? 0) }

        var diffText: String?
        var perFile: [String: String]?
        if generateDiffText {
            let pathFilter = (scope == .selected) ? requestedPaths : nil
            if scope == .all || (pathFilter?.isEmpty == false) {
                // Get diff text via backend (handles normalization for jj)
                let trackedDiff = try await backend.getDiffText(
                    compare: normalizedCompare,
                    paths: pathFilter,
                    contextLines: contextLines,
                    detectRenames: detectRenames,
                    at: repoURL
                )

                // Get untracked diff (for git; jj returns empty as it has no untracked concept)
                let untrackedPaths = filtered.filter { $0.status == "??" }.map(\.path)
                let untrackedDiff: String = if !untrackedPaths.isEmpty, includeUntrackedInUnstaged {
                    try await backend.getUntrackedDiff(for: untrackedPaths, contextLines: contextLines, at: repoURL)
                } else {
                    ""
                }

                let combined = [trackedDiff, untrackedDiff]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                if !combined.isEmpty {
                    diffText = combined
                    perFile = GitService.splitUnifiedDiffByFile(combined)
                }
            }
        }

        return GitDiffSnapshotBuildResult(
            fingerprint: fingerprint,
            compare: compare,
            scope: scope,
            requestedPaths: requestedPaths,
            diffText: diffText,
            perFile: perFile,
            changedFiles: filtered,
            summary: (files: summaryFiles, insertions: summaryInsertions, deletions: summaryDeletions)
        )
    }

    func diffText(
        target: GitDiffTarget,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        useCache: Bool = true
    ) async throws -> DiffTextResult {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let selectedPathsKey = normalizedSelected.sorted().joined(separator: "|")

        switch target {
        case let .uncommitted(base):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let normalizedBase = backend.normalizeBaseRef(base)
            if await isRemoteBranch(normalizedBase, repoURL: repoURL) {
                try? await backend.fetch(at: repoURL)
            }
            let fingerprint = try await backend.getStatusFingerprint(at: repoURL, baseRef: normalizedBase)
            let cacheKey = CacheKey(
                repoPath: repoURL.path,
                targetKey: target.keyString,
                scope: scope,
                selectedPathsKey: selectedPathsKey,
                statusHash: fingerprint.statusHash,
                backendKind: backend.kind
            )
            if useCache, let cached = cache[cacheKey] {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommitted(base: normalizedBase)
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                at: repoURL
            )
            let filtered = filterChangedFiles(
                changedFiles,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoRootPath: repoURL.path
            )
            guard !filtered.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            // Use backend for diff text (respects jj normalization)
            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: tracked,
                    contextLines: 3,
                    detectRenames: false,
                    at: repoURL
                )
            } else {
                ""
            }

            let untrackedDiff: String = if !untracked.isEmpty {
                try await backend.getUntrackedDiff(for: untracked, contextLines: 3, at: repoURL)
            } else {
                ""
            }

            let combined = [trackedDiff, untrackedDiff]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let perFile = combined.isEmpty ? nil : GitService.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache[cacheKey] = result
            return result

        case let .uncommittedMergeBase(base):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let normalizedBase = backend.normalizeBaseRef(base)
            if await isRemoteBranch(normalizedBase, repoURL: repoURL) {
                try? await backend.fetch(at: repoURL)
            }
            let fingerprint = try await backend.getStatusFingerprint(at: repoURL, baseRef: normalizedBase)
            let cacheKey = CacheKey(
                repoPath: repoURL.path,
                targetKey: target.keyString,
                scope: scope,
                selectedPathsKey: selectedPathsKey,
                statusHash: fingerprint.statusHash,
                backendKind: backend.kind
            )
            if useCache, let cached = cache[cacheKey] {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommittedMergeBase(base: normalizedBase)
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                at: repoURL
            )
            let filtered = filterChangedFiles(
                changedFiles,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoRootPath: repoURL.path
            )
            guard !filtered.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: tracked,
                    contextLines: 3,
                    detectRenames: false,
                    at: repoURL
                )
            } else {
                ""
            }

            let untrackedDiff: String = if !untracked.isEmpty {
                try await backend.getUntrackedDiff(for: untracked, contextLines: 3, at: repoURL)
            } else {
                ""
            }

            let combined = [trackedDiff, untrackedDiff]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let perFile = combined.isEmpty ? nil : GitService.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache[cacheKey] = result
            return result

        case let .commit(sha):
            return try await diffTextForImmutableTarget(
                ref: "\(sha)^!",
                fingerprintBaseRef: sha,
                target: target,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoURL: repoURL,
                useCache: useCache
            )

        case let .range(from, to):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let resolvedFrom = await from.isEmpty ? from : ((try? backend.getRefID(ref: from, at: repoURL)) ?? from)
            let resolvedTo = await to.isEmpty ? to : ((try? backend.getRefID(ref: to, at: repoURL)) ?? to)
            let resolvedRange = "\(resolvedFrom)..\(resolvedTo)"
            let statusHashOverride = "range:\(resolvedRange)"
            return try await diffTextForImmutableTarget(
                ref: resolvedRange,
                fingerprintBaseRef: resolvedRange,
                target: target,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoURL: repoURL,
                statusHashOverride: statusHashOverride,
                useCache: useCache
            )
        }
    }

    private func diffTextForImmutableTarget(
        ref: String,
        fingerprintBaseRef: String,
        target: GitDiffTarget,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        statusHashOverride: String? = nil,
        useCache: Bool
    ) async throws -> DiffTextResult {
        let statusHash = statusHashOverride ?? target.keyString
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let headSHA = try await backend.getHeadID(at: repoURL)
        let fingerprint = GitDiffFingerprint(
            headSHA: headSHA,
            baseRef: fingerprintBaseRef,
            statusHash: statusHash,
            generatedAt: Date()
        )
        let cacheKey = CacheKey(
            repoPath: repoURL.path,
            targetKey: target.keyString,
            scope: scope,
            selectedPathsKey: selectedAbsolutePaths.sorted().joined(separator: "|"),
            statusHash: statusHash,
            backendKind: backend.kind
        )
        if useCache, let cached = cache[cacheKey] {
            return cached
        }

        let diffText: String
        switch scope {
        case .all:
            diffText = try await backend.getDiffText(
                compare: .revspec(ref),
                paths: nil,
                contextLines: 3,
                detectRenames: false,
                at: repoURL
            )
        case .selected:
            let gitPaths = gitRelativePaths(from: selectedAbsolutePaths, repoRootPath: repoURL.path)
            guard !gitPaths.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }
            diffText = try await backend.getDiffText(
                compare: .revspec(ref),
                paths: gitPaths,
                contextLines: 3,
                detectRenames: false,
                at: repoURL
            )
        }

        let perFile = diffText.isEmpty ? nil : GitService.splitUnifiedDiffByFile(diffText)
        let result = DiffTextResult(fingerprint: fingerprint, text: diffText, perFile: perFile)
        cache[cacheKey] = result
        return result
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedAbsolutePaths(_ paths: [String]) -> [String] {
        GitDiffPathNormalization.normalizedAbsolutePaths(paths)
    }

    private func filterChangedFiles(
        _ files: [VCSUncommittedFile],
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoRootPath: String
    ) -> [VCSUncommittedFile] {
        switch scope {
        case .all:
            return files
        case .selected:
            let selectedSet = Set(gitRelativePaths(from: selectedAbsolutePaths, repoRootPath: repoRootPath))
            guard !selectedSet.isEmpty else { return [] }
            return files.filter { selectedSet.contains($0.path) }
        }
    }

    private func gitRelativePaths(from absolutePaths: [String], repoRootPath: String) -> [String] {
        GitDiffPathNormalization.gitRelativePaths(from: absolutePaths, repoRootPath: repoRootPath)
    }

    private func isRemoteBranch(_ branchName: String, repoURL: URL) async -> Bool {
        guard branchName != "HEAD", !branchName.isEmpty else { return false }
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        return await backend.hasRemoteTrackingRef(named: branchName, at: repoURL)
    }
}
