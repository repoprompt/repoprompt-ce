import Foundation

struct HeadlessCatalogScanResult {
    var entries: [HeadlessCatalogEntry]
    var entryLimit: Int
    var wasTruncated: Bool
    var skippedEntryCount: Int
}

final class HeadlessFileCatalog {
    private let fileManager: FileManager
    private let secureFileAccess: HeadlessSecureFileAccess
    private let skippedDirectoryNames: Set<String> = [".git", ".svn", ".hg", ".build", "node_modules", ".DS_Store"]

    init(
        fileManager: FileManager = .default,
        secureFileAccess: HeadlessSecureFileAccess = HeadlessSecureFileAccess()
    ) {
        self.fileManager = fileManager
        self.secureFileAccess = secureFileAccess
    }

    func scan(
        roots: [HeadlessAllowedRoot],
        under basePath: HeadlessResolvedPath? = nil,
        maxEntries: Int = 20000,
        shouldContinue: (() throws -> Bool)? = nil
    ) throws -> HeadlessCatalogScanResult {
        let entryLimit = max(0, maxEntries)
        let scanRoots: [(root: HeadlessAllowedRoot, relativePath: String)] = if let basePath {
            [(basePath.root, basePath.relativePath)]
        } else {
            roots.map { ($0, "") }
        }

        var entries: [HeadlessCatalogEntry] = []
        var wasTruncated = false
        var skippedEntryCount = 0
        rootLoop: for item in scanRoots {
            if try shouldContinue?() == false {
                wasTruncated = true
                break
            }
            guard entries.count < entryLimit else {
                wasTruncated = true
                break
            }
            let remainingEntries = entryLimit - entries.count - 1
            let enumeration = try secureFileAccess.enumerate(
                root: item.root,
                relativePath: item.relativePath,
                maxEntries: max(0, remainingEntries),
                maxExaminedEntries: max(0, remainingEntries + 1),
                maxEntriesPerDirectory: 1000,
                skippedNames: skippedDirectoryNames,
                shouldContinue: shouldContinue
            )
            entries.append(catalogEntry(
                root: item.root,
                relativePath: item.relativePath,
                metadata: enumeration.baseMetadata
            ))
            for entry in enumeration.entries {
                entries.append(catalogEntry(
                    root: item.root,
                    relativePath: entry.relativePath,
                    metadata: entry.metadata
                ))
            }
            skippedEntryCount += enumeration.skippedEntryCount
            if enumeration.wasTruncated {
                wasTruncated = true
                break rootLoop
            }
        }
        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.root.id == rhs.root.id {
                if lhs.relativePath.isEmpty { return true }
                if rhs.relativePath.isEmpty { return false }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            return lhs.root.name.localizedStandardCompare(rhs.root.name) == .orderedAscending
        }
        return HeadlessCatalogScanResult(
            entries: sortedEntries,
            entryLimit: entryLimit,
            wasTruncated: wasTruncated,
            skippedEntryCount: skippedEntryCount
        )
    }

    private func catalogEntry(
        root: HeadlessAllowedRoot,
        relativePath: String,
        metadata: HeadlessSecureFileMetadata
    ) -> HeadlessCatalogEntry {
        let resolvedURL = relativePath.isEmpty
            ? URL(fileURLWithPath: root.resolvedPath, isDirectory: true)
            : URL(fileURLWithPath: root.resolvedPath, isDirectory: true).appendingPathComponent(relativePath)
        let displayPath = relativePath.isEmpty ? root.name : "\(root.name)/\(relativePath)"
        return HeadlessCatalogEntry(
            root: root,
            url: resolvedURL,
            resolvedURL: resolvedURL,
            relativePath: relativePath,
            displayPath: displayPath,
            isDirectory: metadata.kind == .directory,
            byteCount: metadata.kind == .regularFile ? metadata.byteCount : nil
        )
    }

    func filesUnder(_ path: HeadlessResolvedPath, maxFiles: Int = 1000) throws -> [HeadlessResolvedPath] {
        guard path.isDirectory else {
            return [path]
        }
        let scanResult = try scan(roots: [path.root], under: path, maxEntries: maxFiles + 1)
        guard !scanResult.wasTruncated else {
            throw HeadlessCommandError(
                "Directory expansion exceeded the headless limit of \(maxFiles) files or entries at \(path.displayPath). Narrow the path and retry.",
                exitCode: 2
            )
        }
        return scanResult.entries
            .filter { !$0.isDirectory && !$0.relativePath.isEmpty }
            .prefix(maxFiles)
            .map { entry in
                HeadlessResolvedPath(
                    root: entry.root,
                    url: entry.url,
                    resolvedURL: entry.resolvedURL,
                    relativePath: entry.relativePath,
                    displayPath: entry.displayPath,
                    isDirectory: false,
                    isRegularFile: true
                )
            }
    }

    func tree(roots: [HeadlessAllowedRoot], basePath: HeadlessResolvedPath?, mode: String, maxDepth: Int?) throws -> (tree: String, rootsCount: Int, wasTruncated: Bool) {
        if mode == "selected" {
            return ("", roots.count, false)
        }
        let targets: [(root: HeadlessAllowedRoot, relativePath: String, label: String)] = if let basePath {
            [(basePath.root, basePath.relativePath, basePath.displayPath)]
        } else {
            roots.map { ($0, "", $0.name) }
        }
        var lines: [String] = []
        var truncated = false
        for (index, target) in targets.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(target.label)
            let remainingLines = max(0, 1500 - lines.count)
            let enumeration = try secureFileAccess.enumerate(
                root: target.root,
                relativePath: target.relativePath,
                maxEntries: remainingLines,
                maxExaminedEntries: remainingLines,
                maxEntriesPerDirectory: 1000,
                maxDepth: maxDepth ?? 4,
                skippedNames: skippedDirectoryNames
            )
            let displayEntries = mode == "folders"
                ? enumeration.entries.filter { $0.metadata.kind == .directory }
                : enumeration.entries
            truncated = enumeration.wasTruncated || appendTreeLines(
                entries: displayEntries,
                parentRelativePath: target.relativePath,
                prefix: "",
                lines: &lines,
                maxLines: 1500
            ) || truncated
        }
        return (lines.joined(separator: "\n"), targets.count, truncated)
    }

    private func appendTreeLines(
        entries: [HeadlessSecureEnumerationEntry],
        parentRelativePath: String,
        prefix: String,
        lines: inout [String],
        maxLines: Int
    ) -> Bool {
        let children = entries.filter { entry in
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            return parent == "." ? parentRelativePath.isEmpty : parent == parentRelativePath
        }.sorted { lhs, rhs in
            if lhs.metadata.kind != rhs.metadata.kind {
                return lhs.metadata.kind == .directory
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        for (index, child) in children.enumerated() {
            guard lines.count < maxLines else {
                return true
            }
            let isLast = index == children.count - 1
            let branch = isLast ? "└── " : "├── "
            let name = (child.relativePath as NSString).lastPathComponent
            let isDirectory = child.metadata.kind == .directory
            lines.append("\(prefix)\(branch)\(name)\(isDirectory ? "/" : "")")
            if isDirectory {
                let childPrefix = prefix + (isLast ? "    " : "│   ")
                let truncated = appendTreeLines(
                    entries: entries,
                    parentRelativePath: child.relativePath,
                    prefix: childPrefix,
                    lines: &lines,
                    maxLines: maxLines
                )
                if truncated { return true }
            }
        }
        return false
    }
}
