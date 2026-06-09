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
        let scanRoots: [(root: HeadlessAllowedRoot, url: URL)] = if let basePath {
            [(basePath.root, basePath.url)]
        } else {
            roots.map { ($0, URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL) }
        }

        var entries: [HeadlessCatalogEntry] = []
        var wasTruncated = false
        var skippedEntryCount = 0
        rootLoop: for item in scanRoots {
            if try shouldContinue?() == false {
                wasTruncated = true
                break
            }
            let rootEntry = try catalogEntry(for: item.root, url: item.url)
            guard entries.count < entryLimit else {
                wasTruncated = true
                break
            }
            entries.append(rootEntry)
            if let basePath, !basePath.isDirectory {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: item.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    skippedEntryCount += 1
                    return true
                }
            ) else {
                skippedEntryCount += 1
                continue
            }
            for case let url as URL in enumerator {
                if try shouldContinue?() == false {
                    wasTruncated = true
                    break rootLoop
                }
                if skippedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values?.isDirectory == false, values?.isRegularFile == false {
                    continue
                }
                do {
                    let entry = try catalogEntry(for: item.root, url: url)
                    if entry.isDirectory || entry.byteCount != nil {
                        guard entries.count < entryLimit else {
                            wasTruncated = true
                            break rootLoop
                        }
                        entries.append(entry)
                    }
                } catch {
                    skippedEntryCount += 1
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
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

    func catalogEntry(for root: HeadlessAllowedRoot, url: URL) throws -> HeadlessCatalogEntry {
        let standardized = url.standardizedFileURL
        let lexicalRootPath: String
        if HeadlessRootAccessPolicy.path(standardized.path, isContainedInOrEqualTo: root.path) {
            lexicalRootPath = root.path
        } else if HeadlessRootAccessPolicy.path(standardized.path, isContainedInOrEqualTo: root.resolvedPath) {
            lexicalRootPath = root.resolvedPath
        } else {
            throw HeadlessCommandError("Path is outside allowed root '\(root.name)': \(url.path)", exitCode: 2)
        }
        let relativePath = HeadlessPathResolver.relativePath(forResolvedPath: standardized.path, rootResolvedPath: lexicalRootPath)
        let metadata = try secureFileAccess.inspect(root: root, relativePath: relativePath)
        let resolvedURL = relativePath.isEmpty
            ? URL(fileURLWithPath: root.resolvedPath, isDirectory: true)
            : URL(fileURLWithPath: root.resolvedPath, isDirectory: true).appendingPathComponent(relativePath)
        let displayPath = relativePath.isEmpty ? root.name : "\(root.name)/\(relativePath)"
        return HeadlessCatalogEntry(
            root: root,
            url: standardized,
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
        let targets: [(HeadlessAllowedRoot, URL)] = if let basePath {
            [(basePath.root, basePath.url)]
        } else {
            roots.map { ($0, URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL) }
        }
        var lines: [String] = []
        var truncated = false
        for (index, target) in targets.enumerated() {
            if index > 0 { lines.append("") }
            let rootLabel = basePath == nil ? target.0.name : (basePath?.displayPath ?? target.0.name)
            lines.append(rootLabel)
            let result = try appendTreeLines(root: target.0, directory: target.1, prefix: "", depth: 0, maxDepth: maxDepth ?? 4, lines: &lines, maxLines: 1500)
            truncated = truncated || result
        }
        return (lines.joined(separator: "\n"), targets.count, truncated)
    }

    private func appendTreeLines(root: HeadlessAllowedRoot, directory: URL, prefix: String, depth: Int, maxDepth: Int, lines: inout [String], maxLines: Int) throws -> Bool {
        guard depth < maxDepth else {
            return false
        }
        guard lines.count < maxLines else {
            return true
        }
        let children = try children(of: directory, root: root)
        for (index, child) in children.enumerated() {
            guard lines.count < maxLines else {
                return true
            }
            let isLast = index == children.count - 1
            let branch = isLast ? "└── " : "├── "
            lines.append("\(prefix)\(branch)\(child.url.lastPathComponent)\(child.isDirectory ? "/" : "")")
            if child.isDirectory {
                let childPrefix = prefix + (isLast ? "    " : "│   ")
                let truncated = try appendTreeLines(root: root, directory: child.url, prefix: childPrefix, depth: depth + 1, maxDepth: maxDepth, lines: &lines, maxLines: maxLines)
                if truncated { return true }
            }
        }
        return false
    }

    private func children(of directory: URL, root: HeadlessAllowedRoot) throws -> [HeadlessCatalogEntry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [HeadlessCatalogEntry] = []
        for url in urls where !skippedDirectoryNames.contains(url.lastPathComponent) {
            if let entry = try? catalogEntry(for: root, url: url), entry.isDirectory || entry.byteCount != nil {
                entries.append(entry)
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }
}
