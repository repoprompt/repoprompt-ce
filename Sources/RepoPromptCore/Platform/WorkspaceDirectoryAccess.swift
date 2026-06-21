import Foundation

package struct WorkspaceDirectoryEntry: Equatable {
    package enum Kind: Equatable {
        case regularFile
        case directory
        case symbolicLink(isDirectory: Bool)
        case other
    }

    package let name: String
    package let kind: Kind

    package init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    package init(name: String, isDir: Bool, isSym: Bool) {
        self.name = name
        kind = isSym ? .symbolicLink(isDirectory: isDir) : (isDir ? .directory : .regularFile)
    }

    package var isDir: Bool {
        isDirectory
    }

    package var isSym: Bool {
        isSymbolicLink
    }

    package var isDirectory: Bool {
        switch kind {
        case .directory, .symbolicLink(isDirectory: true):
            true
        case .regularFile, .symbolicLink(isDirectory: false), .other:
            false
        }
    }

    package var isSymbolicLink: Bool {
        if case .symbolicLink = kind { return true }
        return false
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

    package init(dev: UInt64, ino: UInt64) {
        device = dev
        inode = ino
    }

    package var dev: UInt64 {
        device
    }

    package var ino: UInt64 {
        inode
    }
}

package protocol WorkspaceDirectoryAccessing: Sendable {
    func listDirectoryWithIgnoreDetection(at path: String) throws -> WorkspaceDirectoryScanResult
    func directoryIdentity(followingSymlinksAt path: String) -> WorkspaceDirectoryIdentity?
    func canonicalPath(for path: String) -> String?
}
