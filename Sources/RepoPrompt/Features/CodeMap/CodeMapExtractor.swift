import Foundation
import SwiftUI

/// Determines how CodeMap definitions are inserted.
enum CodeMapUsage: String, CaseIterable, Codable {
    case auto
    case complete
    /// Include code-map for selected files only (handled at injection sites;
    /// returning it here would duplicate).
    case selected
    case none
}

/// A small struct returning code-map text + the number of files included in that text.
struct DefinitionBlockResult {
    let text: String
    let fileCount: Int
}

/// File tree build result with marker flags
struct FileTreeResult {
    let tree: String
    let usedSelectedMarker: Bool
    let usedCodeMapMarker: Bool
    let wasTruncated: Bool
    let note: String?
    var usesLegend: Bool {
        usedSelectedMarker || usedCodeMapMarker
    }
}

/// Explicit inputs for file-tree rendering.
/// Selection membership is separate from prompt inclusion and drives `*` markers/root filtering.
struct FileTreeSelectionContext {
    let rootFolders: [FolderViewModel]
    let selectedFileIDs: Set<UUID>
    let option: FileTreeOption
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeLegend: Bool
    let isMCPContext: Bool
    let showCodeMapMarkers: Bool

    init(
        rootFolders: [FolderViewModel],
        selectedFileIDs: Set<UUID>,
        option: FileTreeOption,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool,
        isMCPContext: Bool,
        showCodeMapMarkers: Bool = true
    ) {
        self.rootFolders = rootFolders
        self.selectedFileIDs = selectedFileIDs
        self.option = option
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeLegend = includeLegend
        self.isMCPContext = isMCPContext
        self.showCodeMapMarkers = showCodeMapMarkers
    }
}

/// Standalone helper to gather relevant FileAPI-based definitions
/// and also handle file tree generation logic.
enum CodeMapExtractor {
    static func generateFileTree(using context: FileTreeSelectionContext) -> String {
        guard context.option != .none else { return "" }
        let mode = switch context.option {
        case .none: "none"
        case .selected: "selected"
        case .files: "full"
        case .auto: "auto"
        }
        return generateFileTreeForRoots(
            rootFolders: context.rootFolders,
            mode: mode,
            maxDepth: nil,
            includeHidden: true,
            filePathDisplay: context.filePathDisplay,
            selectedFileIDs: context.selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: context.onlyIncludeRootsWithSelectedFiles,
            includeLegend: context.includeLegend,
            isMCPContext: context.isMCPContext,
            showCodeMapMarkers: context.showCodeMapMarkers
        )
    }

    struct RootInfo: Hashable {
        let standardizedRootFullPath: String
        let displayName: String
    }

    // File-private statics for filtering (moved from per-call locals)
    private static let badExt: Set<String> = ["o", "obj", "a", "so", "dll", "exe", "tmp", "swp"]
    private static let badDirs: Set<String> = ["build", "deriveddata", "node_modules", "pods", ".git", "_git_data"]

    // Soft token budget used by AUTO mode when progressively building trees
    private static let autoTokenBudget: Int = 6000
    private static let mcpTokenBudget: Int = 15000
    private static let mcpTruncationMessage = "Output truncated - exceeded 15k token limit. Try mode='auto', increase max_depth constraint, or use a more specific starting path."
    /// Per-folder sibling cap for AUTO mode (disabled when explicitly rendering a subtree)
    private static let maxChildrenPerFolderAutoCap: Int = 100

    // New markers and legends
    private static let selectedMark = " *"
    private static let codeMapMark = " +"
    private static let selectedLegend = "(* denotes selected files)"
    private static let codeMapLegend = "(+ denotes code-map available)"

    /// Collect FileViewModel IDs that have an already-accepted code-map.
    private static func collectCodeMapIDs(from roots: [FolderViewModel]) -> Set<UUID> {
        var ids = Set<UUID>()
        var visited = Set<UUID>()
        var stack = roots
        while let folder = stack.popLast() {
            if Task.isCancelled { break }
            if !visited.insert(folder.id).inserted { continue }
            for child in folder.children {
                if Task.isCancelled { break }
                switch child {
                case let .file(f):
                    if f.hasAcceptedCodeMap { ids.insert(f.id) }
                case let .folder(sub):
                    stack.append(sub)
                }
            }
        }
        return ids
    }

    // REPOMARK:SCOPE: 1 - Remove includeHidden from BuildSettings and VCCacheKey; rely on RepoPrompt visibility (top-level helpers)
    // Lightweight settings passed around during a single build
    private struct BuildSettings {
        let mode: String
        let filePathDisplay: FilePathDisplay
        /// If set, limit the number of immediate children emitted per folder while still
        /// always including selected items. Applies only to AUTO attempts (top-level).
        let siblingCap: Int?
        let showCodeMapMarkers: Bool

        init(mode: String, filePathDisplay: FilePathDisplay, siblingCap: Int?, showCodeMapMarkers: Bool = true) {
            self.mode = mode
            self.filePathDisplay = filePathDisplay
            self.siblingCap = siblingCap
            self.showCodeMapMarkers = showCodeMapMarkers
        }
    }

    /// Cache key for "visible children" filtered + sorted lists
    private struct VCCacheKey: Hashable {
        let folderID: UUID
        let mode: UInt8 // 0=auto, 1=full, 2=folders
    }

    /// Single-buffer string builder with incremental token estimate
    private struct StringBuilder {
        private(set) var estimatedTokens: Int = 0
        private var s: String = ""
        init(reserve: Int = 0) {
            if reserve > 0 { s.reserveCapacity(reserve) }
        }

        @inline(__always) mutating func appendLine(_ line: String) {
            s.append(line)
            s.append("\n")
            // Same heuristic as estimateTokens(for:)
            estimatedTokens &+= Int((Double(line.count + 1) * 1.05) / 4.0)
        }

        var result: String {
            s
        }

        var isEmpty: Bool {
            s.isEmpty
        }
    }

    /// Outcome for budget-aware builds
    private enum BuildOutcome {
        case ok
        case tooLarge
    }

    /// Per-build context (mutable fields passed inout)
    private struct BuildContext {
        let settings: BuildSettings
        let selectedFileIDs: Set<UUID>
        let getSelectedFolderIDs: () -> Set<UUID> // lazy thunk
        var childrenCache: [VCCacheKey: [FileSystemItemType]] = [:]
        var usedSelectedMarker: Bool = false
        let tokenBudget: Int? // set in auto attempts; nil otherwise
        let maxDepth: Int? // depth cap for this build attempt
    }

    private static func buildDepthZeroTree(
        roots: [FolderViewModel],
        settings: BuildSettings,
        selectedFileIDs: Set<UUID>,
        fetchSelectedFolderIDs: () -> Set<UUID>,
        childrenCache: inout [VCCacheKey: [FileSystemItemType]],
        sb: inout StringBuilder,
        usedSelectedMarker: inout Bool,
        tokenBudget: Int?
    ) -> BuildOutcome {
        if Task.isCancelled { return .tooLarge }
        let m = settings.mode.lowercased()
        // Precompute selectedFolderIDs once to avoid escaping the thunk
        let selectedFolderIDsSet = fetchSelectedFolderIDs()
        // Precompute code-map IDs once for all roots in this pass when markers are enabled.
        let codeMapIDs = settings.showCodeMapMarkers ? collectCodeMapIDs(from: roots) : []

        /// Local helper to emit only selected descendants (used when expanding beyond depth cap)
        func emitSelectedOnlyLocal(
            child: FileSystemItemType,
            basePrefix: String,
            isLast: Bool,
            visited: inout Set<UUID>
        ) -> Bool {
            if Task.isCancelled { return true }
            if let budget = tokenBudget, sb.estimatedTokens >= budget { return true }

            switch child {
            case let .file(fi):
                let marked = selectedFileIDs.contains(fi.id)
                let hasMap = settings.showCodeMapMarkers && codeMapIDs.contains(fi.id)
                if marked { usedSelectedMarker = true }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fi.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                return false

            case let .folder(fo):
                if !visited.insert(fo.id).inserted { return false }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fo.name)")
                let nextPrefix = basePrefix + (isLast ? "    " : "│   ")

                // Only descend along selected paths
                var relevant: [FileSystemItemType] = fo.children.filter { c in
                    switch c {
                    case let .file(f): selectedFileIDs.contains(f.id)
                    case let .folder(s): selectedFolderIDsSet.contains(s.id)
                    }
                }

                // Folder-first ordering for the selected subset
                relevant.sort { a, b in
                    switch (a, b) {
                    case (.folder, .file): true
                    case (.file, .folder): false
                    case let (.folder(fa), .folder(fb)):
                        fa.name < fb.name
                    case let (.file(fa), .file(fb)):
                        fa.name < fb.name
                    }
                }

                for (idx, ch) in relevant.enumerated() {
                    let chIsLast = idx == relevant.count - 1
                    if emitSelectedOnlyLocal(child: ch, basePrefix: nextPrefix, isLast: chIsLast, visited: &visited) {
                        return true
                    }
                }
                return false
            }
        }

        for (idx, root) in roots.enumerated() {
            if Task.isCancelled { return .tooLarge }
            if let budget = tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }

            // Root line with project context derived from the actual root being rendered.
            let rootIdentity = FileTreeRenderedRootIdentity(root: root)
            let rootLine = contextualRootLabel(for: root, within: rootIdentity, filePathDisplay: settings.filePathDisplay)
            sb.appendLine(rootLine)

            let base = "" // root has no prefix
            let childBasePrefix = base

            // Immediate visible children (mode-aware, but "selected" handled specially)
            let immediate: [FileSystemItemType]
            if m == "selected" {
                var subset: [FileSystemItemType] = root.children.filter {
                    switch $0 {
                    case let .file(f): selectedFileIDs.contains(f.id)
                    case let .folder(s): selectedFolderIDsSet.contains(s.id)
                    }
                }
                subset.sort { a, b in
                    switch (a, b) {
                    case (.folder, .file): true
                    case (.file, .folder): false
                    case let (.folder(fa), .folder(fb)):
                        fa.name < fb.name
                    case let (.file(fa), .file(fb)):
                        fa.name < fb.name
                    }
                }
                immediate = subset
            } else {
                // Inline of visibleChildren(...) with per-build cache
                let modeKey: UInt8 = switch m {
                case "auto": 0
                case "full": 1
                case "folders": 2
                default: 1
                }
                let key = VCCacheKey(folderID: root.id, mode: modeKey)
                if let cached = childrenCache[key] {
                    immediate = cached
                } else {
                    var folders: [FolderViewModel] = []
                    var files: [FileViewModel] = []
                    for child in root.children {
                        switch child {
                        case let .folder(fo):
                            let includeFolder: Bool = switch m {
                            case "auto":
                                // Rely on RepoPrompt visibility; filter out known junk dirs
                                !badDirs.contains(fo.name.lowercased())
                            case "full", "folders":
                                true
                            default:
                                true
                            }
                            if includeFolder { folders.append(fo) }
                        case let .file(fi):
                            // In folders-only mode, still surface selected files
                            if m == "folders" {
                                if selectedFileIDs.contains(fi.id) { files.append(fi) }
                            } else {
                                let includeFile: Bool = {
                                    switch m {
                                    case "auto":
                                        // Rely on RepoPrompt visibility; filter by extension only
                                        if let ext = fi.fileExtension?.lowercased(), badExt.contains(ext) { return false }
                                        return true
                                    case "full":
                                        return true
                                    default:
                                        return true
                                    }
                                }()
                                if includeFile { files.append(fi) }
                            }
                        }
                    }
                    folders.sort { $0.name < $1.name }
                    files.sort { $0.name < $1.name }
                    var merged: [FileSystemItemType] = []
                    merged.reserveCapacity(folders.count + files.count)
                    merged.append(contentsOf: folders.map { .folder($0) })
                    merged.append(contentsOf: files.map { .file($0) })
                    childrenCache[key] = merged
                    immediate = merged
                }
            }

            // Selected-only expansion beyond the cap
            let selectedOnly: [FileSystemItemType] = immediate.filter {
                switch $0 {
                case let .file(f): selectedFileIDs.contains(f.id)
                case let .folder(s): selectedFolderIDsSet.contains(s.id)
                }
            }
            let hasOther = !immediate.isEmpty && (immediate.count > selectedOnly.count)

            var visited = Set<UUID>()
            for (i, ch) in selectedOnly.enumerated() {
                let isLast = !hasOther && (i == selectedOnly.count - 1)
                switch ch {
                case let .file(f):
                    if let budget = tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                    let marked = selectedFileIDs.contains(f.id)
                    let hasMap = settings.showCodeMapMarkers && codeMapIDs.contains(f.id)
                    if marked { usedSelectedMarker = true }
                    sb.appendLine("\(childBasePrefix)\(isLast ? "└── " : "├── ")\(f.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                case .folder:
                    if emitSelectedOnlyLocal(child: ch, basePrefix: childBasePrefix, isLast: isLast, visited: &visited) {
                        return .tooLarge
                    }
                }
            }

            if hasOther {
                let ellPrefix = childBasePrefix + (selectedOnly.isEmpty ? "└── " : "├── ")
                sb.appendLine(ellPrefix + "...")
            }

            if idx < roots.count - 1 { sb.appendLine("") } // blank line between roots
        }

        return .ok
    }

    // MARK: - Code-map definitions

    // MARK: - Result variants with marker flags

    static func generateFileTreeForRootsResult(
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        includeLegend: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> FileTreeResult {
        let modeString = switch option {
        case .none: "none"
        case .selected: "selected"
        case .files: "full"
        case .auto: "auto"
        }
        let tree = generateFileTreeForRoots(
            rootFolders: rootFolders,
            mode: modeString,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers
        )
        let usedSel = tree.contains(selectedMark)
        let usedCM = showCodeMapMarkers && tree.contains(codeMapMark)
        return FileTreeResult(
            tree: tree,
            usedSelectedMarker: usedSel,
            usedCodeMapMarker: usedCM,
            wasTruncated: tree.contains(mcpTruncationMessage),
            note: nil
        )
    }

    static func generateFileTreeForRootsResult(
        rootFolders: [FolderViewModel],
        mode: String,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        includeLegend: Bool = false,
        isMCPContext: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> FileTreeResult {
        let tree = generateFileTreeForRoots(
            rootFolders: rootFolders,
            mode: mode,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            isMCPContext: isMCPContext,
            showCodeMapMarkers: showCodeMapMarkers
        )
        let usedSel = tree.contains(selectedMark)
        let usedCM = showCodeMapMarkers && tree.contains(codeMapMark)
        return FileTreeResult(
            tree: tree,
            usedSelectedMarker: usedSel,
            usedCodeMapMarker: usedCM,
            wasTruncated: tree.contains(mcpTruncationMessage),
            note: nil
        )
    }

    static func generateFileTreeStartingAtPathResult(
        startFolderFullPath: String,
        rootFolders: [FolderViewModel],
        mode: String,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID> = [],
        includeLegend: Bool = false,
        isMCPContext: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> FileTreeResult {
        let tree = generateFileTreeStartingAtPath(
            startFolderFullPath: startFolderFullPath,
            rootFolders: rootFolders,
            mode: mode,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            includeLegend: includeLegend,
            isMCPContext: isMCPContext,
            showCodeMapMarkers: showCodeMapMarkers
        )
        let usedSel = tree.contains(selectedMark)
        let usedCM = showCodeMapMarkers && tree.contains(codeMapMark)
        return FileTreeResult(
            tree: tree,
            usedSelectedMarker: usedSel,
            usedCodeMapMarker: usedCM,
            wasTruncated: tree.contains(mcpTruncationMessage),
            note: nil
        )
    }

    static func generateFileTreeForRoots(
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        maxDepth: Int?,
        includeHidden: Bool, // Note: This parameter is now ignored; visibility is handled by RepoPrompt
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool = true,
        isExplicitSubtree: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        if option == .none { return "" }
        let mode = switch option {
        case .none: "none"
        case .selected: "selected"
        case .files: "full"
        case .auto: "auto"
        }
        return generateFileTreeForRoots(
            rootFolders: rootFolders,
            mode: mode,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            isExplicitSubtree: isExplicitSubtree,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }

    /// Build the local definition block if codeMapUsage != .none,
    /// returning both the text and the count of files included.
    static func buildLocalDefinitionBlockIfNeeded(
        codeMapUsage: CodeMapUsage,
        selectedFiles: [FileViewModel],
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        rootFolders: [FolderViewModel]
    ) -> DefinitionBlockResult {
        buildLocalDefinitionBlockIfNeeded(
            codeMapUsage: codeMapUsage,
            selectedAPIs: acceptedFileAPIs(from: selectedFiles),
            selectedPaths: Set(selectedFiles.map(\.standardizedFullPath)),
            allFileAPIs: allFileAPIs,
            filePathDisplay: filePathDisplay,
            roots: codeMapRootInfos(from: rootFolders)
        )
    }

    /// Value-backed local definition builder for active/headless packaging paths.
    static func buildLocalDefinitionBlockIfNeeded(
        codeMapUsage: CodeMapUsage,
        selectedFiles: [WorkspaceFileRecord],
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        roots: [RootInfo]
    ) -> DefinitionBlockResult {
        buildLocalDefinitionBlockIfNeeded(
            codeMapUsage: codeMapUsage,
            selectedAPIs: acceptedFileAPIs(from: selectedFiles, allFileAPIs: allFileAPIs),
            selectedPaths: Set(selectedFiles.map(\.standardizedFullPath)),
            allFileAPIs: allFileAPIs,
            filePathDisplay: filePathDisplay,
            roots: roots
        )
    }

    private static func buildLocalDefinitionBlockIfNeeded(
        codeMapUsage: CodeMapUsage,
        selectedAPIs: [FileAPI],
        selectedPaths: Set<String>,
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        roots: [RootInfo]
    ) -> DefinitionBlockResult {
        guard codeMapUsage != .none else {
            return DefinitionBlockResult(text: "", fileCount: 0)
        }

        let rootFilteredAPIs = filterAPIsToCurrentRoots(allFileAPIs, roots: roots)
        let unselectedAPIs = rootFilteredAPIs.filter { !selectedPaths.contains(standardizedAPIFilePath($0)) }

        switch codeMapUsage {
        case .none:
            return DefinitionBlockResult(text: "", fileCount: 0)
        case .auto:
            return buildAutoDefinitionsBlock(
                using: selectedAPIs,
                allFileAPIs: unselectedAPIs,
                filePathDisplay: filePathDisplay,
                roots: roots
            )
        case .complete:
            let text = buildCompleteDefinitionsBlock(
                from: unselectedAPIs,
                filePathDisplay: filePathDisplay,
                roots: roots
            )
            return DefinitionBlockResult(text: text, fileCount: unselectedAPIs.count)
        case .selected:
            // In *selected* mode the FileAPI is already injected in place of the raw file-content elsewhere.
            return DefinitionBlockResult(text: "", fileCount: 0)
        }
    }

    // MARK: - Path display helpers

    @inline(__always)
    private static func standardizedAPIFilePath(_ api: FileAPI) -> String {
        StandardizedPath.absolute(api.filePath)
    }

    @inline(__always)
    private static func codeMapRootInfos(from rootFolders: [FolderViewModel]) -> [RootInfo] {
        rootFolders.map {
            RootInfo(
                standardizedRootFullPath: $0.standardizedFullPath,
                displayName: ($0.standardizedFullPath as NSString).lastPathComponent
            )
        }
    }

    private static func acceptedFileAPIs(from files: [FileViewModel]) -> [FileAPI] {
        files.compactMap { file in
            guard file.hasAcceptedCodeMap, let api = file.fileAPI else { return nil }
            return api
        }
    }

    private static func acceptedFileAPIs(from files: [WorkspaceFileRecord], allFileAPIs: [FileAPI]) -> [FileAPI] {
        guard !files.isEmpty, !allFileAPIs.isEmpty else { return [] }
        #if DEBUG || EDIT_FLOW_PERF
            let pathGrouping = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping)
            let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping, pathGrouping)
            let selectedRecordProjection = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)
            let selectedAPIs = files.compactMap { file in
                apisByPath[file.standardizedFullPath]?.first
            }
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)
            return selectedAPIs
        #else
            let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })
            return files.compactMap { file in
                apisByPath[file.standardizedFullPath]?.first
            }
        #endif
    }

    private static func acceptedFileAPIs(
        from files: [WorkspaceFileRecord],
        firstFileAPIByStandardizedNestedPath: [String: FileAPI]
    ) -> [FileAPI] {
        guard !files.isEmpty, !firstFileAPIByStandardizedNestedPath.isEmpty else { return [] }
        #if DEBUG || EDIT_FLOW_PERF
            let selectedRecordProjection = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)
            let selectedAPIs = files.compactMap { file in
                firstFileAPIByStandardizedNestedPath[file.standardizedFullPath]
            }
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)
            return selectedAPIs
        #else
            return files.compactMap { file in
                firstFileAPIByStandardizedNestedPath[file.standardizedFullPath]
            }
        #endif
    }

    private static func isUnderCurrentRoots(_ standardizedPath: String, roots: [RootInfo]) -> Bool {
        roots.contains { root in
            StandardizedPath.isDescendant(standardizedPath, of: root.standardizedRootFullPath)
        }
    }

    private static func filterAPIsToCurrentRoots(_ apis: [FileAPI], rootFolders: [FolderViewModel]) -> [FileAPI] {
        filterAPIsToCurrentRoots(apis, roots: codeMapRootInfos(from: rootFolders))
    }

    private static func filterAPIsToCurrentRoots(_ apis: [FileAPI], roots: [RootInfo]) -> [FileAPI] {
        guard !apis.isEmpty, !roots.isEmpty else { return [] }

        var seen = Set<String>()
        var filtered: [FileAPI] = []
        filtered.reserveCapacity(apis.count)
        for api in apis {
            let standardized = standardizedAPIFilePath(api)
            guard isUnderCurrentRoots(standardized, roots: roots), seen.insert(standardized).inserted else { continue }
            filtered.append(api)
        }
        return filtered
    }

    private static func displayPath(
        for absolutePath: String,
        filePathDisplay: FilePathDisplay,
        rootFolders: [FolderViewModel]
    ) -> String {
        displayPath(
            for: absolutePath,
            filePathDisplay: filePathDisplay,
            roots: codeMapRootInfos(from: rootFolders)
        )
    }

    private static func displayPath(
        for absolutePath: String,
        filePathDisplay: FilePathDisplay,
        roots: [RootInfo]
    ) -> String {
        guard filePathDisplay == .relative else { return absolutePath }
        let standardizedAbsolutePath = StandardizedPath.absolute(absolutePath)
        let matching = roots
            .filter { root in
                standardizedAbsolutePath == root.standardizedRootFullPath
                    || standardizedAbsolutePath.hasPrefix(root.standardizedRootFullPath + "/")
            }
            .sorted { $0.standardizedRootFullPath.count > $1.standardizedRootFullPath.count }

        if let root = matching.first {
            let rootAbs = root.standardizedRootFullPath
            let rel: String
            if standardizedAbsolutePath == rootAbs {
                rel = ""
            } else if standardizedAbsolutePath.hasPrefix(rootAbs + "/") {
                let start = standardizedAbsolutePath.index(rootAbs.endIndex, offsetBy: 1)
                rel = String(standardizedAbsolutePath[start...])
            } else {
                rel = standardizedAbsolutePath
            }
            if roots.count > 1 {
                return root.displayName.isEmpty ? rel : (rel.isEmpty ? root.displayName : "\(root.displayName)/\(rel)")
            } else {
                return rel
            }
        } else {
            return (standardizedAbsolutePath as NSString).lastPathComponent
        }
    }

    private static func buildCompleteDefinitionsBlock(
        from apis: [FileAPI],
        filePathDisplay: FilePathDisplay,
        rootFolders: [FolderViewModel]
    ) -> String {
        buildCompleteDefinitionsBlock(
            from: apis,
            filePathDisplay: filePathDisplay,
            roots: codeMapRootInfos(from: rootFolders)
        )
    }

    private static func buildCompleteDefinitionsBlock(
        from apis: [FileAPI],
        filePathDisplay: FilePathDisplay,
        roots: [RootInfo]
    ) -> String {
        guard !apis.isEmpty else { return "" }
        var output = "\n<Complete Definitions>"
        for api in apis {
            let shownPath = displayPath(for: api.filePath, filePathDisplay: filePathDisplay, roots: roots)
            output += "\n"
            output += api.getFullAPIDescription(displayPath: shownPath)
            output += "\n"
        }
        output += "</Complete Definitions>"
        return output
    }

    /// Returns the list of FileAPIs that are referenced by the selected files (for auto mode).
    /// This is a helper to avoid duplicating logic when we just need the file list.
    static func getAutoReferencedAPIs(
        selectedAPIs: [FileAPI],
        unselectedAPIs: [FileAPI]
    ) -> [FileAPI] {
        guard !selectedAPIs.isEmpty else { return [] }

        // Map: defined type → FileAPI
        var typeToFileAPI: [String: FileAPI] = [:]
        for api in unselectedAPIs {
            for type in api.definedTypeNames {
                typeToFileAPI[type] = api
            }
        }

        // All referenced types from selected files
        let referencedTypes = Set(selectedAPIs.flatMap(\.referencedTypes))
        let localRefs = referencedTypes.compactMap { typeToFileAPI[$0] }

        // Unique by standardized filePath (avoid duplicates if multiple types resolve to the same file)
        var seen = Set<String>()
        var included: [FileAPI] = []
        for api in localRefs {
            if seen.insert(standardizedAPIFilePath(api)).inserted {
                included.append(api)
            }
        }
        return included
    }

    /// Resolves the absolute file paths for referenced FileAPIs used when auto-including codemaps.
    static func resolveReferencedFilePaths(
        from selectedFiles: [FileViewModel],
        among allFileAPIs: [FileAPI]
    ) -> [String] {
        guard !selectedFiles.isEmpty else { return [] }

        let selectedAPIs = acceptedFileAPIs(from: selectedFiles)
        guard !selectedAPIs.isEmpty else { return [] }

        let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
        let allFileAPIPaths = allFileAPIs.map { (api: $0, standardizedPath: standardizedAPIFilePath($0)) }
        let unselectedAPIs = allFileAPIPaths.compactMap { entry in
            selectedPaths.contains(entry.standardizedPath) ? nil : entry.api
        }

        let referencedAPIs = getAutoReferencedAPIs(
            selectedAPIs: selectedAPIs,
            unselectedAPIs: unselectedAPIs
        )

        var seen = Set<String>()
        var ordered: [String] = []
        for api in referencedAPIs {
            let standardized = standardizedAPIFilePath(api)
            if seen.insert(standardized).inserted {
                ordered.append(standardized)
            }
        }

        return ordered
    }

    static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        among allFileAPIs: [FileAPI]
    ) -> [String] {
        guard !selectedFiles.isEmpty else { return [] }
        let acceptedFileAPIFilter = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter)
        let selectedAPIs = acceptedFileAPIs(from: selectedFiles, allFileAPIs: allFileAPIs)
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter, acceptedFileAPIFilter)
        return resolveReferencedFilePaths(from: selectedFiles, selectedAPIs: selectedAPIs, among: allFileAPIs)
    }

    static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        among allFileAPIs: [FileAPI],
        firstFileAPIByStandardizedNestedPath: [String: FileAPI]
    ) -> [String] {
        guard !selectedFiles.isEmpty else { return [] }
        let acceptedFileAPIFilter = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter)
        let selectedAPIs = acceptedFileAPIs(
            from: selectedFiles,
            firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath
        )
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter, acceptedFileAPIFilter)
        return resolveReferencedFilePaths(from: selectedFiles, selectedAPIs: selectedAPIs, among: allFileAPIs)
    }

    private static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        selectedAPIs: [FileAPI],
        among allFileAPIs: [FileAPI]
    ) -> [String] {
        guard !selectedAPIs.isEmpty else { return [] }

        let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
        let unselectedAPIs = allFileAPIs.filter { !selectedPaths.contains(standardizedAPIFilePath($0)) }
        let autoReferencedAPIComputation = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation)
        let referencedAPIs = getAutoReferencedAPIs(selectedAPIs: selectedAPIs, unselectedAPIs: unselectedAPIs)
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation, autoReferencedAPIComputation)

        var seen = Set<String>()
        var ordered: [String] = []
        for api in referencedAPIs {
            let standardized = standardizedAPIFilePath(api)
            if seen.insert(standardized).inserted {
                ordered.append(standardized)
            }
        }
        return ordered
    }

    /// Returns the list of file paths that have codemaps based on the specified mode.
    /// This centralizes the logic for determining which files get codemaps.
    /// Paths are displayed according to filePathDisplay (full or relative with root aliasing).
    static func getCodeMapFilePaths(
        codeMapUsage: CodeMapUsage,
        selectedFiles: [FileViewModel],
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        rootFolders: [FolderViewModel]
    ) -> [String] {
        guard codeMapUsage != .none else { return [] }

        let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
        let rootFilteredAPIs = filterAPIsToCurrentRoots(allFileAPIs, rootFolders: rootFolders)
        let allFileAPIPaths = rootFilteredAPIs.map { (api: $0, standardizedPath: standardizedAPIFilePath($0)) }
        let rootInfos = codeMapRootInfos(from: rootFolders)

        let absolutePaths: [String]
        switch codeMapUsage {
        case .selected:
            // For selected mode, codemap files are selected files with accepted FileAPIs.
            absolutePaths = acceptedFileAPIs(from: selectedFiles)
                .map(standardizedAPIFilePath)
                .sorted()

        case .auto:
            // For auto mode, only include files that are actually referenced by selected files
            let selectedAPIs = acceptedFileAPIs(from: selectedFiles)
            let unselectedAPIs = allFileAPIPaths.compactMap { entry in
                selectedPaths.contains(entry.standardizedPath) ? nil : entry.api
            }
            let referencedAPIs = getAutoReferencedAPIs(
                selectedAPIs: selectedAPIs,
                unselectedAPIs: unselectedAPIs
            )
            absolutePaths = referencedAPIs.map(standardizedAPIFilePath).sorted()

        case .complete:
            // For complete mode, all unselected files with APIs
            let unselectedAPIs = allFileAPIPaths.compactMap { entry in
                selectedPaths.contains(entry.standardizedPath) ? nil : entry.standardizedPath
            }
            absolutePaths = unselectedAPIs.sorted()

        case .none:
            return []
        }

        // Convert to display paths (relative with root aliasing if requested)
        return absolutePaths.map { absolutePath in
            displayPath(for: absolutePath, filePathDisplay: filePathDisplay, roots: rootInfos)
        }
    }

    private static func buildAutoDefinitionsBlock(
        using selectedAPIs: [FileAPI],
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        rootFolders: [FolderViewModel]
    ) -> DefinitionBlockResult {
        buildAutoDefinitionsBlock(
            using: selectedAPIs,
            allFileAPIs: allFileAPIs,
            filePathDisplay: filePathDisplay,
            roots: codeMapRootInfos(from: rootFolders)
        )
    }

    private static func buildAutoDefinitionsBlock(
        using selectedAPIs: [FileAPI],
        allFileAPIs: [FileAPI],
        filePathDisplay: FilePathDisplay,
        roots: [RootInfo]
    ) -> DefinitionBlockResult {
        if Task.isCancelled { return DefinitionBlockResult(text: "", fileCount: 0) }
        let included = getAutoReferencedAPIs(selectedAPIs: selectedAPIs, unselectedAPIs: allFileAPIs)
        guard !included.isEmpty else {
            return DefinitionBlockResult(text: "", fileCount: 0)
        }

        var output = "\n<Referenced APIs>"
        for api in included.sorted(by: { standardizedAPIFilePath($0) < standardizedAPIFilePath($1) }) {
            if Task.isCancelled { break }
            let shownPath = displayPath(for: api.filePath, filePathDisplay: filePathDisplay, roots: roots)
            output += "\n"
            output += api.getFullAPIDescription(displayPath: shownPath)
            output += "\n"
        }
        output += "</Referenced APIs>"

        return DefinitionBlockResult(text: output, fileCount: included.count)
    }

    // MARK: - Selection helpers

    /// Returns the set of `FolderViewModel.id` that lie on the path to at least one selected file.
    static func folderIDsContainingSelectedFiles(
        rootFolder: FolderViewModel,
        selectedFileIDs: Set<UUID>
    ) -> Set<UUID> {
        var result = Set<UUID>()
        var visited = Set<UUID>()

        @discardableResult
        func dfs(_ folder: FolderViewModel) -> Bool {
            if Task.isCancelled { return false }
            if !visited.insert(folder.id).inserted { return false }
            var contains = false
            for child in folder.children {
                if Task.isCancelled { return false }
                switch child {
                case let .file(file):
                    if selectedFileIDs.contains(file.id) { contains = true }
                case let .folder(subfolder):
                    if dfs(subfolder) { contains = true }
                }
            }
            if contains { result.insert(folder.id) }
            return contains
        }

        _ = dfs(rootFolder)
        return result
    }

    /// Returns `true` if the provided folder or any of its descendants contains a selected file.
    private static func folderContainsSelectedFile(
        _ folder: FolderViewModel,
        selectedFileIDs: Set<UUID>
    ) -> Bool {
        var visited = Set<UUID>()
        var stack = [folder]
        while let current = stack.popLast() {
            if Task.isCancelled { return false }
            if !visited.insert(current.id).inserted { continue }
            for child in current.children {
                switch child {
                case let .file(file):
                    if selectedFileIDs.contains(file.id) { return true }
                case let .folder(sub):
                    stack.append(sub)
                }
            }
        }
        return false
    }

    // MARK: - Subset tree helpers (NEW)

    /// Builds a file tree limited to a subset of files identified by absolute full paths.
    static func generateFileTreeForSubsetFiles(
        rootFolders: [FolderViewModel],
        subsetFullPaths: Set<String>,
        filePathDisplay: FilePathDisplay,
        includeLegend: Bool = false,
        codeMapAvailableFullPaths: Set<String> = [],
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard !subsetFullPaths.isEmpty, !rootFolders.isEmpty else { return "" }
        let roots = codeMapRootInfos(from: rootFolders)
        return generateFileTreeForSubsetPaths(
            roots: roots,
            subsetFullPaths: subsetFullPaths,
            filePathDisplay: filePathDisplay,
            selectedMarkAll: true,
            codeMapAvailableFullPaths: codeMapAvailableFullPaths,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }

    private struct SubsetNode {
        var folders: [String: SubsetNode] = [:]
        var files: [String: String] = [:] // name -> standardized full path
    }

    /// Builds a file tree limited to a subset of files identified by absolute full paths,
    /// without traversing the FolderViewModel graph.
    static func generateFileTreeForSubsetPaths(
        roots: [RootInfo],
        subsetFullPaths: Set<String>,
        filePathDisplay: FilePathDisplay,
        selectedMarkAll: Bool = true,
        codeMapAvailableFullPaths: Set<String> = [],
        includeLegend: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard !subsetFullPaths.isEmpty, !roots.isEmpty else { return "" }
        if Task.isCancelled { return "" }

        let matchingRoots = roots.sorted { $0.standardizedRootFullPath.count > $1.standardizedRootFullPath.count }
        var rootNodes: [String: SubsetNode] = [:]
        rootNodes.reserveCapacity(roots.count)

        func insertPathComponents(_ comps: [String], fullPath: String, into node: inout SubsetNode) {
            guard let head = comps.first else { return }
            if comps.count == 1 {
                node.files[head] = fullPath
                return
            }
            var child = node.folders[head] ?? SubsetNode()
            insertPathComponents(Array(comps.dropFirst()), fullPath: fullPath, into: &child)
            node.folders[head] = child
        }

        for rawPath in subsetFullPaths {
            if Task.isCancelled { break }
            let stdPath = StandardizedPath.absolute(rawPath)
            guard let root = matchingRoots.first(where: {
                stdPath == $0.standardizedRootFullPath || stdPath.hasPrefix($0.standardizedRootFullPath + "/")
            }) else { continue }

            let rootFull = root.standardizedRootFullPath
            if stdPath == rootFull { continue }
            let needsSlash = stdPath.hasPrefix(rootFull + "/")
            let startIdx = stdPath.index(stdPath.startIndex, offsetBy: rootFull.count + (needsSlash ? 1 : 0))
            let rel = String(stdPath[startIdx...])
            let comps = rel.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }

            var node = rootNodes[rootFull] ?? SubsetNode()
            insertPathComponents(comps, fullPath: stdPath, into: &node)
            rootNodes[rootFull] = node
        }

        guard !rootNodes.isEmpty else { return "" }

        let standardizedCodeMapPaths = showCodeMapMarkers
            ? Set(codeMapAvailableFullPaths.map(StandardizedPath.absolute))
            : []
        var sb = StringBuilder(reserve: 8192)
        var usedSelected = false
        var usedCodeMap = false

        func emitNode(
            _ node: SubsetNode,
            basePrefix: String
        ) {
            if Task.isCancelled { return }
            let folderNames = node.folders.keys.sorted()
            let fileNames = node.files.keys.sorted()
            let totalCount = folderNames.count + fileNames.count
            var current = 0

            for name in folderNames {
                current += 1
                let isLast = current == totalCount
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(name)")
                let nextPrefix = basePrefix + (isLast ? "    " : "│   ")
                emitNode(node.folders[name] ?? SubsetNode(), basePrefix: nextPrefix)
            }

            for name in fileNames {
                current += 1
                let isLast = current == totalCount
                let fullPath = node.files[name] ?? ""
                let marked = selectedMarkAll
                let hasMap = showCodeMapMarkers && !fullPath.isEmpty && standardizedCodeMapPaths.contains(fullPath)
                if marked { usedSelected = true }
                if hasMap { usedCodeMap = true }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
            }
        }

        let rootsWithContent = roots.filter { rootNodes[$0.standardizedRootFullPath] != nil }
        for (idx, root) in rootsWithContent.enumerated() {
            if Task.isCancelled { break }
            let rootLabel: String = if filePathDisplay == .full {
                root.standardizedRootFullPath
            } else {
                if !root.displayName.isEmpty {
                    root.displayName
                } else {
                    (root.standardizedRootFullPath as NSString).lastPathComponent
                }
            }
            sb.appendLine(rootLabel)
            if let node = rootNodes[root.standardizedRootFullPath] {
                emitNode(node, basePrefix: "")
            }
            if idx < rootsWithContent.count - 1 {
                sb.appendLine("")
            }
        }

        var text = sb.result
        if includeLegend, usedSelected || usedCodeMap {
            var legends: [String] = []
            if usedSelected { legends.append(selectedLegend) }
            if usedCodeMap { legends.append(codeMapLegend) }
            text += "\n\n" + legends.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Multi-root file tree with progressive fallbacks

    /// Builds an ASCII directory tree for multiple root folders with progressive fallbacks.
    /// Depth limiting semantics (aligned with `get_file_tree` max_depth spec):
    /// - `maxDepth == 0`: show **root + its immediate children** only (one level under root).
    /// - `maxDepth == 1`: show root, children, and grandchildren (two levels under root).
    /// - `maxDepth == 2`: show up to great‑grandchildren, and so on.
    /// Selected files are always visible (unbounded) via a selected-only pass when we reach the cap.
    /// When deeper content is hidden, we append an ellipsis summarizer (e.g. `... (N items)`).
    // REPOMARK:SCOPE: 3 - In generateFileTreeForRoots(mode:...), remove any includeHidden usage; simplify local cache function and settings init
    static func generateFileTreeForRoots(
        rootFolders: [FolderViewModel],
        mode: String,
        maxDepth userMaxDepth: Int?,
        includeHidden: Bool, // Note: This parameter is now ignored; visibility is handled by RepoPrompt
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        includeLegend: Bool = true,
        isExplicitSubtree: Bool = false,
        isMCPContext: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard !rootFolders.isEmpty else { return "" }
        if Task.isCancelled { return "" }

        // Filter roots if requested to include only those that contain selected files.
        let effectiveRoots: [FolderViewModel] = onlyIncludeRootsWithSelectedFiles
            ? rootFolders.filter { folderContainsSelectedFile($0, selectedFileIDs: selectedFileIDs) }
            : rootFolders

        guard !effectiveRoots.isEmpty else { return "" }
        if Task.isCancelled { return "" }

        let normalizedMode = mode.lowercased()
        let shouldApplyMCPBudget = isMCPContext
            && normalizedMode != "auto"
            && normalizedMode != "selected"
            && normalizedMode != "none"
        let tokenBudget = shouldApplyMCPBudget ? mcpTokenBudget : nil

        // Precompute selected-folder IDs for all roots lazily (only when needed).
        var _selectedFolderIDs: Set<UUID>? = nil
        @inline(__always)
        func selectedFolderIDs() -> Set<UUID> {
            if let s = _selectedFolderIDs { return s }
            guard !selectedFileIDs.isEmpty else { _selectedFolderIDs = []
                return []
            }
            let computed = effectiveRoots.reduce(into: Set<UUID>()) { acc, root in
                acc.formUnion(folderIDsContainingSelectedFiles(rootFolder: root, selectedFileIDs: selectedFileIDs))
            }
            _selectedFolderIDs = computed
            return computed
        }

        /// Helper for a single root; enforces depth cap and renders ellipses where content is truncated.
        func buildOnce(mode: String, depthLimit: Int?, tokenBudget: Int?) -> (tree: String, usedSelectionMarker: Bool, truncated: Bool) {
            var parts: [String] = []
            var usedSel = false
            var hitBudget = false
            var remaining = tokenBudget

            for (idx, root) in effectiveRoots.enumerated() {
                if Task.isCancelled { hitBudget = true
                    break
                }
                if let rem = remaining, rem <= 0 {
                    hitBudget = true
                    break
                }

                let (text, flag, truncated) = generateFileTreeWithDepth(
                    rootFolder: root,
                    mode: mode,
                    maxDepth: depthLimit,
                    includeHidden: false, // ignored internally
                    filePathDisplay: filePathDisplay,
                    tokenBudget: remaining,
                    selectedFileIDs: selectedFileIDs,
                    selectedFolderIDs: selectedFolderIDs(),
                    badExt: badExt,
                    badDirs: badDirs,
                    showCodeMapMarkers: showCodeMapMarkers
                )

                if !text.isEmpty {
                    parts.append(text)
                }

                usedSel = usedSel || flag

                if let rem = remaining {
                    let consumedTokens = text.isEmpty ? 0 : max(1, estimateTokens(for: text))
                    let updated = max(0, rem - consumedTokens)
                    remaining = updated
                }

                if truncated {
                    hitBudget = true
                    if remaining != nil { remaining = 0 }
                    break
                }

                if let rem = remaining, rem <= 0 {
                    hitBudget = true
                    break
                }

                if idx < effectiveRoots.count - 1, !text.isEmpty {
                    parts.append("")
                }
            }

            return (parts.joined(separator: "\n"), usedSel, hitBudget)
        }

        // Non-auto modes: single pass (depth cap honored if provided)
        if normalizedMode != "auto" {
            if let cap = userMaxDepth, cap == 0 {
                // Fast path: depth == 0
                var cache: [VCCacheKey: [FileSystemItemType]] = [:]
                var used = false
                var sb = StringBuilder(reserve: 8192)
                let outcome = buildDepthZeroTree(
                    roots: effectiveRoots,
                    settings: .init(mode: mode, filePathDisplay: filePathDisplay, siblingCap: nil, showCodeMapMarkers: showCodeMapMarkers),
                    selectedFileIDs: selectedFileIDs,
                    fetchSelectedFolderIDs: { selectedFolderIDs() },
                    childrenCache: &cache,
                    sb: &sb,
                    usedSelectedMarker: &used,
                    tokenBudget: tokenBudget
                )
                let truncatedByBudget = (tokenBudget != nil && outcome == .tooLarge)
                if case .tooLarge = outcome, tokenBudget == nil {
                    // Depth-0 should be tiny; but if budgeted earlier, just fall back to names
                    let showFull = (filePathDisplay == .full)
                    return effectiveRoots.map { showFull ? $0.fullPath : $0.name }.joined(separator: "\n")
                }
                var text = sb.result
                let usedCM = showCodeMapMarkers && text.contains(codeMapMark)
                if includeLegend {
                    if used || usedCM {
                        var legends: [String] = []
                        if used { legends.append(selectedLegend) }
                        if usedCM { legends.append(codeMapLegend) }
                        text += "\n\n" + legends.joined(separator: "\n")
                        if text.contains("\n...") {
                            text += "\n\n… indicates additional items hidden."
                        }
                    } else if text.contains("\n...") {
                        text += "\n\n… indicates additional items hidden."
                    }
                }
                var didTruncate = truncatedByBudget
                if !didTruncate, let limit = tokenBudget, estimateTokens(for: text) > limit {
                    didTruncate = true
                }
                if didTruncate {
                    appendMCPTruncationNotice(to: &text)
                }
                return text
            } else {
                let (tree, usedSel, truncated) = buildOnce(mode: mode, depthLimit: userMaxDepth, tokenBudget: tokenBudget)
                if tree.isEmpty { return tree }
                var text = tree
                let usedCM = showCodeMapMarkers && text.contains(codeMapMark)
                if includeLegend, usedSel || usedCM {
                    var legends: [String] = []
                    if usedSel { legends.append(selectedLegend) }
                    if usedCM { legends.append(codeMapLegend) }
                    text += "\n\n" + legends.joined(separator: "\n")
                }
                var didTruncate = truncated
                if !didTruncate, let limit = tokenBudget, estimateTokens(for: text) > limit {
                    didTruncate = true
                }
                if didTruncate {
                    appendMCPTruncationNotice(to: &text)
                }
                return text
            }
        }

        // AUTO: progressive fallbacks (depth limit always honored if provided)
        enum Attempt { case fullUnlimited, fullDepth3, foldersUnlimited, foldersDepth3, selectedOnly }
        let attempts: [Attempt] = [.fullUnlimited, .fullDepth3, .foldersUnlimited, .foldersDepth3, .selectedOnly]
        // Apply sibling cap for AUTO runs, except when explicitly invoked on a subtree
        let siblingCapForAuto: Int? = isExplicitSubtree ? nil : maxChildrenPerFolderAutoCap

        for attempt in attempts {
            let (modeForBuild, depthCap): (String, Int?) = {
                switch attempt {
                case .fullUnlimited:
                    return ("full", userMaxDepth)
                case .fullDepth3:
                    if let userDepth = userMaxDepth { return ("full", min(3, userDepth)) }
                    return ("full", 3)
                case .foldersUnlimited:
                    return ("folders", userMaxDepth)
                case .foldersDepth3:
                    if let userDepth = userMaxDepth { return ("folders", min(3, userDepth)) }
                    return ("folders", 3)
                case .selectedOnly:
                    // Show only the selected files (and their ancestor folders)
                    return ("selected", userMaxDepth)
                }
            }()

            var cache: [VCCacheKey: [FileSystemItemType]] = [:]
            var used = false
            var sb = StringBuilder(reserve: 16384)
            let outcome: BuildOutcome
            if let cap = depthCap, cap == 0 {
                outcome = buildDepthZeroTree(
                    roots: effectiveRoots,
                    // Depth-0 pass: the sibling cap does not apply
                    settings: .init(mode: modeForBuild, filePathDisplay: filePathDisplay, siblingCap: nil, showCodeMapMarkers: showCodeMapMarkers),
                    selectedFileIDs: selectedFileIDs,
                    fetchSelectedFolderIDs: { selectedFolderIDs() },
                    childrenCache: &cache,
                    sb: &sb,
                    usedSelectedMarker: &used,
                    tokenBudget: autoTokenBudget
                )
            } else {
                // Budget-aware multi-root emit
                var ctx = BuildContext(
                    settings: .init(mode: modeForBuild, filePathDisplay: filePathDisplay, siblingCap: siblingCapForAuto, showCodeMapMarkers: showCodeMapMarkers),
                    selectedFileIDs: selectedFileIDs,
                    getSelectedFolderIDs: { selectedFolderIDs() },
                    childrenCache: [:],
                    usedSelectedMarker: false,
                    tokenBudget: autoTokenBudget,
                    maxDepth: depthCap
                )
                outcome = {
                    // Precompute code-map IDs for all effective roots in this pass when markers are enabled.
                    let codeMapIDs = ctx.settings.showCodeMapMarkers ? collectCodeMapIDs(from: effectiveRoots) : []
                    for (idx, root) in effectiveRoots.enumerated() {
                        if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                        /// Use the same emitter as in generateFileTreeWithDepth by defining a minimal local version
                        /// Local visible-children (no hidden-file flag; rely on RepoPrompt visibility)
                        func localVisibleChildren(of folder: FolderViewModel, mode: String, selectedFileIDs: Set<UUID>, cache: inout [VCCacheKey: [FileSystemItemType]]) -> [FileSystemItemType] {
                            let m = mode.lowercased()
                            let modeKey: UInt8 = switch m {
                            case "auto": 0
                            case "full": 1
                            case "folders": 2
                            default: 1
                            }
                            let key = VCCacheKey(folderID: folder.id, mode: modeKey)
                            if let cached = cache[key] { return cached }
                            var folders: [FolderViewModel] = []
                            var files: [FileViewModel] = []
                            for child in folder.children {
                                switch child {
                                case let .folder(fo):
                                    let includeFolder: Bool = switch m {
                                    case "auto":
                                        // Rely on RepoPrompt visibility; filter out known junk dirs
                                        !badDirs.contains(fo.name.lowercased())
                                    case "full", "folders":
                                        true
                                    default:
                                        true
                                    }
                                    if includeFolder { folders.append(fo) }
                                case let .file(fi):
                                    if m == "folders" {
                                        // Keep selected files visible in folders-only
                                        if selectedFileIDs.contains(fi.id) { files.append(fi) }
                                    } else {
                                        let includeFile: Bool = {
                                            switch m {
                                            case "auto":
                                                // Rely on RepoPrompt visibility; filter by extension only
                                                if let ext = fi.fileExtension?.lowercased(), badExt.contains(ext) { return false }
                                                return true
                                            case "full":
                                                return true
                                            default:
                                                return true
                                            }
                                        }()
                                        if includeFile { files.append(fi) }
                                    }
                                }
                            }
                            folders.sort { $0.name < $1.name }
                            files.sort { $0.name < $1.name }
                            var merged: [FileSystemItemType] = []
                            merged.reserveCapacity(folders.count + files.count)
                            merged.append(contentsOf: folders.map { .folder($0) })
                            merged.append(contentsOf: files.map { .file($0) })
                            cache[key] = merged
                            return merged
                        }
                        func localEmitSelectedOnly(
                            child: FileSystemItemType,
                            basePrefix: String,
                            isLast: Bool,
                            ctx: inout BuildContext,
                            sb: inout StringBuilder,
                            visited: inout Set<UUID>
                        ) -> BuildOutcome {
                            if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                            switch child {
                            case let .file(fi):
                                let marked = ctx.selectedFileIDs.contains(fi.id)
                                let hasMap = ctx.settings.showCodeMapMarkers && codeMapIDs.contains(fi.id)
                                if marked { ctx.usedSelectedMarker = true }
                                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fi.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                                return .ok
                            case let .folder(fo):
                                if !visited.insert(fo.id).inserted { return .ok }
                                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fo.name)")
                                let nextPrefix = basePrefix + (isLast ? "    " : "│   ")
                                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                                var relevant: [FileSystemItemType] = fo.children.filter { c in
                                    switch c {
                                    case let .file(f): ctx.selectedFileIDs.contains(f.id)
                                    case let .folder(s): selectedFolderIDs.contains(s.id)
                                    }
                                }
                                relevant.sort { a, b in
                                    switch (a, b) {
                                    case (.folder, .file): true
                                    case (.file, .folder): false
                                    case let (.folder(fa), .folder(fb)):
                                        fa.name < fb.name
                                    case let (.file(fa), .file(fb)):
                                        fa.name < fb.name
                                    }
                                }
                                for (i, ch) in relevant.enumerated() {
                                    let chIsLast = i == relevant.count - 1
                                    if case .tooLarge = localEmitSelectedOnly(child: ch, basePrefix: nextPrefix, isLast: chIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                                        return .tooLarge
                                    }
                                }
                                return .ok
                            }
                        }
                        let rootIdentity = FileTreeRenderedRootIdentity(root: root)
                        func localEmit(
                            _ folder: FolderViewModel,
                            depth: Int,
                            prefix: String,
                            isRoot: Bool,
                            isLast: Bool,
                            ctx: inout BuildContext,
                            sb: inout StringBuilder,
                            visited: inout Set<UUID>
                        ) -> BuildOutcome {
                            if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                            if !visited.insert(folder.id).inserted { return .ok }
                            let m = ctx.settings.mode.lowercased()

                            let includeFolder: Bool = {
                                if m == "selected" { return isRoot || ctx.getSelectedFolderIDs().contains(folder.id) }
                                if m == "auto" {
                                    if isRoot { return true }
                                    // No hidden-file filtering; rely on RepoPrompt visibility
                                    return !badDirs.contains(folder.name.lowercased())
                                }
                                return true
                            }()
                            guard includeFolder else { return .ok }
                            let folderName = isRoot
                                ? contextualRootLabel(for: folder, within: rootIdentity, filePathDisplay: ctx.settings.filePathDisplay)
                                : folder.name
                            let linePrefix = isRoot ? "" : prefix + (isLast ? "└── " : "├── ")
                            sb.appendLine(linePrefix + folderName)
                            if let cap = ctx.maxDepth, depth > cap {
                                let childBasePrefix = prefix + (isRoot ? "" : (isLast ? "    " : "│   "))
                                let wouldInclude: [FileSystemItemType]
                                if m == "selected" {
                                    let selectedFolderIDs = ctx.getSelectedFolderIDs()
                                    var subset: [FileSystemItemType] = folder.children.filter {
                                        switch $0 {
                                        case let .file(f): ctx.selectedFileIDs.contains(f.id)
                                        case let .folder(s): selectedFolderIDs.contains(s.id)
                                        }
                                    }
                                    subset.sort { a, b in
                                        switch (a, b) {
                                        case (.folder, .file): true
                                        case (.file, .folder): false
                                        case let (.folder(fa), .folder(fb)):
                                            fa.name < fb.name
                                        case let (.file(fa), .file(fb)):
                                            fa.name < fb.name
                                        }
                                    }
                                    wouldInclude = subset
                                } else {
                                    wouldInclude = localVisibleChildren(
                                        of: folder,
                                        mode: m == "folders" ? "folders" : (m == "full" ? "full" : "auto"),
                                        selectedFileIDs: ctx.selectedFileIDs,
                                        cache: &ctx.childrenCache
                                    )
                                }
                                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                                let selectedOnly: [FileSystemItemType] = wouldInclude.filter {
                                    switch $0 {
                                    case let .file(fi): ctx.selectedFileIDs.contains(fi.id)
                                    case let .folder(fo): selectedFolderIDs.contains(fo.id)
                                    }
                                }
                                let hasOther = !wouldInclude.isEmpty && (wouldInclude.count > selectedOnly.count)
                                for (i, ch) in selectedOnly.enumerated() {
                                    let chIsLast = !hasOther && (i == selectedOnly.count - 1)
                                    if case .tooLarge = localEmitSelectedOnly(child: ch, basePrefix: childBasePrefix, isLast: chIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                                        return .tooLarge
                                    }
                                }
                                if hasOther {
                                    let ellPrefix = childBasePrefix + (selectedOnly.isEmpty ? "└── " : "├── ")
                                    sb.appendLine(ellPrefix + "...")
                                }
                                return .ok
                            }
                            let childPrefixBase = prefix + (isRoot ? "" : (isLast ? "    " : "│   "))
                            let wouldInclude: [FileSystemItemType]
                            if m == "selected" {
                                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                                var subset: [FileSystemItemType] = folder.children.filter {
                                    switch $0 {
                                    case let .file(f): ctx.selectedFileIDs.contains(f.id)
                                    case let .folder(s): selectedFolderIDs.contains(s.id)
                                    }
                                }
                                subset.sort { a, b in
                                    switch (a, b) {
                                    case (.folder, .file): true
                                    case (.file, .folder): false
                                    case let (.folder(fa), .folder(fb)):
                                        fa.name < fb.name
                                    case let (.file(fa), .file(fb)):
                                        fa.name < fb.name
                                    }
                                }
                                wouldInclude = subset
                            } else {
                                wouldInclude = localVisibleChildren(
                                    of: folder,
                                    mode: m == "folders" ? "folders" : (m == "full" ? "full" : "auto"),
                                    selectedFileIDs: ctx.selectedFileIDs,
                                    cache: &ctx.childrenCache
                                )
                            }
                            /// Selection-first + sibling cap (AUTO-only, top-level)
                            func prioritizeAndCap(_ items: [FileSystemItemType], ctx: inout BuildContext) -> (items: [FileSystemItemType], hidden: Int) {
                                let selFolderIDs = ctx.getSelectedFolderIDs()
                                var selFolders: [FileSystemItemType] = []
                                var otherFolders: [FileSystemItemType] = []
                                var selFiles: [FileSystemItemType] = []
                                var otherFiles: [FileSystemItemType] = []
                                for it in items {
                                    switch it {
                                    case let .folder(fo):
                                        if selFolderIDs.contains(fo.id) { selFolders.append(it) } else { otherFolders.append(it) }
                                    case let .file(fi):
                                        if ctx.selectedFileIDs.contains(fi.id) { selFiles.append(it) } else { otherFiles.append(it) }
                                    }
                                }
                                let prioritized = selFolders + otherFolders + selFiles + otherFiles
                                guard let cap = ctx.settings.siblingCap else {
                                    return (prioritized, 0)
                                }
                                let selectedCount = (selFolders.count + selFiles.count)
                                let allowed = max(cap, selectedCount)
                                if prioritized.count <= allowed { return (prioritized, 0) }
                                return (Array(prioritized.prefix(allowed)), prioritized.count - allowed)
                            }
                            let capResult = prioritizeAndCap(wouldInclude, ctx: &ctx)
                            let children = capResult.items
                            _ = capResult.hidden
                            for (i, node) in children.enumerated() {
                                let childIsLast = i == children.count - 1
                                switch node {
                                case let .folder(fo):
                                    if case .tooLarge = localEmit(fo, depth: depth + 1, prefix: childPrefixBase, isRoot: false, isLast: childIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                                        return .tooLarge
                                    }
                                case let .file(fi):
                                    if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                                    let marked = ctx.selectedFileIDs.contains(fi.id)
                                    let hasMap = ctx.settings.showCodeMapMarkers && codeMapIDs.contains(fi.id)
                                    if marked { ctx.usedSelectedMarker = true }
                                    sb.appendLine("\(childPrefixBase)\(childIsLast ? "└── " : "├── ")\(fi.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                                }
                            }
                            return .ok
                        }
                        var visited = Set<UUID>()
                        if case .tooLarge = localEmit(root, depth: 0, prefix: "", isRoot: true, isLast: true, ctx: &ctx, sb: &sb, visited: &visited) {
                            return .tooLarge
                        }
                        if idx < effectiveRoots.count - 1 { sb.appendLine("") }
                    }
                    used = ctx.usedSelectedMarker
                    return .ok
                }()
            }
            if case .ok = outcome {
                var text = sb.result
                let usedCM = showCodeMapMarkers && text.contains(codeMapMark)
                if estimateTokens(for: text) <= autoTokenBudget {
                    // Build a minimal note about the fallback used in AUTO
                    var noteParts: [String] = []
                    switch attempt {
                    case .fullUnlimited:
                        break
                    case .fullDepth3:
                        if let d = depthCap { noteParts.append("depth cap \(d)") }
                    case .foldersUnlimited:
                        noteParts.append("directory-only view")
                        if !selectedFileIDs.isEmpty { noteParts.append("selected files shown") }
                    case .foldersDepth3:
                        noteParts.append("directory-only view")
                        if let d = depthCap { noteParts.append("depth cap \(d)") }
                        if !selectedFileIDs.isEmpty { noteParts.append("selected files shown") }
                    case .selectedOnly:
                        noteParts.append("selected-only view")
                    }
                    // Render legends first (preserve original styling)
                    if includeLegend, used || usedCM {
                        var legends: [String] = []
                        if used { legends.append(selectedLegend) }
                        if usedCM { legends.append(codeMapLegend) }
                        text += "\n\n" + legends.joined(separator: "\n")
                    }
                    // Render a separate, clear note line if present
                    if includeLegend, !noteParts.isEmpty {
                        let noteLine = "Config: " + noteParts.joined(separator: "; ") + "."
                        // If legends were printed, add a single spacer line; otherwise a double spacer
                        let spacer = (used || usedCM) ? "\n" : "\n\n"
                        text += spacer + noteLine
                    }
                    return text
                }
            }
            // otherwise tooLarge: try next attempt
        }

        // Final fallback: list root folder names/paths only.
        let showFull = (filePathDisplay == .full)
        return effectiveRoots.map { showFull ? $0.fullPath : $0.name }.joined(separator: "\n")
    }

    /// Helper for a single root; enforces depth cap and renders ellipses where content is truncated.
    // REPOMARK:SCOPE: 4 - In generateFileTreeWithDepth(...), remove includeHidden usage and dotfile checks; rely on RepoPrompt visibility
    private static func generateFileTreeWithDepth(
        rootFolder: FolderViewModel,
        mode: String,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        tokenBudget: Int?,
        selectedFileIDs: Set<UUID>,
        selectedFolderIDs: Set<UUID>,
        badExt: Set<String>,
        badDirs: Set<String>,
        showCodeMapMarkers: Bool
    ) -> (String, Bool, Bool) {
        if Task.isCancelled { return ("", false, false) }
        var usedSelectedMarker = false
        // Precompute code-map IDs for this subtree when markers are enabled.
        let codeMapIDs = showCodeMapMarkers ? collectCodeMapIDs(from: [rootFolder]) : []

        let rootIdentity = FileTreeRenderedRootIdentity(root: rootFolder)

        /// Local cached visible children
        /// Local cached visible children (includeHidden is ignored)
        func visibleChildren(
            of folder: FolderViewModel,
            mode: String,
            selectedFileIDs: Set<UUID>,
            cache: inout [VCCacheKey: [FileSystemItemType]]
        ) -> [FileSystemItemType] {
            if Task.isCancelled { return [] }
            let m = mode.lowercased()
            let modeKey: UInt8 = switch m {
            case "auto": 0
            case "full": 1
            case "folders": 2
            default: 1
            }
            let key = VCCacheKey(folderID: folder.id, mode: modeKey)
            if let cached = cache[key] { return cached }

            var folders: [FolderViewModel] = []
            var files: [FileViewModel] = []

            for child in folder.children {
                if Task.isCancelled { break }
                switch child {
                case let .folder(fo):
                    let includeFolder: Bool = switch m {
                    case "auto":
                        // Rely on RepoPrompt visibility; filter out known junk dirs
                        !badDirs.contains(fo.name.lowercased())
                    case "full", "folders":
                        true
                    default:
                        true
                    }
                    if includeFolder { folders.append(fo) }
                case let .file(fi):
                    if m == "folders" {
                        // Keep selected files visible even in folders-only mode
                        if selectedFileIDs.contains(fi.id) { files.append(fi) }
                    } else {
                        let includeFile: Bool = {
                            switch m {
                            case "auto":
                                // Rely on RepoPrompt visibility; filter by extension only
                                if let ext = fi.fileExtension?.lowercased(), badExt.contains(ext) { return false }
                                return true
                            case "full":
                                return true
                            default:
                                return true
                            }
                        }()
                        if includeFile { files.append(fi) }
                    }
                }
            }

            folders.sort { $0.name < $1.name }
            files.sort { $0.name < $1.name }

            var merged: [FileSystemItemType] = []
            merged.reserveCapacity(folders.count + files.count)
            merged.append(contentsOf: folders.map { .folder($0) })
            merged.append(contentsOf: files.map { .file($0) })

            cache[key] = merged
            return merged
        }

        func emitSelectedOnly(
            child: FileSystemItemType,
            basePrefix: String,
            isLast: Bool,
            ctx: inout BuildContext,
            sb: inout StringBuilder,
            visited: inout Set<UUID>
        ) -> BuildOutcome {
            if Task.isCancelled { return .tooLarge }
            if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }

            switch child {
            case let .file(fi):
                let marked = ctx.selectedFileIDs.contains(fi.id)
                let hasMap = ctx.settings.showCodeMapMarkers && codeMapIDs.contains(fi.id)
                if marked { ctx.usedSelectedMarker = true }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fi.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                return .ok

            case let .folder(fo):
                if !visited.insert(fo.id).inserted { return .ok }
                sb.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(fo.name)")
                let nextPrefix = basePrefix + (isLast ? "    " : "│   ")

                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                var relevant: [FileSystemItemType] = fo.children.filter { c in
                    switch c {
                    case let .file(f): ctx.selectedFileIDs.contains(f.id)
                    case let .folder(s): selectedFolderIDs.contains(s.id)
                    }
                }
                relevant.sort { a, b in
                    switch (a, b) {
                    case (.folder, .file): true
                    case (.file, .folder): false
                    case let (.folder(fa), .folder(fb)):
                        fa.name < fb.name
                    case let (.file(fa), .file(fb)):
                        fa.name < fb.name
                    }
                }

                for (idx, ch) in relevant.enumerated() {
                    let chIsLast = idx == relevant.count - 1
                    if case .tooLarge = emitSelectedOnly(child: ch, basePrefix: nextPrefix, isLast: chIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                        return .tooLarge
                    }
                }
                return .ok
            }
        }

        func emit(
            _ folder: FolderViewModel,
            depth: Int,
            prefix: String,
            isRoot: Bool,
            isLast: Bool,
            ctx: inout BuildContext,
            sb: inout StringBuilder,
            visited: inout Set<UUID>
        ) -> BuildOutcome {
            if Task.isCancelled { return .tooLarge }
            if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
            if !visited.insert(folder.id).inserted { return .ok }

            let m = ctx.settings.mode.lowercased()

            // Folder inclusion rules
            let includeFolder: Bool = {
                if m == "selected" { return isRoot || ctx.getSelectedFolderIDs().contains(folder.id) }
                if m == "auto" {
                    if isRoot { return true }
                    // No hidden-file filtering; rely on RepoPrompt visibility
                    return !badDirs.contains(folder.name.lowercased())
                }
                // full/folders
                return true
            }()
            guard includeFolder else { return .ok }

            // Emit folder line (use contextual label for subtree root in relative mode)
            let folderName: String = if isRoot {
                contextualRootLabel(for: folder, within: rootIdentity, filePathDisplay: ctx.settings.filePathDisplay)
            } else {
                folder.name
            }

            let linePrefix = isRoot ? "" : prefix + (isLast ? "└── " : "├── ")
            sb.appendLine(linePrefix + folderName)

            // Depth cap handling
            if let cap = ctx.maxDepth, depth > cap {
                let childBasePrefix = prefix + (isRoot ? "" : (isLast ? "    " : "│   "))

                // Would include = children visible under the current (non-selected) mode
                let wouldInclude: [FileSystemItemType]
                if m == "selected" {
                    let selectedFolderIDs = ctx.getSelectedFolderIDs()
                    var subset: [FileSystemItemType] = folder.children.filter {
                        switch $0 {
                        case let .file(f): ctx.selectedFileIDs.contains(f.id)
                        case let .folder(s): selectedFolderIDs.contains(s.id)
                        }
                    }
                    subset.sort { a, b in
                        switch (a, b) {
                        case (.folder, .file): true
                        case (.file, .folder): false
                        case let (.folder(fa), .folder(fb)):
                            fa.name < fb.name
                        case let (.file(fa), .file(fb)):
                            fa.name < fb.name
                        }
                    }
                    wouldInclude = subset
                } else {
                    wouldInclude = visibleChildren(
                        of: folder,
                        mode: m == "folders" ? "folders" : (m == "full" ? "full" : "auto"),
                        selectedFileIDs: ctx.selectedFileIDs,
                        cache: &ctx.childrenCache
                    )
                }

                // Selected-only pass beyond cap
                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                let selectedOnly: [FileSystemItemType] = wouldInclude.filter {
                    switch $0 {
                    case let .file(fi): ctx.selectedFileIDs.contains(fi.id)
                    case let .folder(fo): selectedFolderIDs.contains(fo.id)
                    }
                }
                let hasOther = !wouldInclude.isEmpty && (wouldInclude.count > selectedOnly.count)

                for (idx, ch) in selectedOnly.enumerated() {
                    let chIsLast = !hasOther && (idx == selectedOnly.count - 1)
                    if case .tooLarge = emitSelectedOnly(child: ch, basePrefix: childBasePrefix, isLast: chIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                        return .tooLarge
                    }
                }

                if hasOther {
                    let ellPrefix = childBasePrefix + (selectedOnly.isEmpty ? "└── " : "├── ")
                    sb.appendLine(ellPrefix + "...")
                }
                return .ok
            }

            // Below depth cap: enumerate children
            let childPrefixBase = prefix + (isRoot ? "" : (isLast ? "    " : "│   "))

            // Children selection strategy per mode
            let wouldInclude: [FileSystemItemType]
            if m == "selected" {
                let selectedFolderIDs = ctx.getSelectedFolderIDs()
                var subset: [FileSystemItemType] = folder.children.filter {
                    switch $0 {
                    case let .file(f): ctx.selectedFileIDs.contains(f.id)
                    case let .folder(s): selectedFolderIDs.contains(s.id)
                    }
                }
                // Folder-first ordering
                subset.sort { a, b in
                    switch (a, b) {
                    case (.folder, .file): true
                    case (.file, .folder): false
                    case let (.folder(fa), .folder(fb)):
                        fa.name < fb.name
                    case let (.file(fa), .file(fb)):
                        fa.name < fb.name
                    }
                }
                wouldInclude = subset
            } else {
                wouldInclude = visibleChildren(
                    of: folder,
                    mode: m == "folders" ? "folders" : (m == "full" ? "full" : "auto"),
                    selectedFileIDs: ctx.selectedFileIDs,
                    cache: &ctx.childrenCache
                )
            }

            /// Selection-first + sibling cap (AUTO-only, top-level)
            func prioritizeAndCap(_ items: [FileSystemItemType], ctx: inout BuildContext) -> (items: [FileSystemItemType], hidden: Int) {
                let selFolderIDs = ctx.getSelectedFolderIDs()
                var selFolders: [FileSystemItemType] = []
                var otherFolders: [FileSystemItemType] = []
                var selFiles: [FileSystemItemType] = []
                var otherFiles: [FileSystemItemType] = []
                for it in items {
                    switch it {
                    case let .folder(fo):
                        if selFolderIDs.contains(fo.id) { selFolders.append(it) } else { otherFolders.append(it) }
                    case let .file(fi):
                        if selectedFileIDs.contains(fi.id) { selFiles.append(it) } else { otherFiles.append(it) }
                    }
                }
                let prioritized = selFolders + otherFolders + selFiles + otherFiles
                guard let cap = ctx.settings.siblingCap else {
                    return (prioritized, 0)
                }
                let selectedCount = (selFolders.count + selFiles.count)
                let allowed = max(cap, selectedCount)
                if prioritized.count <= allowed { return (prioritized, 0) }
                return (Array(prioritized.prefix(allowed)), prioritized.count - allowed)
            }
            let capResult = prioritizeAndCap(wouldInclude, ctx: &ctx)
            let children = capResult.items
            _ = capResult.hidden
            for (idx, node) in children.enumerated() {
                let childIsLast = idx == children.count - 1
                switch node {
                case let .folder(fo):
                    if case .tooLarge = emit(fo, depth: depth + 1, prefix: childPrefixBase, isRoot: false, isLast: childIsLast, ctx: &ctx, sb: &sb, visited: &visited) {
                        return .tooLarge
                    }
                case let .file(fi):
                    if let budget = ctx.tokenBudget, sb.estimatedTokens >= budget { return .tooLarge }
                    let marked = ctx.selectedFileIDs.contains(fi.id)
                    let hasMap = ctx.settings.showCodeMapMarkers && codeMapIDs.contains(fi.id)
                    if marked { ctx.usedSelectedMarker = true }
                    sb.appendLine("\(childPrefixBase)\(childIsLast ? "└── " : "├── ")\(fi.name)\(marked ? selectedMark : "")\(hasMap ? codeMapMark : "")")
                }
            }

            return .ok
        }

        var sb = StringBuilder(reserve: 8192)
        var ctx = BuildContext(
            settings: .init(mode: mode, filePathDisplay: filePathDisplay, siblingCap: nil, showCodeMapMarkers: showCodeMapMarkers),
            selectedFileIDs: selectedFileIDs,
            getSelectedFolderIDs: { selectedFolderIDs },
            childrenCache: [:],
            usedSelectedMarker: false,
            tokenBudget: tokenBudget,
            maxDepth: maxDepth
        )

        var visited = Set<UUID>()
        let outcome = emit(rootFolder, depth: 0, prefix: "", isRoot: true, isLast: true, ctx: &ctx, sb: &sb, visited: &visited)
        usedSelectedMarker = ctx.usedSelectedMarker
        let truncated = (tokenBudget != nil && outcome == .tooLarge)
        return (sb.result, usedSelectedMarker, truncated)
    }

    // MARK: - Single-folder starting point helpers

    /// Generate a file tree starting at a specific folder (absolute `fullPath`), using FileTreeOption.
    static func generateFileTreeStartingAtPath(
        startFolderFullPath: String,
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID> = [],
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        includeLegend: Bool = true,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard let match = findFolderWithContainingRoot(byFullPath: startFolderFullPath, in: rootFolders) else {
            return ""
        }
        let start = match.folder
        let raw = generateFileTreeForRoots(
            rootFolders: [start],
            option: option,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            isExplicitSubtree: true,
            showCodeMapMarkers: showCodeMapMarkers
        )
        // Ensure contextual root label for subtree in relative display mode.
        let targetRootLabel = contextualRootLabel(
            for: start,
            within: FileTreeRenderedRootIdentity(root: match.root),
            filePathDisplay: filePathDisplay
        )
        return patchedTreeReplacingFirstLine(raw, with: targetRootLabel)
    }

    /// Lower-level variant with explicit mode/limits.
    static func generateFileTreeStartingAtPath(
        startFolderFullPath: String,
        rootFolders: [FolderViewModel],
        mode: String,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID> = [],
        includeLegend: Bool = true,
        isMCPContext: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard let match = findFolderWithContainingRoot(byFullPath: startFolderFullPath, in: rootFolders) else {
            return ""
        }
        let start = match.folder
        let raw = generateFileTreeForRoots(
            rootFolders: [start],
            mode: mode,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: includeLegend,
            isExplicitSubtree: true,
            isMCPContext: isMCPContext,
            showCodeMapMarkers: showCodeMapMarkers
        )
        // Ensure contextual root label for subtree in relative display mode.
        let targetRootLabel = contextualRootLabel(
            for: start,
            within: FileTreeRenderedRootIdentity(root: match.root),
            filePathDisplay: filePathDisplay
        )
        return patchedTreeReplacingFirstLine(raw, with: targetRootLabel)
    }

    static func generateFileTreeStartingAtPath(
        startFolderFullPath: String,
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        maxDepth: Int?,
        includeHidden: Bool,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID> = [],
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        includeLegend: Bool = true,
        showCodeMapMarkers: Bool = true
    ) -> String {
        guard let match = findFolderWithContainingRoot(byFullPath: startFolderFullPath, in: rootFolders) else {
            return ""
        }
        let start = match.folder
        let raw = generateFileTreeForRoots(
            rootFolders: [start],
            option: option,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            isExplicitSubtree: true,
            showCodeMapMarkers: showCodeMapMarkers
        )
        // Ensure contextual root label for subtree in relative display mode.
        let targetRootLabel = contextualRootLabel(
            for: start,
            within: FileTreeRenderedRootIdentity(root: match.root),
            filePathDisplay: filePathDisplay
        )
        return patchedTreeReplacingFirstLine(raw, with: targetRootLabel)
    }

    /// DFS lookup of a FolderViewModel by absolute path, preserving the top-level root that contains it.
    private static func findFolderWithContainingRoot(
        byFullPath fullPath: String,
        in roots: [FolderViewModel]
    ) -> (folder: FolderViewModel, root: FolderViewModel)? {
        let targetPath = StandardizedPath.absolute(fullPath)
        let candidateRoots = roots
            .filter { root in
                let rootPath = root.standardizedFullPath
                return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
            }
            .sorted { $0.standardizedFullPath.count > $1.standardizedFullPath.count }

        for root in candidateRoots {
            if root.standardizedFullPath == targetPath { return (root, root) }
            var stack = [FolderViewModel]()
            var visited = Set<UUID>()
            visited.insert(root.id)
            for child in root.children {
                if case let .folder(f) = child { stack.append(f) }
            }
            while let f = stack.popLast() {
                if !visited.insert(f.id).inserted { continue }
                if f.standardizedFullPath == targetPath { return (f, root) }
                for child in f.children {
                    if case let .folder(sub) = child { stack.append(sub) }
                }
            }
        }
        return nil
    }

    // MARK: - Convenience API for FileTreeOption (existing usage)

    /// Converts FileTreeOption enum to string mode for unified implementation.
    static func generateFileTreeForRoots(
        rootFolders: [FolderViewModel],
        option: FileTreeOption,
        filePathDisplay: FilePathDisplay,
        selectedFileIDs: Set<UUID>,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool = true,
        isExplicitSubtree: Bool = false,
        showCodeMapMarkers: Bool = true
    ) -> String {
        if option == .none { return "" }

        // Preserve legacy behavior: no explicit depth cap and includeHidden = true.
        return generateFileTreeForRoots(
            rootFolders: rootFolders,
            option: option,
            maxDepth: nil,
            includeHidden: true,
            filePathDisplay: filePathDisplay,
            selectedFileIDs: selectedFileIDs,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeLegend: includeLegend,
            showCodeMapMarkers: showCodeMapMarkers
        )
    }

    // MARK: - Token estimator

    static func estimateTokens(for text: String) -> Int {
        Int(Double(text.count) * 1.05 / 4.0)
    }

    private static func appendMCPTruncationNotice(to text: inout String) {
        if text.isEmpty {
            text = mcpTruncationMessage
            return
        }

        if !text.hasSuffix("\n") {
            text.append("\n")
        }

        text.append("\n")
        text.append(mcpTruncationMessage)
    }
}

/// Canonical identity for the top-level root whose tree is currently being rendered.
/// Root labels must use this rendered/containing root rather than each node's `rootPath`,
/// because `rootPath` can be stale on synthetic or incrementally-created folder nodes.
private struct FileTreeRenderedRootIdentity {
    let standardizedFullPath: String
    let displayName: String

    init(root: FolderViewModel) {
        standardizedFullPath = root.standardizedFullPath
        let lastPathComponent = (root.standardizedFullPath as NSString).lastPathComponent
        displayName = lastPathComponent.isEmpty ? root.name : lastPathComponent
    }
}

/// Builds a contextual label for a folder root when rendering a tree/subtree.
/// - If filePathDisplay == .full, returns the folder's absolute fullPath.
/// - If .relative, returns "RootName/relative" using the actual rendered/containing root identity.
/// - Falls back to "RootName/folder.name" if the folder is not under the containing root.
private func contextualRootLabel(
    for folder: FolderViewModel,
    within rootIdentity: FileTreeRenderedRootIdentity,
    filePathDisplay: FilePathDisplay
) -> String {
    if filePathDisplay == .full {
        return folder.fullPath
    }

    let folderFull = folder.standardizedFullPath
    let rootFull = rootIdentity.standardizedFullPath
    let rootName = rootIdentity.displayName

    if folderFull == rootFull {
        return rootName.isEmpty ? folder.name : rootName
    }

    if folderFull.hasPrefix(rootFull + "/") {
        let startIdx = folderFull.index(folderFull.startIndex, offsetBy: rootFull.count + 1)
        let relPart = String(folderFull[startIdx...])
        return relPart.isEmpty ? rootName : "\(rootName)/\(relPart)"
    }

    return rootName.isEmpty ? folder.name : "\(rootName)/\(folder.name)"
}

/// Replaces the first line (root label) of an ASCII tree with a new label.
/// If the tree has a single line, it becomes the label.
private func patchedTreeReplacingFirstLine(
    _ tree: String,
    with newRootLabel: String
) -> String {
    guard !tree.isEmpty else { return tree }
    if let nl = tree.firstIndex(of: "\n") {
        let rest = tree[nl...]
        return newRootLabel + String(rest)
    } else {
        return newRootLabel
    }
}
