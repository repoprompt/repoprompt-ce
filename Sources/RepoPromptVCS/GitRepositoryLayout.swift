import Foundation

package enum GitRepositoryKind: Equatable {
    case nonGit
    case bare
    case worktree
}

// MARK: - Git Repository Layout

/// Describes the layout of a Git repository, including worktree configurations.
///
/// Git worktrees have a `.git` file (not directory) that points to the actual git dir.
/// This struct captures both normal repos and worktree configurations.
public struct GitRepositoryLayout: Sendable, Equatable {
    /// The working tree root (the directory the user opened).
    public let workTreeRoot: URL

    /// The `.git` path (file or directory) at the worktree root.
    public let dotGitPath: URL

    /// The resolved git directory (always a directory).
    /// For normal repos: same as dotGitPath
    /// For worktrees: the resolved path from the gitfile (e.g., `.../.git/worktrees/<name>`)
    public let gitDir: URL

    /// The common directory (shared repo data).
    /// For normal repos: same as gitDir
    /// For worktrees: the main repo's `.git` directory
    public let commonDir: URL

    /// Whether this checkout uses a gitfile (`.git` is a file, not a directory).
    ///
    /// A gitfile can represent either a linked worktree or a primary checkout created with
    /// `git init --separate-git-dir`; use `isLinkedWorktree` when that distinction matters.
    public let isWorktree: Bool

    /// Whether this checkout has a per-worktree git directory distinct from the shared common directory.
    public var isLinkedWorktree: Bool {
        gitDir.standardizedFileURL.path != commonDir.standardizedFileURL.path
    }

    /// The primary checkout root when it can be established without invoking Git.
    ///
    /// Primary checkouts, including `--separate-git-dir`, are authoritative for themselves.
    /// Linked worktrees can only infer the main checkout from a conventional `<root>/.git`
    /// common directory. External common directories require structured Git metadata.
    public var knownMainWorktreeRoot: URL? {
        if !isLinkedWorktree {
            return workTreeRoot.standardizedFileURL
        }
        guard commonDir.lastPathComponent == ".git" else {
            return nil
        }
        let candidate = commonDir.deletingLastPathComponent().standardizedFileURL
        guard let candidateLayout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate),
              !candidateLayout.isLinkedWorktree,
              candidateLayout.commonDir.standardizedFileURL.path == commonDir.standardizedFileURL.path
        else {
            return nil
        }
        return candidate
    }

    package init(
        workTreeRoot: URL,
        dotGitPath: URL,
        gitDir: URL,
        commonDir: URL,
        isWorktree: Bool
    ) {
        self.workTreeRoot = workTreeRoot
        self.dotGitPath = dotGitPath
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.isWorktree = isWorktree
    }
}

// MARK: - Git Repository Layout Resolver

/// Resolves Git repository layout information efficiently.
///
/// Performance characteristics:
/// - For normal repos (`.git` is a directory): Single `stat()` call
/// - For worktrees (`.git` is a file): Reads small gitfile + optional `commondir` file
public enum GitRepositoryLayoutResolver {
    /// Resolve the Git layout for a potential worktree root.
    ///
    /// - Parameter root: The candidate worktree root directory.
    /// - Returns: The resolved layout, or nil if not a Git repository.
    public static func resolve(atWorkTreeRoot root: URL) -> GitRepositoryLayout? {
        let fm = FileManager.default
        let dotGitPath = root.appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGitPath.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            // Normal repository - .git is a directory
            return GitRepositoryLayout(
                workTreeRoot: root,
                dotGitPath: dotGitPath,
                gitDir: dotGitPath,
                commonDir: dotGitPath,
                isWorktree: false
            )
        }

        // Gitfile worktree - .git is a file containing "gitdir: <path>"
        guard let gitDir = parseGitFile(at: dotGitPath, relativeTo: root) else {
            return nil
        }

        // Resolve common dir (shared repo data)
        let commonDir = resolveCommonDir(gitDir: gitDir)

        return GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: dotGitPath,
            gitDir: gitDir,
            commonDir: commonDir,
            isWorktree: true
        )
    }

    /// Resolve metadata for a workspace-scoped read without treating discovery as authority.
    /// External metadata is permitted only for a reciprocally registered linked worktree;
    /// granting that metadata does not grant reads of the main or sibling working trees.
    package static func resolveForRead(atWorkTreeRoot root: URL, authorizedRoots: [URL]) -> GitRepositoryLayout? {
        let rootPaths = authorizedRoots.map(\.path)
        guard GitRepoRootAuthorization.isPathWithinAuthorizedRoots(root.path, roots: rootPaths) else { return nil }
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard GitRepoRootAuthorization.isPathWithinAuthorizedRoots(dotGit.path, roots: rootPaths) else { return nil }
            let commonFile = dotGit.appendingPathComponent("commondir")
            if FileManager.default.fileExists(atPath: commonFile.path) {
                guard let commonDir = readMetadataPath(at: commonFile, relativeTo: dotGit),
                      GitRepoRootAuthorization.isPathWithinAuthorizedRoots(commonDir.path, roots: rootPaths)
                else { return nil }
            }
            return resolve(atWorkTreeRoot: root)
        }
        guard GitRepoRootAuthorization.isPathWithinAuthorizedRoots(dotGit.path, roots: rootPaths),
              let gitDir = parseGitFile(at: dotGit, relativeTo: root)
        else { return nil }
        var gitDirIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &gitDirIsDirectory), gitDirIsDirectory.boolValue else { return nil }

        if GitRepoRootAuthorization.isPathWithinAuthorizedRoots(gitDir.path, roots: rootPaths) {
            let commonFile = gitDir.appendingPathComponent("commondir")
            if FileManager.default.fileExists(atPath: commonFile.path) {
                guard let commonDir = readMetadataPath(at: commonFile, relativeTo: gitDir),
                      GitRepoRootAuthorization.isPathWithinAuthorizedRoots(commonDir.path, roots: rootPaths)
                else { return nil }
            }
            guard let layout = resolve(atWorkTreeRoot: root),
                  GitRepoRootAuthorization.isPathWithinAuthorizedRoots(layout.commonDir.path, roots: rootPaths)
            else { return nil }
            return layout
        }

        // A linked worktree's metadata lives at <common>/worktrees/<id>. Check the
        // backpointer before following commondir, rather than accepting any gitfile.
        let canonicalGitDir = gitDir.resolvingSymlinksInPath().standardizedFileURL
        let registrations = canonicalGitDir.deletingLastPathComponent()
        guard registrations.lastPathComponent == "worktrees",
              let backlink = readMetadataPath(at: canonicalGitDir.appendingPathComponent("gitdir"), relativeTo: canonicalGitDir),
              GitRepoRootAuthorization.canonicalPath(backlink.path) == GitRepoRootAuthorization.canonicalPath(dotGit.path),
              let commonDir = readMetadataPath(at: canonicalGitDir.appendingPathComponent("commondir"), relativeTo: canonicalGitDir),
              GitRepoRootAuthorization.canonicalPath(commonDir.path) == GitRepoRootAuthorization.canonicalPath(registrations.deletingLastPathComponent().path)
        else { return nil }
        return GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: dotGit,
            gitDir: gitDir,
            commonDir: commonDir,
            isWorktree: true
        )
    }

    private static func readMetadataText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let content = String(data: data, encoding: .utf8)
        else { return nil }
        var text = content
        while text.last == "\r" || text.last == "\n" {
            text.removeLast()
        }
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\r"), !text.contains("\0") else { return nil }
        return text
    }

    private static func readMetadataPath(at url: URL, relativeTo base: URL) -> URL? {
        guard let path = readMetadataText(at: url) else { return nil }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }

    // MARK: - Private Helpers

    /// Parse a gitfile to extract the git directory path.
    /// Gitfiles contain: "gitdir: <path>\n"
    private static func parseGitFile(at url: URL, relativeTo base: URL) -> URL? {
        // Refuse truncated or ambiguous metadata rather than authorizing a prefix
        // that Git would interpret as a different path. Preserve path whitespace.
        let prefix = "gitdir: "
        guard let content = readMetadataText(at: url), content.hasPrefix(prefix) else { return nil }
        let pathStr = String(content.dropFirst(prefix.count))
        guard !pathStr.isEmpty else { return nil }

        // Resolve relative paths against the worktree root
        let gitDirURL: URL = if pathStr.hasPrefix("/") {
            URL(fileURLWithPath: pathStr)
        } else {
            base.appendingPathComponent(pathStr)
        }

        return gitDirURL.standardizedFileURL
    }

    /// Resolve the common directory for a worktree's git dir.
    /// The common dir is where shared repo data lives (objects, refs, etc.).
    private static func resolveCommonDir(gitDir: URL) -> URL {
        // Try reading the `commondir` file first (most reliable)
        let commondirFile = gitDir.appendingPathComponent("commondir")
        if let commonDir = readMetadataPath(at: commondirFile, relativeTo: gitDir) {
            return commonDir
        }

        // Fallback heuristic: if gitDir looks like `.git/worktrees/<name>`,
        // common dir is `.git`
        let gitDirPath = gitDir.path
        if gitDirPath.contains("/worktrees/") {
            // Walk up to find .git (the parent of worktrees/)
            var current = gitDir
            while current.lastPathComponent != "worktrees", current.path != "/" {
                current = current.deletingLastPathComponent()
            }
            if current.lastPathComponent == "worktrees" {
                return current.deletingLastPathComponent().standardizedFileURL
            }
        }

        // If we can't determine common dir, use gitDir itself
        return gitDir
    }
}
