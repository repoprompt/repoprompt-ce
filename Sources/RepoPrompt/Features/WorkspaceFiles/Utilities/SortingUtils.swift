import Foundation
import RepoPromptWorkspaceContext

enum SortMethod: String, CaseIterable {
    case nameAscending
    case nameDescending
    case extensionAscending
    case extensionDescending
    case dateNewest
    case dateOldest
    case tokenAscending
    case tokenDescending

    static var selectedFilesAllowed: [SortMethod] {
        [
            .nameAscending,
            .nameDescending,
            .tokenAscending,
            .tokenDescending
        ]
    }

    static var fileTreeAllowed: [SortMethod] {
        [
            .nameAscending,
            .nameDescending,
            .extensionAscending,
            .extensionDescending,
            .dateNewest,
            .dateOldest
        ]
    }

    var icon: String {
        switch self {
        case .nameAscending:
            "arrow.up"
        case .nameDescending:
            "arrow.down"
        case .extensionAscending:
            "arrow.up.doc"
        case .extensionDescending:
            "arrow.down.doc"
        case .dateNewest:
            "arrow.down.circle"
        case .dateOldest:
            "arrow.up.circle"
        case .tokenAscending:
            "chart.bar"
        case .tokenDescending:
            "chart.bar.fill"
        }
    }

    var displayName: String {
        switch self {
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .extensionAscending: "Extension (A–Z)"
        case .extensionDescending: "Extension (Z–A)"
        case .dateNewest: "Date (Newest)"
        case .dateOldest: "Date (Oldest)"
        case .tokenAscending: "Tokens (Low–High)"
        case .tokenDescending: "Tokens (High–Low)"
        }
    }
}

func sortItems(_ items: [FileSystemItemType], by method: SortMethod) -> [FileSystemItemType] {
    let (folders, files) = items.reduce(into: ([FileSystemItemType](), [FileSystemItemType]())) { result, item in
        switch item {
        case .folder:
            result.0.append(item)
        case .file:
            result.1.append(item)
        }
    }

    let sortedFolders = folders.sorted { lhs, rhs in
        guard case let .folder(lhsFolder) = lhs, case let .folder(rhsFolder) = rhs else { return false }
        return compare(lhsFolder, rhsFolder, by: method)
    }

    let sortedFiles = files.sorted { lhs, rhs in
        guard case let .file(lhsFile) = lhs, case let .file(rhsFile) = rhs else { return false }
        return compare(lhsFile, rhsFile, by: method)
    }

    return sortedFolders + sortedFiles
}

func compare<T: FileSystemItemViewModel>(_ lhs: T, _ rhs: T, by method: SortMethod) -> Bool {
    switch method {
    case .nameAscending:
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey < rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.relativePath < rhs.relativePath
    case .nameDescending:
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey > rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name > rhs.name
        }
        return lhs.relativePath > rhs.relativePath
    case .extensionAscending:
        let leftExt = lhs.fileExtension ?? ""
        let rightExt = rhs.fileExtension ?? ""
        if leftExt != rightExt {
            return leftExt < rightExt
        }
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey < rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.relativePath < rhs.relativePath
    case .extensionDescending:
        let leftExt = lhs.fileExtension ?? ""
        let rightExt = rhs.fileExtension ?? ""
        if leftExt != rightExt {
            return leftExt > rightExt
        }
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey > rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name > rhs.name
        }
        return lhs.relativePath > rhs.relativePath
    case .dateNewest:
        // Add name tie-breaker for deterministic sorting when dates are equal
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate > rhs.modificationDate
        }
        // For _git_data date folders (YYYY-MM-DD), reverse name sort gives newest first
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey > rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name > rhs.name
        }
        return lhs.relativePath > rhs.relativePath
    case .dateOldest:
        // Add name tie-breaker for deterministic sorting when dates are equal
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate < rhs.modificationDate
        }
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey < rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.relativePath < rhs.relativePath
    case .tokenAscending:
        // For general file system items, fall back to name sorting
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey < rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.relativePath < rhs.relativePath
    case .tokenDescending:
        // For general file system items, fall back to name sorting
        if lhs.nameSortKey != rhs.nameSortKey {
            return lhs.nameSortKey > rhs.nameSortKey
        }
        if lhs.name != rhs.name {
            return lhs.name > rhs.name
        }
        return lhs.relativePath > rhs.relativePath
    }
}

/// Returns the insertion index for `element` in a pre-sorted array.
/// - Important: `compare` must define a strict total order for `method`.
func insertionIndex<T: FileSystemItemViewModel>(of element: T, in sorted: [T], by method: SortMethod) -> Int {
    var low = 0
    var high = sorted.count

    while low < high {
        let mid = (low + high) / 2
        if compare(element, sorted[mid], by: method) {
            high = mid
        } else {
            low = mid + 1
        }
    }
    return low
}

extension String {
    var fileExtension: String? {
        let components = components(separatedBy: ".")
        return components.count > 1 ? components.last : nil
    }
}

func sortSelectedFiles(
    _ files: [FileViewModel],
    by method: SortMethod,
    tokenInfo: [UUID: TokenInfo]
) -> [FileViewModel] {
    files.sorted { lhs, rhs in
        switch method {
        case .nameAscending:
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey < rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey < rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath < rhs.uniqueRelativePath
        case .nameDescending:
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey > rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name > rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey > rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath > rhs.uniqueRelativePath
        case .extensionAscending:
            let leftExt = lhs.fileExtension ?? ""
            let rightExt = rhs.fileExtension ?? ""
            if leftExt != rightExt {
                return leftExt < rightExt
            }
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey < rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey < rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath < rhs.uniqueRelativePath
        case .extensionDescending:
            let leftExt = lhs.fileExtension ?? ""
            let rightExt = rhs.fileExtension ?? ""
            if leftExt != rightExt {
                return leftExt > rightExt
            }
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey > rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name > rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey > rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath > rhs.uniqueRelativePath
        case .dateNewest:
            return lhs.modificationDate > rhs.modificationDate
        case .dateOldest:
            return lhs.modificationDate < rhs.modificationDate
        case .tokenAscending:
            let leftTokens = tokenInfo[lhs.id]?.count ?? 0
            let rightTokens = tokenInfo[rhs.id]?.count ?? 0
            if leftTokens != rightTokens {
                return leftTokens < rightTokens
            }
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey < rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey < rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath < rhs.uniqueRelativePath
        case .tokenDescending:
            let lhsTokens = tokenInfo[lhs.id]?.count ?? 0
            let rhsTokens = tokenInfo[rhs.id]?.count ?? 0
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            if lhs.nameSortKey != rhs.nameSortKey {
                return lhs.nameSortKey > rhs.nameSortKey
            }
            if lhs.name != rhs.name {
                return lhs.name > rhs.name
            }
            if lhs.uniqueRelativePathSortKey != rhs.uniqueRelativePathSortKey {
                return lhs.uniqueRelativePathSortKey > rhs.uniqueRelativePathSortKey
            }
            return lhs.uniqueRelativePath > rhs.uniqueRelativePath
        }
    }
}

func sortFolderItems(
    _ folderItems: [FileTreeItem],
    by method: SortMethod,
    folderTokenInfo: [String: TokenInfo]
) -> [FileTreeItem] {
    folderItems.sorted { lhs, rhs in
        switch (lhs, rhs) {
        case let (.folder(pathL, _), .folder(pathR, _)):
            let lTokens = folderTokenInfo[pathL]?.count ?? 0
            let rTokens = folderTokenInfo[pathR]?.count ?? 0

            switch method {
            case .tokenAscending:
                return lTokens < rTokens
            case .tokenDescending:
                return lTokens > rTokens
            case .nameAscending:
                return pathL < pathR
            case .nameDescending:
                return pathL > pathR
            default:
                return pathL < pathR
            }

        case (.folder, .file), (.file, .folder):
            return false

        case (.file, .file):
            return false
        }
    }
}
