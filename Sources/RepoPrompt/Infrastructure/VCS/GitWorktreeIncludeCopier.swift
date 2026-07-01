import Foundation

enum GitWorktreeIncludeCopier {
    private static let includeFileName = ".worktreeinclude"

    static func copyIncludedFiles(
        from sourceRoot: URL,
        to destinationRoot: URL,
        ignoredFilesNULOutput: String,
        appManagedContainer: URL? = nil,
        fileManager: FileManager = .default
    ) -> GitWorktreeIncludeCopyResult? {
        let includeURL = sourceRoot.appendingPathComponent(includeFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: includeURL.path) else { return nil }

        let content: String
        do {
            content = try String(contentsOf: includeURL, encoding: .utf8)
        } catch {
            return GitWorktreeIncludeCopyResult(
                copiedCount: 0,
                matchedCount: 0,
                errorSummaries: ["could not read .worktreeinclude: \(error.localizedDescription)"]
            )
        }

        let rules = GitignoreCompiler.compile(content: content, directoryPath: "")
        var copiedCount = 0
        var matchedCount = 0
        var copiedRelativePaths: [String] = []
        var skippedSummaries: [String] = []
        var errorSummaries: [String] = []
        let appManagedContainerComponents = appManagedContainer.flatMap {
            relativePathComponentsIfInside(child: $0, root: sourceRoot)
        }

        for relativePathSlice in ignoredFilesNULOutput.split(separator: "\0", omittingEmptySubsequences: false) {
            guard !relativePathSlice.isEmpty else { continue }
            let relativePath = String(relativePathSlice)
            guard let pathComponents = safePathComponents(relativePath) else {
                skippedSummaries.append("skipped unsafe path \(relativePath)")
                continue
            }
            if let appManagedContainerComponents,
               isPathComponents(pathComponents, equalToOrInside: appManagedContainerComponents)
            {
                continue
            }

            let matchComponents = pathComponents.map { Substring($0) }
            guard rules.outcome(for: matchComponents, isDirectory: false) == .ignore else {
                continue
            }
            matchedCount += 1

            guard let sourceURL = fileURL(root: sourceRoot, pathComponents: pathComponents),
                  let destinationURL = fileURL(root: destinationRoot, pathComponents: pathComponents)
            else {
                skippedSummaries.append("skipped unsafe path \(relativePath)")
                continue
            }

            guard !hasSymlinkAncestor(root: sourceRoot, pathComponents: pathComponents, fileManager: fileManager) else {
                skippedSummaries.append("source path uses a symlink ancestor for \(relativePath)")
                continue
            }
            guard !hasSymlinkAncestor(
                root: destinationRoot,
                pathComponents: pathComponents,
                fileManager: fileManager
            ) else {
                skippedSummaries.append("destination path uses a symlink ancestor for \(relativePath)")
                continue
            }
            guard !isSymlink(destinationURL, fileManager: fileManager) else {
                skippedSummaries.append("destination is a symlink for \(relativePath)")
                continue
            }
            guard fileManager.fileExists(atPath: destinationURL.path) == false else {
                skippedSummaries.append("destination already exists for \(relativePath)")
                continue
            }

            do {
                let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    skippedSummaries.append("source is not a regular file for \(relativePath)")
                    continue
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                copiedCount += 1
                copiedRelativePaths.append(pathComponents.joined(separator: "/"))
            } catch {
                errorSummaries.append("failed to copy \(relativePath): \(error.localizedDescription)")
            }
        }

        guard matchedCount > 0 || !skippedSummaries.isEmpty || !errorSummaries.isEmpty else {
            return nil
        }
        return GitWorktreeIncludeCopyResult(
            copiedCount: copiedCount,
            matchedCount: matchedCount,
            copiedRelativePaths: copiedRelativePaths.sorted(),
            skippedSummaries: skippedSummaries,
            errorSummaries: errorSummaries
        )
    }

    private static func safePathComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private static func fileURL(root: URL, pathComponents: [String]) -> URL? {
        guard !pathComponents.isEmpty else { return nil }
        return pathComponents.reduce(root.standardizedFileURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func relativePathComponentsIfInside(child: URL, root: URL) -> [String]? {
        let childPath = StandardizedPath.absolute(child.path)
        let rootPath = StandardizedPath.absolute(root.path)
        guard StandardizedPath.isDescendant(childPath, of: rootPath) else { return nil }
        guard childPath != rootPath else { return [] }

        let suffix: Substring = if rootPath == "/" {
            childPath.dropFirst()
        } else {
            childPath.dropFirst(rootPath.count)
        }
        let relativePath = StandardizedPath.relative(String(suffix))
        guard !relativePath.isEmpty else { return [] }
        return safePathComponents(relativePath)
    }

    private static func isPathComponents(_ pathComponents: [String], equalToOrInside rootComponents: [String]) -> Bool {
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func hasSymlinkAncestor(
        root: URL,
        pathComponents: [String],
        fileManager: FileManager
    ) -> Bool {
        guard pathComponents.count > 1 else { return false }
        var current = root.standardizedFileURL
        for component in pathComponents.dropLast() {
            current = current.appendingPathComponent(component, isDirectory: true)
            if isSymlink(current, fileManager: fileManager) {
                return true
            }
        }
        return false
    }

    private static func isSymlink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
