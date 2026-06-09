import Foundation

package struct WorkspaceDirectoryEntry: Equatable {
    package let name: String
    package let isDirectory: Bool
    package let isSymbolicLink: Bool

    package var isDir: Bool {
        isDirectory
    }

    package var isSym: Bool {
        isSymbolicLink
    }

    package init(name: String, isDirectory: Bool, isSymbolicLink: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

package struct WorkspaceDirectoryScanResult: Equatable {
    package let entries: [WorkspaceDirectoryEntry]
    package let hasGitignore: Bool
    package let hasRepoIgnore: Bool
    package let hasCursorignore: Bool

    package init(
        entries: [WorkspaceDirectoryEntry],
        hasGitignore: Bool,
        hasRepoIgnore: Bool,
        hasCursorignore: Bool
    ) {
        self.entries = entries
        self.hasGitignore = hasGitignore
        self.hasRepoIgnore = hasRepoIgnore
        self.hasCursorignore = hasCursorignore
    }
}

package struct WorkspaceDirectoryIdentity: Hashable {
    package let device: UInt64
    package let inode: UInt64

    package init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

package typealias DirEntry = WorkspaceDirectoryEntry
package typealias DirectoryScanResult = WorkspaceDirectoryScanResult
package typealias DirID = WorkspaceDirectoryIdentity

package protocol WorkspaceDirectoryListingBackend: Sendable {
    func listDirectoryWithIgnoreDetection(at path: String) throws -> WorkspaceDirectoryScanResult
    func directoryIdentity(followingSymlinksAt path: String) -> WorkspaceDirectoryIdentity?
    func canonicalPath(for path: String) -> String?
}
