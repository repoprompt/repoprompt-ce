import Foundation

enum GitRepositoryKind: Equatable {
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

    // MARK: - Private Helpers

    /// Parse a gitfile to extract the git directory path.
    /// Gitfiles contain: "gitdir: <path>\n"
    private static func parseGitFile(at url: URL, relativeTo base: URL) -> URL? {
        // Read only the first line (gitfiles are tiny, typically < 100 bytes)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        // Read a small chunk - gitdir lines are short
        guard let data = try? handle.read(upToCount: 512),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        // Parse "gitdir: <path>"
        let prefix = "gitdir:"
        guard content.hasPrefix(prefix) else {
            return nil
        }

        var pathStr = String(content.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle newlines in case there's more content
        if let newlineIndex = pathStr.firstIndex(of: "\n") {
            pathStr = String(pathStr[..<newlineIndex])
        }

        guard !pathStr.isEmpty else {
            return nil
        }

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
        if let handle = try? FileHandle(forReadingFrom: commondirFile) {
            defer { try? handle.close() }

            if let data = try? handle.read(upToCount: 512),
               let content = String(data: data, encoding: .utf8)
            {
                let pathStr = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pathStr.isEmpty {
                    // commondir is relative to gitDir
                    if pathStr.hasPrefix("/") {
                        return URL(fileURLWithPath: pathStr).standardizedFileURL
                    } else {
                        return gitDir.appendingPathComponent(pathStr).standardizedFileURL
                    }
                }
            }
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
