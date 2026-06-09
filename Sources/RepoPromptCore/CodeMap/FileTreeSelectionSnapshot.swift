import Foundation

package struct FileTreeSelectionSnapshot {
    package let roots: [FileTreeFolderSnapshot]
    package let selectedFileIDs: Set<UUID>
    package let mode: String
    package let showFullPaths: Bool
    package let onlyIncludeRootsWithSelectedFiles: Bool
    package let includeLegend: Bool
    package let showCodeMapMarkers: Bool
    package let maxDepth: Int?

    package init(
        roots: [FileTreeFolderSnapshot],
        selectedFileIDs: Set<UUID>,
        mode: String,
        showFullPaths: Bool,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool,
        showCodeMapMarkers: Bool = true,
        maxDepth: Int? = nil
    ) {
        self.roots = roots
        self.selectedFileIDs = selectedFileIDs
        self.mode = mode
        self.showFullPaths = showFullPaths
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeLegend = includeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.maxDepth = maxDepth
    }
}

package struct FileTreeFolderSnapshot: Hashable {
    package let id: UUID
    package let name: String
    package let fullPath: String
    package let standardizedFullPath: String
    package let standardizedRootPath: String
    package let children: [FileTreeNodeSnapshot]

    package init(
        id: UUID,
        name: String,
        fullPath: String,
        standardizedFullPath: String,
        standardizedRootPath: String,
        children: [FileTreeNodeSnapshot]
    ) {
        self.id = id
        self.name = name
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.standardizedRootPath = standardizedRootPath
        self.children = children
    }
}

package struct FileTreeFileSnapshot: Hashable {
    package let id: UUID
    package let name: String
    package let fileExtension: String?
    package let hasCodeMap: Bool

    package init(id: UUID, name: String, fileExtension: String?, hasCodeMap: Bool) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.hasCodeMap = hasCodeMap
    }
}

package indirect enum FileTreeNodeSnapshot: Hashable {
    case folder(FileTreeFolderSnapshot)
    case file(FileTreeFileSnapshot)

    package var id: UUID {
        switch self {
        case let .folder(folder): folder.id
        case let .file(file): file.id
        }
    }

    package var name: String {
        switch self {
        case let .folder(folder): folder.name
        case let .file(file): file.name
        }
    }
}
