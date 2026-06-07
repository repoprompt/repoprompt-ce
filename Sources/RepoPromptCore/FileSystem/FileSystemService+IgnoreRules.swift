import Foundation

extension FileSystemService {
    // MARK: - Ignore rules change consumption

    /// Payload describing ignore rules changes since last consumption
    public struct IgnoreRulesChange: Sendable {
        public let revision: UInt64
        public let changedDirs: Set<String>
    }

    /// Atomically retrieves and clears pending ignore rules changes.
    /// Returns nil if no ignore files have changed since the last call.
    /// Use this instead of the deprecated `filterHashChanged` property.
    public func takePendingIgnoreRulesChange() -> IgnoreRulesChange? {
        guard !pendingIgnoreChangeDirs.isEmpty else { return nil }
        let change = IgnoreRulesChange(
            revision: ignoreRulesRevision,
            changedDirs: pendingIgnoreChangeDirs
        )
        pendingIgnoreChangeDirs.removeAll()
        return change
    }

    package func rebuildPerFolderIgnoreCache(
        changedDirs: Set<String>? = nil
    ) async {
        // Clear all per-path ignore caches to avoid stale decisions
        ignoreCacheStore = IgnoreCacheStore()

        // ── Legacy: full rebuild ────────────────────────────────────────────
        guard let dirs = changedDirs, !dirs.isEmpty else {
            perFolderIgnoreCache.removeAll()
            clearNoIgnoreFilesCache()
            do {
                ignoreRules = try await ignoreRulesManager.getIgnoreRules(
                    for: path,
                    respectGitignore: respectGitignore,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore
                )
                cacheIgnoreRules(ignoreRules, for: "")
            } catch {
                print("Failed to rebuild ignore rules: \(error)")
            }
            return
        }

        // ── Partial invalidation ────────────────────────────────────────────
        // Root ignore changes affect all derived rules; rebuild everything.
        if dirs.contains("") {
            perFolderIgnoreCache.removeAll()
            clearNoIgnoreFilesCache()
            do {
                ignoreRules = try await ignoreRulesManager.getIgnoreRules(
                    for: path,
                    respectGitignore: respectGitignore,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore
                )
                cacheIgnoreRules(ignoreRules, for: "")
            } catch {
                print("Failed to rebuild root ignore rules: \(error)")
            }
            return
        }

        // 1) Remove affected keys from per-folder ignore cache
        let keysToRemove = perFolderIgnoreCache.keys.filter { key in
            dirs.contains { dir in
                key == dir || key.hasPrefix(dir + "/")
            }
        }
        for k in keysToRemove {
            perFolderIgnoreCache.removeValue(forKey: k)
        }

        // 2) Prune the no-ignore file cache
        removeNoIgnoreFilesCached { path in
            dirs.contains { dir in
                path == dir || path.hasPrefix(dir + "/")
            }
        }

        // 3) Root changes are handled above; no further action needed here.
    }

    // MARK: - New prefix-based ignore check (cached in this actor)

    package func cachedIgnoreRules(for directoryPath: String) -> IgnoreRules? {
        perFolderIgnoreCache[directoryPath]
    }

    /// We walk each parent sub-path, caching the result.
    package func isIgnoredPrefixCheck(relativePath: String, isDirectory: Bool = false) -> Bool {
        let comps = pathCompsCache.components(for: relativePath)
        return ignoreCacheStore.isIgnoredPrefixCheck(
            components: comps,
            isDirectory: isDirectory,
            ignoreRules: ignoreRules
        )
    }

    /// Check if a path is ignored using hierarchical rules (for delta events)
    package func isIgnoredHierarchical(relativePath: String, isDirectory overrideValue: Bool? = nil) async -> Bool {
        // Get the file type
        let isDir = overrideValue ?? (visitedItems[relativePath] ?? fileOrFolderIsDir(relativePath))

        // If hierarchical ignores are disabled, use the simple check
        if !enableHierarchicalIgnores {
            return isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: isDir)
        }

        // Create a rules provider that uses our cache and can compute rules on demand
        let provider = FileSystemRulesProvider(service: self)
        let evaluator = HierarchicalIgnoreEvaluator(rulesProvider: provider)

        do {
            return try await evaluator.isIgnored(relativePath: relativePath, isDirectory: isDir)
        } catch {
            // Fall back to simple check if hierarchical evaluation fails
            return isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: isDir)
        }
    }

    /// Hierarchical check that treats the target as a directory regardless of current disk state.
    package func isIgnoredHierarchicalDir(_ relativePath: String) async -> Bool {
        if relativePath.isEmpty {
            return false
        }
        if !enableHierarchicalIgnores {
            return isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: true)
        }

        return await isIgnoredHierarchical(relativePath: relativePath, isDirectory: true)
    }

    /// Rules provider implementation for the hierarchical evaluator
    package final class FileSystemRulesProvider: HierarchicalIgnoreEvaluator.RulesProvider {
        let service: FileSystemService

        init(service: FileSystemService) {
            self.service = service
        }

        package func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules {
            // Check cache first
            if let cached = await service.cachedIgnoreRules(for: directoryPath) {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheHit()
                #endif
                return cached
            }
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheMiss()
            #endif

            // Root directory uses global rules
            if directoryPath.isEmpty {
                return await service.ignoreRules
            }

            // Recursively compute parent rules so nested directories inherit correctly
            let parentPathComponents = directoryPath.split(separator: "/").dropLast()
            let parentPath = parentPathComponents.joined(separator: "/")
            let parentRules = try await rulesForDirectory(parentPath)

            // Compute rules for this directory
            let dirURL = URL(fileURLWithPath: service.path).appendingPathComponent(directoryPath)
            return try await service.effectiveRules(
                for: dirURL,
                parentRelPath: directoryPath,
                parentRules: parentRules
            )
        }
    }

    @discardableResult
    package func ensureRulesChain(for relativeDirectory: String, using scanResult: WorkspaceDirectoryScanResult? = nil) async throws -> IgnoreRules {
        if let cached = perFolderIgnoreCache[relativeDirectory] {
            return cached
        }

        if relativeDirectory.isEmpty {
            cacheIgnoreRules(ignoreRules, for: relativeDirectory)
            return ignoreRules
        }

        let parent = parentDirectory(of: relativeDirectory)
        let parentRules = try await ensureRulesChain(for: parent)
        let absPath = fullPath(forRelativePath: relativeDirectory)

        let scan: WorkspaceDirectoryScanResult = if let provided = scanResult {
            provided
        } else {
            try listDirectoryForCurrentFilesystem(absPath)
        }

        let dirURL = URL(fileURLWithPath: absPath)
        return try await optimizedEffectiveRules(
            for: dirURL,
            parentRelPath: relativeDirectory,
            parentRules: parentRules,
            hasGitignore: scan.hasGitignore && respectGitignore,
            hasRepoIgnore: scan.hasRepoIgnore && respectRepoIgnore,
            hasCursorignore: scan.hasCursorignore && respectCursorignore
        )
    }

    /// If you had snapshot/merge logic:
    package func snapshotIgnoreCache() -> [String: Bool] {
        ignoreCacheStore.snapshotIgnoreCache()
    }

    package func snapshotIgnoreCacheWithPathKeys() -> [IgnoreCacheStore.PathKey: Bool] {
        ignoreCacheStore.snapshotIgnoreCacheWithPathKeys()
    }

    package func mergeIgnoreCache(_ localCache: [String: Bool]) {
        ignoreCacheStore.mergeIgnoreCache(localCache)
    }

    package func mergeIgnoreCache(_ localCache: [IgnoreCacheStore.PathKey: Bool]) {
        guard !localCache.isEmpty else { return }
        ignoreCacheStore.mergeIgnoreCache(localCache)
    }

    public func updateRespectGitignore(_ newValue: Bool) async throws {
        guard respectGitignore != newValue else { return }
        respectGitignore = newValue
        try await refreshIgnoreRules()
    }

    public func updateRespectRepoIgnore(_ newValue: Bool) async throws {
        guard respectRepoIgnore != newValue else { return }
        respectRepoIgnore = newValue
        try await refreshIgnoreRules()
    }

    public func updateRespectCursorignore(_ newValue: Bool) async throws {
        guard respectCursorignore != newValue else { return }
        respectCursorignore = newValue
        try await refreshIgnoreRules()
    }

    public func updateSkipSymlinks(_ newValue: Bool) {
        skipSymlinks = newValue
    }

    public func updateEnableHierarchicalIgnores(_ newValue: Bool) {
        guard enableHierarchicalIgnores != newValue else { return }
        enableHierarchicalIgnores = newValue
        invalidateAllIgnoreCaches()
        if !newValue {
            // Clear the per-folder cache when disabling
            Task { await rebuildPerFolderIgnoreCache() }
        }
    }

    public func refreshIgnoreRules() async throws {
        ignoreRules = try await ignoreRulesManager.getIgnoreRules(
            for: path,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore
        )
        invalidateAllIgnoreCaches()
    }

    package func effectiveRules(
        for dirURL: URL,
        parentRelPath: String,
        parentRules: IgnoreRules
    ) async throws -> IgnoreRules {
        // Performance optimization: batch check both files at once
        // This method is only called when hierarchical ignores are enabled
        // We need to check what files exist
        let scanResult = try listDirectoryForCurrentFilesystem(dirURL.path)
        return try await optimizedEffectiveRules(
            for: dirURL,
            parentRelPath: parentRelPath,
            parentRules: parentRules,
            hasGitignore: scanResult.hasGitignore && respectGitignore,
            hasRepoIgnore: scanResult.hasRepoIgnore && respectRepoIgnore,
            hasCursorignore: scanResult.hasCursorignore && respectCursorignore
        )
    }

    /// Optimized version that minimizes file system operations
    package func optimizedEffectiveRules(
        for dirURL: URL,
        parentRelPath: String,
        parentRules: IgnoreRules,
        hasGitignore: Bool,
        hasRepoIgnore: Bool,
        hasCursorignore: Bool
    ) async throws -> IgnoreRules {
        let hasLocalIgnoreFiles = hasGitignore || hasRepoIgnore || hasCursorignore
        if hasLocalIgnoreFiles {
            removeNoIgnoreFilesCached(parentRelPath)
            perFolderIgnoreCache.removeValue(forKey: parentRelPath)
        }

        // Check cache first
        if let cached = perFolderIgnoreCache[parentRelPath] {
            return cached
        }

        // We already know which files exist from the directory scan
        if !hasLocalIgnoreFiles {
            // Check if we've already determined this directory has no ignore files
            if hasNoIgnoreFilesCached(parentRelPath) {
                // Use parent rules and cache them
                cacheIgnoreRules(parentRules, for: parentRelPath)
                return parentRules
            }
            // No ignore files, use parent rules
            markNoIgnoreFilesCached(parentRelPath)
            cacheIgnoreRules(parentRules, for: parentRelPath)
            return parentRules
        }

        // Clone parent rules and add new layers
        let effectiveRules = parentRules.clone()

        if hasGitignore, respectGitignore {
            let gitignoreURL = dirURL.appendingPathComponent(".gitignore")
            do {
                #if DEBUG
                    let content: String
                    if fm is FileManager {
                        // Use fast production path for real file system
                        content = try String(contentsOf: gitignoreURL, encoding: .utf8)
                    } else {
                        // Test path - use virtual filesystem
                        let data = fm.contents(atPath: gitignoreURL.path) ?? Data()
                        content = String(data: data, encoding: .utf8) ?? ""
                    }
                #else
                    let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
                #endif
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
                effectiveRules.addCompiledLayer(compiled)
            } catch {
                print("Failed to compile .gitignore at \(gitignoreURL.path): \(error)")
            }
        }

        if hasRepoIgnore {
            let repoIgnoreURL = dirURL.appendingPathComponent(".repo_ignore")
            do {
                #if DEBUG
                    let content: String
                    if fm is FileManager {
                        // Use fast production path for real file system
                        content = try String(contentsOf: repoIgnoreURL, encoding: .utf8)
                    } else {
                        // Test path - use virtual filesystem
                        let data = fm.contents(atPath: repoIgnoreURL.path) ?? Data()
                        content = String(data: data, encoding: .utf8) ?? ""
                    }
                #else
                    let content = try String(contentsOf: repoIgnoreURL, encoding: .utf8)
                #endif
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
                effectiveRules.addCompiledLayer(compiled)
            } catch {
                print("Failed to compile .repo_ignore at \(repoIgnoreURL.path): \(error)")
            }
        }

        if hasCursorignore {
            let cursorignoreURL = dirURL.appendingPathComponent(".cursorignore")
            do {
                #if DEBUG
                    let content: String
                    if fm is FileManager {
                        // Use fast production path for real file system
                        content = try String(contentsOf: cursorignoreURL, encoding: .utf8)
                    } else {
                        // Test path - use virtual filesystem
                        let data = fm.contents(atPath: cursorignoreURL.path) ?? Data()
                        content = String(data: data, encoding: .utf8) ?? ""
                    }
                #else
                    let content = try String(contentsOf: cursorignoreURL, encoding: .utf8)
                #endif
                let compiled = GitignoreCompiler.compile(content: content, directoryPath: parentRelPath)
                effectiveRules.addCompiledLayer(compiled)
            } catch {
                print("Failed to compile .cursorignore at \(cursorignoreURL.path): \(error)")
            }
        }

        // Cache and return
        cacheIgnoreRules(effectiveRules, for: parentRelPath)
        return effectiveRules
    }

    package func effectiveRulesSnapshot(
        for dirURL: URL,
        parentRelPath: String,
        hasGitignore: Bool,
        hasRepoIgnore: Bool,
        hasCursorignore: Bool
    ) async throws -> IgnoreRulesSnapshot {
        let parentRel = parentDirectory(of: parentRelPath)
        let parentRules: IgnoreRules = if let cached = perFolderIgnoreCache[parentRel] {
            cached
        } else {
            try await ensureRulesChain(for: parentRel)
        }
        let effectiveRules = try await optimizedEffectiveRules(
            for: dirURL,
            parentRelPath: parentRelPath,
            parentRules: parentRules,
            hasGitignore: hasGitignore,
            hasRepoIgnore: hasRepoIgnore,
            hasCursorignore: hasCursorignore
        )
        return effectiveRules.snapshot()
    }

    /// Cache ignore rules with LRU eviction
    package func cacheIgnoreRules(_ rules: IgnoreRules, for path: String) {
        let evicted = perFolderIgnoreCache.set(rules, forKey: path)
        if let evictedKey = evicted {
            removeNoIgnoreFilesCached(evictedKey)
            if evictedKey == "", path != "" {
                let secondEvicted = perFolderIgnoreCache.set(ignoreRules, forKey: "")
                if let secondKey = secondEvicted {
                    removeNoIgnoreFilesCached(secondKey)
                }
            }
        }
    }

    package func hasNoIgnoreFilesCached(_ path: String) -> Bool {
        noIgnoreFileCache[path] == true
    }

    package func markNoIgnoreFilesCached(_ path: String) {
        _ = noIgnoreFileCache.set(true, forKey: path)
    }

    package func removeNoIgnoreFilesCached(_ path: String) {
        noIgnoreFileCache.removeValue(forKey: path)
    }

    package func removeNoIgnoreFilesCached(where shouldRemove: (String) -> Bool) {
        for key in noIgnoreFileCache.keys where shouldRemove(key) {
            removeNoIgnoreFilesCached(key)
        }
    }

    package func clearNoIgnoreFilesCache() {
        noIgnoreFileCache.removeAll()
    }

    /// Clear all ignore-related caches and seed the root rules.
    package func invalidateAllIgnoreCaches() {
        ignoreCacheStore = IgnoreCacheStore()
        perFolderIgnoreCache.removeAll()
        clearNoIgnoreFilesCache()
        cacheIgnoreRules(ignoreRules, for: "")
    }

    /// Mark a directory as having no ignore files
    package func markNoIgnoreFiles(_ path: String, parentRules: IgnoreRules) {
        markNoIgnoreFilesCached(path)
        cacheIgnoreRules(parentRules, for: path)
    }

    /// Mark a directory as having no ignore files using cached parent rules
    package func markNoIgnoreFilesUsingCache(_ path: String) async throws {
        let parentRel = parentDirectory(of: path)
        let parentRules: IgnoreRules = if let cached = perFolderIgnoreCache[parentRel] {
            cached
        } else {
            try await ensureRulesChain(for: parentRel)
        }
        markNoIgnoreFilesCached(path)
        cacheIgnoreRules(parentRules, for: path)
    }
}
