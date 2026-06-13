import CryptoKit
import Foundation

// ============ The Cache Data Structures ============

struct CodeMapContentFingerprint: Codable, Equatable {
    let contentHash: String
    let byteCount: Int

    init(contentHash: String, byteCount: Int) {
        self.contentHash = contentHash
        self.byteCount = byteCount
    }

    init(content: String) {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        contentHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        byteCount = data.count
    }
}

struct CodeMapCacheFileEntry: Codable {
    let modificationDate: Date
    let contentFingerprint: CodeMapContentFingerprint?
    let fileAPI: FileAPI

    init(
        modificationDate: Date,
        contentFingerprint: CodeMapContentFingerprint,
        fileAPI: FileAPI
    ) {
        self.modificationDate = modificationDate
        self.contentFingerprint = contentFingerprint
        self.fileAPI = fileAPI
    }
}

struct CodeMapCacheRootFolder: Codable {
    var files: [String: CodeMapCacheFileEntry]
}

/// Container to wrap the cache data with a version number.
struct CodeMapCacheContainer: Codable {
    /// Version of the cached data format.
    let version: Int
    /// The actual cache data.
    let rootFolder: CodeMapCacheRootFolder
}

// ============ The Manager ============

class CodeMapCacheManager {
    /// The current cache version.
    private let currentCacheVersion = 6

    /// In‑memory dictionary: root folder path → its cache data
    private var cache: [String: CodeMapCacheRootFolder] = [:]

    /// Tracks which root folders have been modified since the last commit
    private var dirtyRootFolders: Set<String> = []

    // MARK: - Public API

    // NEW: async loader that reads & decodes the entire root cache from disk.
    // No reads/writes to any in-memory state inside this class.
    func loadRootFolderCacheAsync(rootFolderPath: String) async -> CodeMapCacheRootFolder? {
        let codeMapFile = cacheFileURL(forRootFolder: rootFolderPath)
        let currentVersion = currentCacheVersion

        return await Task.detached(priority: .utility) { () -> CodeMapCacheRootFolder? in
            guard FileManager.default.fileExists(atPath: codeMapFile.path) else { return nil }
            do {
                let data = try Data(contentsOf: codeMapFile)
                let container = try JSONDecoder().decode(CodeMapCacheContainer.self, from: data)

                // Purge mismatched versions on the spot (keeps follow-ups fast)
                if container.version == -1 || currentVersion == -1 || container.version != currentVersion {
                    try? FileManager.default.removeItem(at: codeMapFile)
                    print("Purged cache for \(rootFolderPath) due to version mismatch (cached: \(container.version), current: \(currentVersion))")
                    return nil
                }
                return container.rootFolder
            } catch {
                // Silent failure: treat as cache miss
                return nil
            }
        }.value
    }

    /// New: Async/background cache lookup to avoid blocking callers (e.g. actors) on heavy JSON decode.
    /// This method is intentionally side-effect free (no reads/writes to self.cache).
    /// It only checks the on-disk JSON and returns a FileAPI if it is fresh.
    func loadCachedCodeMapAsync(
        rootFolderPath: String,
        relativeFilePath: String,
        currentFullPath: String,
        currentModDate: Date,
        contentFingerprint: CodeMapContentFingerprint
    ) async -> FileAPI? {
        // NOTE:
        // This method is intentionally side-effect free now (no touching self.cache).
        // It only checks the on-disk JSON and returns a FileAPI if it is fresh.

        // Compute cache file URL up front
        let codeMapFile = cacheFileURL(forRootFolder: rootFolderPath)
        let currentVersion = currentCacheVersion

        // Offload disk read + JSON decoding to a detached task
        let loadedRoot: CodeMapCacheRootFolder? = await Task.detached(priority: .utility) { () -> CodeMapCacheRootFolder? in
            guard FileManager.default.fileExists(atPath: codeMapFile.path) else { return nil }
            do {
                let data = try Data(contentsOf: codeMapFile)
                let container = try JSONDecoder().decode(CodeMapCacheContainer.self, from: data)

                // Purge mismatched versions on the spot (keeps follow-ups fast)
                if container.version == -1 || currentVersion == -1 || container.version != currentVersion {
                    try? FileManager.default.removeItem(at: codeMapFile)
                    print("Purged cache for \(rootFolderPath) due to version mismatch (cached: \(container.version), current: \(currentVersion))")
                    return nil
                }
                return container.rootFolder
            } catch {
                // Silent failure: treat as cache miss
                return nil
            }
        }.value

        // Return the requested entry directly if it's fresh and content-identical.
        if let loaded = loadedRoot, let fileEntry = loaded.files[relativeFilePath] {
            return cachedAPI(
                from: fileEntry,
                rootFolderPath: rootFolderPath,
                relativeFilePath: relativeFilePath,
                currentFullPath: currentFullPath,
                currentModDate: currentModDate,
                contentFingerprint: contentFingerprint
            )
        }
        return nil
    }

    /// Looks up a file's cached FileAPI for a given root folder & relative file path.
    /// Returns nil if not present OR if the stored modification date is older than `currentModDate`.
    func loadCachedCodeMap(
        rootFolderPath: String,
        relativeFilePath: String,
        currentFullPath: String,
        currentModDate: Date,
        contentFingerprint: CodeMapContentFingerprint
    ) -> FileAPI? {
        // 1) Check in‑memory first
        if let rootEntry = cache[rootFolderPath],
           let entry = rootEntry.files[relativeFilePath]
        {
            return cachedAPI(
                from: entry,
                rootFolderPath: rootFolderPath,
                relativeFilePath: relativeFilePath,
                currentFullPath: currentFullPath,
                currentModDate: currentModDate,
                contentFingerprint: contentFingerprint
            )
        }

        // 2) Not found in memory → attempt to load from disk
        if let loadedEntry = loadRootFolderCache(from: rootFolderPath) {
            cache[rootFolderPath] = loadedEntry
            if let fileEntry = loadedEntry.files[relativeFilePath] {
                return cachedAPI(
                    from: fileEntry,
                    rootFolderPath: rootFolderPath,
                    relativeFilePath: relativeFilePath,
                    currentFullPath: currentFullPath,
                    currentModDate: currentModDate,
                    contentFingerprint: contentFingerprint
                )
            }
        }

        return nil
    }

    /// Stores or updates a single file’s cache data in memory (no disk write until `commit()`).
    func storeCodeMap(
        rootFolderPath: String,
        relativeFilePath: String,
        modificationDate: Date,
        contentFingerprint: CodeMapContentFingerprint,
        fileAPI: FileAPI
    ) {
        var rootEntry = cache[rootFolderPath] ?? CodeMapCacheRootFolder(files: [:])
        let fileEntry = CodeMapCacheFileEntry(
            modificationDate: modificationDate,
            contentFingerprint: contentFingerprint,
            fileAPI: fileAPI
        )
        rootEntry.files[relativeFilePath] = fileEntry
        cache[rootFolderPath] = rootEntry

        // Mark this root folder as dirty
        dirtyRootFolders.insert(rootFolderPath)
    }

    /// Removes the entire cache (in memory and on disk) for the given root folder.
    func removeRootFolder(_ rootFolderPath: String) {
        cache.removeValue(forKey: rootFolderPath)
        dirtyRootFolders.remove(rootFolderPath)

        let codeMapFileURL = cacheFileURL(forRootFolder: rootFolderPath)
        do {
            if FileManager.default.fileExists(atPath: codeMapFileURL.path) {
                try FileManager.default.removeItem(at: codeMapFileURL)
            }
        } catch {
            print("Failed to remove codeMapCache for \(rootFolderPath): \(error)")
        }
    }

    /// Replaces the entire file dictionary in memory for a given root folder.
    func overwriteRootFolderEntry(rootPath: String, newFilesDict: [String: CodeMapCacheFileEntry]) {
        var rootEntry = cache[rootPath] ?? CodeMapCacheRootFolder(files: [:])
        rootEntry.files = newFilesDict
        cache[rootPath] = rootEntry

        // Mark as dirty
        dirtyRootFolders.insert(rootPath)
    }

    /// Retrieves the root folder’s entire cache (either from memory or disk).
    func fetchRootFolderEntry(_ rootFolderPath: String) -> CodeMapCacheRootFolder? {
        if let entry = cache[rootFolderPath] {
            return entry
        }
        if let loaded = loadRootFolderCache(from: rootFolderPath) {
            cache[rootFolderPath] = loaded
            return loaded
        }
        return nil
    }

    /// Writes to disk only the caches for root folders that have changed.
    func commit() {
        for (rootFolderPath, rootEntry) in cache {
            if dirtyRootFolders.contains(rootFolderPath),
               saveRootFolderCache(rootFolderPath, rootEntry: rootEntry)
            {
                dirtyRootFolders.remove(rootFolderPath)
            }
        }
    }

    /// Removes the in‑memory cache for a given root folder without deleting the on‑disk file.
    /// Useful if a folder is unloaded from the app but we still want to keep the disk cache around.
    func unloadCache(forRootFolder rootFolderPath: String) {
        cache.removeValue(forKey: rootFolderPath)
        dirtyRootFolders.remove(rootFolderPath)
    }

    /// Removes any on-disk caches that do not match the provided root paths.
    func purgeStaleRootCaches(keepingRootPaths: [String]) {
        let normalizedRoots = keepingRootPaths.map { ($0 as NSString).standardizingPath }
        let keepSet = Set(normalizedRoots)
        let keepFiles = Set(normalizedRoots.map { "\(hashedFilename(forRootFolderPath: $0)).json" })

        // Drop in-memory entries that are no longer kept.
        for rootKey in Array(cache.keys) where !keepSet.contains(rootKey) {
            cache.removeValue(forKey: rootKey)
            dirtyRootFolders.remove(rootKey)
        }

        let dir = baseCacheDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in contents where fileURL.pathExtension == "json" {
            if !keepFiles.contains(fileURL.lastPathComponent) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func cachedAPI(
        from entry: CodeMapCacheFileEntry,
        rootFolderPath: String,
        relativeFilePath: String,
        currentFullPath: String,
        currentModDate: Date,
        contentFingerprint: CodeMapContentFingerprint
    ) -> FileAPI? {
        guard entry.modificationDate >= currentModDate else { return nil }
        guard entry.contentFingerprint == contentFingerprint else { return nil }

        let standardizedRoot = StandardizedPath.absolute(rootFolderPath)
        let standardizedFullPath = StandardizedPath.absolute(currentFullPath)
        guard StandardizedPath.isDescendant(standardizedFullPath, of: standardizedRoot) else { return nil }

        let standardizedRelativePath = StandardizedPath.relative(relativeFilePath)
        let expectedFullPath = StandardizedPath.join(
            standardizedRoot: standardizedRoot,
            standardizedRelativePath: standardizedRelativePath
        )
        guard standardizedFullPath == expectedFullPath else { return nil }
        guard StandardizedPath.absolute(entry.fileAPI.filePath) == standardizedFullPath else { return nil }

        return entry.fileAPI
    }

    // MARK: - Private Helpers

    /// Returns the base directory: ~/Library/Application Support/RepoPrompt CE/CodeMapCaches
    private func baseCacheDirectory() -> URL {
        let codeMapDir = MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("CodeMapCaches", isDirectory: true)
        try? FileManager.default.createDirectory(at: codeMapDir, withIntermediateDirectories: true)
        return codeMapDir
    }

    /// Returns an SHA-256 hash for the given string, used as a unique filename.
    private func hashedFilename(forRootFolderPath rootFolderPath: String) -> String {
        let data = Data(rootFolderPath.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func cacheFileURL(forRootFolder rootFolderPath: String) -> URL {
        let folderHash = hashedFilename(forRootFolderPath: rootFolderPath)
        return baseCacheDirectory().appendingPathComponent("\(folderHash).json", isDirectory: false)
    }

    /// Loads the cache for a given root folder from disk.
    private func loadRootFolderCache(from rootFolderPath: String) -> CodeMapCacheRootFolder? {
        let codeMapFile = cacheFileURL(forRootFolder: rootFolderPath)
        guard FileManager.default.fileExists(atPath: codeMapFile.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: codeMapFile)
            let container = try JSONDecoder().decode(CodeMapCacheContainer.self, from: data)

            // Purge cache if the version doesn't match the current supported version.
            if container.version == -1 || currentCacheVersion == -1 || container.version != currentCacheVersion {
                try FileManager.default.removeItem(at: codeMapFile)
                print("Purged cache for \(rootFolderPath) due to version mismatch (cached: \(container.version), current: \(currentCacheVersion))")
                return nil
            }
            return container.rootFolder
        } catch {
            // print("Failed to load codeMapCache from disk (\(codeMapFile.path)): \(error)")
            return nil
        }
    }

    private static let fileSaveQueue = DispatchQueue(label: "com.repoprompt.codeMapCacheManagerFileSaveQueue")

    /// Saves the cache for a given root folder to disk.
    /// CHANGED: made public so the actor can flush its in-memory cache to disk.
    @discardableResult
    func saveRootFolderCache(_ rootFolderPath: String, rootEntry: CodeMapCacheRootFolder) -> Bool {
        Self.fileSaveQueue.sync {
            let codeMapFile = cacheFileURL(forRootFolder: rootFolderPath)
            let directoryURL = codeMapFile.deletingLastPathComponent()
            do {
                if !FileManager.default.fileExists(atPath: directoryURL.path) {
                    try FileManager.default.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                }
                let container = CodeMapCacheContainer(version: currentCacheVersion, rootFolder: rootEntry)
                let data = try JSONEncoder().encode(container)
                try data.write(to: codeMapFile, options: .atomic)
                return true
            } catch {
                print("Failed to save codeMapCache to disk for \(rootFolderPath): \(error)")
                return false
            }
        }
    }
}
