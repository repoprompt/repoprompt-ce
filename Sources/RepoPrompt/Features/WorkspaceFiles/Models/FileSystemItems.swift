import Foundation

enum FileTreeItem: Identifiable {
    case folder(String, [FileViewModel])
    case file(FileViewModel)

    var id: String {
        switch self {
        case let .folder(path, _):
            "folder_\(path)"
        case let .file(file):
            "file_\(file.id)"
        }
    }

    var path: String {
        switch self {
        case let .folder(name, _): name
        case let .file(file): file.relativePath
        }
    }
}
