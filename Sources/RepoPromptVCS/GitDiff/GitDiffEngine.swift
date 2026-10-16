import CryptoKit
import Foundation
import RepoPromptFileSystem
import RepoPromptFoundation

package actor GitDiffEngine {
    package struct CacheLimits: Equatable {
        package static let production = CacheLimits(
            maximumEntryCount: 32,
            maximumRetainedUTF8Bytes: 64 * 1024 * 1024
        )

        package let maximumEntryCount: Int
        package let maximumRetainedUTF8Bytes: Int

        package init(maximumEntryCount: Int, maximumRetainedUTF8Bytes: Int) {
            precondition(maximumEntryCount > 0)
            precondition(maximumRetainedUTF8Bytes > 0)
            self.maximumEntryCount = maximumEntryCount
            self.maximumRetainedUTF8Bytes = maximumRetainedUTF8Bytes
        }
    }

    package struct DiffTextResult {
        package let fingerprint: GitDiffFingerprint
        package let text: String
        package let perFile: [String: String]?

        package init(
            fingerprint: GitDiffFingerprint,
            text: String,
            perFile: [String: String]? = nil
        ) {
            self.fingerprint = fingerprint
            self.text = text
            self.perFile = perFile
        }
    }

    package struct GitDiffSnapshotBuildResult {
        package let fingerprint: GitDiffFingerprint
        package let compare: GitDiffCompareSpec
        package let scope: GitDiffScope
        package let requestedPaths: [String]?
        package let diffText: String?
        package let perFile: [String: String]?
        package let changedFiles: [VCSUncommittedFile]
        package let summary: (files: Int, insertions: Int, deletions: Int)

        package init(
            fingerprint: GitDiffFingerprint,
            compare: GitDiffCompareSpec,
            scope: GitDiffScope,
            requestedPaths: [String]? = nil,
            diffText: String? = nil,
            perFile: [String: String]? = nil,
            changedFiles: [VCSUncommittedFile],
            summary: (files: Int, insertions: Int, deletions: Int)
        ) {
            self.fingerprint = fingerprint
            self.compare = compare
            self.scope = scope
            self.requestedPaths = requestedPaths
            self.diffText = diffText
            self.perFile = perFile
            self.changedFiles = changedFiles
            self.summary = summary
        }
    }

    private let vcsService: any VCSBackendResolving
    private let gitCommands: GitDiffCommandClient
    private var cache: DiffTextCache

    package struct CacheKey: Hashable {
        package let repoPath: String
        package let targetKey: String
        package let scope: GitDiffScope
        package let selectedPathsKey: String
        package let statusHash: String
        package let backendKind: VCSBackendKind

        package init(
            repoPath: String,
            targetKey: String,
            scope: GitDiffScope,
            selectedPathsKey: String,
            statusHash: String,
            backendKind: VCSBackendKind
        ) {
            self.repoPath = repoPath
            self.targetKey = targetKey
            self.scope = scope
            self.selectedPathsKey = selectedPathsKey
            self.statusHash = statusHash
            self.backendKind = backendKind
        }
    }

    package struct DiffTextCache {
        private struct Entry {
            let result: DiffTextResult
            let retainedUTF8Bytes: Int
        }

        #if DEBUG
            package struct HealthSnapshot: Equatable {
                package let entryCount: Int
                package let retainedUTF8Bytes: Int
                package let hitCount: Int
                package let missCount: Int
                package let bypassCount: Int
                package let admissionCount: Int
                package let replacementCount: Int
                package let evictionCount: Int
                package let oversizedRejectionCount: Int

                package init(
                    entryCount: Int,
                    retainedUTF8Bytes: Int,
                    hitCount: Int,
                    missCount: Int,
                    bypassCount: Int,
                    admissionCount: Int,
                    replacementCount: Int,
                    evictionCount: Int,
                    oversizedRejectionCount: Int
                ) {
                    self.entryCount = entryCount
                    self.retainedUTF8Bytes = retainedUTF8Bytes
                    self.hitCount = hitCount
                    self.missCount = missCount
                    self.bypassCount = bypassCount
                    self.admissionCount = admissionCount
                    self.replacementCount = replacementCount
                    self.evictionCount = evictionCount
                    self.oversizedRejectionCount = oversizedRejectionCount
                }
            }
        #endif

        private let limits: CacheLimits
        private var entries: LRUCache<CacheKey, Entry>
        package private(set) var retainedUTF8Bytes = 0

        #if DEBUG
            private var hitCount = 0
            private var missCount = 0
            private var bypassCount = 0
            private var admissionCount = 0
            private var replacementCount = 0
            private var evictionCount = 0
            private var oversizedRejectionCount = 0
        #endif

        package init(limits: CacheLimits) {
            self.limits = limits
            entries = LRUCache(capacity: limits.maximumEntryCount)
        }

        package var count: Int {
            entries.count
        }

        package mutating func value(for key: CacheKey) -> DiffTextResult? {
            guard let entry = entries[key] else {
                #if DEBUG
                    missCount &+= 1
                #endif
                return nil
            }
            #if DEBUG
                hitCount &+= 1
            #endif
            return entry.result
        }

        package mutating func recordBypass() {
            #if DEBUG
                bypassCount &+= 1
            #endif
        }

        @discardableResult
        package mutating func admit(_ result: DiffTextResult, for key: CacheKey) -> Bool {
            if let replaced = entries.removeValue(forKey: key) {
                retainedUTF8Bytes = max(0, retainedUTF8Bytes - replaced.retainedUTF8Bytes)
                #if DEBUG
                    replacementCount &+= 1
                #endif
            }

            let byteCount = Self.retainedUTF8ByteCount(for: key, result: result)
            guard byteCount <= limits.maximumRetainedUTF8Bytes else {
                #if DEBUG
                    oversizedRejectionCount &+= 1
                #endif
                return false
            }

            while true {
                let (proposedBytes, overflow) = retainedUTF8Bytes.addingReportingOverflow(byteCount)
                if !overflow, proposedBytes <= limits.maximumRetainedUTF8Bytes {
                    retainedUTF8Bytes = proposedBytes
                    break
                }
                guard let evicted = entries.removeLeastRecentlyUsed() else { return false }
                removeFromAccounting(evicted.value)
                #if DEBUG
                    evictionCount &+= 1
                #endif
            }

            let entry = Entry(result: result, retainedUTF8Bytes: byteCount)
            if let evicted = entries.setReturningEvictedEntry(entry, forKey: key) {
                removeFromAccounting(evicted.value)
                #if DEBUG
                    evictionCount &+= 1
                #endif
            }
            #if DEBUG
                admissionCount &+= 1
            #endif
            return true
        }

        package static func retainedUTF8ByteCount(for key: CacheKey, result: DiffTextResult) -> Int {
            var count = 0
            for string in [
                key.repoPath,
                key.targetKey,
                key.selectedPathsKey,
                key.statusHash,
                result.fingerprint.headSHA,
                result.fingerprint.baseRef,
                result.fingerprint.statusHash,
                result.text
            ] {
                count = saturatingAdd(count, string.utf8.count)
            }
            if let perFile = result.perFile {
                for (path, text) in perFile {
                    count = saturatingAdd(count, path.utf8.count)
                    count = saturatingAdd(count, text.utf8.count)
                }
            }
            return count
        }

        #if DEBUG
            package var healthSnapshot: HealthSnapshot {
                HealthSnapshot(
                    entryCount: count,
                    retainedUTF8Bytes: retainedUTF8Bytes,
                    hitCount: hitCount,
                    missCount: missCount,
                    bypassCount: bypassCount,
                    admissionCount: admissionCount,
                    replacementCount: replacementCount,
                    evictionCount: evictionCount,
                    oversizedRejectionCount: oversizedRejectionCount
                )
            }
        #endif

        private mutating func removeFromAccounting(_ entry: Entry) {
            retainedUTF8Bytes = max(0, retainedUTF8Bytes - entry.retainedUTF8Bytes)
        }

        package static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }

    package init(
        backendResolver: any VCSBackendResolving,
        gitCommands: GitDiffCommandClient,
        cacheLimits: CacheLimits = .production
    ) {
        vcsService = backendResolver
        self.gitCommands = gitCommands
        cache = DiffTextCache(limits: cacheLimits)
    }

    #if DEBUG
        package func cacheHealthSnapshot() -> DiffTextCache.HealthSnapshot {
            cache.healthSnapshot
        }
    #endif

    package func statusFingerprint(baseRef: String, repoURL: URL) async throws -> GitDiffFingerprint {
        try await vcsService.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }

    package func fingerprint(for compare: GitDiffCompareSpec, repoURL: URL) async throws -> GitDiffFingerprint {
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
            let statusData = try await gitCommands.statusPorcelainZ(repoURL)
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
    package func buildSnapshotInputs(
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
        let discoveryPathspecs = pathspecs.map {
            GitDiffPathNormalization.gitDiscoveryPathspecs(from: $0, repoRootPath: repoURL.path)
        }
        let hasUserAuthoredRelativePathspecs = pathspecs?.contains { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed as NSString).expandingTildeInPath.hasPrefix("/")
        } ?? false
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
            paths: hasPathspecs ? (discoveryPathspecs ?? []) : nil,
            at: repoURL
        )

        // Keep backend-agnostic filtering as a defensive projection boundary.
        let filtered: [VCSUncommittedFile] = if hasUserAuthoredRelativePathspecs {
            // Git is authoritative for user-authored relative pathspec glob/magic semantics.
            changedFiles
        } else if let normalizedPathspecs, !normalizedPathspecs.isEmpty {
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
            let pathFilter = discoveryPathspecs

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
                perFile = gitCommands.splitUnifiedDiffByFile(combined)
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

    package func buildSnapshotInputs(
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
        let discoveryPaths = scope == .selected
            ? GitDiffPathNormalization.literalGitPathspecs(
                gitRelativePaths(from: normalizedSelected, repoRootPath: repoURL.path)
            )
            : nil
        let changedFiles = try await backend.getChangedFilesStats(
            compare: normalizedCompare,
            includeUntrackedWhenApplicable: includeUntracked,
            detectRenames: detectRenames,
            paths: discoveryPaths,
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
            let pathFilter = (scope == .selected) ? discoveryPaths : nil
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
                    perFile = gitCommands.splitUnifiedDiffByFile(combined)
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

    /// When false, skips cache lookup and recomputes the diff. Every recomputed result
    /// replaces the matching cache entry within the retention limits; oversized results
    /// remove any old matching entry but are returned without being retained.
    package func diffText(
        target: GitDiffTarget,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        allowCachedResult: Bool = true
    ) async throws -> DiffTextResult {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let selectedPathsKey = normalizedSelected.sorted().joined(separator: "|")
        if !allowCachedResult {
            cache.recordBypass()
        }

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
            if allowCachedResult, let cached = cache.value(for: cacheKey) {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommitted(base: normalizedBase)
            let discoveryPaths = scope == .selected
                ? GitDiffPathNormalization.literalGitPathspecs(
                    gitRelativePaths(from: normalizedSelected, repoRootPath: repoURL.path)
                )
                : nil
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                paths: discoveryPaths,
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
                // Always admit recomputed results so allowCachedResult:false only bypasses
                // lookup (force refresh), never leaves a stale resident entry.
                cache.admit(result, for: cacheKey)
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            // Use backend for diff text (respects jj normalization)
            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: GitDiffPathNormalization.literalGitPathspecs(tracked),
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
            let perFile = combined.isEmpty ? nil : gitCommands.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache.admit(result, for: cacheKey)
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
            if allowCachedResult, let cached = cache.value(for: cacheKey) {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommittedMergeBase(base: normalizedBase)
            let discoveryPaths = scope == .selected
                ? GitDiffPathNormalization.literalGitPathspecs(
                    gitRelativePaths(from: normalizedSelected, repoRootPath: repoURL.path)
                )
                : nil
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                paths: discoveryPaths,
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
                cache.admit(result, for: cacheKey)
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: GitDiffPathNormalization.literalGitPathspecs(tracked),
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
            let perFile = combined.isEmpty ? nil : gitCommands.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache.admit(result, for: cacheKey)
            return result

        case let .commit(sha):
            return try await diffTextForImmutableTarget(
                ref: "\(sha)^!",
                fingerprintBaseRef: sha,
                target: target,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoURL: repoURL,
                allowCachedResult: allowCachedResult
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
                allowCachedResult: allowCachedResult
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
        allowCachedResult: Bool
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
        if allowCachedResult, let cached = cache.value(for: cacheKey) {
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
                cache.admit(result, for: cacheKey)
                return result
            }
            diffText = try await backend.getDiffText(
                compare: .revspec(ref),
                paths: GitDiffPathNormalization.literalGitPathspecs(gitPaths),
                contextLines: 3,
                detectRenames: false,
                at: repoURL
            )
        }

        let perFile = diffText.isEmpty ? nil : gitCommands.splitUnifiedDiffByFile(diffText)
        let result = DiffTextResult(fingerprint: fingerprint, text: diffText, perFile: perFile)
        cache.admit(result, for: cacheKey)
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
