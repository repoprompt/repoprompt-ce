import Foundation
import RepoPromptCore

extension CodeMapExtractor {
    @MainActor
    static func makeFileTreeSnapshot(using context: FileTreeSelectionContext) -> FileTreeSelectionSnapshot {
        var roots: [FileTreeFolderSnapshot] = []
        roots.reserveCapacity(context.rootFolders.count)
        for root in context.rootFolders {
            var visited = Set<UUID>()
            if let snapshot = appSnapshot(
                folder: root,
                rootStandardizedPath: root.standardizedFullPath,
                visited: &visited
            ) {
                roots.append(snapshot)
            }
        }
        let mode = switch context.option {
        case .none: "none"
        case .selected: "selected"
        case .files: "full"
        case .auto: "auto"
        }
        return FileTreeSelectionSnapshot(
            roots: roots,
            selectedFileIDs: context.selectedFileIDs,
            mode: mode,
            showFullPaths: context.filePathDisplay == .full,
            onlyIncludeRootsWithSelectedFiles: context.onlyIncludeRootsWithSelectedFiles,
            includeLegend: context.includeLegend,
            showCodeMapMarkers: context.showCodeMapMarkers
        )
    }

    static func generateFileTree(using snapshot: FileTreeSelectionSnapshot) -> String {
        FileTreeSnapshotRenderer.generateFileTree(using: snapshot)
    }

    @MainActor
    private static func appSnapshot(
        folder: FolderViewModel,
        rootStandardizedPath: String,
        visited: inout Set<UUID>
    ) -> FileTreeFolderSnapshot? {
        guard visited.insert(folder.id).inserted else { return nil }
        var children: [FileTreeNodeSnapshot] = []
        children.reserveCapacity(folder.children.count)
        for child in folder.children {
            switch child {
            case let .folder(subfolder):
                if let childSnapshot = appSnapshot(
                    folder: subfolder,
                    rootStandardizedPath: rootStandardizedPath,
                    visited: &visited
                ) {
                    children.append(.folder(childSnapshot))
                }
            case let .file(file):
                children.append(.file(FileTreeFileSnapshot(
                    id: file.id,
                    name: file.name,
                    fileExtension: file.fileExtension,
                    hasCodeMap: file.hasAcceptedCodeMap
                )))
            }
        }
        return FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: rootStandardizedPath,
            children: children
        )
    }
}
