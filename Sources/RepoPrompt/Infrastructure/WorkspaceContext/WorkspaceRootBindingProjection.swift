import Foundation

struct WorkspaceRootBindingProjection: Equatable {
    let sessionID: UUID
    let replacementsByLogicalRootPath: [String: BoundRoot]
    private let visibleLogicalRoots: [WorkspaceRootRef]

    struct BoundRoot: Equatable {
        let logicalRoot: WorkspaceRootRef
        let physicalRoot: WorkspaceRootRef
        let binding: AgentSessionWorktreeBinding
    }

    init(sessionID: UUID, boundRoots: [BoundRoot], visibleLogicalRoots: [WorkspaceRootRef] = []) {
        self.sessionID = sessionID
        var replacements: [String: BoundRoot] = [:]
        for boundRoot in boundRoots {
            replacements[boundRoot.logicalRoot.standardizedFullPath] = boundRoot
        }
        replacementsByLogicalRootPath = replacements
        self.visibleLogicalRoots = visibleLogicalRoots.isEmpty
            ? boundRoots.map(\.logicalRoot)
            : visibleLogicalRoots
    }

    var isEmpty: Bool {
        replacementsByLogicalRootPath.isEmpty
    }

    var logicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.keys)
    }

    var physicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.values.map(\.physicalRoot.standardizedFullPath))
    }

    var lookupRootScope: WorkspaceLookupRootScope {
        .sessionBoundWorkspace(logicalRootPaths: logicalRootPaths, physicalRootPaths: physicalRootPaths)
    }

    var logicalRootRefs: [WorkspaceRootRef] {
        replacementsByLogicalRootPath.values
            .map(\.logicalRoot)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var visibleLogicalRootRefs: [WorkspaceRootRef] {
        visibleLogicalRoots.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var physicalRootRefs: [WorkspaceRootRef] {
        replacementsByLogicalRootPath.values
            .map(\.physicalRoot)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    var boundRootsForMetadata: [BoundRoot] {
        replacementsByLogicalRootPath.values.sorted { lhs, rhs in
            if lhs.logicalRoot.standardizedFullPath != rhs.logicalRoot.standardizedFullPath {
                return lhs.logicalRoot.standardizedFullPath < rhs.logicalRoot.standardizedFullPath
            }
            if lhs.physicalRoot.standardizedFullPath != rhs.physicalRoot.standardizedFullPath {
                return lhs.physicalRoot.standardizedFullPath < rhs.physicalRoot.standardizedFullPath
            }
            return lhs.binding.worktreeID < rhs.binding.worktreeID
        }
    }

    func translateInputPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/") ? StandardizedPath.absolute(expanded) : StandardizedPath.relative(expanded)

        if standardized.hasPrefix("/") {
            if pathIsUnderAnyPhysicalRoot(standardized) {
                return standardized
            }
            if let boundRoot = boundRoot(containingLogicalAbsolutePath: standardized) {
                return replacePrefix(
                    in: standardized,
                    from: boundRoot.logicalRoot.standardizedFullPath,
                    to: boundRoot.physicalRoot.standardizedFullPath
                )
            }
            return standardized
        }

        if let aliasTranslated = translateAliasPrefixedRelativePath(standardized) {
            return aliasTranslated
        }
        if isAliasPrefixedToUnboundLogicalRoot(standardized) {
            return rawPath
        }

        let boundRoots = Array(replacementsByLogicalRootPath.values)
        guard boundRoots.count == 1, let boundRoot = boundRoots.first else { return rawPath }
        return StandardizedPath.join(
            standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
            standardizedRelativePath: standardized
        )
    }

    func translateInputPaths(_ paths: [String]) -> [String] {
        paths.map { translateInputPath($0) }
    }

    func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        slices.map { input in
            WorkspaceSelectionSliceInput(
                path: translateInputPath(input.path),
                ranges: input.ranges
            )
        }
    }

    func projectedLogicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let logicalAbsolute = replacePrefix(
            in: standardized,
            from: boundRoot.physicalRoot.standardizedFullPath,
            to: boundRoot.logicalRoot.standardizedFullPath
        )
        if display == .full {
            return logicalAbsolute
        }
        let relative = String(logicalAbsolute.dropFirst(boundRoot.logicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ClientPathFormatter.displayPath(
            root: boundRoot.logicalRoot,
            relativePath: relative,
            visibleRoots: visibleLogicalRootRefs
        )
    }

    func logicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String {
        projectedLogicalDisplayPath(forPhysicalPath: rawPath, display: display)
            ?? StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
    }

    func logicalizeFileTreeSnapshot(_ snapshot: FileTreeSelectionSnapshot) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map { logicalizeFolderSnapshot($0) },
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: snapshot.showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    private func logicalizeFolderSnapshot(_ folder: FileTreeFolderSnapshot) -> FileTreeFolderSnapshot {
        let logicalFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.fullPath, display: .full)
        let logicalStandardizedFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedFullPath, display: .full)
        let logicalStandardizedRootPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedRootPath, display: .full)
        let name: String = if let logicalStandardizedRootPath,
                              logicalStandardizedFullPath == logicalStandardizedRootPath,
                              let boundRoot = replacementsByLogicalRootPath[logicalStandardizedRootPath]
        {
            boundRoot.logicalRoot.name
        } else {
            folder.name
        }
        return FileTreeFolderSnapshot(
            id: folder.id,
            name: name,
            fullPath: logicalFullPath ?? folder.fullPath,
            standardizedFullPath: logicalStandardizedFullPath ?? folder.standardizedFullPath,
            standardizedRootPath: logicalStandardizedRootPath ?? folder.standardizedRootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(childFolder):
                    .folder(logicalizeFolderSnapshot(childFolder))
                case let .file(file):
                    .file(file)
                }
            }
        )
    }

    func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            slices[logicalDisplayPath(forPhysicalPath: path, display: .full)] = ranges
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { logicalDisplayPath(forPhysicalPath: $0, display: .full) },
            autoCodemapPaths: selection.autoCodemapPaths.map { logicalDisplayPath(forPhysicalPath: $0, display: .full) },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            slices[translateInputPath(path)] = ranges
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { translateInputPath($0) },
            autoCodemapPaths: selection.autoCodemapPaths.map { translateInputPath($0) },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private func translateAliasPrefixedRelativePath(_ standardizedRelativePath: String) -> String? {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return boundRoot.physicalRoot.standardizedFullPath
        case let .prefixed(root, _, remainder):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return StandardizedPath.join(
                standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
        case .ambiguous, .notAliasPrefixed:
            return nil
        }
    }

    private func isAliasPrefixedToUnboundLogicalRoot(_ standardizedRelativePath: String) -> Bool {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _), let .prefixed(root, _, _):
            replacementsByLogicalRootPath[root.standardizedFullPath] == nil
        case .ambiguous, .notAliasPrefixed:
            false
        }
    }

    private func boundRoot(containingLogicalAbsolutePath path: String) -> BoundRoot? {
        replacementsByLogicalRootPath.values
            .filter { path == $0.logicalRoot.standardizedFullPath || path.hasPrefix($0.logicalRoot.standardizedFullPath + "/") }
            .max { $0.logicalRoot.standardizedFullPath.count < $1.logicalRoot.standardizedFullPath.count }
    }

    private func boundRoot(containingPhysicalAbsolutePath path: String) -> BoundRoot? {
        replacementsByLogicalRootPath.values
            .filter { path == $0.physicalRoot.standardizedFullPath || path.hasPrefix($0.physicalRoot.standardizedFullPath + "/") }
            .max { $0.physicalRoot.standardizedFullPath.count < $1.physicalRoot.standardizedFullPath.count }
    }

    private func pathIsUnderAnyPhysicalRoot(_ path: String) -> Bool {
        boundRoot(containingPhysicalAbsolutePath: path) != nil
    }

    private func replacePrefix(in path: String, from oldRoot: String, to newRoot: String) -> String {
        guard path != oldRoot else { return newRoot }
        let suffix = String(path.dropFirst(oldRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StandardizedPath.join(standardizedRoot: newRoot, standardizedRelativePath: suffix)
    }
}

struct WorkspaceRootBindingProjectionMaterializer {
    let store: WorkspaceFileContextStore

    func materialize(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding]
    ) async -> WorkspaceRootBindingProjection? {
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        var boundRoots: [WorkspaceRootBindingProjection.BoundRoot] = []
        var loadedSessionWorktreeRootIDs: [UUID] = []
        for binding in bindings {
            let logicalPath = StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath)
            let logicalRoot = visibleRoots.first { $0.standardizedFullPath == logicalPath }
                ?? WorkspaceRootRef(
                    id: UUID(),
                    name: binding.logicalRootName ?? URL(fileURLWithPath: logicalPath).lastPathComponent,
                    fullPath: logicalPath
                )
            let physicalRoot: WorkspaceRootRef
            do {
                let physicalRecord = try await store.loadRoot(
                    path: binding.worktreeRootPath,
                    kind: .sessionWorktree,
                    respectGitignore: true,
                    respectRepoIgnore: true,
                    respectCursorignore: true
                )
                physicalRoot = WorkspaceRootRef(
                    id: physicalRecord.id,
                    name: logicalRoot.name,
                    fullPath: physicalRecord.standardizedFullPath
                )
                loadedSessionWorktreeRootIDs.append(physicalRecord.id)
            } catch {
                // Fail closed for bound sessions: keep the logical -> physical projection so
                // display paths and complete-diff policy still know this session is worktree-bound,
                // but do not substitute the logical/base root when the physical worktree cannot be
                // loaded. `sessionBoundWorkspace` scopes only include actually loaded
                // `.sessionWorktree` roots, so lookups against this fabricated ref miss instead of
                // reading stale base-checkout content.
                physicalRoot = WorkspaceRootRef(
                    id: UUID(),
                    name: logicalRoot.name,
                    fullPath: StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
                )
            }
            boundRoots.append(.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding))
        }
        guard !boundRoots.isEmpty else { return nil }
        _ = await store.initializeCodemapsForSessionWorktreeRoots(rootIDs: loadedSessionWorktreeRootIDs)
        return WorkspaceRootBindingProjection(sessionID: sessionID, boundRoots: boundRoots, visibleLogicalRoots: visibleRoots)
    }
}

struct WorkspaceLookupContext: Equatable {
    let rootScope: WorkspaceLookupRootScope
    let bindingProjection: WorkspaceRootBindingProjection?

    static let visibleWorkspace = WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: nil)

    func translateInputPath(_ path: String) -> String {
        bindingProjection?.translateInputPath(path) ?? path
    }

    func translateInputPaths(_ paths: [String]) -> [String] {
        bindingProjection?.translateInputPaths(paths) ?? paths
    }

    func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        bindingProjection?.translateSliceInputs(slices) ?? slices
    }

    func displayPath(forPhysicalPath path: String, display: FilePathDisplay = .relative) -> String {
        bindingProjection?.logicalDisplayPath(forPhysicalPath: path, display: display) ?? path
    }

    func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.logicalizeSelection(selection) ?? selection
    }

    func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.physicalizeSelection(selection) ?? selection
    }
}
