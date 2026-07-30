import Foundation

extension CodeMapExtractor {
    static func generateFileTree(using snapshot: FileTreeSelectionSnapshot) -> String {
        WorkspaceFileTreePresentationRenderer.render(snapshot)
    }
}

enum WorkspaceFileTreePresentationRenderer {
    static func render(_ snapshot: WorkspaceFileTreePresentationSnapshot) -> String {
        guard snapshot.mode.lowercased() != "none" else { return "" }
        guard !snapshot.roots.isEmpty else { return "" }
        if Task.isCancelled { return "" }

        let effectiveRoots = snapshot.onlyIncludeRootsWithSelectedFiles
            ? snapshot.roots.filter { snapshotFolderContainsSelectedFile($0, selectedFileIDs: snapshot.selectedFileIDs) }
            : snapshot.roots
        guard !effectiveRoots.isEmpty else { return "" }

        var cachedSelectedFolderIDs: Set<UUID>? = nil
        func selectedFolderIDs() -> Set<UUID> {
            if let cachedSelectedFolderIDs { return cachedSelectedFolderIDs }
            guard !snapshot.selectedFileIDs.isEmpty else {
                cachedSelectedFolderIDs = []
                return []
            }
            let computed = effectiveRoots.reduce(into: Set<UUID>()) { acc, root in
                acc.formUnion(snapshotFolderIDsContainingSelectedFiles(rootFolder: root, selectedFileIDs: snapshot.selectedFileIDs))
            }
            cachedSelectedFolderIDs = computed
            return computed
        }

        func buildOnce(
            mode: String,
            depthLimit: Int?,
            tokenBudget: Int?,
            siblingCap: Int?
        ) -> (tree: String, usedSelectedMarker: Bool, truncated: Bool) {
            var parts: [String] = []
            var usedSelectedMarker = false
            var hitBudget = false
            var remaining = tokenBudget

            for (index, root) in effectiveRoots.enumerated() {
                if Task.isCancelled {
                    hitBudget = true
                    break
                }
                if let remaining, remaining <= 0 {
                    hitBudget = true
                    break
                }

                let (text, usedSelection, truncated) = generateFileTreeSnapshotWithDepth(
                    rootFolder: root,
                    mode: mode,
                    maxDepth: depthLimit,
                    showFullPaths: snapshot.showFullPaths,
                    tokenBudget: remaining,
                    selectedFileIDs: snapshot.selectedFileIDs,
                    selectedFolderIDs: selectedFolderIDs(),
                    siblingCap: siblingCap,
                    showCodeMapMarkers: snapshot.showCodeMapMarkers
                )

                if !text.isEmpty {
                    parts.append(text)
                }
                usedSelectedMarker = usedSelectedMarker || usedSelection

                if let currentRemaining = remaining {
                    let consumedTokens = text.isEmpty ? 0 : max(
                        1,
                        TokenCalculationService.estimateTokens(for: text)
                    )
                    remaining = max(0, currentRemaining - consumedTokens)
                }

                if truncated {
                    hitBudget = true
                    remaining = 0
                    break
                }

                if let remaining, remaining <= 0 {
                    hitBudget = true
                    break
                }

                if index < effectiveRoots.count - 1, !text.isEmpty {
                    parts.append("")
                }
            }

            return (parts.joined(separator: "\n"), usedSelectedMarker, hitBudget)
        }

        let normalizedMode = snapshot.mode.lowercased()
        if normalizedMode != "auto" {
            let built = buildOnce(mode: snapshot.mode, depthLimit: snapshot.maxDepth, tokenBudget: nil, siblingCap: nil)
            return finalizeSnapshotTree(
                tree: built.tree,
                includeLegend: snapshot.includeLegend,
                usedSelectedMarker: built.usedSelectedMarker,
                usedCodeMapMarker: snapshot.showCodeMapMarkers && built.tree.contains(snapshotCodeMapMark)
            )
        }

        enum Attempt {
            case fullUnlimited
            case fullDepth3
            case foldersUnlimited
            case foldersDepth3
            case selectedOnly
        }

        let attempts: [Attempt] = [.fullUnlimited, .fullDepth3, .foldersUnlimited, .foldersDepth3, .selectedOnly]
        for attempt in attempts {
            let (mode, depthCap, noteParts): (String, Int?, [String]) = switch attempt {
            case .fullUnlimited:
                ("full", nil, [])
            case .fullDepth3:
                ("full", 3, ["depth cap 3"])
            case .foldersUnlimited:
                ("folders", nil, snapshot.selectedFileIDs.isEmpty ? ["directory-only view"] : ["directory-only view", "selected files shown"])
            case .foldersDepth3:
                ("folders", 3, snapshot.selectedFileIDs.isEmpty ? ["directory-only view", "depth cap 3"] : ["directory-only view", "depth cap 3", "selected files shown"])
            case .selectedOnly:
                ("selected", nil, ["selected-only view"])
            }

            let built = buildOnce(
                mode: mode,
                depthLimit: depthCap,
                tokenBudget: snapshotAutoTokenBudget,
                siblingCap: snapshotMaxChildrenPerFolderAutoCap
            )
            guard !built.tree.isEmpty else { continue }
            guard !built.truncated else { continue }

            var text = built.tree
            let usedCodeMapMarker = snapshot.showCodeMapMarkers && text.contains(snapshotCodeMapMark)
            if TokenCalculationService.estimateTokens(for: text) <= snapshotAutoTokenBudget {
                text = finalizeSnapshotTree(
                    tree: text,
                    includeLegend: snapshot.includeLegend,
                    usedSelectedMarker: built.usedSelectedMarker,
                    usedCodeMapMarker: usedCodeMapMarker
                )
                if snapshot.includeLegend, !noteParts.isEmpty {
                    let noteLine = "Config: " + noteParts.joined(separator: "; ") + "."
                    let spacer = (built.usedSelectedMarker || usedCodeMapMarker) ? "\n" : "\n\n"
                    text += spacer + noteLine
                }
                return text
            }
        }

        return effectiveRoots
            .map { snapshot.showFullPaths ? $0.fullPath : $0.name }
            .joined(separator: "\n")
    }
}

private let snapshotBadExt: Set<String> = ["o", "obj", "a", "so", "dll", "exe", "tmp", "swp"]
private let snapshotBadDirs: Set<String> = ["build", "deriveddata", "node_modules", "pods", ".git", "_git_data"]
private let snapshotAutoTokenBudget = 6000
private let snapshotMaxChildrenPerFolderAutoCap = 100
private let snapshotSelectedMark = " *"
private let snapshotCodeMapMark = " +"
private let snapshotSelectedLegend = "(* denotes selected files)"
private let snapshotCodeMapLegend = "(+ denotes code-map available)"

private struct SnapshotStringBuilder {
    private(set) var estimatedTokens: Int = 0
    private var storage = ""

    init(reserve: Int = 0) {
        if reserve > 0 {
            storage.reserveCapacity(reserve)
        }
    }

    mutating func appendLine(_ line: String) {
        storage.append(line)
        storage.append("\n")
        estimatedTokens += Int((Double(line.count + 1) * 1.05) / 4.0)
    }

    var result: String {
        storage
    }
}

private func finalizeSnapshotTree(
    tree: String,
    includeLegend: Bool,
    usedSelectedMarker: Bool,
    usedCodeMapMarker: Bool
) -> String {
    guard includeLegend else { return tree }
    guard usedSelectedMarker || usedCodeMapMarker else { return tree }

    var legends: [String] = []
    if usedSelectedMarker { legends.append(snapshotSelectedLegend) }
    if usedCodeMapMarker { legends.append(snapshotCodeMapLegend) }
    return tree + "\n\n" + legends.joined(separator: "\n")
}

private func snapshotNodeSort(_ lhs: FileTreeNodeSnapshot, _ rhs: FileTreeNodeSnapshot) -> Bool {
    switch (lhs, rhs) {
    case (.folder, .file):
        true
    case (.file, .folder):
        false
    default:
        lhs.name < rhs.name
    }
}

private func visibleChildren(
    of folder: FileTreeFolderSnapshot,
    mode: String,
    selectedFileIDs: Set<UUID>
) -> [FileTreeNodeSnapshot] {
    let normalizedMode = mode.lowercased()
    var folders: [FileTreeNodeSnapshot] = []
    var files: [FileTreeNodeSnapshot] = []

    for child in folder.children {
        if Task.isCancelled { break }
        switch child {
        case let .folder(subfolder):
            let includeFolder: Bool = switch normalizedMode {
            case "auto":
                !snapshotBadDirs.contains(subfolder.name.lowercased())
            default:
                true
            }
            if includeFolder {
                folders.append(child)
            }
        case let .file(file):
            if normalizedMode == "folders" {
                if selectedFileIDs.contains(file.id) {
                    files.append(child)
                }
            } else {
                let includeFile = switch normalizedMode {
                case "auto":
                    if let ext = file.fileExtension?.lowercased(), snapshotBadExt.contains(ext) {
                        false
                    } else {
                        true
                    }
                default:
                    true
                }
                if includeFile {
                    files.append(child)
                }
            }
        }
    }

    return (folders + files).sorted(by: snapshotNodeSort)
}

private func selectedChildren(
    of folder: FileTreeFolderSnapshot,
    selectedFileIDs: Set<UUID>,
    selectedFolderIDs: Set<UUID>
) -> [FileTreeNodeSnapshot] {
    folder.children
        .filter { child in
            switch child {
            case let .file(file):
                selectedFileIDs.contains(file.id)
            case let .folder(subfolder):
                selectedFolderIDs.contains(subfolder.id)
            }
        }
        .sorted(by: snapshotNodeSort)
}

private func prioritizeAndCap(
    _ items: [FileTreeNodeSnapshot],
    selectedFileIDs: Set<UUID>,
    selectedFolderIDs: Set<UUID>,
    siblingCap: Int?
) -> [FileTreeNodeSnapshot] {
    var selectedFolders: [FileTreeNodeSnapshot] = []
    var otherFolders: [FileTreeNodeSnapshot] = []
    var selectedFiles: [FileTreeNodeSnapshot] = []
    var otherFiles: [FileTreeNodeSnapshot] = []

    for item in items {
        switch item {
        case let .folder(folder):
            if selectedFolderIDs.contains(folder.id) {
                selectedFolders.append(item)
            } else {
                otherFolders.append(item)
            }
        case let .file(file):
            if selectedFileIDs.contains(file.id) {
                selectedFiles.append(item)
            } else {
                otherFiles.append(item)
            }
        }
    }

    let prioritized = selectedFolders + otherFolders + selectedFiles + otherFiles
    guard let siblingCap else { return prioritized }

    let selectedCount = selectedFolders.count + selectedFiles.count
    let allowed = max(siblingCap, selectedCount)
    guard prioritized.count > allowed else { return prioritized }
    return Array(prioritized.prefix(allowed))
}

private func snapshotFolderIDsContainingSelectedFiles(
    rootFolder: FileTreeFolderSnapshot,
    selectedFileIDs: Set<UUID>
) -> Set<UUID> {
    var result = Set<UUID>()
    var visited = Set<UUID>()

    @discardableResult
    func dfs(_ folder: FileTreeFolderSnapshot) -> Bool {
        if Task.isCancelled { return false }
        guard visited.insert(folder.id).inserted else { return false }

        var contains = false
        for child in folder.children {
            if Task.isCancelled { return false }
            switch child {
            case let .file(file):
                if selectedFileIDs.contains(file.id) {
                    contains = true
                }
            case let .folder(subfolder):
                if dfs(subfolder) {
                    contains = true
                }
            }
        }

        if contains {
            result.insert(folder.id)
        }
        return contains
    }

    _ = dfs(rootFolder)
    return result
}

private func snapshotFolderContainsSelectedFile(
    _ folder: FileTreeFolderSnapshot,
    selectedFileIDs: Set<UUID>
) -> Bool {
    var visited = Set<UUID>()
    var stack = [folder]

    while let current = stack.popLast() {
        if Task.isCancelled { return false }
        guard visited.insert(current.id).inserted else { continue }

        for child in current.children {
            switch child {
            case let .file(file):
                if selectedFileIDs.contains(file.id) {
                    return true
                }
            case let .folder(subfolder):
                stack.append(subfolder)
            }
        }
    }

    return false
}

private func generateFileTreeSnapshotWithDepth(
    rootFolder: FileTreeFolderSnapshot,
    mode: String,
    maxDepth: Int?,
    showFullPaths: Bool,
    tokenBudget: Int?,
    selectedFileIDs: Set<UUID>,
    selectedFolderIDs: Set<UUID>,
    siblingCap: Int?,
    showCodeMapMarkers: Bool
) -> (String, Bool, Bool) {
    var usedSelectedMarker = false
    let codeMapIDs = showCodeMapMarkers ? collectCodeMapIDs(from: [rootFolder]) : []
    let normalizedMode = mode.lowercased()

    func emitSelectedOnly(
        _ node: FileTreeNodeSnapshot,
        basePrefix: String,
        isLast: Bool,
        builder: inout SnapshotStringBuilder,
        visited: inout Set<UUID>
    ) -> Bool {
        if Task.isCancelled { return true }
        if let tokenBudget, builder.estimatedTokens >= tokenBudget { return true }

        switch node {
        case let .file(file):
            let marked = selectedFileIDs.contains(file.id)
            if marked { usedSelectedMarker = true }
            let hasCodeMap = showCodeMapMarkers && codeMapIDs.contains(file.id)
            builder.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(file.name)\(marked ? snapshotSelectedMark : "")\(hasCodeMap ? snapshotCodeMapMark : "")")
            return false
        case let .folder(folder):
            guard visited.insert(folder.id).inserted else { return false }
            builder.appendLine("\(basePrefix)\(isLast ? "└── " : "├── ")\(folder.name)")
            let nextPrefix = basePrefix + (isLast ? "    " : "│   ")
            let relevant = selectedChildren(
                of: folder,
                selectedFileIDs: selectedFileIDs,
                selectedFolderIDs: selectedFolderIDs
            )
            for (index, child) in relevant.enumerated() {
                if emitSelectedOnly(
                    child,
                    basePrefix: nextPrefix,
                    isLast: index == relevant.count - 1,
                    builder: &builder,
                    visited: &visited
                ) {
                    return true
                }
            }
            return false
        }
    }

    func emit(
        _ folder: FileTreeFolderSnapshot,
        depth: Int,
        prefix: String,
        isRoot: Bool,
        isLast: Bool,
        builder: inout SnapshotStringBuilder,
        visited: inout Set<UUID>
    ) -> Bool {
        if Task.isCancelled { return true }
        if let tokenBudget, builder.estimatedTokens >= tokenBudget { return true }
        guard visited.insert(folder.id).inserted else { return false }

        let includeFolder: Bool = {
            if normalizedMode == "selected" {
                return isRoot || selectedFolderIDs.contains(folder.id)
            }
            if normalizedMode == "auto" {
                return isRoot || !snapshotBadDirs.contains(folder.name.lowercased())
            }
            return true
        }()
        guard includeFolder else { return false }

        let folderName = isRoot
            ? contextualRootLabel(for: folder, showFullPaths: showFullPaths)
            : folder.name
        let linePrefix = isRoot ? "" : prefix + (isLast ? "└── " : "├── ")
        builder.appendLine(linePrefix + folderName)

        let childPrefixBase = prefix + (isRoot ? "" : (isLast ? "    " : "│   "))
        let wouldInclude = normalizedMode == "selected"
            ? selectedChildren(of: folder, selectedFileIDs: selectedFileIDs, selectedFolderIDs: selectedFolderIDs)
            : visibleChildren(of: folder, mode: normalizedMode, selectedFileIDs: selectedFileIDs)

        if let maxDepth, depth > maxDepth {
            let selectedOnly = wouldInclude.filter { child in
                switch child {
                case let .file(file):
                    selectedFileIDs.contains(file.id)
                case let .folder(subfolder):
                    selectedFolderIDs.contains(subfolder.id)
                }
            }
            let hasOther = !wouldInclude.isEmpty && wouldInclude.count > selectedOnly.count
            for (index, child) in selectedOnly.enumerated() {
                if emitSelectedOnly(
                    child,
                    basePrefix: childPrefixBase,
                    isLast: !hasOther && index == selectedOnly.count - 1,
                    builder: &builder,
                    visited: &visited
                ) {
                    return true
                }
            }
            if hasOther {
                let ellipsisPrefix = childPrefixBase + (selectedOnly.isEmpty ? "└── " : "├── ")
                builder.appendLine(ellipsisPrefix + "...")
            }
            return false
        }

        let children = prioritizeAndCap(
            wouldInclude,
            selectedFileIDs: selectedFileIDs,
            selectedFolderIDs: selectedFolderIDs,
            siblingCap: siblingCap
        )

        for (index, child) in children.enumerated() {
            let childIsLast = index == children.count - 1
            switch child {
            case let .folder(subfolder):
                if emit(
                    subfolder,
                    depth: depth + 1,
                    prefix: childPrefixBase,
                    isRoot: false,
                    isLast: childIsLast,
                    builder: &builder,
                    visited: &visited
                ) {
                    return true
                }
            case let .file(file):
                if let tokenBudget, builder.estimatedTokens >= tokenBudget { return true }
                let marked = selectedFileIDs.contains(file.id)
                if marked { usedSelectedMarker = true }
                let hasCodeMap = showCodeMapMarkers && codeMapIDs.contains(file.id)
                builder.appendLine("\(childPrefixBase)\(childIsLast ? "└── " : "├── ")\(file.name)\(marked ? snapshotSelectedMark : "")\(hasCodeMap ? snapshotCodeMapMark : "")")
            }
        }
        return false
    }

    var builder = SnapshotStringBuilder(reserve: 8192)
    var visited = Set<UUID>()
    let truncated = emit(
        rootFolder,
        depth: 0,
        prefix: "",
        isRoot: true,
        isLast: true,
        builder: &builder,
        visited: &visited
    )

    return (builder.result, usedSelectedMarker, truncated)
}

private func collectCodeMapIDs(from roots: [FileTreeFolderSnapshot]) -> Set<UUID> {
    var ids = Set<UUID>()
    var visited = Set<UUID>()
    var stack = roots

    while let folder = stack.popLast() {
        if Task.isCancelled { break }
        guard visited.insert(folder.id).inserted else { continue }

        for child in folder.children {
            if Task.isCancelled { break }
            switch child {
            case let .file(file):
                if file.hasCodeMap {
                    ids.insert(file.id)
                }
            case let .folder(subfolder):
                stack.append(subfolder)
            }
        }
    }

    return ids
}

private func contextualRootLabel(
    for folder: FileTreeFolderSnapshot,
    showFullPaths: Bool
) -> String {
    if showFullPaths {
        return folder.fullPath
    }

    let rootName = (folder.standardizedRootPath as NSString).lastPathComponent
    if folder.standardizedFullPath == folder.standardizedRootPath {
        return rootName.isEmpty ? folder.name : rootName
    }

    if folder.standardizedFullPath.hasPrefix(folder.standardizedRootPath + "/") {
        let startIndex = folder.standardizedFullPath.index(
            folder.standardizedFullPath.startIndex,
            offsetBy: folder.standardizedRootPath.count + 1
        )
        let relativePart = String(folder.standardizedFullPath[startIndex...])
        return relativePart.isEmpty ? rootName : "\(rootName)/\(relativePart)"
    }

    return rootName.isEmpty ? folder.name : "\(rootName)/\(folder.name)"
}
