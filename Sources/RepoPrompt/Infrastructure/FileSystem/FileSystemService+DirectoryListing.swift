import Foundation
import RepoPromptCore
import RepoPromptCoreMacOS

extension FileSystemService {
    typealias DirEntry = RepoPromptCore.WorkspaceDirectoryEntry
    typealias DirectoryScanResult = RepoPromptCore.WorkspaceDirectoryScanResult
    typealias DirID = RepoPromptCore.WorkspaceDirectoryIdentity

    static let universalIgnoreDirs: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".npm", ".pnpm-store", ".yarn", ".cache", "bower_components",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".venv", "venv",
        ".gradle", ".m2", ".idea",
        ".nuget",
        ".cargo",
        ".ccache", "gch",
        ".bundle", ".gem"
    ]

    #if DEBUG
        static func listDirectoryWithIgnoreDetection(
            _ path: String,
            fm: any FileSystemProviding
        ) throws -> DirectoryScanResult {
            if fm is FileManager {
                return try listDirectoryWithIgnoreDetection(path)
            }

            let children = try fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            var entries: [DirEntry] = []
            var hasGitignore = false
            var hasRepoIgnore = false
            var hasCursorignore = false

            for url in children {
                let name = url.lastPathComponent
                guard name != ".", name != "..", !isRepoPromptTempFilename(name) else { continue }
                switch name {
                case ".gitignore": hasGitignore = true
                case ".repo_ignore": hasRepoIgnore = true
                case ".cursorignore": hasCursorignore = true
                default: break
                }

                var isDirectory: ObjCBool = false
                _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let isSymbolicLink =
                    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                        ?? false
                entries.append(
                    DirEntry(
                        name: name,
                        isDir: isDirectory.boolValue,
                        isSym: isSymbolicLink
                    )
                )
            }

            return DirectoryScanResult(
                entries: entries,
                hasGitignore: hasGitignore,
                hasRepoIgnore: hasRepoIgnore,
                hasCursorignore: hasCursorignore
            )
        }
    #endif

    @inline(__always)
    static func isRepoPromptTempFilename(_ name: String) -> Bool {
        name.hasPrefix(".repoprompt.tmp.")
    }

    static func listDirectoryWithIgnoreDetection(
        _ path: String
    ) throws -> DirectoryScanResult {
        try MacOSWorkspaceDirectoryAccess().listDirectoryWithIgnoreDetection(at: path)
    }

    @inline(__always)
    static func dirID(followingSymlinksAtPath path: String) -> DirID? {
        MacOSWorkspaceDirectoryAccess().directoryIdentity(followingSymlinksAt: path)
    }

    @inline(__always)
    static func realpathString(_ path: String) -> String? {
        MacOSWorkspaceDirectoryAccess().canonicalPath(for: path)
    }
}
