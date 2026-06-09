import Foundation

package extension FileSystemService {
    func listDirectoryForCurrentFilesystem(_ path: String) throws -> WorkspaceDirectoryScanResult {
        #if DEBUG
            if let override = fileManagerOverride, !(override is FileManager) {
                return try Self.listDirectory(path, using: override)
            }
        #endif
        return try directoryListingBackend.listDirectoryWithIgnoreDetection(at: path)
    }
}

#if DEBUG
    extension FileSystemService {
        nonisolated static func listDirectory(
            _ path: String,
            using fileSystem: any FileSystemProviding
        ) throws -> WorkspaceDirectoryScanResult {
            let children = try fileSystem.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            var entries: [WorkspaceDirectoryEntry] = []
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
                var isDirectory = ObjCBool(false)
                _ = fileSystem.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let isSymbolicLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                entries.append(WorkspaceDirectoryEntry(
                    name: name,
                    isDirectory: isDirectory.boolValue,
                    isSymbolicLink: isSymbolicLink
                ))
            }
            return WorkspaceDirectoryScanResult(
                entries: entries,
                hasGitignore: hasGitignore,
                hasRepoIgnore: hasRepoIgnore,
                hasCursorignore: hasCursorignore
            )
        }
    }
#endif

package extension FileSystemService {
    @inline(__always)
    nonisolated static func isRepoPromptTempFilename(_ name: String) -> Bool {
        name.hasPrefix(".repoprompt.tmp.")
    }
}
