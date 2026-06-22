import Foundation

/// Immutable logical/physical translation captured by the app after worktree authorization.
/// Core may use physical identities for reads, but all presentation leaves this type through
/// logical display helpers.
package struct FrozenWorkspacePathProjection: Equatable, @unchecked Sendable {
    package struct RootBinding: Equatable {
        package let logicalRoot: WorkspaceRootRef
        package let physicalRoot: WorkspaceRootRef

        package init(logicalRoot: WorkspaceRootRef, physicalRoot: WorkspaceRootRef) {
            self.logicalRoot = logicalRoot
            self.physicalRoot = physicalRoot
        }
    }

    package let bindings: [RootBinding]
    package let visibleLogicalRoots: [WorkspaceRootRef]
    package let rootScope: WorkspaceLookupRootScope

    package init(
        bindings: [RootBinding],
        visibleLogicalRoots: [WorkspaceRootRef],
        rootScope: WorkspaceLookupRootScope
    ) {
        self.bindings = bindings.sorted {
            $0.logicalRoot.standardizedFullPath < $1.logicalRoot.standardizedFullPath
        }
        self.visibleLogicalRoots = visibleLogicalRoots.sorted {
            $0.standardizedFullPath < $1.standardizedFullPath
        }
        self.rootScope = rootScope
    }

    package var expectedPhysicalRoots: [WorkspaceRootRef] {
        bindings.map(\.physicalRoot)
    }

    package func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            let translated = physicalPath(forInput: path)
            slices[translated] = SliceRangeMath.normalize((slices[translated] ?? []) + ranges)
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map(physicalPath(forInput:)),
            autoCodemapPaths: selection.autoCodemapPaths.map(physicalPath(forInput:)),
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    package func logicalDisplayPath(
        forPhysicalPath rawPath: String,
        display: FilePathDisplay
    ) -> String? {
        let path = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let binding = binding(containingPhysicalPath: path) else { return nil }
        let relative = suffix(of: path, below: binding.physicalRoot.standardizedFullPath)
        if display == .full {
            return StandardizedPath.join(
                standardizedRoot: binding.logicalRoot.standardizedFullPath,
                standardizedRelativePath: relative
            )
        }
        return ClientPathFormatter.displayPath(
            root: binding.logicalRoot,
            relativePath: relative,
            visibleRoots: visibleLogicalRoots
        )
    }

    package func logicalizeFileTreeSnapshot(
        _ snapshot: FileTreeSelectionSnapshot
    ) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map(logicalizeFolder),
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: snapshot.showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    package func logicalizePath(_ rawPath: String, display: FilePathDisplay) -> String {
        logicalDisplayPath(forPhysicalPath: rawPath, display: display)
            ?? URL(fileURLWithPath: rawPath).lastPathComponent
    }

    private func physicalPath(forInput rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/")
            ? StandardizedPath.absolute(expanded)
            : StandardizedPath.relative(expanded)

        if standardized.hasPrefix("/") {
            if binding(containingPhysicalPath: standardized) != nil { return standardized }
            guard let binding = binding(containingLogicalPath: standardized) else { return standardized }
            return StandardizedPath.join(
                standardizedRoot: binding.physicalRoot.standardizedFullPath,
                standardizedRelativePath: suffix(of: standardized, below: binding.logicalRoot.standardizedFullPath)
            )
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: visibleLogicalRoots,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _):
            return bindings.first(where: { $0.logicalRoot == root })?.physicalRoot.standardizedFullPath ?? rawPath
        case let .prefixed(root, _, remainder):
            guard let binding = bindings.first(where: { $0.logicalRoot == root }) else { return rawPath }
            return StandardizedPath.join(
                standardizedRoot: binding.physicalRoot.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
        case .ambiguous, .notAliasPrefixed:
            guard bindings.count == 1, let binding = bindings.first else { return rawPath }
            return StandardizedPath.join(
                standardizedRoot: binding.physicalRoot.standardizedFullPath,
                standardizedRelativePath: standardized
            )
        }
    }

    private func logicalizeFolder(_ folder: FileTreeFolderSnapshot) -> FileTreeFolderSnapshot {
        let fullPath = logicalDisplayPath(forPhysicalPath: folder.fullPath, display: .full) ?? folder.fullPath
        let standardizedFullPath = logicalDisplayPath(
            forPhysicalPath: folder.standardizedFullPath,
            display: .full
        ) ?? folder.standardizedFullPath
        let rootPath = logicalDisplayPath(
            forPhysicalPath: folder.standardizedRootPath,
            display: .full
        ) ?? folder.standardizedRootPath
        let rootName = bindings.first(where: {
            $0.logicalRoot.standardizedFullPath == rootPath
        })?.logicalRoot.name
        return FileTreeFolderSnapshot(
            id: folder.id,
            name: standardizedFullPath == rootPath ? (rootName ?? folder.name) : folder.name,
            fullPath: fullPath,
            standardizedFullPath: standardizedFullPath,
            standardizedRootPath: rootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(value): .folder(logicalizeFolder(value))
                case let .file(value): .file(value)
                }
            }
        )
    }

    private func binding(containingPhysicalPath path: String) -> RootBinding? {
        bindings.filter {
            path == $0.physicalRoot.standardizedFullPath
                || path.hasPrefix($0.physicalRoot.standardizedFullPath + "/")
        }.max {
            $0.physicalRoot.standardizedFullPath.count < $1.physicalRoot.standardizedFullPath.count
        }
    }

    private func binding(containingLogicalPath path: String) -> RootBinding? {
        bindings.filter {
            path == $0.logicalRoot.standardizedFullPath
                || path.hasPrefix($0.logicalRoot.standardizedFullPath + "/")
        }.max {
            $0.logicalRoot.standardizedFullPath.count < $1.logicalRoot.standardizedFullPath.count
        }
    }

    private func suffix(of path: String, below root: String) -> String {
        guard path != root else { return "" }
        return StandardizedPath.relative(
            String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }
}
