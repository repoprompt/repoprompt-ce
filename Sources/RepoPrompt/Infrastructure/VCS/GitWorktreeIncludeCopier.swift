import Darwin
import Foundation
import RepoPromptDomainRuntime

enum GitWorktreeIncludeCopier {
    private static let includeFileName = ".worktreeinclude"

    /// Copies Git-ignored files (and, only when `untrackedFilesNULOutput` is supplied by an
    /// explicit opt-in, untracked non-ignored files) whose final `.worktreeinclude` match is
    /// positive. Regular files are APFS-cloned through parent directory descriptors opened
    /// with `O_NOFOLLOW`; volumes that cannot clone fall back to an exclusive byte copy.
    static func copyIncludedFiles(
        from sourceRoot: URL,
        to destinationRoot: URL,
        ignoredFilesNULOutput: String,
        untrackedFilesNULOutput: String = "",
        appManagedContainer: URL? = nil,
        fileManager: FileManager = .default,
        physicalMutationGuard: DomainMutationPhysicalCommitGuard? = nil,
        clone: GitWorktreeFileCloner.CloneSyscall = GitWorktreeFileCloner.systemClone
    ) throws -> GitWorktreeIncludeCopyResult? {
        let admittedDirectories: DomainMutationWorktreeDirectories?
        if let physicalMutationGuard {
            guard let destinationIdentity = GitWorktreeTrackedCheckoutClone.directoryIdentity(destinationRoot) else {
                throw DomainMutationPathFenceError.pathResolutionChanged(destinationRoot.path)
            }
            admittedDirectories = try physicalMutationGuard.openCreatedWorktreeDirectories(
                sourcePath: sourceRoot.path,
                destinationPath: destinationRoot.path,
                destinationDevice: UInt64(destinationIdentity.device),
                destinationInode: UInt64(destinationIdentity.inode)
            )
        } else {
            admittedDirectories = nil
        }
        let includeURL = sourceRoot.appendingPathComponent(includeFileName, isDirectory: false)
        if admittedDirectories == nil {
            guard fileManager.fileExists(atPath: includeURL.path) else { return nil }
        }

        let content: String
        do {
            if let admittedDirectories {
                let descriptor = openat(
                    admittedDirectories.sourceFD,
                    includeFileName,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                )
                if descriptor < 0, errno == ENOENT { return nil }
                guard descriptor >= 0 else {
                    throw GitWorktreeFileClonerError(operation: "open-worktreeinclude", code: errno)
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                var status = stat()
                guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    throw GitWorktreeFileClonerError(operation: "stat-worktreeinclude", code: EFTYPE)
                }
                let data = try handle.readToEnd() ?? Data()
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                content = decoded
            } else {
                content = try String(contentsOf: includeURL, encoding: .utf8)
            }
        } catch {
            return GitWorktreeIncludeCopyResult(
                copiedCount: 0,
                matchedCount: 0,
                errorSummaries: ["could not read .worktreeinclude: \(error)"]
            )
        }

        let rules = GitignoreCompiler.compile(content: content, directoryPath: "")
        var copiedCount = 0
        var clonedCount = 0
        var copiedUntrackedCount = 0
        var matchedCount = 0
        var copiedRelativePaths: [String] = []
        var skippedSummaries: [String] = []
        var errorSummaries: [String] = []
        let appManagedContainerComponents = appManagedContainer.flatMap {
            relativePathComponentsIfInside(child: $0, root: sourceRoot)
        }
        var sourceCursor: GitWorktreeFileCloner.DirectoryCursor?
        var destinationCursor: GitWorktreeFileCloner.DirectoryCursor?

        var candidates: [(relativePath: String, isUntracked: Bool)] = []
        var seenCandidates = Set<String>()
        for (output, isUntracked) in [(ignoredFilesNULOutput, false), (untrackedFilesNULOutput, true)] {
            for slice in output.split(separator: "\0", omittingEmptySubsequences: true) {
                let relativePath = String(slice)
                guard seenCandidates.insert(relativePath).inserted else { continue }
                candidates.append((relativePath, isUntracked))
            }
        }

        for (relativePath, isUntracked) in candidates {
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
            } catch {
                errorSummaries.append("failed to inspect \(relativePath): \(error.localizedDescription)")
                continue
            }

            try admittedDirectories?.revalidate()
            let parentComponents = pathComponents.dropLast()
            let sourceDirectory: Int32
            let destinationDirectory: Int32
            do {
                // The source root may legitimately be opened through a symlinked path, so it is
                // resolved once; the new worktree root must not be a symlink at all.
                let sourceWalker = try sourceCursor ?? {
                    if let admittedDirectories {
                        return try GitWorktreeFileCloner.DirectoryCursor(
                            rootDescriptor: admittedDirectories.sourceFD,
                            createMissing: false
                        )
                    }
                    return try GitWorktreeFileCloner.DirectoryCursor(
                        rootPath: sourceRoot.resolvingSymlinksInPath().standardizedFileURL.path,
                        createMissing: false,
                        noFollowRoot: true
                    )
                }()
                sourceCursor = sourceWalker
                let destinationWalker = try destinationCursor ?? {
                    if let admittedDirectories {
                        return try GitWorktreeFileCloner.DirectoryCursor(
                            rootDescriptor: admittedDirectories.destinationFD,
                            createMissing: true
                        )
                    }
                    return try GitWorktreeFileCloner.DirectoryCursor(
                        rootPath: destinationRoot.standardizedFileURL.path,
                        createMissing: true,
                        noFollowRoot: true
                    )
                }()
                destinationCursor = destinationWalker
                sourceDirectory = try sourceWalker.directory(for: parentComponents)
                destinationDirectory = try destinationWalker.directory(for: parentComponents)
            } catch {
                errorSummaries.append("failed to prepare \(relativePath): \(error)")
                continue
            }

            try admittedDirectories?.revalidate()
            let outcome = GitWorktreeFileCloner.cloneRegularFile(
                sourceDirectory: sourceDirectory,
                name: pathComponents[pathComponents.count - 1],
                destinationDirectory: destinationDirectory,
                metadata: .preserveSource,
                allowCopyFallback: true,
                clone: clone
            )
            switch outcome {
            case .cloned, .copied:
                copiedCount += 1
                if outcome == .cloned { clonedCount += 1 }
                if isUntracked { copiedUntrackedCount += 1 }
                copiedRelativePaths.append(pathComponents.joined(separator: "/"))
            case .destinationExists:
                skippedSummaries.append("destination already exists for \(relativePath)")
            case .sourceTypeMismatch:
                skippedSummaries.append("source is not a regular file for \(relativePath)")
            case .sourceMissing:
                errorSummaries.append("failed to copy \(relativePath): source file disappeared")
            case let .failed(operation, code):
                errorSummaries.append(
                    "failed to copy \(relativePath): \(GitWorktreeFileClonerError(operation: operation, code: code))"
                )
            case let .cloneUnsupported(code):
                errorSummaries.append(
                    "failed to copy \(relativePath): \(GitWorktreeFileClonerError(operation: "clone", code: code))"
                )
            case .symbolicLinkCreated:
                errorSummaries.append("failed to copy \(relativePath): unexpected link result")
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
            errorSummaries: errorSummaries,
            clonedCount: clonedCount,
            copiedUntrackedCount: copiedUntrackedCount
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
