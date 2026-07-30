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

    func rebuildPerFolderIgnoreCache(
        changedDirs: Set<String>? = nil
    ) async {
        let earlyFilterGeneration = watcherEarlyFilter.currentGeneration()
        // Clear all per-path ignore caches to avoid stale decisions
        ignoreCacheStore = IgnoreCacheStore()

        // ── Legacy: full rebuild ────────────────────────────────────────────
        guard let dirs = changedDirs, !dirs.isEmpty else {
            perFolderIgnoreCache.removeAll()
            clearNoIgnoreFilesCache()
            do {
                let resolved = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
                    for: path,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    policy: ignoreRulePolicy
                )
                installResolvedIgnoreRules(resolved)
                cacheIgnoreRules(ignoreRules, for: "")
                watcherEarlyFilter.install(ignoreRules.snapshot(), generation: earlyFilterGeneration)
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
                let resolved = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
                    for: path,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    policy: ignoreRulePolicy
                )
                installResolvedIgnoreRules(resolved)
                cacheIgnoreRules(ignoreRules, for: "")
                watcherEarlyFilter.install(ignoreRules.snapshot(), generation: earlyFilterGeneration)
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
        watcherEarlyFilter.install(ignoreRules.snapshot(), generation: earlyFilterGeneration)
    }

    private func installResolvedIgnoreRules(
        _ resolved: IgnoreRulesManager.ResolvedIgnoreRules
    ) {
        ignoreRules = resolved.rules
        catalogPolicyIdentity = WorkspaceRootCatalogPolicyIdentity(
            schemaVersion: WorkspaceRootCatalogPolicyIdentity.currentSchemaVersion,
            mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
            globalIgnoreDefaultsDigest: resolved.globalIgnoreDefaultsDigest,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            skipSymlinks: skipSymlinks
        )
        ignoreRulesRevision &+= 1
    }

    private func refreshCatalogPolicyIdentityForConfigurationChange() {
        catalogPolicyIdentity = WorkspaceRootCatalogPolicyIdentity(
            schemaVersion: WorkspaceRootCatalogPolicyIdentity.currentSchemaVersion,
            mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
            globalIgnoreDefaultsDigest: catalogPolicyIdentity.globalIgnoreDefaultsDigest,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            skipSymlinks: skipSymlinks
        )
        ignoreRulesRevision &+= 1
    }

    // MARK: - New prefix-based ignore check (cached in this actor)

    func cachedIgnoreRules(for directoryPath: String) -> IgnoreRules? {
        perFolderIgnoreCache[directoryPath]
    }

    /// We walk each parent sub-path, caching the result.
    func isIgnoredPrefixCheck(relativePath: String, isDirectory: Bool = false) -> Bool {
        let comps = pathCompsCache.components(for: relativePath)
        return ignoreCacheStore.isIgnoredPrefixCheck(
            components: comps,
            isDirectory: isDirectory,
            ignoreRules: ignoreRules
        )
    }

    func directoryIsIncludedInOrdinaryCrawl(relativePath: String) async -> Bool {
        let rulesSnapshot: IgnoreRulesSnapshot
        if enableHierarchicalIgnores {
            let parentPath = parentDirectory(of: relativePath)
            guard let rules = try? await FileSystemRulesProvider(service: self)
                .rulesForDirectory(parentPath)
            else { return false }
            rulesSnapshot = rules.snapshot()
        } else {
            rulesSnapshot = ignoreRules.snapshot()
        }

        return WorkspaceCatalogDirectoryReachability.shouldTraverse(
            repositoryRelativeDirectory: relativePath,
            rules: rulesSnapshot
        )
    }

    /// Check if a path is ignored using hierarchical rules (for delta events)
    func isIgnoredHierarchical(relativePath: String, isDirectory overrideValue: Bool? = nil) async -> Bool {
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
    func isIgnoredHierarchicalDir(_ relativePath: String) async -> Bool {
        if relativePath.isEmpty {
            return false
        }
        if !enableHierarchicalIgnores {
            return isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: true)
        }

        return await isIgnoredHierarchical(relativePath: relativePath, isDirectory: true)
    }

    /// Rules provider implementation for the hierarchical evaluator
    final class FileSystemRulesProvider: HierarchicalIgnoreEvaluator.RulesProvider {
        let service: FileSystemService

        init(service: FileSystemService) {
            self.service = service
        }

        func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules {
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
    func ensureRulesChain(for relativeDirectory: String, using scanResult: DirectoryScanResult? = nil) async throws -> IgnoreRules {
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

        let scan: DirectoryScanResult
        if let provided = scanResult {
            scan = provided
        } else {
            #if DEBUG
                scan = try Self.listDirectoryWithIgnoreDetection(absPath, fm: fm)
            #else
                scan = try Self.listDirectoryWithIgnoreDetection(absPath)
            #endif
        }

        let dirURL = URL(fileURLWithPath: absPath)
        return try await optimizedEffectiveRules(
            for: dirURL,
            parentRelPath: relativeDirectory,
            parentRules: parentRules,
            hasGitignore: scan.hasGitignore,
            hasRepoIgnore: scan.hasRepoIgnore && respectRepoIgnore,
            hasCursorignore: scan.hasCursorignore && respectCursorignore
        )
    }

    /// If you had snapshot/merge logic:
    func snapshotIgnoreCache() -> [String: Bool] {
        ignoreCacheStore.snapshotIgnoreCache()
    }

    func snapshotIgnoreCacheWithPathKeys() -> [IgnoreCacheStore.PathKey: Bool] {
        ignoreCacheStore.snapshotIgnoreCacheWithPathKeys()
    }

    func mergeIgnoreCache(_ localCache: [String: Bool]) {
        ignoreCacheStore.mergeIgnoreCache(localCache)
    }

    func mergeIgnoreCache(_ localCache: [IgnoreCacheStore.PathKey: Bool]) {
        guard !localCache.isEmpty else { return }
        ignoreCacheStore.mergeIgnoreCache(localCache)
    }

    public func updateRespectRepoIgnore(_ newValue: Bool) async throws {
        guard respectRepoIgnore != newValue else { return }
        let resolved = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
            for: path,
            respectRepoIgnore: newValue,
            respectCursorignore: respectCursorignore,
            policy: ignoreRulePolicy
        )
        respectRepoIgnore = newValue
        installResolvedIgnoreRules(resolved)
        invalidateAllIgnoreCaches()
    }

    public func updateRespectCursorignore(_ newValue: Bool) async throws {
        guard respectCursorignore != newValue else { return }
        let resolved = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
            for: path,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: newValue,
            policy: ignoreRulePolicy
        )
        respectCursorignore = newValue
        installResolvedIgnoreRules(resolved)
        invalidateAllIgnoreCaches()
    }

    public func updateSkipSymlinks(_ newValue: Bool) {
        guard skipSymlinks != newValue else { return }
        skipSymlinks = newValue
        refreshCatalogPolicyIdentityForConfigurationChange()
    }

    public func updateEnableHierarchicalIgnores(_ newValue: Bool) {
        guard enableHierarchicalIgnores != newValue else { return }
        enableHierarchicalIgnores = newValue
        refreshCatalogPolicyIdentityForConfigurationChange()
        invalidateAllIgnoreCaches()
        if !newValue {
            // Clear the per-folder cache when disabling
            Task { await rebuildPerFolderIgnoreCache() }
        }
    }

    public func refreshIgnoreRules() async throws {
        let earlyFilterGeneration = watcherEarlyFilter.invalidate()
        let resolved = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
            for: path,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: ignoreRulePolicy
        )
        installResolvedIgnoreRules(resolved)
        invalidateAllIgnoreCaches()
        watcherEarlyFilter.install(ignoreRules.snapshot(), generation: earlyFilterGeneration)
    }

    func effectiveRules(
        for dirURL: URL,
        parentRelPath: String,
        parentRules: IgnoreRules
    ) async throws -> IgnoreRules {
        // Performance optimization: batch check both files at once
        // This method is only called when hierarchical ignores are enabled
        // We need to check what files exist
        #if DEBUG
            let scanResult = try Self.listDirectoryWithIgnoreDetection(dirURL.path, fm: fm)
        #else
            let scanResult = try Self.listDirectoryWithIgnoreDetection(dirURL.path)
        #endif
        return try await optimizedEffectiveRules(
            for: dirURL,
            parentRelPath: parentRelPath,
            parentRules: parentRules,
            hasGitignore: scanResult.hasGitignore,
            hasRepoIgnore: scanResult.hasRepoIgnore && respectRepoIgnore,
            hasCursorignore: scanResult.hasCursorignore && respectCursorignore
        )
    }

    /// Optimized version that minimizes file system operations
    func optimizedEffectiveRules(
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
        let repositoryRelativeDirectory = ignoreRulePolicy.repositoryRelativePath(appending: parentRelPath)

        if hasGitignore {
            let gitignoreURL = dirURL.appendingPathComponent(".gitignore")
            do {
                let content: String
                if ignoreRulePolicy.enforcesGitIgnoreFloor {
                    content = try IgnoreRulesManager.loadMandatoryGitIgnoreContent(at: gitignoreURL)
                } else {
                    #if DEBUG
                        if fm is FileManager {
                            content = try String(contentsOf: gitignoreURL, encoding: .utf8)
                        } else {
                            let data = fm.contents(atPath: gitignoreURL.path) ?? Data()
                            content = String(data: data, encoding: .utf8) ?? ""
                        }
                    #else
                        content = try String(contentsOf: gitignoreURL, encoding: .utf8)
                    #endif
                }
                let compiled = GitignoreCompiler.compile(
                    content: content,
                    directoryPath: repositoryRelativeDirectory
                )
                effectiveRules.addCompiledLayer(compiled, authority: .mandatoryGit)
            } catch {
                if ignoreRulePolicy.enforcesGitIgnoreFloor { throw error }
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
                let compiled = GitignoreCompiler.compile(
                    content: content,
                    directoryPath: repositoryRelativeDirectory
                )
                effectiveRules.addCompiledLayer(compiled, authority: .secondary)
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
                let compiled = GitignoreCompiler.compile(
                    content: content,
                    directoryPath: repositoryRelativeDirectory
                )
                effectiveRules.addCompiledLayer(compiled, authority: .secondary)
            } catch {
                print("Failed to compile .cursorignore at \(cursorignoreURL.path): \(error)")
            }
        }

        // Cache and return
        cacheIgnoreRules(effectiveRules, for: parentRelPath)
        return effectiveRules
    }

    func effectiveRulesSnapshot(
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
    func cacheIgnoreRules(_ rules: IgnoreRules, for path: String) {
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

    func hasNoIgnoreFilesCached(_ path: String) -> Bool {
        noIgnoreFileCache[path] == true
    }

    func markNoIgnoreFilesCached(_ path: String) {
        _ = noIgnoreFileCache.set(true, forKey: path)
    }

    func removeNoIgnoreFilesCached(_ path: String) {
        noIgnoreFileCache.removeValue(forKey: path)
    }

    func removeNoIgnoreFilesCached(where shouldRemove: (String) -> Bool) {
        for key in noIgnoreFileCache.keys where shouldRemove(key) {
            removeNoIgnoreFilesCached(key)
        }
    }

    func clearNoIgnoreFilesCache() {
        noIgnoreFileCache.removeAll()
    }

    /// Clear all ignore-related caches and seed the root rules.
    func invalidateAllIgnoreCaches() {
        ignoreCacheStore = IgnoreCacheStore()
        perFolderIgnoreCache.removeAll()
        clearNoIgnoreFilesCache()
        cacheIgnoreRules(ignoreRules, for: "")
    }

    /// Mark a directory as having no ignore files
    func markNoIgnoreFiles(_ path: String, parentRules: IgnoreRules) {
        markNoIgnoreFilesCached(path)
        cacheIgnoreRules(parentRules, for: path)
    }

    /// Mark a directory as having no ignore files using cached parent rules
    func markNoIgnoreFilesUsingCache(_ path: String) async throws {
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
