import CryptoKit
import Foundation

struct GitDiffSnapshotStore {
    init() {}

    struct SnapshotEntry {
        let snapshotID: String
        let snapshotDir: URL
        let manifest: GitDiffSnapshotManifest
        let repoKey: String? // nil for legacy snapshots
    }

    struct GitDiffSnapshotRef: Hashable {
        let repoKey: String? // nil for legacy
        let snapshotID: String

        var snapshotDirRel: String {
            guard let repoKey else { return snapshotID }
            return "repos/\(repoKey)/\(snapshotID)"
        }
    }

    struct LegacyPurgeResult {
        let removedLegacyCurrent: Bool
        let removedLegacyDiffSnapshotsDir: Bool
        let deletedLegacySnapshotDirs: Int
    }

    // MARK: - Legacy (single-repo) paths

    /// Root directory for all git data in a workspace
    func gitDataRoot(workspaceDirectory: URL) -> URL {
        workspaceDirectory
            .appendingPathComponent("_git_data", isDirectory: true)
    }

    /// Legacy snapshots root (for backward compatibility)
    func snapshotsRoot(workspaceDirectory: URL) -> URL {
        gitDataRoot(workspaceDirectory: workspaceDirectory)
    }

    func snapshotDir(workspaceDirectory: URL, snapshotID: String) -> URL {
        snapshotsRoot(workspaceDirectory: workspaceDirectory)
            .appendingPathComponent(snapshotID, isDirectory: true)
    }

    func currentPointerURL(workspaceDirectory: URL) -> URL {
        snapshotsRoot(workspaceDirectory: workspaceDirectory)
            .appendingPathComponent("CURRENT")
    }

    func snapshotExists(workspaceDirectory: URL, snapshotID: String) -> Bool {
        let url = snapshotDir(workspaceDirectory: workspaceDirectory, snapshotID: snapshotID)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Multi-root (repo-scoped) paths

    /// Root directory for repo-scoped snapshots: _git_data/repos/
    func reposRoot(workspaceDirectory: URL) -> URL {
        gitDataRoot(workspaceDirectory: workspaceDirectory)
            .appendingPathComponent("repos", isDirectory: true)
    }

    /// Snapshots root for a specific repo: _git_data/repos/<repoKey>/
    func snapshotsRoot(workspaceDirectory: URL, repoKey: String) -> URL {
        reposRoot(workspaceDirectory: workspaceDirectory)
            .appendingPathComponent(repoKey, isDirectory: true)
    }

    /// Snapshot directory for a specific repo: _git_data/repos/<repoKey>/<snapshotID>/
    func snapshotDir(workspaceDirectory: URL, repoKey: String, snapshotID: String) -> URL {
        snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
            .appendingPathComponent(snapshotID, isDirectory: true)
    }

    /// CURRENT pointer for a specific repo: _git_data/repos/<repoKey>/CURRENT
    func currentPointerURL(workspaceDirectory: URL, repoKey: String) -> URL {
        snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
            .appendingPathComponent("CURRENT")
    }

    /// Check if a snapshot exists for a specific repo
    func snapshotExists(workspaceDirectory: URL, repoKey: String, snapshotID: String) -> Bool {
        let url = snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Relative path from workspace to snapshot dir (for display): repos/<repoKey>/<snapshotID>
    func snapshotRelativePath(repoKey: String, snapshotID: String) -> String {
        "repos/\(repoKey)/\(snapshotID)"
    }

    func parseSnapshotRef(_ raw: String) -> GitDiffSnapshotRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.count >= 3, parts.first == "repos" {
            let repoKey = parts[1]
            let snapshotID = parts.dropFirst(2).joined(separator: "/")
            guard let normalized = Self.normalizeSnapshotID(snapshotID) else { return nil }
            return GitDiffSnapshotRef(repoKey: repoKey, snapshotID: normalized)
        }
        guard let normalized = Self.normalizeSnapshotID(trimmed) else { return nil }
        return GitDiffSnapshotRef(repoKey: nil, snapshotID: normalized)
    }

    func snapshotDir(workspaceDirectory: URL, ref: GitDiffSnapshotRef) -> URL {
        if let repoKey = ref.repoKey {
            return snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: ref.snapshotID)
        }
        return snapshotDir(workspaceDirectory: workspaceDirectory, snapshotID: ref.snapshotID)
    }

    func readManifest(workspaceDirectory: URL, ref: GitDiffSnapshotRef) throws -> GitDiffSnapshotManifest? {
        if let repoKey = ref.repoKey {
            return try readManifest(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: ref.snapshotID)
        }
        return try readManifest(workspaceDirectory: workspaceDirectory, snapshotID: ref.snapshotID)
    }

    func readCurrentSnapshotID(workspaceDirectory: URL) -> String? {
        let url = currentPointerURL(workspaceDirectory: workspaceDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("/") {
                let root = snapshotsRoot(workspaceDirectory: workspaceDirectory).path
                if trimmed.hasPrefix(root) || trimmed.lowercased().hasPrefix(root.lowercased()) {
                    var rel = String(trimmed.dropFirst(root.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    return rel.isEmpty ? nil : rel
                }
            }
            return trimmed
        }
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func writeCurrentSnapshotID(_ snapshotID: String, workspaceDirectory: URL) throws {
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory)
        let pointerURL = currentPointerURL(workspaceDirectory: workspaceDirectory)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: pointerURL.path) {
            try? fileManager.removeItem(at: pointerURL)
        }
        let relativeTarget = snapshotID
        do {
            try fileManager.createSymbolicLink(atPath: pointerURL.path, withDestinationPath: relativeTarget)
        } catch {
            let data = Data(relativeTarget.utf8)
            try data.write(to: pointerURL, options: .atomic)
        }
    }

    // MARK: - Repo-scoped read/write methods

    /// Read CURRENT snapshot ID for a specific repo, with optional legacy fallback
    /// - Parameters:
    ///   - workspaceDirectory: The workspace directory
    ///   - repoKey: The repo key for scoped storage
    ///   - fallbackToLegacy: If true and repo-scoped CURRENT doesn't exist, check legacy location
    /// - Returns: The current snapshot ID, or nil if none
    func readCurrentSnapshotID(workspaceDirectory: URL, repoKey: String, fallbackToLegacy: Bool = false) -> String? {
        let url = currentPointerURL(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        if let result = readCurrentPointer(at: url, relativeTo: snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)) {
            return result
        }
        // Fallback to legacy if requested
        if fallbackToLegacy {
            return readCurrentSnapshotID(workspaceDirectory: workspaceDirectory)
        }
        return nil
    }

    /// Write CURRENT pointer for a specific repo
    func writeCurrentSnapshotID(_ snapshotID: String, workspaceDirectory: URL, repoKey: String) throws {
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        let pointerURL = currentPointerURL(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: pointerURL.path) {
            try? fileManager.removeItem(at: pointerURL)
        }
        let relativeTarget = snapshotID
        do {
            try fileManager.createSymbolicLink(atPath: pointerURL.path, withDestinationPath: relativeTarget)
        } catch {
            let data = Data(relativeTarget.utf8)
            try data.write(to: pointerURL, options: .atomic)
        }
    }

    /// Read manifest for a repo-scoped snapshot
    func readManifest(workspaceDirectory: URL, repoKey: String, snapshotID: String) throws -> GitDiffSnapshotManifest? {
        let manifestURL = snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)
            .appendingPathComponent("manifest.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitDiffSnapshotManifest.self, from: data)
    }

    /// List snapshot entries for a specific repo
    func listSnapshotEntries(workspaceDirectory: URL, repoKey: String) throws -> [SnapshotEntry] {
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        return try listSnapshotEntries(in: root, allowLegacyPaths: false, repoKey: repoKey)
    }

    /// Delete a snapshot for a specific repo, cleaning up empty parent directories
    func deleteSnapshot(workspaceDirectory: URL, repoKey: String, snapshotID: String) throws -> Bool {
        let dir = snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir.path) else { return false }
        try fileManager.removeItem(at: dir)

        // Clean up empty parent directories (e.g., date folders like "2026-01-21/")
        // Stop at the repo root directory
        let repoRoot = snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        removeEmptyParentDirectories(from: dir.deletingLastPathComponent(), stopAt: repoRoot)

        return true
    }

    /// Removes empty parent directories from `start` up to (but not including) `stop`.
    /// Used to clean up intermediate directories like date folders after snapshot deletion.
    private func removeEmptyParentDirectories(from start: URL, stopAt stop: URL) {
        let fileManager = FileManager.default
        var dir = start

        // Walk up the directory tree, removing empty directories
        while dir.path.hasPrefix(stop.path), dir.path != stop.path {
            // Check if directory is empty (ignoring .DS_Store and similar)
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else { break }
            let significantContents = contents.filter { !$0.hasPrefix(".") }
            guard significantContents.isEmpty else { break }

            // Remove the empty directory
            try? fileManager.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Update CURRENT pointer to newest snapshot for a specific repo
    func updateCurrentToNewest(workspaceDirectory: URL, repoKey: String, excluding deletedIDs: Set<String> = []) throws {
        let entries = try listSnapshotEntries(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
            .filter { !deletedIDs.contains($0.snapshotID) }
            .sorted { $0.manifest.generatedAt > $1.manifest.generatedAt }
        if let newest = entries.first {
            try writeCurrentSnapshotID(newest.snapshotID, workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        } else {
            let pointerURL = currentPointerURL(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
            if FileManager.default.fileExists(atPath: pointerURL.path) {
                try? FileManager.default.removeItem(at: pointerURL)
            }
        }
    }

    /// List all repo keys that have snapshots
    func listRepoKeys(workspaceDirectory: URL) -> [String] {
        let reposDir = reposRoot(workspaceDirectory: workspaceDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: reposDir.path) else { return [] }
        do {
            let contents = try fileManager.contentsOfDirectory(at: reposDir, includingPropertiesForKeys: [.isDirectoryKey])
            return contents.compactMap { url -> String? in
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
                let name = url.lastPathComponent
                // Skip hidden folders and special files
                guard !name.hasPrefix("."), name != "CURRENT" else { return nil }
                return name
            }
        } catch {
            return []
        }
    }

    /// Search for a snapshot ID across all repos
    /// Returns tuples of (repoKey, manifest) for repos that contain this snapshot
    func findSnapshot(workspaceDirectory: URL, snapshotID: String) -> [(repoKey: String?, manifest: GitDiffSnapshotManifest)] {
        var results: [(repoKey: String?, manifest: GitDiffSnapshotManifest)] = []
        for repoKey in listRepoKeys(workspaceDirectory: workspaceDirectory) {
            if let manifest = try? readManifest(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID) {
                results.append((repoKey, manifest))
            }
        }
        // Also check legacy location
        if let manifest = try? readManifest(workspaceDirectory: workspaceDirectory, snapshotID: snapshotID) {
            results.append((nil, manifest))
        }
        return results
    }

    func locateSnapshotRefs(workspaceDirectory: URL, snapshotID: String) -> [GitDiffSnapshotRef] {
        var results: [GitDiffSnapshotRef] = []
        for repoKey in listRepoKeys(workspaceDirectory: workspaceDirectory) {
            if (try? readManifest(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)) != nil {
                results.append(GitDiffSnapshotRef(repoKey: repoKey, snapshotID: snapshotID))
            }
        }
        if (try? readManifest(workspaceDirectory: workspaceDirectory, snapshotID: snapshotID)) != nil {
            results.append(GitDiffSnapshotRef(repoKey: nil, snapshotID: snapshotID))
        }
        return results
    }

    func locateRepoScopedSnapshotRefs(workspaceDirectory: URL, snapshotID: String) -> [GitDiffSnapshotRef] {
        var results: [GitDiffSnapshotRef] = []
        for repoKey in listRepoKeys(workspaceDirectory: workspaceDirectory) {
            if (try? readManifest(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)) != nil {
                results.append(GitDiffSnapshotRef(repoKey: repoKey, snapshotID: snapshotID))
            }
        }
        return results
    }

    func manifestMatchesRepo(_ manifest: GitDiffSnapshotManifest, repo: GitRepoDescriptor) -> Bool {
        if let manifestRepoKey = manifest.repoKey, manifestRepoKey == repo.repoKey {
            return true
        }
        guard let manifestRepoRoot = manifest.repoRoot else { return false }
        let manifestPath = (manifestRepoRoot as NSString).standardizingPath
        let repoPath = (repo.rootPath as NSString).standardizingPath
        return manifestPath == repoPath
    }

    func purgeLegacyGitDiffSnapshots(workspaceDirectory: URL) throws -> LegacyPurgeResult {
        let legacySnapshotDirs = locateLegacySnapshotDirs(workspaceDirectory: workspaceDirectory)
        let removedLegacyCurrent = removeIfExists(currentPointerURL(workspaceDirectory: workspaceDirectory))
        let legacyDiffSnapshotsDir = snapshotsRoot(workspaceDirectory: workspaceDirectory)
            .appendingPathComponent("diff-snapshots", isDirectory: true)
        let removedLegacyDiffSnapshotsDir = removeIfExists(legacyDiffSnapshotsDir)

        let fileManager = FileManager.default
        var deletedCount = 0
        for dir in legacySnapshotDirs {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
                deletedCount += 1
            }
        }

        return LegacyPurgeResult(
            removedLegacyCurrent: removedLegacyCurrent,
            removedLegacyDiffSnapshotsDir: removedLegacyDiffSnapshotsDir,
            deletedLegacySnapshotDirs: deletedCount
        )
    }

    private func locateLegacySnapshotDirs(workspaceDirectory: URL) -> Set<URL> {
        let root = gitDataRoot(workspaceDirectory: workspaceDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: Set<URL> = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent != "manifest.json" { continue }
            let path = fileURL.path
            if path.contains("/repos/") { continue }
            if path.contains("/diff-snapshots/") { continue }
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            results.insert(fileURL.deletingLastPathComponent())
        }
        return results
    }

    private func removeIfExists(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try? fileManager.removeItem(at: url)
        return true
    }

    /// Helper to read a CURRENT symlink/file at a given URL
    private func readCurrentPointer(at url: URL, relativeTo root: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("/") {
                let rootPath = root.path
                if trimmed.hasPrefix(rootPath) || trimmed.lowercased().hasPrefix(rootPath.lowercased()) {
                    var rel = String(trimmed.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    return rel.isEmpty ? nil : rel
                }
            }
            return trimmed
        }
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Write a snapshot for a specific repo (multi-root support)
    func writeSnapshot(
        workspaceDirectory: URL,
        repoKey: String,
        snapshotID: String,
        mode: GitDiffPublishMode,
        compareRaw: String,
        compareInput: String?,
        scope: GitDiffScope,
        requestedPaths: [String]?,
        fingerprint: GitDiffFingerprint,
        contextLines: Int,
        detectRenames: Bool,
        inputs: GitDiffEngine.GitDiffSnapshotBuildResult,
        commitGraph: String,
        repoRoot: String? = nil,
        tabID: UUID? = nil
    ) throws -> GitDiffSnapshotManifest {
        let fileManager = FileManager.default
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory, repoKey: repoKey)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let snapshotDir = snapshotDir(workspaceDirectory: workspaceDirectory, repoKey: repoKey, snapshotID: snapshotID)
        if fileManager.fileExists(atPath: snapshotDir.path) {
            try fileManager.removeItem(at: snapshotDir)
        }
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true, attributes: nil)
        let snapshotDirRel = snapshotRelativePath(repoKey: repoKey, snapshotID: snapshotID)
        let indexDir = snapshotDir.appendingPathComponent("index", isDirectory: true)
        try fileManager.createDirectory(at: indexDir, withIntermediateDirectories: true, attributes: nil)

        let generatedAt = Date()
        var writtenPatches: [String: PatchInfo] = [:]
        var allPatchPath: String? = nil

        if mode != .quick {
            if let perFile = inputs.perFile, !perFile.isEmpty {
                let diffDir = snapshotDir.appendingPathComponent("diff", isDirectory: true)
                let perFileDir = diffDir.appendingPathComponent("per-file", isDirectory: true)
                try fileManager.createDirectory(at: perFileDir, withIntermediateDirectories: true, attributes: nil)

                for (gitPath, diffText) in perFile.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                    let data = Data(diffText.utf8)
                    let fileName = Self.encodeGitPathForPatchFileName(gitPath)
                    let fileURL = perFileDir.appendingPathComponent(fileName)
                    try data.write(to: fileURL, options: .atomic)
                    let linesCount = diffText.split(separator: "\n", omittingEmptySubsequences: false).count
                    let hunks = buildHunkIndex(for: diffText)
                    let relPath = relativePath(from: snapshotDir, to: fileURL)
                    writtenPatches[gitPath] = PatchInfo(path: relPath, bytes: data.count, lines: linesCount, hunks: hunks, text: diffText)
                }
            }

            if let diffText = inputs.diffText, !diffText.isEmpty {
                let diffDir = snapshotDir.appendingPathComponent("diff", isDirectory: true)
                try fileManager.createDirectory(at: diffDir, withIntermediateDirectories: true, attributes: nil)
                let allPatchURL = diffDir.appendingPathComponent("all.patch")
                let data = Data(diffText.utf8)
                try data.write(to: allPatchURL, options: .atomic)
                allPatchPath = relativePath(from: snapshotDir, to: allPatchURL)
            }
        }

        let orderedChanges = inputs.changedFiles.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let fileEntries: [GitDiffSnapshotManifest.FileEntry] = orderedChanges.map { file in
            let patch = writtenPatches[file.path]
            return GitDiffSnapshotManifest.FileEntry(
                gitPath: file.path,
                status: file.status,
                additions: file.additions,
                deletions: file.deletions,
                patchPath: patch?.path,
                bytes: patch?.bytes,
                lines: patch?.lines,
                hunks: patch?.hunks
            )
        }

        let summary = GitDiffSnapshotManifest.Summary(
            files: inputs.summary.files,
            insertions: inputs.summary.insertions,
            deletions: inputs.summary.deletions
        )
        let worktreeMeta = worktreeMetadata(for: repoRoot)

        let manifest = GitDiffSnapshotManifest(
            snapshotID: snapshotID,
            generatedAt: generatedAt,
            mode: mode,
            compare: compareRaw,
            compareInput: compareInput,
            scope: scope,
            requestedPaths: requestedPaths,
            fingerprint: fingerprint,
            contextLines: contextLines,
            detectRenames: detectRenames,
            summary: summary,
            files: fileEntries,
            repoKey: repoKey,
            repoRoot: repoRoot,
            isWorktree: worktreeMeta.isWorktree,
            worktreeName: worktreeMeta.worktreeName,
            worktreeRoot: worktreeMeta.worktreeRoot,
            mainWorktreeRoot: worktreeMeta.mainWorktreeRoot,
            commonGitDir: worktreeMeta.commonGitDir,
            tabID: tabID
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let manifestURL = snapshotDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        let filesTsvURL = indexDir.appendingPathComponent("files.tsv")
        let filesTsv = buildFilesTsv(files: fileEntries)
        try filesTsv.write(to: filesTsvURL, atomically: true, encoding: .utf8)

        var changedLinesTsvWritten = false
        if mode != .quick, let perFile = inputs.perFile, !perFile.isEmpty {
            let changedLinesTsv = GitDiffPatchParsing.buildChangedLinesTsv(from: perFile)
            let changedLinesURL = indexDir.appendingPathComponent("changed_lines.tsv")
            try changedLinesTsv.write(to: changedLinesURL, atomically: true, encoding: .utf8)
            changedLinesTsvWritten = true
        }

        let treeText = buildChangedFileTreeText(files: fileEntries)
        let treeURL = indexDir.appendingPathComponent("files.tree.txt")
        try treeText.write(to: treeURL, atomically: true, encoding: .utf8)

        if let requestedPaths {
            let selectionURL = indexDir.appendingPathComponent("selection.paths.txt")
            let selectionText = requestedPaths.joined(separator: "\n")
            try selectionText.write(to: selectionURL, atomically: true, encoding: .utf8)
        }

        if mode == .deep {
            let deepDir = snapshotDir.appendingPathComponent("deep", isDirectory: true)
            try fileManager.createDirectory(at: deepDir, withIntermediateDirectories: true, attributes: nil)
            let deep = parseDeepArtifacts(perFilePatches: writtenPatches)
            let hunksURL = deepDir.appendingPathComponent("hunks.jsonl")
            let linesURL = deepDir.appendingPathComponent("changed_lines.tsv")
            try deep.hunksJsonl.write(to: hunksURL, atomically: true, encoding: .utf8)
            try deep.changedLinesTsv.write(to: linesURL, atomically: true, encoding: .utf8)
        }

        var artifacts: [String: String] = [
            "manifest": "manifest.json",
            "map": "MAP.txt",
            "files_tsv": "index/files.tsv",
            "tree": "index/files.tree.txt"
        ]
        if changedLinesTsvWritten {
            artifacts["changed_lines"] = "index/changed_lines.tsv"
        }
        if requestedPaths != nil {
            artifacts["selection_paths"] = "index/selection.paths.txt"
        }
        if let allPatchPath {
            artifacts["all_patch"] = allPatchPath
        }
        if mode == .deep {
            artifacts["deep_hunks"] = "deep/hunks.jsonl"
            artifacts["deep_changed_lines"] = "deep/changed_lines.tsv"
        }

        let mapText = GitDiffMapBuilder.build(
            GitDiffMapBuilder.Inputs(
                snapshotID: snapshotID,
                snapshotDir: snapshotDirRel,
                generatedAt: generatedAt,
                mode: mode,
                compareRaw: compareRaw,
                compareInput: compareInput,
                scope: scope,
                requestedPaths: requestedPaths,
                fingerprint: fingerprint,
                contextLines: contextLines,
                detectRenames: detectRenames,
                summary: summary,
                files: fileEntries,
                commitGraph: commitGraph,
                treeText: treeText,
                jumpTableText: buildJumpTableText(files: fileEntries),
                artifacts: artifacts,
                repoKey: repoKey,
                repoRoot: repoRoot,
                isWorktree: worktreeMeta.isWorktree,
                worktreeName: worktreeMeta.worktreeName,
                worktreeRoot: worktreeMeta.worktreeRoot,
                mainWorktreeRoot: worktreeMeta.mainWorktreeRoot,
                commonGitDir: worktreeMeta.commonGitDir
            )
        )
        let mapURL = snapshotDir.appendingPathComponent("MAP.txt")
        try mapText.write(to: mapURL, atomically: true, encoding: .utf8)

        return manifest
    }

    func readManifest(workspaceDirectory: URL, snapshotID: String) throws -> GitDiffSnapshotManifest? {
        let manifestURL = snapshotDir(workspaceDirectory: workspaceDirectory, snapshotID: snapshotID)
            .appendingPathComponent("manifest.json")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitDiffSnapshotManifest.self, from: data)
    }

    private func listSnapshotEntries(in root: URL, allowLegacyPaths: Bool, repoKey: String? = nil) throws -> [SnapshotEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [SnapshotEntry] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent != "manifest.json" { continue }
            if fileURL.path.contains("/CURRENT/") { continue }
            if !allowLegacyPaths, fileURL.path.contains("/diff-snapshots/") { continue }
            // Skip repos subdirectory when listing legacy root
            if repoKey == nil, fileURL.path.contains("/repos/") { continue }
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let snapshotDir = fileURL.deletingLastPathComponent()
            let snapshotID = relativePath(from: root, to: snapshotDir)
            guard let data = try? Data(contentsOf: fileURL),
                  let manifest = try? decoder.decode(GitDiffSnapshotManifest.self, from: data)
            else {
                continue
            }
            entries.append(SnapshotEntry(snapshotID: snapshotID, snapshotDir: snapshotDir, manifest: manifest, repoKey: repoKey))
        }
        return entries
    }

    func listSnapshotEntries(workspaceDirectory: URL) throws -> [SnapshotEntry] {
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory)
        return try listSnapshotEntries(in: root, allowLegacyPaths: false, repoKey: nil)
    }

    func deleteSnapshot(workspaceDirectory: URL, snapshotID: String) throws -> Bool {
        let dir = snapshotDir(workspaceDirectory: workspaceDirectory, snapshotID: snapshotID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir.path) else { return false }
        try fileManager.removeItem(at: dir)

        // Clean up empty parent directories (e.g., date folders)
        let gitDataRoot = snapshotsRoot(workspaceDirectory: workspaceDirectory)
        removeEmptyParentDirectories(from: dir.deletingLastPathComponent(), stopAt: gitDataRoot)

        return true
    }

    /// Clears all git diff snapshots and the CURRENT pointer for a workspace.
    /// - Parameter workspaceDirectory: The workspace directory containing the _git_data folder.
    /// - Returns: The number of snapshots deleted.
    func clearAllSnapshots(workspaceDirectory: URL) throws -> Int {
        let root = snapshotsRoot(workspaceDirectory: workspaceDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        // Count snapshots before deletion (include legacy diff-snapshots layout)
        let entries = (try? listSnapshotEntries(workspaceDirectory: workspaceDirectory)) ?? []
        var count = entries.count
        let legacyRoot = root.appendingPathComponent("diff-snapshots", isDirectory: true)
        if fileManager.fileExists(atPath: legacyRoot.path) {
            let legacyEntries = (try? listSnapshotEntries(in: legacyRoot, allowLegacyPaths: true)) ?? []
            count += legacyEntries.count
        }

        // Remove snapshot contents but keep the _git_data root
        let contents = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try? fileManager.removeItem(at: item)
        }

        return count
    }

    func updateCurrentToNewest(workspaceDirectory: URL, excluding deletedIDs: Set<String> = []) throws {
        let entries = try listSnapshotEntries(workspaceDirectory: workspaceDirectory)
            .filter { !deletedIDs.contains($0.snapshotID) }
            .sorted { $0.manifest.generatedAt > $1.manifest.generatedAt }
        if let newest = entries.first {
            try writeCurrentSnapshotID(newest.snapshotID, workspaceDirectory: workspaceDirectory)
        } else {
            let pointerURL = currentPointerURL(workspaceDirectory: workspaceDirectory)
            if FileManager.default.fileExists(atPath: pointerURL.path) {
                try? FileManager.default.removeItem(at: pointerURL)
            }
        }
    }

    static func encodeGitPathForPatchFileName(_ gitPath: String) -> String {
        var normalized = gitPath
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        normalized = normalized.replacingOccurrences(of: "/", with: "__")
        normalized = normalized.replacingOccurrences(of: " ", with: "_")
        if normalized.isEmpty {
            normalized = "file"
        }
        let ext = ".patch"
        var name = normalized + ext
        let maxLength = 180
        if name.count > maxLength {
            let hash = sha256Hex(Data(name.utf8)).prefix(8)
            let keep = max(1, maxLength - ext.count - hash.count - 1)
            let prefix = String(normalized.prefix(keep))
            name = prefix + "-" + hash + ext
        }
        return name
    }

    static func normalizeSnapshotID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return nil
        }
        var cleaned = trimmed
        while cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.lowercased() == "current" {
            return nil
        }
        let parts = cleaned.split(separator: "/").map(String.init)
        for part in parts {
            if part == "." || part == ".." || part.isEmpty {
                return nil
            }
            if part.contains(":") {
                return nil
            }
        }
        return parts.joined(separator: "/")
    }

    private func relativePath(from base: URL, to url: URL) -> String {
        let basePath = (base.path as NSString).standardizingPath
        let targetPath = (url.path as NSString).standardizingPath
        if targetPath.hasPrefix(basePath) {
            var rel = String(targetPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        let baseLower = basePath.lowercased()
        let targetLower = targetPath.lowercased()
        if targetLower.hasPrefix(baseLower) {
            var rel = String(targetPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.path
    }

    func worktreeMetadata(for repoRoot: String?) -> (isWorktree: Bool?, worktreeName: String?, worktreeRoot: String?, mainWorktreeRoot: String?, commonGitDir: String?) {
        guard let repoRoot, !repoRoot.isEmpty else {
            return (nil, nil, nil, nil, nil)
        }
        let rootURL = URL(fileURLWithPath: repoRoot)
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL), layout.isLinkedWorktree else {
            return (nil, nil, nil, nil, nil)
        }
        let worktreeName = layout.gitDir.lastPathComponent.isEmpty ? nil : layout.gitDir.lastPathComponent
        return (
            true,
            worktreeName,
            layout.workTreeRoot.path,
            layout.knownMainWorktreeRoot?.path,
            layout.commonDir.path
        )
    }

    private func buildHunkIndex(for diffText: String) -> [DiffHunkIndex]? {
        let lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        var hunks: [DiffHunkIndex] = []
        var currentHeader: String?
        var currentStart: Int?

        func flush(at endLine: Int) {
            guard let header = currentHeader, let start = currentStart else { return }
            hunks.append(DiffHunkIndex(header: header, startLine: start, endLine: endLine))
            currentHeader = nil
            currentStart = nil
        }

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.hasPrefix("@@") {
                if currentHeader != nil {
                    flush(at: lineNumber - 1)
                }
                currentHeader = line
                currentStart = lineNumber
            }
        }

        if let _ = currentHeader, let _ = currentStart {
            flush(at: lines.count)
        }

        return hunks.isEmpty ? nil : hunks
    }

    private func buildFilesTsv(files: [GitDiffSnapshotManifest.FileEntry]) -> String {
        var lines: [String] = []
        lines.append("status\tadditions\tdeletions\tgit_path\tpatch_path\tbytes\tlines")
        for entry in files {
            let status = entry.status ?? ""
            let add = entry.additions.map(String.init) ?? ""
            let del = entry.deletions.map(String.init) ?? ""
            let patch = entry.patchPath ?? ""
            let bytes = entry.bytes.map(String.init) ?? ""
            let linesCount = entry.lines.map(String.init) ?? ""
            lines.append([status, add, del, entry.gitPath, patch, bytes, linesCount].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private func sortCaseInsensitiveKeys(_ keys: [String]) -> [String] {
        let keyed = keys.map { key in
            (lower: key.lowercased(), original: key)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.original)
    }

    private func sortCaseInsensitive<T>(_ items: [T], key: (T) -> String) -> [T] {
        let keyed = items.map { value in
            let original = key(value)
            return (lower: original.lowercased(), original: original, value: value)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.value)
    }

    private func statusSummary(for entry: GitDiffSnapshotManifest.FileEntry) -> String {
        let status = entry.status ?? ""
        let add = entry.additions.map { "+\($0)" } ?? "+?"
        let del = entry.deletions.map { "-\($0)" } ?? "-?"
        if status.isEmpty {
            return "\(add) \(del)"
        }
        return "\(status) \(add) \(del)"
    }

    static func displayOrderedFiles(_ files: [GitDiffSnapshotManifest.FileEntry]) -> [GitDiffSnapshotManifest.FileEntry] {
        files.sorted { lhs, rhs in
            let lhsLower = lhs.gitPath.lowercased()
            let rhsLower = rhs.gitPath.lowercased()
            if lhsLower != rhsLower {
                return lhsLower < rhsLower
            }
            return lhs.gitPath < rhs.gitPath
        }
    }

    private func buildJumpTableText(files: [GitDiffSnapshotManifest.FileEntry]) -> String {
        let ordered = Self.displayOrderedFiles(files)
        let indexWidth = max(2, String(ordered.count).count)
        var lines: [String] = []
        for (index, entry) in ordered.enumerated() {
            let idx = index + 1
            let idxText = String(format: "%0*d", indexWidth, idx)
            let status = statusSummary(for: entry)
            let target = entry.patchPath ?? "(no patch)"
            lines.append("[\(idxText)] \(status)  \(entry.gitPath) -> \(target)")
        }
        return lines.joined(separator: "\n")
    }

    private func buildChangedFileTreeText(files: [GitDiffSnapshotManifest.FileEntry]) -> String {
        let ordered = Self.displayOrderedFiles(files)
        let indexWidth = max(2, String(ordered.count).count)
        // Duplicate-tolerant (last-wins) so duplicated git paths never trap —
        // they should be unique per snapshot, but the tree render should not
        // SIGTRAP if the manifest ever repeats a path.
        let indexMap = Dictionary(
            ordered.enumerated().map { offset, entry in (entry.gitPath, offset + 1) },
            uniquingKeysWith: { _, last in last }
        )

        let root = TreeNode(name: "")
        for entry in ordered {
            let parts = entry.gitPath.split(separator: "/").map(String.init)
            var node = root
            for (idx, part) in parts.enumerated() {
                let isLeaf = idx == parts.count - 1
                let child = node.children[part] ?? TreeNode(name: part)
                if isLeaf {
                    child.fileEntry = entry
                }
                node.children[part] = child
                node = child
            }
        }

        var output: [String] = []
        func render(node: TreeNode, indent: String) {
            let dirs = sortCaseInsensitive(node.children.values.filter { $0.fileEntry == nil }, key: { $0.name })
            let files = sortCaseInsensitive(node.children.values.filter { $0.fileEntry != nil }, key: { $0.name })
            for dir in dirs {
                output.append("\(indent)\(dir.name)/")
                render(node: dir, indent: indent + "  ")
            }
            for file in files {
                guard let entry = file.fileEntry else { continue }
                let idx = indexMap[entry.gitPath] ?? 0
                let idxText = String(format: "%0*d", indexWidth, idx)
                let status = statusSummary(for: entry)
                output.append("\(indent)\(file.name)  [\(idxText)] \(status)")
            }
        }
        render(node: root, indent: "")
        return output.joined(separator: "\n")
    }

    private func parseDeepArtifacts(perFilePatches: [String: PatchInfo]) -> (hunksJsonl: String, changedLinesTsv: String) {
        let orderedKeys = sortCaseInsensitiveKeys(Array(perFilePatches.keys))
        var hunksLines: [String] = []
        var changedLines: [String] = []
        let encoder = JSONEncoder()

        for gitPath in orderedKeys {
            guard let patch = perFilePatches[gitPath] else { continue }
            let lines = patch.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var oldLine = 0
            var newLine = 0
            for line in lines {
                if line.hasPrefix("@@") {
                    if let header = GitDiffPatchParsing.parseHunkHeader(line) {
                        oldLine = header.oldStart
                        newLine = header.newStart
                        let record = DeepHunkRecord(
                            path: gitPath,
                            header: line,
                            oldStart: header.oldStart,
                            oldCount: header.oldLines,
                            newStart: header.newStart,
                            newCount: header.newLines
                        )
                        if let data = try? encoder.encode(record),
                           let json = String(data: data, encoding: .utf8)
                        {
                            hunksLines.append(json)
                        }
                    }
                    continue
                }
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") {
                    continue
                }
                if line.hasPrefix("+") {
                    let text = String(line.dropFirst())
                    let row = [gitPath, "+", "", String(newLine), text].joined(separator: "\t")
                    changedLines.append(row)
                    newLine += 1
                    continue
                }
                if line.hasPrefix("-") {
                    let text = String(line.dropFirst())
                    let row = [gitPath, "-", String(oldLine), "", text].joined(separator: "\t")
                    changedLines.append(row)
                    oldLine += 1
                    continue
                }
                if line.hasPrefix(" ") {
                    oldLine += 1
                    newLine += 1
                    continue
                }
                if line.hasPrefix("\\") {
                    continue
                }
            }
        }

        return (hunksLines.joined(separator: "\n"), changedLines.joined(separator: "\n"))
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct PatchInfo {
    let path: String
    let bytes: Int
    let lines: Int
    let hunks: [DiffHunkIndex]?
    let text: String
}

private final class TreeNode {
    let name: String
    var children: [String: TreeNode] = [:]
    var fileEntry: GitDiffSnapshotManifest.FileEntry?

    init(name: String) {
        self.name = name
    }
}

private struct DeepHunkRecord: Codable {
    let path: String
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    private enum CodingKeys: String, CodingKey {
        case path
        case header
        case oldStart = "old_start"
        case oldCount = "old_count"
        case newStart = "new_start"
        case newCount = "new_count"
    }
}

enum GitDiffMapBuilder {
    struct Inputs {
        let snapshotID: String
        let snapshotDir: String
        let generatedAt: Date
        let mode: GitDiffPublishMode
        let compareRaw: String
        let compareInput: String?
        let scope: GitDiffScope
        let requestedPaths: [String]?
        let fingerprint: GitDiffFingerprint
        let contextLines: Int
        let detectRenames: Bool
        let summary: GitDiffSnapshotManifest.Summary
        let files: [GitDiffSnapshotManifest.FileEntry]
        let commitGraph: String
        let treeText: String
        let jumpTableText: String
        let artifacts: [String: String]
        // Multi-root metadata (optional)
        let repoKey: String?
        let repoRoot: String?

        // Worktree metadata (optional)
        let isWorktree: Bool?
        let worktreeName: String?
        let worktreeRoot: String?
        let mainWorktreeRoot: String?
        let commonGitDir: String?

        init(
            snapshotID: String,
            snapshotDir: String,
            generatedAt: Date,
            mode: GitDiffPublishMode,
            compareRaw: String,
            compareInput: String?,
            scope: GitDiffScope,
            requestedPaths: [String]?,
            fingerprint: GitDiffFingerprint,
            contextLines: Int,
            detectRenames: Bool,
            summary: GitDiffSnapshotManifest.Summary,
            files: [GitDiffSnapshotManifest.FileEntry],
            commitGraph: String,
            treeText: String,
            jumpTableText: String,
            artifacts: [String: String],
            repoKey: String? = nil,
            repoRoot: String? = nil,
            isWorktree: Bool? = nil,
            worktreeName: String? = nil,
            worktreeRoot: String? = nil,
            mainWorktreeRoot: String? = nil,
            commonGitDir: String? = nil
        ) {
            self.isWorktree = isWorktree
            self.worktreeName = worktreeName
            self.worktreeRoot = worktreeRoot
            self.mainWorktreeRoot = mainWorktreeRoot
            self.commonGitDir = commonGitDir
            self.snapshotID = snapshotID
            self.snapshotDir = snapshotDir
            self.generatedAt = generatedAt
            self.mode = mode
            self.compareRaw = compareRaw
            self.compareInput = compareInput
            self.scope = scope
            self.requestedPaths = requestedPaths
            self.fingerprint = fingerprint
            self.contextLines = contextLines
            self.detectRenames = detectRenames
            self.summary = summary
            self.files = files
            self.commitGraph = commitGraph
            self.treeText = treeText
            self.jumpTableText = jumpTableText
            self.artifacts = artifacts
            self.repoKey = repoKey
            self.repoRoot = repoRoot
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func build(_ inputs: Inputs) -> String {
        var lines: [String] = []
        lines.append("# MAP.txt v1")
        lines.append("# (grep tip: search for \"SNAPSHOT_\" or \"SECTION:\")")
        lines.append("")
        lines.append("SECTION: SNAPSHOT_META")
        lines.append("SNAPSHOT_ID: \(inputs.snapshotID)")
        lines.append("SNAPSHOT_DIR: \(inputs.snapshotDir)")
        lines.append("SNAPSHOT_GENERATED_AT: \(dateFormatter.string(from: inputs.generatedAt))")
        lines.append("SNAPSHOT_MODE: \(inputs.mode.rawValue)")
        lines.append("SNAPSHOT_MODE_DETAILS: \(modeDetails(for: inputs.mode))")
        lines.append("SNAPSHOT_COMPARE: \(inputs.compareRaw)")
        if let compareInput = inputs.compareInput, compareInput != inputs.compareRaw {
            lines.append("SNAPSHOT_COMPARE_INPUT: \(compareInput)")
        }
        lines.append("SNAPSHOT_SCOPE: \(inputs.scope.rawValue)")
        if let requestedPaths = inputs.requestedPaths {
            lines.append("SNAPSHOT_SELECTED_PATHS_COUNT: \(requestedPaths.count)")
        }
        lines.append("SNAPSHOT_CHANGED_FILES: \(inputs.summary.files)")
        lines.append("SNAPSHOT_INSERTIONS: \(inputs.summary.insertions)")
        lines.append("SNAPSHOT_DELETIONS: \(inputs.summary.deletions)")

        // Multi-root metadata (when available)
        if let repoKey = inputs.repoKey {
            lines.append("")
            lines.append("SECTION: REPOSITORY")
            lines.append("REPO_KEY: \(repoKey)")
            if let repoRoot = inputs.repoRoot {
                lines.append("REPO_ROOT: \(repoRoot)")
            }
        }

        if inputs.isWorktree == true {
            lines.append("")
            lines.append("SECTION: WORKTREE")
            lines.append("WORKTREE_IS_WORKTREE: true")
            if let worktreeName = inputs.worktreeName {
                lines.append("WORKTREE_NAME: \(worktreeName)")
            }
            if let worktreeRoot = inputs.worktreeRoot {
                lines.append("WORKTREE_ROOT: \(worktreeRoot)")
            }
            if let mainRoot = inputs.mainWorktreeRoot {
                lines.append("WORKTREE_MAIN_ROOT: \(mainRoot)")
            }
            if let commonGitDir = inputs.commonGitDir {
                lines.append("WORKTREE_COMMON_GIT_DIR: \(commonGitDir)")
            }
        }

        lines.append("")
        lines.append("SECTION: FINGERPRINT")
        lines.append("FINGERPRINT_HEAD_SHA: \(inputs.fingerprint.headSHA)")
        lines.append("FINGERPRINT_BASE_REF: \(inputs.fingerprint.baseRef)")
        lines.append("FINGERPRINT_STATUS_HASH: \(inputs.fingerprint.statusHash)")

        lines.append("")
        lines.append("SECTION: ADVANCED")
        lines.append("ADV_CONTEXT_LINES: \(inputs.contextLines)")
        lines.append("ADV_DETECT_RENAMES: \(inputs.detectRenames)")

        lines.append("")
        lines.append("SECTION: ARTIFACTS")
        if let manifest = inputs.artifacts["manifest"] { lines.append("ARTIFACT_MANIFEST: \(manifest)") }
        if let map = inputs.artifacts["map"] { lines.append("ARTIFACT_MAP: \(map)") }
        if let filesTsv = inputs.artifacts["files_tsv"] { lines.append("ARTIFACT_FILES_TSV: \(filesTsv)") }
        if let changedLines = inputs.artifacts["changed_lines"] { lines.append("ARTIFACT_CHANGED_LINES: \(changedLines)") }
        if let tree = inputs.artifacts["tree"] { lines.append("ARTIFACT_TREE: \(tree)") }
        if let selection = inputs.artifacts["selection_paths"] { lines.append("ARTIFACT_SELECTION_PATHS: \(selection)") }
        if let allPatch = inputs.artifacts["all_patch"] { lines.append("ARTIFACT_ALL_PATCH: \(allPatch)") }
        if let deepHunks = inputs.artifacts["deep_hunks"] { lines.append("ARTIFACT_DEEP_HUNKS: \(deepHunks)") }
        if let deepChanged = inputs.artifacts["deep_changed_lines"] { lines.append("ARTIFACT_DEEP_CHANGED_LINES: \(deepChanged)") }

        if inputs.artifacts["changed_lines"] != nil {
            lines.append("")
            lines.append("SECTION: CHANGED_LINES_FORMAT")
            lines.append("index/changed_lines.tsv: TSV columns: path, line_number, change_type(+/-), content")
            lines.append("  - line_number: new-file line for '+', old-file line for '-'")
        }

        if inputs.mode == .deep {
            lines.append("")
            lines.append("SECTION: DEEP_FORMAT")
            lines.append("deep/hunks.jsonl: JSONL records {path, header, old_start, old_count, new_start, new_count}")
            lines.append("deep/changed_lines.tsv: TSV columns: path, op(+/-), old_line, new_line, text")
        }

        if let requestedPaths = inputs.requestedPaths {
            lines.append("")
            lines.append("SECTION: SELECTION_PATHS")
            lines.append("(selection.paths.txt is the canonical list; shown here for convenience)")
            for path in requestedPaths {
                lines.append("- \(path)")
            }
        }

        lines.append("")
        lines.append("SECTION: COMMIT_GRAPH")
        lines.append(inputs.commitGraph)

        lines.append("")
        lines.append("SECTION: CHANGED_FILE_TREE")
        lines.append(inputs.treeText)

        lines.append("")
        lines.append("SECTION: JUMP_TABLE")
        lines.append(inputs.jumpTableText)

        if let perFileSelectionPathsText = buildPerFilePatchSelectionPathsText(snapshotDir: inputs.snapshotDir, files: inputs.files) {
            lines.append("")
            lines.append("SECTION: PER_FILE_PATCH_SELECTION_PATHS")
            lines.append(perFileSelectionPathsText)
        }

        lines.append("")
        lines.append("SECTION: NOTES")
        let omittedCount = inputs.files.count(where: { $0.patchPath == nil })
        let binaryCount = inputs.files.count(where: { $0.additions == nil && $0.deletions == nil })
        lines.append("NOTE_PATCH_OMITTED_COUNT: \(omittedCount)")
        if omittedCount > 0, inputs.mode == .quick {
            lines.append("NOTE_PATCH_OMITTED_REASON: quick_mode")
        }
        lines.append("NOTE_QUICK_MODE: \(inputs.mode == .quick)")
        if let emptyReason = emptyReason(
            summary: inputs.summary,
            scope: inputs.scope,
            requestedPaths: inputs.requestedPaths,
            compareRaw: inputs.compareRaw
        ) {
            lines.append("NOTE_EMPTY_RESULT: true")
            lines.append("NOTE_EMPTY_REASON: \(emptyReason)")
        }
        if binaryCount > 0 {
            lines.append("NOTE_BINARY_FILES: \(binaryCount)")
        }

        if binaryCount > 0 {
            lines.append("")
            lines.append("SECTION: BINARY_FILES")
            let binaryFiles = inputs.files.filter { $0.additions == nil && $0.deletions == nil }
            for entry in binaryFiles {
                let status = entry.status ?? ""
                let label = status.isEmpty ? entry.gitPath : "\(status) \(entry.gitPath)"
                lines.append("- \(label)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func inlineExcerpt(from fullMap: String, maxLines: Int, sections: [String]? = nil) -> (excerpt: String, truncated: Bool, totalLines: Int, returnedLines: Int) {
        guard maxLines > 0 else { return ("", false, 0, 0) }
        let mapText = sections.flatMap { extractSections(from: fullMap, sections: $0) } ?? fullMap
        let lines = mapText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let truncated = lines.count > maxLines
        let excerpt = lines.prefix(maxLines).joined(separator: "\n")
        return (excerpt, truncated, lines.count, min(maxLines, lines.count))
    }

    private static func extractSections(from fullMap: String, sections: [String]) -> String? {
        guard !sections.isEmpty else { return nil }
        let lines = fullMap.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headerLines: [String] = []
        var sectionBlocks: [String: [String]] = [:]
        var currentName: String?
        var currentLines: [String] = []
        var sawFirstSection = false

        func flush() {
            guard let name = currentName else { return }
            sectionBlocks[name] = currentLines
            currentName = nil
            currentLines = []
        }

        for line in lines {
            if line.hasPrefix("SECTION: ") {
                if currentName != nil {
                    flush()
                } else if !sawFirstSection {
                    sawFirstSection = true
                }
                let name = line.replacingOccurrences(of: "SECTION: ", with: "")
                currentName = name
                currentLines = [line]
                continue
            }
            if let _ = currentName {
                currentLines.append(line)
            } else if !sawFirstSection {
                headerLines.append(line)
            }
        }
        if currentName != nil {
            flush()
        }

        var output: [String] = []
        if !headerLines.isEmpty {
            output.append(contentsOf: headerLines)
        }
        for section in sections {
            if let block = sectionBlocks[section] {
                if !output.isEmpty { output.append("") }
                output.append(contentsOf: block)
            }
        }
        let text = output.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildPerFilePatchSelectionPathsText(
        snapshotDir: String,
        files: [GitDiffSnapshotManifest.FileEntry]
    ) -> String? {
        let patches = GitDiffSnapshotStore.perFilePatchArtifacts(snapshotDir: snapshotDir, files: files)
        guard !patches.isEmpty else { return nil }

        let indexWidth = max(2, String(patches.map(\.jumpIndex).max() ?? 0).count)
        var lines: [String] = []
        lines.append("(selection-ready `_git_data/...` paths for direct selection; no manual snapshot-dir reconstruction or `__` filename encoding required)")
        for patch in patches {
            let idxText = String(format: "%0*d", indexWidth, patch.jumpIndex)
            let status = perFilePatchStatusSummary(patch)
            lines.append("[\(idxText)] \(status)  \(patch.gitPath) -> \(patch.selectionPath)")
        }
        return lines.joined(separator: "\n")
    }

    private static func perFilePatchStatusSummary(_ patch: GitDiffPerFilePatchArtifact) -> String {
        let status = patch.status ?? ""
        let add = patch.additions.map { "+\($0)" } ?? "+?"
        let del = patch.deletions.map { "-\($0)" } ?? "-?"
        if status.isEmpty {
            return "\(add) \(del)"
        }
        return "\(status) \(add) \(del)"
    }

    static func modeDetails(for mode: GitDiffPublishMode) -> String {
        switch mode {
        case .quick:
            "quick: no patch text, summary-only artifacts"
        case .standard:
            "standard: full diff patches (all.patch + per-file when size allows)"
        case .deep:
            "deep: standard patches + hunk and changed-line indexes"
        }
    }

    static func emptyReason(
        summary: GitDiffSnapshotManifest.Summary,
        scope: GitDiffScope,
        requestedPaths: [String]?,
        compareRaw: String
    ) -> String? {
        guard summary.files == 0 else { return nil }
        if scope == .selected {
            if requestedPaths?.isEmpty ?? true {
                return "selection_empty"
            }
            return "no_changes_in_selected_paths"
        }
        let lowered = compareRaw.lowercased()
        if lowered == "staged" || lowered.hasPrefix("staged:") {
            return "no_staged_changes"
        }
        if lowered == "unstaged" {
            return "no_unstaged_changes"
        }
        if lowered == "uncommitted" || lowered.hasPrefix("uncommitted:") {
            return "no_uncommitted_changes"
        }
        return "no_changes"
    }
}
