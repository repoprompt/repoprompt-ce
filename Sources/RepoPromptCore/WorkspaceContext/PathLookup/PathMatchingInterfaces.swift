import Foundation

// MARK: - Minimal Read-Only Protocols

/// Represents a file with essential properties for path matching
package protocol FileRecord: Sendable {
    var name: String { get }
    var relativePath: String { get }
    var fullPath: String { get }
    var rootFolderPath: String { get }
}

/// Represents a folder with essential properties for path matching.
/// Note: This protocol intentionally excludes `files` to prevent UI type dependencies
/// and ensure frozen records cannot accidentally traverse live view model graphs.
package protocol FolderRecord: Sendable {
    var name: String { get }
    var displayName: String { get }
    var relativePath: String { get }
    var fullPath: String { get }
    var rootPath: String { get }
}

/// Read-only view of the file hierarchy index
package protocol FileHierarchyReadable {
    var filesByFullPath: [String: FileRecord] { get }
    var foldersByFullPath: [String: FolderRecord] { get }
    var rootFolders: [FolderRecord] { get }
}

// MARK: - Frozen value types (copy-only, thread-safe)

// These structs copy only primitive string fields from the view models.
// They prevent background PathMatcher work from touching @MainActor state.

public struct FrozenFileRecord: FileRecord {
    public let name: String
    public let relativePath: String
    public let fullPath: String
    public let rootFolderPath: String

    public init(name: String, relativePath: String, fullPath: String, rootFolderPath: String) {
        self.name = name
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.rootFolderPath = rootFolderPath
    }
}

public struct FrozenFolderRecord: FolderRecord {
    public let name: String
    public let displayName: String
    public let relativePath: String
    public let fullPath: String
    public let rootPath: String

    public init(name: String, relativePath: String, fullPath: String, rootPath: String, displayName: String? = nil) {
        self.name = name
        self.displayName = displayName ?? name
        self.relativePath = relativePath
        self.fullPath = (fullPath as NSString).standardizingPath
        self.rootPath = (rootPath as NSString).standardizingPath
    }
}
