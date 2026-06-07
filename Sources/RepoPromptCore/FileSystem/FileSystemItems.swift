import Foundation

package protocol FileSystemItem: Identifiable, Equatable, Sendable {
    var id: UUID { get }
    var name: String { get }
    var path: String { get }
    var modificationDate: Date { get }
}

package struct Folder: FileSystemItem {
    package let id: UUID
    package let name: String
    package let path: String
    package let modificationDate: Date

    package init(id: UUID = UUID(), name: String, path: String, modificationDate: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.modificationDate = modificationDate
    }

    package static func == (lhs: Folder, rhs: Folder) -> Bool {
        lhs.path == rhs.path
    }
}

package extension FileSystemItem {
    func relativePath(rootPath: String) -> String {
        RelativePath.from(absolutePath: path, rootPath: rootPath)
    }
}

package struct File: FileSystemItem {
    package let id: UUID
    package let name: String
    package let path: String
    package let modificationDate: Date

    package init(id: UUID = UUID(), name: String, path: String, modificationDate: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.modificationDate = modificationDate
    }

    package static func == (lhs: File, rhs: File) -> Bool {
        lhs.path == rhs.path
    }
}
