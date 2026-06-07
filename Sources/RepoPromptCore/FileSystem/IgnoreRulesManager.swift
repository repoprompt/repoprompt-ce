import Foundation

/// Shared defaults and legacy key handling for app-wide ignore preferences.
///
/// Kept outside `IgnoreRulesManager` so JSON-backed settings, legacy mirrors,
/// and runtime ignore-rule loading agree on the canonical defaults/version.
package enum IgnoreSettingsDefaults {
    package static let globalIgnoreDefaultsKey = "globalIgnoreDefaults"
    package static let globalIgnoreDefaultsVersionKey = "globalIgnoreDefaultsVersion"
    /// Bump when we add new "required by default" patterns.
    package static let currentGlobalIgnoreDefaultsVersion = 2

    /// Canonical default patterns (do NOT include `.git`; that is always ignored separately).
    /// These mirror our "big dirs" heuristic plus a few common temp files.
    package static let canonicalGlobalIgnoreDefaults: String = """
    # RepoPrompt global ignore defaults (v\(currentGlobalIgnoreDefaultsVersion))
    **/node_modules/
    **/.npm/
    **/.pnpm-store/
    **/.yarn/
    **/.cache/
    **/bower_components/

    **/__pycache__/
    **/.pytest_cache/
    **/.mypy_cache/

    **/.gradle/
    **/.m2/
    **/.nuget/
    **/.cargo/
    **/.stack-work/
    **/.ccache/

    **/.idea/
    **/.vscode/
    **/.bundle/
    **/.gem/

    # Virtual environments
    **/.venv/
    **/venv/

    # Common temp/junk files
    **/*.swp
    **/*~
    **/*.tmp
    **/*.temp
    **/*.bak
    """
}

/// A lightweight manager that builds `IgnoreRules` on demand, with no caching.
package actor IgnoreRulesManager {
    private let fileManager = FileManager.default
    private let globalIgnoreDefaults: String

    #if DEBUG
        private var fileManagerOverride: (any FileSystemProviding)?

        func setFileManagerOverride(_ fm: (any FileSystemProviding)?) {
            fileManagerOverride = fm
        }

        private var fm: any FileSystemProviding {
            fileManagerOverride ?? fileManager
        }
    #else
        private var fm: FileManager {
            fileManager
        }
    #endif

    private let ioSemaphore = WorkspaceTaskSemaphore(4) // Max 4 concurrent file reads
    /// Compile-result cache keyed by (dev, ino, mtime) to avoid duplicate work across symlinks.
    private struct FileMetaKey: Hashable {
        let dev: UInt64
        let ino: UInt64
        let mtime: UInt64
    }

    private var compiledCache = LRUCache<FileMetaKey, Task<CompiledIgnoreRules, Error>>(
        capacity: 500
    ) // metadata → task

    package init(globalIgnoreDefaults: String) {
        self.globalIgnoreDefaults = globalIgnoreDefaults
    }

    #if DEBUG
        /// Detect if we're running under XCTest to make ignore behavior deterministic
        private static let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #endif

    // MARK: - File metadata helper

    /// Compute a unique cache key based on (device, inode, modification time).
    /// Falls back to a hash of the path if `stat()` fails.
    private func fileMetaKey(for url: URL) -> FileMetaKey {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey])
        let identifier = values?.fileResourceIdentifier.map { String(describing: $0) } ?? url.path
        return FileMetaKey(
            dev: 0,
            ino: UInt64(bitPattern: Int64(identifier.hashValue)),
            mtime: UInt64(max(0, values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        )
    }

    /// Loads .gitignore and/or .repo_ignore content from disk, merges them into a single IgnoreRules.
    package func getIgnoreRules(
        for path: String,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true
    ) async throws -> IgnoreRules {
        let ignoreRules = IgnoreRules()

        // If we want to load .gitignore content:
        if respectGitignore {
            let gitignorePath = (path as NSString).appendingPathComponent(".gitignore")
            if fm.fileExists(atPath: gitignorePath, isDirectory: nil) {
                let gitignoreContent = try await loadFileContent(at: gitignorePath)
                ignoreRules.addIgnoreFile(content: gitignoreContent, priority: 1)
            }
        }

        // Always add global ignore defaults from user settings (lower priority)
        let globalIgnoreContent = fetchGlobalDefaults()
        ignoreRules.addIgnoreFile(content: globalIgnoreContent, priority: 2)

        // If enabled and a local .repo_ignore exists, add it with higher priority (overriding global defaults)
        if respectRepoIgnore {
            let repoIgnorePath = (path as NSString).appendingPathComponent(".repo_ignore")
            if fm.fileExists(atPath: repoIgnorePath, isDirectory: nil) {
                let repoIgnoreContent = try await loadFileContent(at: repoIgnorePath)
                ignoreRules.addIgnoreFile(content: repoIgnoreContent, priority: 3)
            }
        }

        // If enabled and a local .cursorignore exists, add it with highest local priority.
        if respectCursorignore {
            let cursorignorePath = (path as NSString).appendingPathComponent(".cursorignore")
            if fm.fileExists(atPath: cursorignorePath, isDirectory: nil) {
                let cursorignoreContent = try await loadFileContent(at: cursorignorePath)
                ignoreRules.addIgnoreFile(content: cursorignoreContent, priority: 4)
            }
        }

        return ignoreRules
    }

    private func loadFileContent(at path: String) async throws -> String {
        #if DEBUG
            if let data = fm.contents(atPath: path),
               let str = String(data: data, encoding: .utf8)
            {
                return str
            }
        #endif
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func fetchGlobalDefaults() -> String {
        #if DEBUG
            if Self.isRunningTests {
                return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
            }
        #endif
        return globalIgnoreDefaults
    }

    /// Asynchronously compile a `.gitignore` / `.repo_ignore` file.
    /// The first caller starts the compilation task; subsequent callers await
    /// the same task, ensuring the file is compiled exactly once.
    package func compiledIgnoreFile(at url: URL) async throws -> CompiledIgnoreRules {
        let key = fileMetaKey(for: url)

        // Fast path: if we already have a task in-flight or completed, just await it.
        if let existing = compiledCache[key] {
            return try await existing.value
        }

        // Create a single shared compilation task.
        let task = Task<CompiledIgnoreRules, Error> {
            // Bounded parallelism
            await ioSemaphore.acquire()
            do {
                // Perform the (blocking) file read on the current executor – it's fine
                // because we have limited the total number of concurrent reads.
                let txt = try String(contentsOf: url, encoding: .utf8)

                // Compile patterns
                let compiled = GitignoreCompiler.compile(content: txt)

                // Release the permit before returning
                await ioSemaphore.release()
                return compiled
            } catch {
                // Make sure we always release the permit
                await ioSemaphore.release()
                throw error
            }
        }

        // Store the task so subsequent callers share it.
        compiledCache[key] = task

        do {
            return try await task.value
        } catch {
            // On failure remove from cache so a later attempt can retry.
            compiledCache.removeValue(forKey: key)
            throw error
        }
    }

    /// Deprecated synchronous helper kept for backward compatibility.
    /// Internally forwards to the new async version.
    package func compileIgnoreFile(at url: URL) throws -> CompiledIgnoreRules {
        // Blocking on async helper – acceptable because it is used only in tests.
        let semaphore = DispatchSemaphore(value: 0)
        var output: CompiledIgnoreRules!
        var caughtErr: Error?

        Task {
            do { output = try await compiledIgnoreFile(at: url) }
            catch { caughtErr = error }
            semaphore.signal()
        }
        semaphore.wait()

        if let err = caughtErr { throw err }
        return output
    }
}
