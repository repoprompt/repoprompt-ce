import Foundation

struct WorkspaceFileTreePresentationSnapshot {
    let roots: [WorkspaceFileTreeFolderPresentation]
    let selectedFileIDs: Set<UUID>
    let mode: String
    let showFullPaths: Bool
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeLegend: Bool
    let showCodeMapMarkers: Bool
    let maxDepth: Int?

    init(
        roots: [WorkspaceFileTreeFolderPresentation],
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

struct WorkspaceFileTreeFolderPresentation: Hashable {
    let id: UUID
    let name: String
    let fullPath: String
    let standardizedFullPath: String
    let standardizedRootPath: String
    let children: [WorkspaceFileTreeNodePresentation]
}

struct WorkspaceFileTreeFilePresentation: Hashable {
    let id: UUID
    let name: String
    let fileExtension: String?
    let hasCodeMap: Bool
}

indirect enum WorkspaceFileTreeNodePresentation: Hashable {
    case folder(WorkspaceFileTreeFolderPresentation)
    case file(WorkspaceFileTreeFilePresentation)

    var id: UUID {
        switch self {
        case let .folder(folder): folder.id
        case let .file(file): file.id
        }
    }

    var name: String {
        switch self {
        case let .folder(folder): folder.name
        case let .file(file): file.name
        }
    }
}

struct WorkspaceFileTreePresentation {
    let content: String
    let rootCount: Int
    let usesLegend: Bool
    let codemapCoverage: WorkspaceCodemapOperationPresentationCoverage
    let codemapIssues: [WorkspaceCodemapOperationIssue]
}

extension WorkspaceFileTreePresentationSnapshot {
    func logicalized(
        roots: [WorkspaceRootRef],
        rootDisplayNamesByRootID: [UUID: String]
    ) -> WorkspaceFileTreePresentationSnapshot {
        let rootsByPath = Dictionary(
            uniqueKeysWithValues: roots.map { ($0.standardizedFullPath, $0) }
        )
        let logicalRoots = self.roots.map { folder -> WorkspaceFileTreeFolderPresentation in
            guard let root = rootsByPath[folder.standardizedRootPath],
                  let label = rootDisplayNamesByRootID[root.id]
            else { return folder }
            let relative = String(folder.standardizedFullPath.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return WorkspaceFileTreeFolderPresentation(
                id: folder.id,
                name: relative.isEmpty ? label : folder.name,
                fullPath: relative.isEmpty ? label : "\(label)/\(relative)",
                standardizedFullPath: relative.isEmpty ? label : "\(label)/\(relative)",
                standardizedRootPath: label,
                children: folder.children
            )
        }
        return WorkspaceFileTreePresentationSnapshot(
            roots: logicalRoots,
            selectedFileIDs: selectedFileIDs,
            mode: mode,
            showFullPaths: showFullPaths,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers,
            maxDepth: maxDepth
        )
    }
}
