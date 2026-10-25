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

/// A binding fence, not a new read-root grant. Callers must authorize the layout first.
/// Git's native discovery probe supplies the ownership/safe.directory decision; data
/// commands retain explicit metadata binding. Revalidate immediately before each spawn.
/// This does not make filesystem checks atomic against same-user metadata replacement.
package struct GitReadRepositoryBinding {
    package let layout: GitRepositoryLayout
    private let canonicalPaths: [String]
    private let metadataIdentities: [String]
    private let gitDirectoryIdentity: String
    private let metadataContents: [Data?]
    private let discoveryCeiling: String

    package init(layout: GitRepositoryLayout) throws {
        self.layout = layout
        canonicalPaths = Self.paths(layout)
        discoveryCeiling = URL(fileURLWithPath: canonicalPaths[0]).deletingLastPathComponent().path
        guard !discoveryCeiling.contains(":") else { throw BindingError.unsupportedCeilingPath }
        metadataIdentities = try Self.identities(layout)
        gitDirectoryIdentity = try Self.identity(URL(fileURLWithPath: canonicalPaths[2]))
        metadataContents = try Self.contents(layout, capturedPaths: canonicalPaths)
        try revalidate()
    }

    package var ownershipProbeArguments: [String] {
        ["-C", layout.workTreeRoot.path, "rev-parse", "--absolute-git-dir"]
    }

    package func ownershipProbeEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = Self.discoveryEnvironment(environment)
        // Git must not enter an enclosing repo even when .git is an invalid directory.
        // A ceiling equal to the current directory is ignored by Git; use its parent.
        result["GIT_CEILING_DIRECTORIES"] = discoveryCeiling
        return result
    }

    package func boundArguments(_ command: [String]) -> [String] {
        [
            "-C",
            layout.workTreeRoot.path,
            "--git-dir",
            layout.gitDir.path,
            "--work-tree",
            layout.workTreeRoot.path
        ] + command
    }

    package static func discoveryEnvironment(_ environment: [String: String]) -> [String: String] {
        let selectors: Set = [
            "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
            "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"
        ]
        var result = environment.filter { !selectors.contains($0.key) }
        result["GIT_OPTIONAL_LOCKS"] = "0"
        result["GIT_TERMINAL_PROMPT"] = "0"
        return result
    }

    package func revalidate() throws {
        // Exact-root resolution never adopts an enclosing repository. Including the
        // captured metadata roots here checks the binding, not workspace authority.
        // Fence pointer-file reads against the captured authority before resolving
        // their contents. A changed symlink must not expand that authority.
        guard Self.paths(layout) == canonicalPaths,
              try Self.identities(layout) == metadataIdentities,
              try Self.contents(layout, capturedPaths: canonicalPaths) == metadataContents,
              let current = GitRepositoryLayoutResolver.resolveForRead(
                  atWorkTreeRoot: layout.workTreeRoot,
                  authorizedRoots: [layout.workTreeRoot, layout.gitDir, layout.commonDir]
              ), Self.paths(current) == canonicalPaths,
              current.isWorktree == layout.isWorktree,
              try Self.identities(current) == metadataIdentities,
              try Self.contents(current, capturedPaths: canonicalPaths) == metadataContents
        else { throw BindingError.changedMetadata }
    }

    package func validateOwnershipProbe(_ output: String) throws {
        let path = String(output.dropLast())
        guard output.hasSuffix("\n"), path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
              // Git may report on-disk casing while the captured URL retains user casing.
              // Compare filesystem identity, not lowercased spellings that can alias
              // different directories on a case-sensitive volume.
              try Self.identity(URL(fileURLWithPath: path).resolvingSymlinksInPath()) == gitDirectoryIdentity
        else { throw BindingError.changedMetadata }
        try revalidate()
    }

    private static func paths(_ layout: GitRepositoryLayout) -> [String] {
        [layout.workTreeRoot, layout.dotGitPath, layout.gitDir, layout.commonDir]
            .map { canonicalPath($0) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func identities(_ layout: GitRepositoryLayout) throws -> [String] {
        try [layout.workTreeRoot, layout.dotGitPath, layout.gitDir, layout.commonDir].map(identity)
    }

    private static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw BindingError.changedMetadata }
        return "\(device):\(inode)"
    }

    private static func contents(_ layout: GitRepositoryLayout, capturedPaths: [String]) throws -> [Data?] {
        let metadataRoots = [capturedPaths[2], capturedPaths[3]]
        // Append optional pointer names after resolving the captured directory.
        // Foundation may leave an entire path unresolved when its leaf is absent,
        // even if an existing parent (.git) is a symlink within the authority.
        let gitDirectory = URL(fileURLWithPath: capturedPaths[2])
        var files: [(URL, [String])] = [(gitDirectory.appendingPathComponent("commondir"), metadataRoots)]
        // A normal checkout or separate-git-dir has no reciprocal backpointer.
        if layout.isWorktree, layout.isLinkedWorktree {
            files.append((gitDirectory.appendingPathComponent("gitdir"), metadataRoots))
        }
        if layout.isWorktree { files.append((layout.dotGitPath, [capturedPaths[1]])) }
        return try files.map { url, roots in
            let target = canonicalPath(url)
            guard roots.contains(where: { target == $0 || target.hasPrefix($0 + "/") })
            else { throw BindingError.changedMetadata }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try VCSMetadataFileReader.contents(of: url)
        }
    }

    private enum BindingError: LocalizedError {
        case changedMetadata
        case unsupportedCeilingPath

        var errorDescription: String? {
            switch self {
            case .changedMetadata:
                "Repository metadata changed or is not valid at the requested Git read root."
            case .unsupportedCeilingPath:
                "Git reads cannot safely probe a repository whose canonical parent path contains ':'."
            }
        }
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
                commonDir: readMetadataPath(at: dotGitPath.appendingPathComponent("commondir"), relativeTo: dotGitPath) ?? dotGitPath,
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
        guard isMetadataFileWithinRoots(root, roots: authorizedRoots) else { return nil }
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard isMetadataFileWithinRoots(dotGit, roots: authorizedRoots) else { return nil }
            let commonFile = dotGit.appendingPathComponent("commondir")
            if FileManager.default.fileExists(atPath: commonFile.path) {
                guard isMetadataFileWithinRoots(commonFile, roots: authorizedRoots),
                      let commonDir = readMetadataPath(at: commonFile, relativeTo: dotGit),
                      isMetadataFileWithinRoots(commonDir, roots: authorizedRoots)
                else { return nil }
            }
            return resolve(atWorkTreeRoot: root)
        }
        guard isMetadataFileWithinRoots(dotGit, roots: authorizedRoots),
              let gitDir = parseGitFile(at: dotGit, relativeTo: root)
        else { return nil }
        var gitDirIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &gitDirIsDirectory), gitDirIsDirectory.boolValue else { return nil }

        if isMetadataFileWithinRoots(gitDir, roots: authorizedRoots) {
            let commonFile = gitDir.appendingPathComponent("commondir")
            if FileManager.default.fileExists(atPath: commonFile.path) {
                guard isMetadataFileWithinRoots(commonFile, roots: authorizedRoots),
                      let commonDir = readMetadataPath(at: commonFile, relativeTo: gitDir),
                      isMetadataFileWithinRoots(commonDir, roots: authorizedRoots)
                else { return nil }
            }
            guard let layout = resolve(atWorkTreeRoot: root),
                  isMetadataFileWithinRoots(layout.commonDir, roots: authorizedRoots)
            else { return nil }
            return layout
        }

        // A linked worktree's metadata lives at <common>/worktrees/<id>. Check the
        // backpointer before following commondir, rather than accepting any gitfile.
        let canonicalGitDir = gitDir.resolvingSymlinksInPath().standardizedFileURL
        let registrations = canonicalGitDir.deletingLastPathComponent()
        let commonRoot = registrations.deletingLastPathComponent()
        let backpointerFile = canonicalGitDir.appendingPathComponent("gitdir")
        let commonFile = canonicalGitDir.appendingPathComponent("commondir")
        guard registrations.lastPathComponent == "worktrees",
              isMetadataFileWithinRoots(backpointerFile, roots: [commonRoot]),
              isMetadataFileWithinRoots(commonFile, roots: [commonRoot]),
              let backlink = readMetadataPath(at: backpointerFile, relativeTo: canonicalGitDir),
              sameFilesystemEntry(backlink, dotGit),
              let commonDir = readMetadataPath(at: commonFile, relativeTo: canonicalGitDir),
              sameFilesystemEntry(commonDir, commonRoot)
        else { return nil }
        return GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: dotGit,
            gitDir: gitDir,
            commonDir: commonDir,
            isWorktree: true
        )
    }

    private static func sameFilesystemEntry(_ lhs: URL, _ rhs: URL) -> Bool {
        let fm = FileManager.default
        guard let left = try? fm.attributesOfItem(atPath: lhs.resolvingSymlinksInPath().path),
              let right = try? fm.attributesOfItem(atPath: rhs.resolvingSymlinksInPath().path),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let leftInode = left[.systemFileNumber] as? NSNumber,
              let rightInode = right[.systemFileNumber] as? NSNumber
        else { return false }
        return leftDevice == rightDevice && leftInode == rightInode
    }

    /// These are literal filesystem metadata paths, not user selectors. Never trim
    /// whitespace or expand '~' before checking the read authority.
    private static func isMetadataFileWithinRoots(_ file: URL, roots: [URL]) -> Bool {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    private static func readMetadataText(at url: URL) -> String? {
        guard let data = try? VCSMetadataFileReader.contents(of: url),
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

        // Without commondir, Git uses gitDir itself. Directory names cannot
        // establish linked-worktree identity (a separate git dir may live below
        // an ordinary directory named "worktrees").
        return gitDir
    }
}
