import Darwin
import Foundation

extension FileSystemService {
    // MARK: - Parallel scanning support

    struct FolderScanBatchResult {
        let deltas: [FileSystemDelta]
        let scannedFolders: Set<String>
    }

    /// Result of scanning a single folder (Sendable for cross-task usage)
    struct ScanResult {
        let folderRel: String
        let children: [String: Bool] // relPath -> isDirectory
        let ignoreFiles: (hasGitignore: Bool, hasRepoIgnore: Bool, hasCursorignore: Bool)
    }

    /// Heavy I/O operation that runs outside the actor for parallelism.
    /// Uses POSIX opendir/readdir for better performance than FileManager.contentsOfDirectory.
    static func enumerateOneLevel(
        absFolder: String,
        relFolder: String,
        skipSymlinks: Bool,
        rules: IgnoreRulesSnapshot,
        preserveChildren: Set<String> = []
    ) throws -> ScanResult {
        // Use the lightweight POSIX-based directory scanner
        let scan: DirectoryScanResult
        do {
            scan = try listDirectoryWithIgnoreDetection(absFolder)
        } catch {
            // Recovery correctness depends on distinguishing an empty directory from
            // an unreadable one. The actor fallback handles missing directories and
            // retains failed targets as dirty instead of treating them as removals.
            throw error
        }

        var children = [String: Bool]()
        children.reserveCapacity(scan.entries.count)

        for entry in scan.entries {
            let name = entry.name

            // Skip control directories
            if name == ".git" { continue }
            if Self.isRepoPromptTempFilename(name) { continue }

            let childRel = relFolder.isEmpty ? name : "\(relFolder)/\(name)"
            let isDirEntry = entry.isDir

            // Skip all symlinks if configured
            if entry.isSym, skipSymlinks {
                continue
            }

            // Apply ignore rules - but preserve tracked files for this folder
            let requiresTraversal = isDirEntry && rules.requiresTraversal(for: childRel)
            let isIgnored = rules.isIgnored(relativePath: childRel, isDirectory: isDirEntry)

            if isIgnored, !preserveChildren.contains(childRel), !requiresTraversal {
                continue
            }

            children[childRel] = isDirEntry
        }

        return ScanResult(
            folderRel: relFolder,
            children: children,
            ignoreFiles: (
                hasGitignore: scan.hasGitignore,
                hasRepoIgnore: scan.hasRepoIgnore,
                hasCursorignore: scan.hasCursorignore
            )
        )
    }

    /// Scan multiple folders in parallel for better I/O performance.
    /// Uses configurable caps to prevent CPU saturation.
    func scanFoldersInParallel(_ folders: [String]) async throws -> FolderScanBatchResult {
        guard !folders.isEmpty else {
            return FolderScanBatchResult(deltas: [], scannedFolders: [])
        }

        // Apply the cap without discarding caller-provided scheduling priority.
        let cappedFolders = Array(folders.prefix(maxFoldersPerBatch))
        let scannedFolders = Set(cappedFolders)

        #if DEBUG
            if isTestMode {
                processedFolderBatches.append(cappedFolders)
            }
        #endif

        // In test mode, use the same cap but scan serially to avoid SpyFS thread-safety issues.
        #if DEBUG
            if isTestMode {
                var deltas: [FileSystemDelta] = []
                for folder in cappedFolders {
                    let folderDeltas = try await scanOneLevelAndDiff(folder)
                    deltas.append(contentsOf: folderDeltas)
                }
                return FolderScanBatchResult(deltas: deltas, scannedFolders: scannedFolders)
            }
        #endif

        // For small sets, just use serial scanning
        if cappedFolders.count <= 2 {
            var deltas: [FileSystemDelta] = []
            for folder in cappedFolders {
                let folderDeltas = try await scanOneLevelAndDiff(folder)
                deltas.append(contentsOf: folderDeltas)
            }
            return FolderScanBatchResult(deltas: deltas, scannedFolders: scannedFolders)
        }

        // Use parallel scanning for larger sets with BOUNDED CONCURRENCY
        var aggregatedDeltas = [FileSystemDelta]()
        let originalVisitedInventory = visitedInventory.captureState()
        let originalPathCompsCache = pathCompsCache

        // Use configured parallelism cap (prevents CPU saturation)
        let maxParallel = min(cappedFolders.count, maxParallelScansPerActor)

        let targetParents = scannedFolders
        var preservedChildrenByFolder: [String: Set<String>] = [:]
        preservedChildrenByFolder.reserveCapacity(targetParents.count)
        for path in visitedPaths {
            let parent = parentDirectory(of: path)
            if targetParents.contains(parent) {
                preservedChildrenByFolder[parent, default: []].insert(path)
            }
        }

        var folderIterator = cappedFolders.makeIterator()
        var inFlight = 0

        // Capture ignoreRules before entering the task group to avoid actor isolation issues
        let fallbackRules = ignoreRules.snapshot()

        do {
            try await withThrowingTaskGroup(of: ScanResult.self) { group in
                /// Helper to schedule tasks up to maxParallel
                /// Note: captures must be resolved before the closure to avoid actor isolation issues
                func scheduleMoreTasks() {
                    while inFlight < maxParallel, let folderRel = folderIterator.next() {
                        // Capture everything we need before going off-actor
                        let absFolder = fullPath(forRelativePath: folderRel)
                        let rulesForFolder = perFolderIgnoreCache[folderRel]?.snapshot() ?? fallbackRules
                        let skipLinks = self.skipSymlinks
                        let preservedChildren = preservedChildrenByFolder[folderRel] ?? Set<String>()
                        #if DEBUG
                            let enumerationHook = parallelFolderEnumerationHookForTesting
                        #endif

                        inFlight += 1
                        group.addTask(priority: .utility) {
                            // This runs outside the actor for true parallelism
                            #if DEBUG
                                if let enumerationHook {
                                    try await enumerationHook(folderRel)
                                }
                            #endif
                            return try Self.enumerateOneLevel(
                                absFolder: absFolder,
                                relFolder: folderRel,
                                skipSymlinks: skipLinks,
                                rules: rulesForFolder,
                                preserveChildren: preservedChildren
                            )
                        }
                    }
                }

                // Prime with initial batch
                scheduleMoreTasks()

                // Process results as they complete
                for try await scan in group {
                    inFlight -= 1 // Decrement as result arrives

                    // Back inside actor context - safe to mutate state
                    let actualSet = Set(scan.children.keys)
                    let oldSet = preservedChildrenByFolder[scan.folderRel] ?? Set<String>()

                    let newItems = actualSet.subtracting(oldSet)
                    let removedItems = oldSet.subtracting(actualSet)

                    // Generate deltas for new items
                    for newItem in newItems {
                        // Skip newly discovered ignore files
                        if isIgnoreFile(newItem) {
                            continue
                        }
                        let isDir = scan.children[newItem] ?? false
                        visitedPaths.insert(newItem)
                        visitedItems[newItem] = isDir

                        if isDir {
                            aggregatedDeltas.append(.folderAdded(newItem))
                            // If this folder is already queued for its own scan, avoid duplicate subtree walk.
                            let hasPendingScan = pendingScanTargets[newItem] != nil
                            if !hasPendingScan {
                                let deeperDeltas = try await scanSubtreeForNewFolder(newItem)
                                aggregatedDeltas.append(contentsOf: deeperDeltas)
                            }
                        } else {
                            aggregatedDeltas.append(.fileAdded(newItem))
                        }
                    }

                    // Generate deltas for removed items
                    for removedItem in removedItems {
                        let wasDir = visitedItems[removedItem] ?? false
                        visitedPaths.remove(removedItem)
                        visitedItems.removeValue(forKey: removedItem)

                        if wasDir {
                            aggregatedDeltas.append(.folderRemoved(removedItem))
                            let subtreeDeltas = removeSubtree(for: removedItem)
                            aggregatedDeltas.append(contentsOf: subtreeDeltas)
                        } else {
                            aggregatedDeltas.append(.fileRemoved(removedItem))
                        }
                    }

                    // Schedule more tasks to fill the slot (sliding window)
                    scheduleMoreTasks()
                }
            }
        } catch {
            visitedInventory.restore(originalVisitedInventory)
            pathCompsCache = originalPathCompsCache
            throw error
        }

        return FolderScanBatchResult(deltas: aggregatedDeltas, scannedFolders: scannedFolders)
    }

    // MARK: - Single-level scanning & removal

    func scanOneLevelAndDiff(_ folderRelPath: String) async throws -> [FileSystemDelta] {
        #if DEBUG
            if let remaining = folderScanFailuresRemainingForTesting[folderRelPath], remaining > 0 {
                if remaining == 1 {
                    folderScanFailuresRemainingForTesting.removeValue(forKey: folderRelPath)
                } else {
                    folderScanFailuresRemainingForTesting[folderRelPath] = remaining - 1
                }
                throw NSError(
                    domain: "FileSystemServiceRecoveryTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Injected folder scan failure for \(folderRelPath)"]
                )
            }
        #endif
        let fm = fm // Cache for multiple calls in this method
        let absFolder = fullPath(forRelativePath: folderRelPath)
        var isDir: ObjCBool = false
        let folderExists = fm.fileExists(atPath: absFolder, isDirectory: &isDir)

        // 1) If missing or not a directory => remove entire subtree
        if !folderExists || !isDir.boolValue {
            return removeSubtree(for: folderRelPath)
        }

        // 2) Single-level listing using POSIX directory scanning
        #if DEBUG
            let scanResult = try Self.listDirectoryWithIgnoreDetection(absFolder, fm: self.fm)
        #else
            let scanResult = try Self.listDirectoryWithIgnoreDetection(absFolder)
        #endif

        let parentRules = folderRelPath.isEmpty
            ? ignoreRules
            : (perFolderIgnoreCache[parentDirectory(of: folderRelPath)] ?? ignoreRules)

        let effectiveRules: IgnoreRules = if enableHierarchicalIgnores {
            try await ensureRulesChain(for: folderRelPath, using: scanResult)
        } else {
            parentRules
        }

        let globalCacheSnapshot = snapshotIgnoreCacheWithPathKeys()
        var deltaCache: [IgnoreCacheStore.PathKey: Bool] = [:]
        var actualChildren: [String] = []
        actualChildren.reserveCapacity(scanResult.entries.count)
        var childIsDir: [String: Bool] = [:]
        childIsDir.reserveCapacity(scanResult.entries.count)

        for entry in scanResult.entries {
            let name = entry.name
            // Never traverse or track .git, regardless of rules.
            if name == ".git" { continue }

            let childRel = folderRelPath.isEmpty ? name : "\(folderRelPath)/\(name)"
            let comps = pathCompsCache.components(for: childRel)
            let isDirEntry = entry.isDir
            if entry.isSym, skipSymlinks {
                continue
            }
            var ignoredAsDir = false
            if isDirEntry {
                ignoredAsDir = IgnoreCacheStore.isIgnored(
                    components: comps,
                    isDirectory: true,
                    readOnlyBase: globalCacheSnapshot,
                    localCache: &deltaCache,
                    ignoreRules: effectiveRules
                )
            }

            let ignoredForItem: Bool = if isDirEntry {
                ignoredAsDir
            } else {
                IgnoreCacheStore.isIgnored(
                    components: comps,
                    isDirectory: false,
                    readOnlyBase: globalCacheSnapshot,
                    localCache: &deltaCache,
                    ignoreRules: effectiveRules
                )
            }

            let requiresTraversal = isDirEntry && effectiveRules.requiresTraversal(for: childRel)

            if ignoredForItem, !visitedPaths.contains(childRel), !requiresTraversal {
                continue
            }

            actualChildren.append(childRel)
            childIsDir[childRel] = isDirEntry
        }

        mergeIgnoreCache(deltaCache)

        let actualSet = Set(actualChildren)
        let oldSet = Set(visitedPaths.filter { parentDirectory(of: $0) == folderRelPath })

        let newItems = actualSet.subtracting(oldSet)
        let removedItems = oldSet.subtracting(actualSet)

        var deltas: [FileSystemDelta] = []

        // 3) Handle new items
        for newItem in newItems {
            // Skip newly discovered ignore files - they'll come through FSEvents
            if isIgnoreFile(newItem) {
                continue
            }

            let isDir = childIsDir[newItem] ?? fileOrFolderIsDir(newItem)
            visitedPaths.insert(newItem)
            visitedItems[newItem] = isDir

            if isDir {
                deltas.append(.folderAdded(newItem))

                // Recursively load everything inside this newly added folder unless it is already queued.
                let hasPendingScan = pendingScanTargets[newItem] != nil
                if !hasPendingScan {
                    let deeperDeltas = try await scanSubtreeForNewFolder(newItem)
                    if !deeperDeltas.isEmpty {
                        deltas.append(contentsOf: deeperDeltas)
                    }
                }

            } else {
                deltas.append(.fileAdded(newItem))
            }
        }

        // 4) Handle removed items
        for removedItem in removedItems {
            let wasDir = visitedItems[removedItem] ?? false
            visitedPaths.remove(removedItem)
            visitedItems.removeValue(forKey: removedItem)

            if wasDir {
                deltas.append(.folderRemoved(removedItem))
                let subtreeDeltas = removeSubtree(for: removedItem)
                deltas.append(contentsOf: subtreeDeltas)
            } else {
                deltas.append(.fileRemoved(removedItem))
            }
        }

        return deltas
    }

    /// Rebuilds the service's canonical path snapshot after bounded incremental
    /// recovery attempts fail. Existing files are marked modified so downstream
    /// content and codemap caches cannot survive an ambiguous recovery interval.
    func reconcileEntireTreeAfterRecoveryFailure() async throws -> [FileSystemDelta] {
        let actualItems = try await gatherPathsUsingEnumerator(
            rootURL: rootURL,
            skipSymlinks: skipSymlinks,
            baseRelativePath: ""
        )
        var reconciledItems = actualItems
        for relativePath in explicitlyManagedIgnoredFilePaths
            where visitedItems[relativePath] == false && actualItems[relativePath] == nil
        {
            let eligibility = await catalogRegularFileEligibility(relativePath: relativePath)
            if case .ineligible(.ignored) = eligibility {
                reconciledItems[relativePath] = false
            }
        }
        var remainingItems = reconciledItems
        var removedItems: [(path: String, wasDirectory: Bool)] = []
        var retainedFiles: [String] = []
        for previous in visitedItems {
            if let currentType = reconciledItems[previous.key], currentType == previous.value {
                remainingItems.removeValue(forKey: previous.key)
                if !currentType { retainedFiles.append(previous.key) }
            } else {
                removedItems.append((previous.key, previous.value))
            }
        }
        removedItems.sort { lhs, rhs in
            let lhsDepth = lhs.path.split(separator: "/").count
            let rhsDepth = rhs.path.split(separator: "/").count
            return lhsDepth == rhsDepth ? lhs.path > rhs.path : lhsDepth > rhsDepth
        }
        let addedFolders = remainingItems.keys.filter { remainingItems[$0] == true }.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            return lhsDepth == rhsDepth ? lhs < rhs : lhsDepth < rhsDepth
        }
        let addedFiles = remainingItems.keys.filter { remainingItems[$0] == false }.sorted()
        retainedFiles.sort()

        var deltas: [FileSystemDelta] = []
        deltas.reserveCapacity(removedItems.count + remainingItems.count + retainedFiles.count)
        for removed in removedItems {
            deltas.append(removed.wasDirectory ? .folderRemoved(removed.path) : .fileRemoved(removed.path))
        }
        deltas.append(contentsOf: addedFolders.map(FileSystemDelta.folderAdded))
        deltas.append(contentsOf: addedFiles.map(FileSystemDelta.fileAdded))
        for relativePath in retainedFiles {
            let modificationDate = try? await getFileModificationDate(atRelativePath: relativePath)
            deltas.append(.fileModified(relativePath, modificationDate))
        }

        visitedInventory.installOrdinary(paths: Set(reconciledItems.keys), items: reconciledItems)
        pathCompsCache.removeAll()
        return deltas
    }

    /// Recursively enumerates everything in a newly discovered folder, creating .fileAdded / .folderAdded deltas.
    func scanSubtreeForNewFolder(_ folderRelPath: String) async throws -> [FileSystemDelta] {
        let absFolder = fullPath(forRelativePath: folderRelPath)
        let subtreeItems = try await gatherPathsUsingEnumerator(
            rootURL: URL(fileURLWithPath: absFolder),
            skipSymlinks: skipSymlinks,
            baseRelativePath: folderRelPath
        )

        var subDeltas: [FileSystemDelta] = []

        for (subRelPath, isDir) in subtreeItems {
            let fullRel = folderRelPath.isEmpty
                ? subRelPath
                : (folderRelPath + "/" + subRelPath)

            if visitedPaths.contains(fullRel) {
                continue
            }
            visitedPaths.insert(fullRel)
            visitedItems[fullRel] = isDir

            if isDir {
                subDeltas.append(.folderAdded(fullRel))
            } else {
                subDeltas.append(.fileAdded(fullRel))
            }
        }

        return subDeltas
    }

    /// Removes an entire subtree for a given folder from visitedPaths. Returns .fileRemoved / .folderRemoved deltas.
    func removeSubtree(for topRelPath: String) -> [FileSystemDelta] {
        let oldSet = visitedPaths.filter {
            $0 == topRelPath || $0.hasPrefix(topRelPath + "/")
        }
        let sortedPaths = oldSet.sorted { $0.count > $1.count } // deeper items first
        var deltas: [FileSystemDelta] = []

        for path in sortedPaths {
            let wasDir = visitedItems[path] ?? false
            visitedPaths.remove(path)
            visitedItems.removeValue(forKey: path)
            if wasDir {
                deltas.append(.folderRemoved(path))
            } else {
                deltas.append(.fileRemoved(path))
            }
        }
        return deltas
    }

    /// Produces a standalone, exact namespace manifest through the same streaming
    /// crawler used by ordinary root loading. This does not publish or seed a root.
    func workspaceRootNamespaceManifest(
        in store: WorkspaceRootNamespaceManifestStore,
        resourcePolicy: WorkspaceRootNamespaceManifestResourcePolicy = .default,
        chunkSize: Int = 200
    ) async throws -> WorkspaceRootNamespaceManifestLease {
        guard pendingIgnoreRulesRebuildCount == 0 else {
            throw WorkspaceRootNamespaceManifestError.corrupt("workspace ignore rules rebuild pending during enumeration")
        }
        let initialRootIdentity = try WorkspaceRootNamespaceRootIdentity(rootURL: rootURL)
        let initialCatalogPolicyIdentity = catalogPolicyIdentity
        let initialIgnoreRulesRevision = ignoreRulesRevision
        let writer = try store.makeWriter(
            identity: WorkspaceRootNamespaceManifestIdentity(
                root: initialRootIdentity,
                catalogPolicy: initialCatalogPolicyIdentity
            ),
            resourcePolicy: resourcePolicy
        )

        do {
            let stream = loadContentsInChunks(of: rootURL, chunkSize: chunkSize)
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .preparedItems(chunk):
                    var records: [WorkspaceRootNamespaceRecord] = []
                    records.reserveCapacity(chunk.folders.count + chunk.files.count)
                    for folder in chunk.folders {
                        records.append(Self.workspaceRootNamespaceRecord(for: folder))
                    }
                    for file in chunk.files {
                        records.append(Self.workspaceRootNamespaceRecord(for: file))
                    }
                    try await writer.append(contentsOf: records)

                case let .items(items):
                    var records: [WorkspaceRootNamespaceRecord] = []
                    records.reserveCapacity(items.count)
                    for (item, _) in items {
                        let relativePath = item.relativePath(rootPath: rootURL.path)
                        records.append(WorkspaceRootNamespaceRecord(
                            relativePath: relativePath,
                            kind: item is Folder ? .directory : .file,
                            isSymbolicLink: false
                        ))
                    }
                    try await writer.append(contentsOf: records)

                case .totalFileCount:
                    continue
                }
            }

            try Task.checkCancellation()
            #if DEBUG
                if let handler = workspaceRootNamespaceEnumerationWillFinishHandler {
                    await handler()
                }
            #endif
            let lease = try await writer.finish()
            let finalRootIdentity = try WorkspaceRootNamespaceRootIdentity(rootURL: rootURL)
            guard finalRootIdentity == initialRootIdentity else {
                throw WorkspaceRootNamespaceManifestError.corrupt("workspace root changed during enumeration")
            }
            guard pendingIgnoreRulesRebuildCount == 0,
                  catalogPolicyIdentity == initialCatalogPolicyIdentity,
                  ignoreRulesRevision == initialIgnoreRulesRevision
            else {
                throw WorkspaceRootNamespaceManifestError.corrupt("workspace ignore policy changed or rebuild pending during enumeration")
            }
            return lease
        } catch {
            await writer.cancel()
            throw error
        }
    }

    static func workspaceRootNamespaceRecord(for item: FSItemDTO) -> WorkspaceRootNamespaceRecord {
        WorkspaceRootNamespaceRecord(
            relativePathBytes: item.relativePathBytes,
            kind: item.isDirectory ? .directory : .file,
            isSymbolicLink: item.isSymbolicLink,
            fileSystemMode: item.fileSystemMode
        )
    }

    public func loadContentsInChunks(
        of folderURL: URL,
        chunkSize: Int = 200
    ) -> AsyncThrowingStream<LoadContentsEvent, Error> {
        AsyncThrowingStream { continuation in
            let loadingTask = Task {
                do {
                    try Task.checkCancellation()

                    #if DEBUG
                        IgnoreDebugMetricsRecorder.resetAndDumpSnapshotIfEnabled(label: "load-start:\(folderURL.standardizedFileURL.path)")
                    #endif

                    var firstReportedCount: Int?
                    var lastEmittedCount: Int?

                    let finalTotal = try await walkPosixRecursivelyEmitChunks(
                        baseURL: folderURL,
                        parentRules: ignoreRules,
                        chunkSize: chunkSize
                    ) { chunk, cumulativeCount in
                        if firstReportedCount == nil {
                            firstReportedCount = cumulativeCount
                            lastEmittedCount = cumulativeCount
                            continuation.yield(.totalFileCount(cumulativeCount))
                        }
                        continuation.yield(.preparedItems(chunk))
                    }

                    if firstReportedCount == nil {
                        continuation.yield(.totalFileCount(finalTotal))
                    } else if lastEmittedCount != finalTotal {
                        continuation.yield(.totalFileCount(finalTotal))
                    }

                    #if DEBUG
                        IgnoreDebugMetricsRecorder.dumpSnapshotIfEnabled(label: "load-finish:\(folderURL.standardizedFileURL.path)")
                    #endif

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                loadingTask.cancel()
            }
        }
    }

    /// Load the entire tree (recursively) as an AsyncThrowingStream of items, respecting skipSymlinks & ignore rules.
    func loadContents(of folder: URL) -> AsyncThrowingStream<(any FileSystemItem, [String]), Error> {
        AsyncThrowingStream { continuation in
            let streamingTask = Task {
                do {
                    let rootFullPath = folder.standardizedFileURL.path
                    let stream = loadContentsInChunks(of: folder, chunkSize: 200)
                    for try await event in stream {
                        switch event {
                        case let .preparedItems(chunk):
                            for folderDTO in chunk.folders {
                                let components = folderDTO.relativePath.split(separator: "/").map(String.init)
                                let folderItem = Folder(
                                    name: components.last ?? folderDTO.relativePath,
                                    path: Self.joinRootAndRelative(root: rootFullPath, relative: folderDTO.relativePath),
                                    modificationDate: .distantPast
                                )
                                continuation.yield((folderItem, components))
                            }
                            for fileDTO in chunk.files {
                                let components = fileDTO.relativePath.split(separator: "/").map(String.init)
                                let fileItem = File(
                                    name: components.last ?? fileDTO.relativePath,
                                    path: Self.joinRootAndRelative(root: rootFullPath, relative: fileDTO.relativePath),
                                    modificationDate: .distantPast
                                )
                                continuation.yield((fileItem, components))
                            }
                        case let .items(legacy):
                            for item in legacy {
                                continuation.yield(item)
                            }
                        case .totalFileCount:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                streamingTask.cancel()
            }
        }
    }

    final class DirChain: @unchecked Sendable {
        let id: DirID
        let parent: DirChain?

        init(_ id: DirID, parent: DirChain?) {
            self.id = id
            self.parent = parent
        }

        func contains(_ needle: DirID) -> Bool {
            var node: DirChain? = self
            while let current = node {
                if current.id == needle { return true }
                node = current.parent
            }
            return false
        }
    }

    struct DirectoryContext {
        let absPath: String
        let relPath: String
        let relPathBytes: Data
        let hierarchy: Int
        let rules: IgnoreRulesSnapshot
        let chain: DirChain?
    }

    struct DirectoryChunkResult {
        let folders: [FSItemDTO]
        let files: [FSItemDTO]
        let subdirs: [DirectoryContext]
        let ignoreCacheDelta: [IgnoreCacheStore.PathKey: Bool]
    }

    static func buildDirectoryChunk(
        service: FileSystemService,
        context: DirectoryContext,
        scanResult: DirectoryScanResult,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        trackCycles: Bool
    ) async throws -> DirectoryChunkResult {
        let effectiveRulesSnapshot: IgnoreRulesSnapshot
        if enableHierarchicalIgnores {
            let hasGitignore = scanResult.hasGitignore
            let hasRepoIgnore = scanResult.hasRepoIgnore && respectRepoIgnore
            let hasCursorignore = scanResult.hasCursorignore && respectCursorignore
            if hasGitignore || hasRepoIgnore || hasCursorignore {
                let dirURL = URL(fileURLWithPath: context.absPath)
                effectiveRulesSnapshot = try await service.effectiveRulesSnapshot(
                    for: dirURL,
                    parentRelPath: context.relPath,
                    hasGitignore: hasGitignore,
                    hasRepoIgnore: hasRepoIgnore,
                    hasCursorignore: hasCursorignore
                )
            } else {
                do {
                    try await service.markNoIgnoreFilesUsingCache(context.relPath)
                } catch {
                    // Best-effort: skip caching if the ignore chain can't be ensured.
                }
                effectiveRulesSnapshot = context.rules
            }
        } else {
            effectiveRulesSnapshot = context.rules
        }

        var folders: [FSItemDTO] = []
        folders.reserveCapacity(scanResult.entries.count)
        var files: [FSItemDTO] = []
        files.reserveCapacity(scanResult.entries.count)
        var subdirs: [DirectoryContext] = []
        subdirs.reserveCapacity(scanResult.entries.count)
        var localCache: [IgnoreCacheStore.PathKey: Bool] = [:]
        var componentsCache = PathComponentsCache()

        for entry in scanResult.entries {
            let name = entry.name
            if name == ".git" { continue }
            if Self.isRepoPromptTempFilename(name) { continue }
            let relativePath = context.relPath.isEmpty ? name : "\(context.relPath)/\(name)"
            let relativePathBytes = Self.joinRelativePathBytes(
                base: context.relPathBytes,
                child: entry.nameBytes
            )
            guard !relativePath.isEmpty else { continue }
            let hierarchy = context.hierarchy + 1
            let comps = componentsCache.components(for: relativePath)
            let isDirEntry = entry.isDir
            let absolutePath = Self.joinRootAndRelative(root: context.absPath, relative: name)

            var ignoredAsDir = false
            if isDirEntry {
                ignoredAsDir = IgnoreCacheStore.isIgnored(
                    components: comps,
                    isDirectory: true,
                    ignoreRules: effectiveRulesSnapshot,
                    localCache: &localCache
                )
            }

            let ignoredForItem: Bool = if isDirEntry {
                ignoredAsDir
            } else {
                IgnoreCacheStore.isIgnored(
                    components: comps,
                    isDirectory: false,
                    ignoreRules: effectiveRulesSnapshot,
                    localCache: &localCache
                )
            }

            let requiresTraversal = isDirEntry && effectiveRulesSnapshot.requiresTraversal(for: relativePath)

            if ignoredForItem, !requiresTraversal {
                continue
            }

            if entry.isSym, skipSymlinks { continue }

            if isDirEntry {
                folders.append(
                    FSItemDTO(
                        relativePath: relativePath,
                        relativePathBytes: relativePathBytes,
                        isDirectory: true,
                        hierarchy: hierarchy,
                        isSymbolicLink: entry.isSym,
                        fileSystemMode: entry.fileSystemMode
                    )
                )

                if trackCycles {
                    guard let id = Self.dirID(followingSymlinksAtPath: absolutePath) else {
                        continue
                    }
                    if let chain = context.chain, chain.contains(id) {
                        continue
                    }
                    let childChain = DirChain(id, parent: context.chain)
                    subdirs.append(
                        DirectoryContext(
                            absPath: absolutePath,
                            relPath: relativePath,
                            relPathBytes: relativePathBytes,
                            hierarchy: hierarchy,
                            rules: effectiveRulesSnapshot,
                            chain: childChain
                        )
                    )
                } else {
                    subdirs.append(
                        DirectoryContext(
                            absPath: absolutePath,
                            relPath: relativePath,
                            relPathBytes: relativePathBytes,
                            hierarchy: hierarchy,
                            rules: effectiveRulesSnapshot,
                            chain: nil
                        )
                    )
                }
            } else {
                files.append(
                    FSItemDTO(
                        relativePath: relativePath,
                        relativePathBytes: relativePathBytes,
                        isDirectory: false,
                        hierarchy: hierarchy,
                        isSymbolicLink: entry.isSym,
                        fileSystemMode: entry.fileSystemMode
                    )
                )
            }
        }

        return DirectoryChunkResult(
            folders: folders,
            files: files,
            subdirs: subdirs,
            ignoreCacheDelta: localCache
        )
    }

    @inline(__always)
    static func joinRootAndRelative(root: String, relative: String) -> String {
        guard !relative.isEmpty else { return root }
        if root.isEmpty {
            return relative
        }
        if root.hasSuffix("/") {
            return root + relative
        }
        return root + "/" + relative
    }

    static func joinRelativePathBytes(base: Data, child: Data) -> Data {
        guard !base.isEmpty else { return child }
        var result = base
        result.append(UInt8(ascii: "/"))
        result.append(child)
        return result
    }

    func walkPosixRecursivelyEmitChunks(
        baseURL: URL,
        parentRules: IgnoreRules,
        chunkSize: Int,
        yield: @escaping (FSPreparedChunk, Int) -> Void
    ) async throws -> Int {
        let rootFullPath = folderURLRootPath(baseURL)
        let skipSymlinks = skipSymlinks
        let rootChain: DirChain?
        #if DEBUG
            let isVirtualFS = isTestMode && !(fm is FileManager)
            if isVirtualFS || skipSymlinks {
                rootChain = nil
            } else if let rootID = Self.dirID(followingSymlinksAtPath: rootFullPath) {
                rootChain = DirChain(rootID, parent: nil)
            } else {
                rootChain = nil
            }
        #else
            if skipSymlinks {
                rootChain = nil
            } else if let rootID = Self.dirID(followingSymlinksAtPath: rootFullPath) {
                rootChain = DirChain(rootID, parent: nil)
            } else {
                rootChain = nil
            }
        #endif
        var directories: [DirectoryContext] = [
            DirectoryContext(
                absPath: rootFullPath,
                relPath: "",
                relPathBytes: Data(),
                hierarchy: -1,
                rules: parentRules.snapshot(),
                chain: rootChain
            )
        ]

        var chunkFolders: [FSItemDTO] = []
        chunkFolders.reserveCapacity(chunkSize)
        var chunkFiles: [FSItemDTO] = []
        chunkFiles.reserveCapacity(chunkSize)
        var pendingFileCount = 0
        var totalFilesSeen = 0

        @inline(__always)
        func flush(force: Bool = false) {
            guard !chunkFolders.isEmpty || !chunkFiles.isEmpty else { return }
            if !force, (chunkFolders.count + chunkFiles.count) < chunkSize { return }
            let newlyCounted = pendingFileCount
            totalFilesSeen += newlyCounted
            let chunk = FSPreparedChunk(folders: chunkFolders, files: chunkFiles)
            chunkFolders.removeAll(keepingCapacity: true)
            chunkFiles.removeAll(keepingCapacity: true)
            pendingFileCount = 0
            yield(chunk, totalFilesSeen)
        }

        // Use configured parallelism cap for consistent behavior across all scan paths
        let maxConcurrent = maxParallelScansPerActor

        while !directories.isEmpty {
            try Task.checkCancellation()

            let batch = Array(directories.prefix(maxConcurrent))
            directories.removeFirst(batch.count)

            let enableHierarchicalIgnores = enableHierarchicalIgnores
            let respectRepoIgnore = respectRepoIgnore
            let respectCursorignore = respectCursorignore

            try await withThrowingTaskGroup(of: DirectoryChunkResult.self) { group in
                for context in batch {
                    #if DEBUG
                        group.addTask { [
                            self,
                            context,
                            isVirtualFS,
                            skipSymlinks,
                            enableHierarchicalIgnores,
                            respectRepoIgnore,
                            respectCursorignore
                        ] in
                            try await Self.processDirectoryOffActor(
                                service: self,
                                context: context,
                                isVirtualFS: isVirtualFS,
                                skipSymlinks: skipSymlinks,
                                enableHierarchicalIgnores: enableHierarchicalIgnores,
                                respectRepoIgnore: respectRepoIgnore,
                                respectCursorignore: respectCursorignore
                            )
                        }
                    #else
                        group.addTask { [
                            self,
                            context,
                            skipSymlinks,
                            enableHierarchicalIgnores,
                            respectRepoIgnore,
                            respectCursorignore
                        ] in
                            try await Self.processDirectoryOffActor(
                                service: self,
                                context: context,
                                skipSymlinks: skipSymlinks,
                                enableHierarchicalIgnores: enableHierarchicalIgnores,
                                respectRepoIgnore: respectRepoIgnore,
                                respectCursorignore: respectCursorignore
                            )
                        }
                    #endif
                }

                for try await result in group {
                    if !result.folders.isEmpty || !result.files.isEmpty {
                        chunkFolders.append(contentsOf: result.folders)
                        chunkFiles.append(contentsOf: result.files)
                        pendingFileCount += result.files.count

                        for folder in result.folders {
                            visitedPaths.insert(folder.relativePath)
                            visitedItems[folder.relativePath] = true
                        }
                        for file in result.files {
                            visitedPaths.insert(file.relativePath)
                            visitedItems[file.relativePath] = false
                        }

                        flush()
                    }

                    if !result.subdirs.isEmpty {
                        directories.append(contentsOf: result.subdirs)
                    }

                    if !result.ignoreCacheDelta.isEmpty {
                        mergeIgnoreCache(result.ignoreCacheDelta)
                    }
                }
            }
        }

        flush(force: true)
        return totalFilesSeen
    }

    #if DEBUG
        func gatherPathsUsingVirtualFS(
            rootURL: URL,
            baseRelativePath: String,
            fs: any FileSystemProviding,
            skipSymlinks: Bool
        ) throws -> [String: Bool] {
            var results = [String: Bool]()

            func recurse(currentURL: URL, subtreeRelativePath: String) throws {
                let children = try fs.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )

                for url in children {
                    let name = url.lastPathComponent
                    if name == "." || name == ".." { continue }
                    if Self.isRepoPromptTempFilename(name) { continue }

                    var isDirFlag: ObjCBool = false
                    _ = fs.fileExists(atPath: url.path, isDirectory: &isDirFlag)

                    let isSym = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                    if skipSymlinks && isSym {
                        continue
                    }

                    let relativeWithinSubtree = subtreeRelativePath.isEmpty ? name : "\(subtreeRelativePath)/\(name)"
                    let repositoryRelativePath = Self.joinRelativePaths(base: baseRelativePath, child: relativeWithinSubtree)

                    let comps = pathCompsCache.components(for: repositoryRelativePath)
                    let requiresTraversal = isDirFlag.boolValue && ignoreRules.requiresTraversal(for: repositoryRelativePath)
                    if ignoreRules.isIgnored(relativePathComponents: comps, isDirectory: isDirFlag.boolValue), !requiresTraversal {
                        continue
                    }

                    results[relativeWithinSubtree] = isDirFlag.boolValue

                    if isDirFlag.boolValue {
                        try recurse(currentURL: url, subtreeRelativePath: relativeWithinSubtree)
                    }
                }
            }

            try recurse(currentURL: rootURL, subtreeRelativePath: "")
            return results
        }
    #endif

    #if DEBUG
        static func processDirectoryOffActor(
            service: FileSystemService,
            context: DirectoryContext,
            isVirtualFS: Bool,
            skipSymlinks: Bool,
            enableHierarchicalIgnores: Bool,
            respectRepoIgnore: Bool,
            respectCursorignore: Bool
        ) async throws -> DirectoryChunkResult {
            let scanResult: DirectoryScanResult
            let testMode = await service.isTestMode
            if testMode {
                let fm = await service.fm
                scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath, fm: fm)
            } else {
                scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath)
            }

            let trackCycles = !skipSymlinks && !isVirtualFS
            return try await buildDirectoryChunk(
                service: service,
                context: context,
                scanResult: scanResult,
                skipSymlinks: skipSymlinks,
                enableHierarchicalIgnores: enableHierarchicalIgnores,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                trackCycles: trackCycles
            )
        }
    #else
        static func processDirectoryOffActor(
            service: FileSystemService,
            context: DirectoryContext,
            skipSymlinks: Bool,
            enableHierarchicalIgnores: Bool,
            respectRepoIgnore: Bool,
            respectCursorignore: Bool
        ) async throws -> DirectoryChunkResult {
            let scanResult = try Self.listDirectoryWithIgnoreDetection(context.absPath)

            let trackCycles = !skipSymlinks
            return try await buildDirectoryChunk(
                service: service,
                context: context,
                scanResult: scanResult,
                skipSymlinks: skipSymlinks,
                enableHierarchicalIgnores: enableHierarchicalIgnores,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                trackCycles: trackCycles
            )
        }
    #endif

    func folderURLRootPath(_ folderURL: URL) -> String {
        folderURL.standardizedFileURL.path
    }

    // MARK: - Internal enumeration & helpers

    func gatherPathsUsingEnumerator(
        rootURL: URL,
        skipSymlinks: Bool,
        baseRelativePath: String
    ) async throws -> [String: Bool] {
        #if DEBUG
            if let overrideFS = fileManagerOverride, !(overrideFS is FileManager) {
                return try gatherPathsUsingVirtualFS(
                    rootURL: rootURL,
                    baseRelativePath: baseRelativePath,
                    fs: overrideFS,
                    skipSymlinks: skipSymlinks
                )
            }
        #endif

        let rootPath = rootURL.path
        #if DEBUG
            let isVirtualFS = isTestMode && !(fm is FileManager)
            if !isVirtualFS {
                let isSym = (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                if isSym, skipSymlinks {
                    return [:]
                }
            }
        #else
            if skipSymlinks {
                let isSym = (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                if isSym {
                    return [:]
                }
            }
        #endif
        let rootChain: DirChain?
        #if DEBUG
            if isVirtualFS || skipSymlinks {
                rootChain = nil
            } else {
                var chain: DirChain?
                if let rootID = Self.dirID(followingSymlinksAtPath: canonicalRootPath) {
                    chain = DirChain(rootID, parent: nil)
                }
                if !baseRelativePath.isEmpty {
                    var relSoFar = ""
                    for component in baseRelativePath.split(separator: "/") {
                        relSoFar = relSoFar.isEmpty ? String(component) : "\(relSoFar)/\(component)"
                        let absPath = Self.joinRootAndRelative(root: path, relative: relSoFar)
                        if let id = Self.dirID(followingSymlinksAtPath: absPath) {
                            chain = DirChain(id, parent: chain)
                        }
                    }
                }
                rootChain = chain
            }
        #else
            if skipSymlinks {
                rootChain = nil
            } else {
                var chain: DirChain?
                if let rootID = Self.dirID(followingSymlinksAtPath: canonicalRootPath) {
                    chain = DirChain(rootID, parent: nil)
                }
                if !baseRelativePath.isEmpty {
                    var relSoFar = ""
                    for component in baseRelativePath.split(separator: "/") {
                        relSoFar = relSoFar.isEmpty ? String(component) : "\(relSoFar)/\(component)"
                        let absPath = Self.joinRootAndRelative(root: path, relative: relSoFar)
                        if let id = Self.dirID(followingSymlinksAtPath: absPath) {
                            chain = DirChain(id, parent: chain)
                        }
                    }
                }
                rootChain = chain
            }
        #endif
        let enableHierarchicalIgnores = enableHierarchicalIgnores
        let respectRepoIgnore = respectRepoIgnore
        let respectCursorignore = respectCursorignore

        let parentRel = parentDirectory(of: baseRelativePath)
        let fallbackRules = ignoreRules.snapshot()
        let parentRulesSnapshot = perFolderIgnoreCache[parentRel]?.snapshot() ?? fallbackRules

        var directories: [DirectoryContext] = [
            DirectoryContext(
                absPath: rootPath,
                relPath: baseRelativePath,
                relPathBytes: Data(baseRelativePath.utf8),
                hierarchy: -1,
                rules: parentRulesSnapshot,
                chain: rootChain
            )
        ]

        var results = [String: Bool]()
        let basePrefix = baseRelativePath.isEmpty ? "" : (baseRelativePath + "/")

        while let context = directories.popLast() {
            #if DEBUG
                let result = try await Self.processDirectoryOffActor(
                    service: self,
                    context: context,
                    isVirtualFS: isVirtualFS,
                    skipSymlinks: skipSymlinks,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore
                )
            #else
                let result = try await Self.processDirectoryOffActor(
                    service: self,
                    context: context,
                    skipSymlinks: skipSymlinks,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore
                )
            #endif

            if !result.ignoreCacheDelta.isEmpty {
                mergeIgnoreCache(result.ignoreCacheDelta)
            }

            for folder in result.folders {
                let repoRelative = folder.relativePath
                let relativeWithinSubtree = basePrefix.isEmpty
                    ? repoRelative
                    : (repoRelative.hasPrefix(basePrefix) ? String(repoRelative.dropFirst(basePrefix.count)) : repoRelative)
                if !relativeWithinSubtree.isEmpty {
                    results[relativeWithinSubtree] = true
                }
            }

            for file in result.files {
                let repoRelative = file.relativePath
                let relativeWithinSubtree = basePrefix.isEmpty
                    ? repoRelative
                    : (repoRelative.hasPrefix(basePrefix) ? String(repoRelative.dropFirst(basePrefix.count)) : repoRelative)
                if !relativeWithinSubtree.isEmpty {
                    results[relativeWithinSubtree] = false
                }
            }

            if !result.subdirs.isEmpty {
                directories.append(contentsOf: result.subdirs)
            }
        }

        return results
    }

    static func joinRelativePaths(base: String, child: String) -> String {
        if base.isEmpty { return child }
        if child.isEmpty { return base }
        return base + "/" + child
    }

    func getCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &count, &size, nil, 0)
        return Int(count)
    }
}
