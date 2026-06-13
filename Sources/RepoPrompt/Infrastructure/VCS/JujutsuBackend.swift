import Foundation

/// Jujutsu (jj) backend implementation.
/// Uses `JJCommandRunner` for all commands and translates RepoPrompt's VCS API into jj operations.
///
/// Key semantics:
/// - "HEAD" is normalized to "@-" (working copy parent).
/// - Staged/unstaged compare specs are degraded to uncommitted with warnings (jj has no staging area).
/// - Unified diffs use `jj diff --git`.
/// - Fingerprint statusHash is prefixed with "jj:" to prevent collisions with git fingerprints.
public actor JujutsuBackend: VCSBackendWithWarnings {
    // MARK: - Configuration

    public nonisolated let kind: VCSBackendKind = .jujutsu
    public nonisolated let capabilities: VCSCapabilities = .jujutsu

    private let runner: JJCommandRunner
    private let bookmarkCacheTTL: TimeInterval = 1.0
    private var bookmarkListTasks: [BookmarkListKey: Task<BookmarkListResult, Error>] = [:]
    private var bookmarkListCache: [BookmarkListKey: TimedCache<[String]>] = [:]
    private var bookmarkSnapshotTasks: [String: Task<BookmarkSnapshot, Error>] = [:]
    private var bookmarkSnapshotCache: [String: TimedCache<BookmarkSnapshot>] = [:]
    private var bookmarkCacheGenerations: [String: Int] = [:]

    public init(runner: JJCommandRunner = JJCommandRunner()) {
        self.runner = runner
    }

    // MARK: - VCSBackendWithWarnings

    public nonisolated func normalizeBaseRef(_ baseRef: String) -> String {
        let trimmed = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "@-" }

        // jj equivalents:
        // - Git "HEAD" (baseline) should correspond to the parent of the working copy commit.
        // - "@": working copy commit
        // - "@-": parent of working copy (closest match to git HEAD baseline)
        // - "@~N" or "@-N": N ancestors back

        // Handle HEAD~N → @~N
        if trimmed.uppercased().hasPrefix("HEAD~") {
            let suffix = String(trimmed.dropFirst(5)) // "HEAD~" is 5 chars
            return "@~\(suffix)"
        }

        // Handle HEAD^ → @- (parent)
        if trimmed.uppercased() == "HEAD^" {
            return "@-"
        }

        // Handle HEAD^N → @~N (N-th parent)
        if trimmed.uppercased().hasPrefix("HEAD^") {
            let suffix = String(trimmed.dropFirst(5))
            if let n = Int(suffix), n > 0 {
                return "@~\(n)"
            }
        }

        // Handle plain HEAD
        if trimmed.caseInsensitiveCompare("HEAD") == .orderedSame {
            return "@-"
        }

        return trimmed
    }

    public nonisolated func normalizeCompareSpec(_ spec: GitDiffCompareSpec) -> GitDiffCompareSpec {
        normalizeCompareSpecWithWarning(spec).spec
    }

    public nonisolated func normalizeCompareSpecWithWarning(_ spec: GitDiffCompareSpec) -> NormalizedCompareResult {
        switch spec {
        case let .uncommitted(base):
            // Preserve the user's base ref input, but normalize "HEAD" at execution time.
            NormalizedCompareResult(spec: .uncommitted(base: base), warning: nil)

        case let .uncommittedMergeBase(base):
            NormalizedCompareResult(
                spec: .uncommitted(base: base),
                warning: "jj backend: 'merge-base' compare is not supported. Degraded to 'uncommitted'."
            )

        case let .staged(base):
            // jj has no staging area; degrade to uncommitted(base: ...)
            NormalizedCompareResult(
                spec: .uncommitted(base: base),
                warning: "jj backend: 'staged' is not supported (no staging area). Degraded to 'uncommitted'."
            )

        case let .stagedMergeBase(base):
            NormalizedCompareResult(
                spec: .staged(base: base),
                warning: "jj backend: 'merge-base' compare is not supported. Degraded to 'staged', which behaves like 'uncommitted' because jj has no staging area."
            )

        case .unstaged:
            // jj has no staging area; degrade to uncommitted(HEAD)
            NormalizedCompareResult(
                spec: .uncommitted(base: "HEAD"),
                warning: "jj backend: 'unstaged' is not supported (no staging area). Degraded to 'uncommitted'."
            )

        case let .revspec(raw):
            // Keep revspec as-is and handle translation at execution time.
            NormalizedCompareResult(spec: .revspec(raw), warning: nil)
        }
    }

    // MARK: - Parent Revset Helper

    /// Returns a jj revset expression for the parents of a revision.
    /// Uses explicit `parents(rev)` syntax instead of `rev-` shorthand to avoid
    /// parsing ambiguities with arbitrary commit IDs.
    private nonisolated func parentRevsetExpr(for rev: String) -> String {
        "parents(\(rev))"
    }

    // MARK: - Repository Discovery

    public func findRepoRoot(from url: URL) async throws -> URL? {
        // jj: `jj root` returns the workspace root directory (repo root for our purposes).
        let (stdout, _, exitCode) = try await runner.run(["root", "--color=never"], at: url)
        guard exitCode == 0 else { return nil }
        let s = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s)
    }

    // MARK: - Reference Operations

    public func getHeadID(at repoURL: URL) async throws -> String {
        // Head ID in jj context: the working copy commit id for "@"
        if let id = try await templateSingleValue(
            args: ["log", "-r", "@", "--no-graph", "--color=never", "-T", "commit_id ++ \"\\n\""],
            at: repoURL
        ) {
            return id
        }

        // Fallback: parse `jj log -r @ --no-graph`
        let text = try await runner.runOrThrow(["log", "-r", "@", "--no-graph", "--color=never"], at: repoURL)
        if let firstHex = firstHexLikeToken(in: text) {
            return firstHex
        }
        throw VCSError.parseError(message: "Unable to resolve jj head id")
    }

    public func getRefID(ref: String, at repoURL: URL) async throws -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VCSError.parseError(message: "Empty ref") }

        if let id = try await templateSingleValue(
            args: ["log", "-r", trimmed, "--no-graph", "--color=never", "-T", "commit_id ++ \"\\n\""],
            at: repoURL
        ) {
            return id
        }

        let text = try await runner.runOrThrow(["log", "-r", trimmed, "--no-graph", "--color=never"], at: repoURL)
        if let firstHex = firstHexLikeToken(in: text) {
            return firstHex
        }
        throw VCSError.parseError(message: "Unable to resolve jj ref id for \(ref)")
    }

    // MARK: - Status Operations

    public func getCurrentBranch(at repoURL: URL) async throws -> String? {
        // jj does not have a direct "current branch" concept; it uses bookmarks.
        // Best-effort: return the first bookmark pointing at @, if we can.
        // If this is too brittle, return nil.
        try await bookmarkSnapshot(repoURL: repoURL).current.first
    }

    public func getLocalBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch] {
        // jj: bookmarks approximate branches.
        // Use bookmarks list; treat all as "local" by default.
        let snapshot = try await bookmarkSnapshot(repoURL: repoURL)
        let current = Set(snapshot.current)
        let capped = Array(snapshot.all.prefix(max(0, limit)))
        return capped.map { name in
            VCSBranch(name: name, isCurrent: current.contains(name), lastCommitDate: nil)
        }
    }

    public func getRemoteBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch] {
        // jj: tracked bookmarks represent remote tracking.
        let names = try await listBookmarks(repoURL: repoURL, mode: .tracked)
        let capped = Array(names.prefix(max(0, limit)))
        return capped.map { name in
            VCSBranch(name: name, isCurrent: false, lastCommitDate: nil)
        }
    }

    public func getTags(at repoURL: URL, limit: Int) async throws -> [VCSTag] {
        // jj does not have first-class tags. Return empty (non-fatal).
        []
    }

    public func getUpstreamRef(at repoURL: URL) async throws -> String? {
        // Not directly modeled in jj bookmarks; return nil.
        nil
    }

    public func getAheadBehind(vs ref: String, at repoURL: URL) async throws -> (ahead: Int, behind: Int)? {
        // Not a stable concept in jj without additional revset calculations; return nil.
        nil
    }

    public func getRepositoryStatus(at repoURL: URL) async throws -> VCSRepositoryStatus {
        async let branch = getCurrentBranch(at: repoURL)
        async let workingStatus = getWorkingStatus(at: repoURL)
        return try await VCSRepositoryStatus(
            branch: branch,
            headID: nil,
            upstream: nil,
            ahead: nil,
            behind: nil,
            workingStatus: workingStatus
        )
    }

    public func getWorkingStatus(at repoURL: URL) async throws -> VCSWorkingStatus {
        // jj has no staging area and no untracked concept in the same way as git.
        // Provide a best-effort \"modified\" list from `jj diff --summary`.
        let refs = try resolveDiffRefs(for: .uncommitted(base: "HEAD"), repoURL: repoURL)
        let summaryText = try await jjDiffSummary(from: refs.from, to: refs.to, repoURL: repoURL, paths: nil)
        let files = parseJjDiffSummary(summaryText).map(\.path)

        return VCSWorkingStatus(
            staged: [],
            modified: files.sorted(),
            untracked: []
        )
    }

    public func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool {
        // jj remote-ish bookmarks are typically shown by `jj bookmark list --tracked`.
        // Best-effort: check membership.
        do {
            let tracked = try await listBookmarks(repoURL: repoURL, mode: .tracked)
            return tracked.contains(refName)
        } catch {
            // Fallback heuristic
            return refName.contains("/")
        }
    }

    // MARK: - Remote Operations

    public func fetch(at repoURL: URL) async throws {
        // jj uses git remotes via `jj git fetch`
        try await withBookmarkCachesBypassed(for: repoURL) {
            _ = try await runner.runOrThrow(["git", "fetch", "--color=never"], at: repoURL)
        }
    }

    // MARK: - Fingerprint Operations

    public func getStatusFingerprint(at repoURL: URL, baseRef: String) async throws -> GitDiffFingerprint {
        let normalizedBase = normalizeBaseRef(baseRef)

        // Use working copy commit id for headSHA equivalent.
        let headID = try await getHeadID(at: repoURL)

        // Stable-ish status material: summary diff between base and @
        let summaryText = try await jjDiffSummary(from: normalizedBase, to: "@", repoURL: repoURL, paths: nil)
        var data = Data(summaryText.utf8)
        data.append(Data(normalizedBase.utf8))

        let statusHashRaw = await runner.sha256Hex(data)
        let statusHash = "jj:" + statusHashRaw

        return GitDiffFingerprint(
            headSHA: headID,
            baseRef: normalizedBase,
            statusHash: statusHash,
            generatedAt: Date()
        )
    }

    // MARK: - Diff Operations

    public func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> [VCSUncommittedFile] {
        // jj has no untracked concept; ignore includeUntrackedWhenApplicable.
        // jj rename detection differs; ignore detectRenames.
        let normalized = normalizeCompareSpecWithWarning(compare).spec
        let refs = try resolveDiffRefs(for: normalized, repoURL: repoURL)

        // 1) Summary for statuses (M/A/D/R/C etc)
        let summaryText = try await jjDiffSummary(from: refs.from, to: refs.to, repoURL: repoURL, paths: nil)
        var entries = parseJjDiffSummary(summaryText)

        // 2) Stat for insertions/deletions (best-effort parse)
        let statText = try await jjDiffStat(from: refs.from, to: refs.to, repoURL: repoURL, paths: nil)
        let statMap = parseJjDiffStat(statText)

        // Merge
        for i in entries.indices {
            let path = entries[i].path
            if let s = statMap[path] {
                entries[i] = VCSUncommittedFile(
                    path: path,
                    status: entries[i].status,
                    additions: s.additions,
                    deletions: s.deletions
                )
            }
        }

        // If stat parsing failed entirely, fall back to scanning a git-format diff for accurate counts.
        if !entries.isEmpty, statMap.isEmpty {
            let diffText = try await jjDiffGit(from: refs.from, to: refs.to, repoURL: repoURL, contextLines: 0, paths: nil)
            let counts = computeAddDelByFileFromUnifiedDiff(diffText)
            for i in entries.indices {
                let path = entries[i].path
                if let c = counts[path] {
                    entries[i] = VCSUncommittedFile(
                        path: path,
                        status: entries[i].status,
                        additions: c.additions,
                        deletions: c.deletions
                    )
                }
            }
        }

        return stableSortFiles(entries)
    }

    public func getDiffText(
        compare: GitDiffCompareSpec,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        // jj doesn't expose a git-style -M; ignore detectRenames.
        let normalized = normalizeCompareSpecWithWarning(compare).spec
        let refs = try resolveDiffRefs(for: normalized, repoURL: repoURL)
        return try await jjDiffGit(from: refs.from, to: refs.to, repoURL: repoURL, contextLines: contextLines, paths: paths)
    }

    public func getUntrackedDiff(
        for files: [String],
        contextLines: Int,
        at repoURL: URL
    ) async throws -> String {
        // jj doesn't have \"untracked\" in the same sense; return empty diff.
        ""
    }

    // MARK: - Log Operations

    public func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String {
        // Default jj log includes a graph; keep it.
        let lim = max(1, maxLines)
        let out = try await runner.runOrThrow(["log", "--color=never", "--limit", "\(lim)"], at: repoURL)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func getLogSummaries(
        count: Int,
        path: String?,
        at repoURL: URL
    ) async throws -> [VCSCommitSummary] {
        let lim = max(1, count)

        // Template-first: emit one line per commit with stable delimiters.
        // NOTE: jj template language may vary across versions; fall back if this fails.
        let template = [
            "commit_id",
            "\"\\t\"",
            "commit_id.short()",
            "\"\\t\"",
            "author.email()",
            "\"\\t\"",
            "committer.timestamp()",
            "\"\\t\"",
            "description.first_line()",
            "\"\\n\""
        ].joined(separator: " ++ ")

        var args: [String] = ["log", "--no-graph", "--color=never", "--limit", "\(lim)", "-T", template]
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append("--")
            args.append(path)
        }

        let (stdout, _, exit) = try await runner.run(args, at: repoURL)
        let lines: [String]
        if exit == 0 {
            lines = stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        } else {
            // Fallback to non-templated log; best-effort parse commit ids and messages.
            let fallback = try await runner.runOrThrow(["log", "--no-graph", "--color=never", "--limit", "\(lim)"], at: repoURL)
            lines = fallback.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }

        var summaries: [VCSCommitSummary] = []
        summaries.reserveCapacity(lines.count)

        for line in lines {
            if let parsed = parseLogLineFromTemplate(line) {
                // Wrap stats retrieval in try/catch so one bad commit doesn't fail the entire log
                let stats: (filesChanged: Int, insertions: Int, deletions: Int)
                do {
                    stats = try await showStatsForCommit(id: parsed.id, repoURL: repoURL)
                } catch {
                    // Degrade gracefully - return commit info with zeroed stats
                    stats = (filesChanged: 0, insertions: 0, deletions: 0)
                }
                summaries.append(VCSCommitSummary(
                    id: parsed.id,
                    shortID: parsed.shortID,
                    author: parsed.author,
                    dateISO: parsed.dateISO,
                    message: parsed.message,
                    filesChanged: stats.filesChanged,
                    insertions: stats.insertions,
                    deletions: stats.deletions
                ))
            } else if let id = firstHexLikeToken(in: line) {
                let shortID = String(id.prefix(12))
                // Wrap stats retrieval in try/catch so one bad commit doesn't fail the entire log
                let stats: (filesChanged: Int, insertions: Int, deletions: Int)
                do {
                    stats = try await showStatsForCommit(id: id, repoURL: repoURL)
                } catch {
                    // Degrade gracefully - return commit info with zeroed stats
                    stats = (filesChanged: 0, insertions: 0, deletions: 0)
                }
                summaries.append(VCSCommitSummary(
                    id: id,
                    shortID: shortID,
                    author: "",
                    dateISO: "",
                    message: line,
                    filesChanged: stats.filesChanged,
                    insertions: stats.insertions,
                    deletions: stats.deletions
                ))
            }
        }

        return summaries
    }

    public func commitInfo(ref: String, at repoURL: URL) async throws -> VCSCommitInfo {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VCSError.parseError(message: "Empty ref") }

        // Template-first, single record.
        let template = [
            "commit_id",
            "\"\\t\"",
            "commit_id.short()",
            "\"\\t\"",
            "author.email()",
            "\"\\t\"",
            "committer.timestamp()",
            "\"\\t\"",
            "description",
            "\"\\n\""
        ].joined(separator: " ++ ")

        let (stdout, _, exit) = try await runner.run(
            ["log", "-r", trimmed, "--no-graph", "--color=never", "-T", template],
            at: repoURL
        )

        if exit == 0 {
            let s = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parts = splitTabFields(s, expectedAtLeast: 5) {
                return VCSCommitInfo(
                    id: parts[0],
                    shortID: parts[1],
                    author: parts[2],
                    dateISO: parts[3],
                    message: parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        // Fallback: `jj show --no-patch` and best-effort parsing.
        let showText = try await runner.runOrThrow(["show", "--color=never", "--no-patch", trimmed], at: repoURL)
        let id = firstHexLikeToken(in: showText) ?? trimmed
        let shortID = String(id.prefix(12))
        let message = extractFirstNonEmptyLine(afterAnyOf: ["description:", "message:"], in: showText) ?? ""
        return VCSCommitInfo(
            id: id,
            shortID: shortID,
            author: "",
            dateISO: "",
            message: message
        )
    }

    // MARK: - Blame Operations

    public func blame(
        path: String,
        lineRange: ClosedRange<Int>?,
        at repoURL: URL
    ) async throws -> [VCSBlameLine] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VCSError.parseError(message: "Empty path") }

        // jj: `jj file annotate <path>`
        let text = try await runner.runOrThrow(["file", "annotate", "--color=never", "--", trimmed], at: repoURL)
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var results: [VCSBlameLine] = []
        results.reserveCapacity(rawLines.count)

        var lineNum = 0
        for raw in rawLines {
            lineNum += 1

            // Apply optional line range after we number lines.
            if let range = lineRange, !range.contains(lineNum) {
                continue
            }

            let parsed = parseAnnotateLine(raw)
            results.append(VCSBlameLine(
                line: lineNum,
                id: parsed.id,
                author: parsed.author,
                dateISO: parsed.dateISO,
                content: parsed.content
            ))
        }

        return results
    }

    // MARK: - Helpers: Resolve compare to jj diff refs

    private struct ResolvedRefs {
        let from: String
        let to: String
    }

    private func resolveDiffRefs(for compare: GitDiffCompareSpec, repoURL: URL) throws -> ResolvedRefs {
        switch compare {
        case let .uncommitted(base), let .uncommittedMergeBase(base), let .staged(base), let .stagedMergeBase(base):
            let from = normalizeBaseRef(base)
            return ResolvedRefs(from: from, to: "@")

        case .unstaged:
            // Should have been normalized by normalizeCompareSpecWithWarning, but be defensive.
            let from = normalizeBaseRef("HEAD")
            return ResolvedRefs(from: from, to: "@")

        case let .revspec(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw VCSError.parseError(message: "Empty revspec")
            }

            // Handle common git-isms we generate elsewhere:
            // - "<sha>^!" means parent..sha
            if trimmed.hasSuffix("^!") {
                let sha = String(trimmed.dropLast(2))
                let normalized = normalizeBaseRef(sha)
                // Use explicit parents() revset syntax instead of "sha-" shorthand
                // to avoid parsing ambiguities with arbitrary commit IDs
                let from = parentRevsetExpr(for: normalized)
                return ResolvedRefs(from: from, to: normalized)
            }

            // Handle three-dot ranges: A...B (degrade to A..B for jj)
            if let range = parseThreeDotRange(trimmed) {
                return ResolvedRefs(from: range.from, to: range.to)
            }

            // Handle simple ranges: A..B
            if let range = parseTwoDotRange(trimmed) {
                return ResolvedRefs(from: range.from, to: range.to)
            }

            // Fallback: treat as "diff from <ref> to @".
            return ResolvedRefs(from: normalizeBaseRef(trimmed), to: "@")
        }
    }

    private func parseTwoDotRange(_ raw: String) -> (from: String, to: String)? {
        // Accept "A..B" (first occurrence)
        guard let r = raw.range(of: ".."), !raw.contains("...") else { return nil }
        let left = raw[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = raw[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let from = left.isEmpty ? "@-" : normalizeBaseRef(left)
        let to = right.isEmpty ? "@" : normalizeBaseRef(right)
        return (from: from, to: to)
    }

    private func parseThreeDotRange(_ raw: String) -> (from: String, to: String)? {
        // Accept "A...B" - in git this means merge-base(A,B)..B
        // jj doesn't have merge-base in the same way; degrade to A..B and warn
        guard let r = raw.range(of: "...") else { return nil }
        let left = raw[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = raw[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let from = left.isEmpty ? "@-" : normalizeBaseRef(left)
        let to = right.isEmpty ? "@" : normalizeBaseRef(right)
        return (from: from, to: to)
    }

    // MARK: - Helpers: jj commands

    private func jjDiffSummary(from: String, to: String, repoURL: URL, paths: [String]?) async throws -> String {
        var args = ["diff", "--summary", "--color=never", "--from", from, "--to", to]
        appendPaths(&args, paths: paths)
        return try await runner.runOrThrow(args, at: repoURL)
    }

    private func jjDiffStat(from: String, to: String, repoURL: URL, paths: [String]?) async throws -> String {
        var args = ["diff", "--stat", "--color=never", "--from", from, "--to", to]
        appendPaths(&args, paths: paths)
        return try await runner.runOrThrow(args, at: repoURL)
    }

    private func jjDiffGit(from: String, to: String, repoURL: URL, contextLines: Int, paths: [String]?) async throws -> String {
        var args: [String] = [
            "diff",
            "--git",
            "--color=never",
            "--from", from,
            "--to", to
        ]
        if contextLines >= 0 {
            args.append(contentsOf: ["--context", "\(contextLines)"])
        }
        appendPaths(&args, paths: paths)
        return try await runner.runOrThrow(args, at: repoURL)
    }

    private func appendPaths(_ args: inout [String], paths: [String]?) {
        guard let paths, !paths.isEmpty else { return }
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        args.append("--")
        args.append(contentsOf: cleaned)
    }

    private enum BookmarkListMode: Hashable {
        case all
        case tracked
    }

    private struct BookmarkListKey: Hashable {
        let repoPath: String
        let mode: BookmarkListMode
    }

    private struct BookmarkListResult {
        let names: [String]
        let isCacheable: Bool
    }

    private struct BookmarkSnapshot {
        let all: [String]
        let current: [String]
    }

    private struct TimedCache<Value> {
        let value: Value
        let expiresAt: Date

        var isValid: Bool {
            Date() < expiresAt
        }
    }

    private func standardizedRepoPath(_ repoURL: URL) -> String {
        repoURL.standardizedFileURL.path
    }

    private func listBookmarks(repoURL: URL, mode: BookmarkListMode) async throws -> [String] {
        let key = BookmarkListKey(repoPath: standardizedRepoPath(repoURL), mode: mode)
        let cacheGeneration = bookmarkCacheGenerations[key.repoPath] ?? 0
        if let cached = bookmarkListCache[key], cached.isValid {
            return cached.value
        }
        if let task = bookmarkListTasks[key] {
            return try await task.value.names
        }

        let task = Task { [runner] in
            var args = ["bookmark", "list", "--color=never"]
            switch mode {
            case .all:
                args.append("--all")
            case .tracked:
                args.append("--tracked")
            }
            let (stdout, _, exit) = try await runner.run(args, at: repoURL)
            guard exit == 0 else {
                // Treat as non-fatal: older jj may not support some flags.
                return BookmarkListResult(names: [], isCacheable: false)
            }
            return BookmarkListResult(names: Self.parseBookmarkList(stdout), isCacheable: true)
        }
        bookmarkListTasks[key] = task
        defer { bookmarkListTasks.removeValue(forKey: key) }

        let result = try await task.value
        if result.isCacheable, cacheGeneration == (bookmarkCacheGenerations[key.repoPath] ?? 0) {
            bookmarkListCache[key] = TimedCache(
                value: result.names,
                expiresAt: Date().addingTimeInterval(bookmarkCacheTTL)
            )
        }
        return result.names
    }

    private nonisolated static func parseBookmarkList(_ output: String) -> [String] {
        // Best-effort parsing:
        // - jj bookmark list commonly prints one bookmark per line, name at the start.
        // - Example-like: "main: <commit>" or "main <commit>" (varies)
        var results: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // Name is before ":" if present, otherwise first whitespace token.
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { results.append(String(name)) }
            } else {
                let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if let first = parts.first, !first.isEmpty { results.append(first) }
            }
        }
        return Array(Set(results)).sorted()
    }

    private func bookmarkSnapshot(repoURL: URL) async throws -> BookmarkSnapshot {
        let key = standardizedRepoPath(repoURL)
        let cacheGeneration = bookmarkCacheGenerations[key] ?? 0
        if let cached = bookmarkSnapshotCache[key], cached.isValid {
            return cached.value
        }
        if let task = bookmarkSnapshotTasks[key] {
            return try await task.value
        }

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let bookmarks = try await listBookmarks(repoURL: repoURL, mode: .all)
            let current = try await currentBookmarksPointingAtAt(repoURL: repoURL, bookmarks: bookmarks)
            return BookmarkSnapshot(all: bookmarks, current: current)
        }
        bookmarkSnapshotTasks[key] = task
        defer { bookmarkSnapshotTasks.removeValue(forKey: key) }

        let snapshot = try await task.value
        if cacheGeneration == (bookmarkCacheGenerations[key] ?? 0) {
            bookmarkSnapshotCache[key] = TimedCache(
                value: snapshot,
                expiresAt: Date().addingTimeInterval(bookmarkCacheTTL)
            )
        }
        return snapshot
    }

    private func currentBookmarksPointingAtAt(repoURL: URL, bookmarks: [String]) async throws -> [String] {
        // Best-effort approach:
        // - Filter all bookmarks to those whose target commit_id equals @'s commit_id.
        // This is potentially expensive; keep it lightweight by limiting to first N bookmarks.
        guard !bookmarks.isEmpty else { return [] }
        let atID = try await getHeadID(at: repoURL)

        // Avoid unbounded calls; check up to 50 bookmarks.
        let cap = min(50, bookmarks.count)
        var matches: [String] = []
        matches.reserveCapacity(4)

        for name in bookmarks.prefix(cap) {
            if Task.isCancelled { break }
            let id = try? await getRefID(ref: name, at: repoURL)
            if id == atID {
                matches.append(name)
            }
        }
        return matches
    }

    private func invalidateBookmarkCaches(for repoURL: URL) {
        let repoPath = standardizedRepoPath(repoURL)
        bookmarkCacheGenerations[repoPath, default: 0] &+= 1
        bookmarkListTasks = bookmarkListTasks.filter { $0.key.repoPath != repoPath }
        bookmarkListCache = bookmarkListCache.filter { $0.key.repoPath != repoPath }
        bookmarkSnapshotTasks.removeValue(forKey: repoPath)
        bookmarkSnapshotCache.removeValue(forKey: repoPath)
    }

    private func withBookmarkCachesBypassed<T>(for repoURL: URL, operation: () async throws -> T) async throws -> T {
        invalidateBookmarkCaches(for: repoURL)
        defer { invalidateBookmarkCaches(for: repoURL) }
        return try await operation()
    }

    // MARK: - Parsers: diff summary/stat

    private func parseJjDiffSummary(_ output: String) -> [VCSUncommittedFile] {
        // Expected-ish forms (varies by jj version):
        // - "M path/to/file"
        // - "A path/to/file"
        // - "D path/to/file"
        // - "R old -> new" or "R old => new" (we take the new path)
        var results: [VCSUncommittedFile] = []

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let first = line.prefix(2)
            if first.count >= 1 {
                let statusChar = first.first!
                let status = String(statusChar)
                if ["M", "A", "D", "R", "C", "U", "?", "!"].contains(status) {
                    var remainder = line.dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Common rename/copy format includes arrows
                    if let arrow = remainder.range(of: "->") ?? remainder.range(of: "=>") {
                        let after = remainder[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                        remainder = after
                    }
                    let path = remainder
                    if !path.isEmpty {
                        results.append(VCSUncommittedFile(path: path, status: status, additions: nil, deletions: nil))
                    }
                    continue
                }
            }

            // Fallback: try "Modified: path" / "Added: path"
            if let (status, path) = parseLabeledSummaryLine(line) {
                results.append(VCSUncommittedFile(path: path, status: status, additions: nil, deletions: nil))
            }
        }

        // De-dupe by path (prefer first status encountered)
        var seen = Set<String>()
        var deduped: [VCSUncommittedFile] = []
        for r in results {
            if seen.insert(r.path).inserted {
                deduped.append(r)
            }
        }
        return stableSortFiles(deduped)
    }

    private func parseLabeledSummaryLine(_ line: String) -> (status: String, path: String)? {
        // Handle labels like:
        // "Modified: foo"
        // "Added: foo"
        // "Removed: foo"
        let lowered = line.lowercased()
        let mapping: [(prefix: String, status: String)] = [
            ("modified:", "M"),
            ("added:", "A"),
            ("removed:", "D"),
            ("deleted:", "D"),
            ("renamed:", "R"),
            ("copied:", "C")
        ]
        for m in mapping {
            if lowered.hasPrefix(m.prefix) {
                let path = line.dropFirst(m.prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return (m.status, path)
                }
            }
        }
        return nil
    }

    private func parseJjDiffStat(_ output: String) -> [String: (additions: Int, deletions: Int)] {
        // Best-effort parsing for a \"git --stat\"-like format:
        // "path/to/file | 12 +++++-----"
        // If jj uses a different stat output, this may yield empty.
        var map: [String: (additions: Int, deletions: Int)] = [:]

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard line.contains("|") else { continue }
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }

            let path = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = parts[1]
            guard !path.isEmpty else { continue }

            // Prefer explicit \"X insertions, Y deletions\" if present
            if let summary = parseInsertionDeletionSummary(rhs) {
                map[path] = (summary.insertions, summary.deletions)
                continue
            }

            // Otherwise count + and - glyphs (may be scaled, but better than nothing)
            let additions = rhs.count(where: { $0 == "+" })
            let deletions = rhs.count(where: { $0 == "-" })
            if additions > 0 || deletions > 0 {
                map[path] = (additions, deletions)
            }
        }

        return map
    }

    private func parseInsertionDeletionSummary(_ text: String) -> (insertions: Int, deletions: Int)? {
        // Try to parse patterns like:
        // "12 insertions(+), 3 deletions(-)"
        let s = text.lowercased()
        let insertions = extractInt(before: "insertion", in: s) ?? extractInt(before: "insertions", in: s)
        let deletions = extractInt(before: "deletion", in: s) ?? extractInt(before: "deletions", in: s)
        if let insertions, let deletions {
            return (insertions, deletions)
        }
        return nil
    }

    private func extractInt(before needle: String, in haystack: String) -> Int? {
        guard let r = haystack.range(of: needle) else { return nil }
        let prefix = haystack[..<r.lowerBound]
        // scan backwards for a number
        var digits = ""
        for ch in prefix.reversed() {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        guard !digits.isEmpty else { return nil }
        return Int(String(digits.reversed()))
    }

    // MARK: - Parsers: unified diff add/del counts

    private func computeAddDelByFileFromUnifiedDiff(_ diff: String) -> [String: (additions: Int, deletions: Int)] {
        var map: [String: (additions: Int, deletions: Int)] = [:]
        for (path, patchText) in GitService.splitUnifiedDiffByFile(diff) {
            var additions = 0
            var deletions = 0
            for line in patchText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") {
                    additions += 1
                } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                    deletions += 1
                }
            }
            map[path] = (additions, deletions)
        }
        return map
    }

    // MARK: - Parsers: log line

    private func parseLogLineFromTemplate(_ line: String) -> (id: String, shortID: String, author: String, dateISO: String, message: String)? {
        guard let parts = splitTabFields(line, expectedAtLeast: 5) else { return nil }
        return (parts[0], parts[1], parts[2], parts[3], parts[4])
    }

    private func splitTabFields(_ s: String, expectedAtLeast: Int) -> [String]? {
        let parts = s.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= expectedAtLeast else { return nil }
        return parts
    }

    // MARK: - Parsers: annotate

    private func parseAnnotateLine(_ line: String) -> (id: String, author: String, dateISO: String, content: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("", "", "", "")
        }

        // Expected-ish: "<id> (<author> <date> ...) <content>"
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count == 2 {
            let idToken = parts[0]
            let rest = parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                let meta = rest[rest.index(after: rest.startIndex) ..< close]
                let after = String(rest[rest.index(after: close)...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let metaParsed = parseAnnotateMeta(String(meta))
                return (idToken, metaParsed.author, metaParsed.dateISO, after)
            }
            return (idToken, "", "", rest)
        }

        // Fallback: no id parse
        return ("", "", "", trimmed)
    }

    private func parseAnnotateMeta(_ meta: String) -> (author: String, dateISO: String) {
        // Try to locate a YYYY-MM-DD substring as date.
        // Everything before it becomes author (best-effort).
        let pattern = #"(\\d{4}-\\d{2}-\\d{2}(?:[ T]\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:?\\d{2})?)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = meta as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: meta, options: [], range: range) {
                let date = ns.substring(with: match.range(at: 1))
                let authorPart = ns.substring(with: NSRange(location: 0, length: match.range.location))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (authorPart, date)
            }
        }
        return (meta.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - Helpers: stats via jj show

    private func showStatsForCommit(id: String, repoURL: URL) async throws -> (filesChanged: Int, insertions: Int, deletions: Int) {
        // Prefer `jj show --stat` and parse its output.
        let (stdout, _, exit) = try await runner.run(["show", "--color=never", "--stat", "--no-patch", id], at: repoURL)
        if exit == 0 {
            if let summary = parseShowStat(stdout) {
                return summary
            }
        }

        // Fallback: compute from git-format diff between commit parent and commit.
        // Use explicit parents() revset syntax instead of "id-" shorthand to avoid
        // parsing ambiguities with arbitrary commit IDs.
        let parentRef = parentRevsetExpr(for: id)
        let diff = try await jjDiffGit(from: parentRef, to: id, repoURL: repoURL, contextLines: 0, paths: nil)
        let byFile = computeAddDelByFileFromUnifiedDiff(diff)
        var insertions = 0
        var deletions = 0
        for v in byFile.values {
            insertions += v.additions
            deletions += v.deletions
        }
        return (filesChanged: byFile.keys.count, insertions: insertions, deletions: deletions)
    }

    private func parseShowStat(_ output: String) -> (filesChanged: Int, insertions: Int, deletions: Int)? {
        // Best-effort: look for a summary line containing \"files\" and \"insertions\"/\"deletions\".
        // If absent, count \"|\" lines as filesChanged.
        let lowered = output.lowercased()

        let filesChanged = extractInt(before: "file", in: lowered)
            ?? extractInt(before: "files", in: lowered)
            ?? output.split(separator: "\n", omittingEmptySubsequences: true).count(where: { $0.contains("|") })

        let insertions = extractInt(before: "insertion", in: lowered)
            ?? extractInt(before: "insertions", in: lowered)
            ?? 0

        let deletions = extractInt(before: "deletion", in: lowered)
            ?? extractInt(before: "deletions", in: lowered)
            ?? 0

        if filesChanged > 0 || insertions > 0 || deletions > 0 {
            return (filesChanged, insertions, deletions)
        }
        return nil
    }

    // MARK: - Helpers: template-safe single value

    private func templateSingleValue(args: [String], at repoURL: URL) async throws -> String? {
        let (stdout, _, exit) = try await runner.run(args, at: repoURL)
        guard exit == 0 else { return nil }
        let s = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - Helpers: misc parsing

    private func firstHexLikeToken(in text: String) -> String? {
        // Find first token that resembles a commit id (hex).
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "," || $0 == ":" }).map(String.init)
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 6, t.count <= 64, t.allSatisfy(\.isHexDigit) {
                return t
            }
        }
        return nil
    }

    private func extractFirstNonEmptyLine(afterAnyOf markers: [String], in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let loweredMarkers = Set(markers.map { $0.lowercased() })
        var capture = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if loweredMarkers.contains(trimmed.lowercased()) {
                capture = true
                continue
            }
            if capture {
                return trimmed
            }
        }
        return nil
    }

    private func stableSortFiles(_ files: [VCSUncommittedFile]) -> [VCSUncommittedFile] {
        let keyed = files.map { f in
            (lower: f.path.lowercased(), original: f.path, file: f)
        }
        return keyed.sorted { a, b in
            if a.lower != b.lower { return a.lower < b.lower }
            return a.original < b.original
        }.map(\.file)
    }
}
