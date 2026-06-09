import Foundation
import RepoPromptC

package enum SearchPathClause: Equatable {
    case exactFile(absPath: String, relPath: String, restrictedRootPath: String?)
    case exactFolder(absLower: String, relLower: String, restrictedRootPath: String?)
    case glob(pattern: String, restrictedRootPath: String?)
    case legacyPrefix(candidateLower: String)
}

package struct SearchPathFilterSpec: Equatable {
    package let caseInsensitive: Bool
    package let clauses: [SearchPathClause]

    package init(caseInsensitive: Bool, clauses: [SearchPathClause]) {
        self.caseInsensitive = caseInsensitive
        self.clauses = clauses
    }
}

package struct FileSearchPathSnapshot {
    package let standardizedFullPath: String
    package let standardizedRelativePath: String
    package let standardizedRootPath: String
    package let clientDisplayPath: String

    package init(
        standardizedFullPath: String,
        standardizedRelativePath: String,
        standardizedRootPath: String,
        clientDisplayPath: String
    ) {
        self.standardizedFullPath = standardizedFullPath
        self.standardizedRelativePath = standardizedRelativePath
        self.standardizedRootPath = standardizedRootPath
        self.clientDisplayPath = clientDisplayPath
    }
}

package struct FileSearchPathFilterResult: Equatable {
    package let matchedFullPaths: [String]
    package let visitedSnapshotCount: Int
    package let cancelled: Bool
}

/// Index-returning variant of `FileSearchPathFilterResult`. `matchedSnapshotIndices`
/// holds indices into the input `snapshots` array, in snapshot iteration order, with
/// each snapshot appearing at most once. Lets callers map matches directly back to
/// their source array without a full-path string round trip.
package struct FileSearchPathIndexFilterResult: Equatable {
    package let matchedSnapshotIndices: [Int]
    package let visitedSnapshotCount: Int
    package let cancelled: Bool
}

@inline(__always)
private func globMatch(_ pattern: String, _ text: String, _ caseInsensitive: Bool) -> Bool {
    let WM_CASEFOLD: UInt32 = 0x10
    let WM_WILDSTAR: UInt32 = 0x40
    let flags: UInt32 = (pattern.contains("**") ? WM_WILDSTAR : 0)
        | (caseInsensitive ? WM_CASEFOLD : 0)
    return pattern.withCString { pC in
        text.withCString { tC in
            repo_wildmatch(pC, tC, flags) == 0
        }
    }
}

@inline(__always)
private func hasExactOrAncestorMatch(_ prefix: String, in path: String) -> Bool {
    path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
}

private enum CompiledSearchPathClause {
    case exactFile(absPath: String, relPath: String, restrictedRootPath: String?)
    case exactFolder(absLower: String, absPrefix: String, relLower: String, relPrefix: String, restrictedRootPath: String?)
    case glob(pattern: String, restrictedRootPath: String?)
    case legacyPrefix(candidateLower: String, normalizedPrefix: String)
}

private func compileSearchPathClauses(_ clauses: [SearchPathClause]) -> [CompiledSearchPathClause] {
    clauses.map { clause in
        switch clause {
        case let .exactFile(absPath, relPath, restrictedRootPath):
            .exactFile(absPath: absPath, relPath: relPath, restrictedRootPath: restrictedRootPath)
        case let .exactFolder(absLower, relLower, restrictedRootPath):
            .exactFolder(
                absLower: absLower,
                absPrefix: absLower.hasSuffix("/") ? absLower : absLower + "/",
                relLower: relLower,
                relPrefix: relLower.hasSuffix("/") ? relLower : relLower + "/",
                restrictedRootPath: restrictedRootPath
            )
        case let .glob(pattern, restrictedRootPath):
            .glob(pattern: pattern, restrictedRootPath: restrictedRootPath)
        case let .legacyPrefix(candidateLower):
            .legacyPrefix(
                candidateLower: candidateLower,
                normalizedPrefix: candidateLower.hasSuffix("/") ? candidateLower : candidateLower + "/"
            )
        }
    }
}

package func filterPaths(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec
) -> [String] {
    filterPathsResult(snapshots: snapshots, spec: spec).matchedFullPaths
}

package func filterPathsResult(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec
) -> FileSearchPathFilterResult {
    let indexResult = filterPathIndicesResult(snapshots: snapshots, spec: spec)
    var results: [String] = []
    results.reserveCapacity(indexResult.matchedSnapshotIndices.count)
    for index in indexResult.matchedSnapshotIndices {
        results.append(snapshots[index].standardizedFullPath)
    }
    return FileSearchPathFilterResult(
        matchedFullPaths: results,
        visitedSnapshotCount: indexResult.visitedSnapshotCount,
        cancelled: indexResult.cancelled
    )
}

/// Core scoped-path filter loop. Returns matched snapshot indices (in input order,
/// deduplicated) plus visited/cancellation metadata. Lowercase path variants are
/// computed lazily per snapshot so exact-file and glob clauses — which never need
/// them — do not pay for lowercasing.
package func filterPathIndicesResult(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec
) -> FileSearchPathIndexFilterResult {
    var indices: [Int] = []
    indices.reserveCapacity(snapshots.count)
    let compiledClauses = compileSearchPathClauses(spec.clauses)
    var visitedSnapshotCount = 0
    var cancelled = false

    for index in snapshots.indices {
        if Task.isCancelled {
            cancelled = true
            break
        }
        visitedSnapshotCount += 1

        let snapshot = snapshots[index]
        let rel = snapshot.standardizedRelativePath
        let full = snapshot.standardizedFullPath
        let root = snapshot.standardizedRootPath
        let clientDisplay = snapshot.clientDisplayPath

        // Lazy lowercase caches: only exact-folder and legacy-prefix clauses need these.
        var relLowerCache: String? = nil
        var fullLowerCache: String? = nil
        var displayLowerCache: String? = nil
        func relLower() -> String {
            if let cached = relLowerCache { return cached }
            let value = rel.lowercased()
            relLowerCache = value
            return value
        }
        func fullLower() -> String {
            if let cached = fullLowerCache { return cached }
            let value = full.lowercased()
            fullLowerCache = value
            return value
        }
        func displayLower() -> String {
            if let cached = displayLowerCache { return cached }
            let value = clientDisplay.lowercased()
            displayLowerCache = value
            return value
        }

        var matched = false
        for clause in compiledClauses {
            switch clause {
            case let .exactFile(absPath, relPath, restrictedRootPath):
                if full == absPath {
                    matched = true
                } else if rel == relPath,
                          restrictedRootPath == nil || restrictedRootPath == root
                {
                    matched = true
                }
            case let .exactFolder(absLower, absPrefix, relLowerClause, relPrefix, restrictedRootPath):
                guard restrictedRootPath == nil || restrictedRootPath == root else { continue }
                let fl = fullLower()
                if fl == absLower || fl.hasPrefix(absPrefix) {
                    matched = true
                } else {
                    let rl = relLower()
                    if rl == relLowerClause || rl.hasPrefix(relPrefix) {
                        matched = true
                    }
                }
            case let .glob(pattern, restrictedRootPath):
                if let restrictedRootPath, restrictedRootPath != root {
                    continue
                }
                if globMatch(pattern, clientDisplay, spec.caseInsensitive)
                    || globMatch(pattern, rel, spec.caseInsensitive)
                    || globMatch(pattern, full, spec.caseInsensitive)
                {
                    matched = true
                }
            case let .legacyPrefix(candidateLower, normalizedPrefix):
                guard !candidateLower.isEmpty else { continue }
                let rl = relLower()
                let dl = displayLower()
                let fl = fullLower()
                if rl == candidateLower || dl == candidateLower || fl == candidateLower {
                    matched = true
                } else if rl.hasPrefix(normalizedPrefix)
                    || dl.hasPrefix(normalizedPrefix)
                    || fl.hasPrefix(normalizedPrefix)
                {
                    matched = true
                }
            }
            if matched {
                indices.append(index)
                break
            }
        }
    }

    return FileSearchPathIndexFilterResult(
        matchedSnapshotIndices: indices,
        visitedSnapshotCount: visitedSnapshotCount,
        cancelled: cancelled
    )
}

// MARK: - Folder fragment resolution (filter.paths)

private let folderSuffixSlashTrim = CharacterSet(charactersIn: "/")

@inline(__always)
package func normalizedFolderSuffixFragment(_ fragment: String, caseInsensitive: Bool = true) -> String? {
    let standardized = (fragment as NSString).standardizingPath as String
    let trimmed = standardized.trimmingCharacters(in: folderSuffixSlashTrim)
    guard !trimmed.isEmpty else { return nil }
    return caseInsensitive ? trimmed.lowercased() : trimmed
}

package struct SearchFolderSuffixIndexEntry<T> {
    package let folder: T
    package let normalizedRelativePath: String
}

package typealias SearchFolderSuffixIndex<T> = [String: [SearchFolderSuffixIndexEntry<T>]]

package func buildFolderSuffixIndex<T>(
    in foldersByFullPath: [String: T],
    relativePath: (T) -> String,
    caseInsensitive: Bool = true
) -> SearchFolderSuffixIndex<T> {
    var index: SearchFolderSuffixIndex<T> = [:]
    index.reserveCapacity(max(16, foldersByFullPath.count / 2))

    for (_, folder) in foldersByFullPath {
        guard let normalizedRel = normalizedFolderSuffixFragment(relativePath(folder), caseInsensitive: caseInsensitive),
              let lastComponent = normalizedRel.split(separator: "/").last.map(String.init),
              !lastComponent.isEmpty
        else {
            continue
        }
        index[lastComponent, default: []].append(SearchFolderSuffixIndexEntry(
            folder: folder,
            normalizedRelativePath: normalizedRel
        ))
    }

    return index
}

package func resolveFoldersBySuffixFragment<T>(
    _ fragment: String,
    using suffixIndex: SearchFolderSuffixIndex<T>,
    caseInsensitive: Bool = true
) -> [T] {
    guard let candidate = normalizedFolderSuffixFragment(fragment, caseInsensitive: caseInsensitive),
          let lastComponent = candidate.split(separator: "/").last.map(String.init)
    else {
        return []
    }
    guard let candidates = suffixIndex[lastComponent], !candidates.isEmpty else { return [] }

    let boundarySuffix = "/" + candidate
    var out: [T] = []
    out.reserveCapacity(min(4, candidates.count))

    for entry in candidates {
        let rel = entry.normalizedRelativePath
        if rel == candidate || rel.hasSuffix(boundarySuffix) {
            out.append(entry.folder)
        }
    }

    return out
}

package func resolveFoldersBySuffixFragment<T>(
    _ fragment: String,
    in foldersByFullPath: [String: T],
    relativePath: (T) -> String,
    caseInsensitive: Bool = true
) -> [T] {
    let index = buildFolderSuffixIndex(
        in: foldersByFullPath,
        relativePath: relativePath,
        caseInsensitive: caseInsensitive
    )
    return resolveFoldersBySuffixFragment(
        fragment,
        using: index,
        caseInsensitive: caseInsensitive
    )
}
