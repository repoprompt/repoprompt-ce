import CryptoKit
import Foundation
import RepoPromptFoundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin // for stat()
#else
    import Glibc
#endif

package enum IgnoreRulePolicyResolutionError: Error {
    case ambiguousGitTopology
}

package enum MandatoryGitIgnoreControlError: Error {
    case unavailable
    case notRegularFile
    case contentLimitExceeded
    case invalidEncoding
    case changedDuringRead
}

/// A lightweight manager that builds `IgnoreRules` on demand, with no caching.
package actor IgnoreRulesManager {
    package struct CompiledRootAuthority {
        package let gitignore: CompiledIgnoreRules?
        package let global: CompiledIgnoreRules
        package let repoIgnore: CompiledIgnoreRules?
        package let cursorignore: CompiledIgnoreRules?
    }

    package struct ResolvedIgnoreRules {
        package let rules: IgnoreRules
        package let globalIgnoreDefaultsDigest: String
    }

    private let fileManager = FileManager.default

    #if DEBUG
        private var fileManagerOverride: (any FileSystemProviding)?

        package func setFileManagerOverride(_ fm: (any FileSystemProviding)?) {
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

    private let ioSemaphore = TaskSemaphore(4) // Max 4 concurrent file reads
    /// Compile-result cache keyed by (dev, ino, mtime) to avoid duplicate work across symlinks.
    private struct FileMetaKey: Hashable {
        let dev: UInt64
        let ino: UInt64
        let mtime: UInt64
    }

    private var compiledCache = LRUCache<FileMetaKey, Task<CompiledIgnoreRules, Error>>(
        capacity: 500
    ) // metadata → task

    private let globalIgnoreProvider: @Sendable () -> String
    private nonisolated let ignorePolicyResolver: @Sendable (URL) throws -> IgnoreRulePolicy
    private let repositoryRootValidator: @Sendable (URL) -> Bool

    package init(
        globalIgnoreProvider: @escaping @Sendable () -> String,
        ignorePolicyResolver: @escaping @Sendable (URL) throws -> IgnoreRulePolicy,
        repositoryRootValidator: @escaping @Sendable (URL) -> Bool
    ) {
        self.globalIgnoreProvider = globalIgnoreProvider
        self.ignorePolicyResolver = ignorePolicyResolver
        self.repositoryRootValidator = repositoryRootValidator
    }

    package nonisolated func resolvingLoadedRoot(_ root: URL) throws -> IgnoreRulePolicy {
        try ignorePolicyResolver(root)
    }

    // MARK: - File metadata helper

    /// Compute a unique cache key based on (device, inode, modification time).
    /// Falls back to a hash of the path if `stat()` fails.
    private func fileMetaKey(for url: URL) -> FileMetaKey {
        var st = stat()
        if stat(url.path, &st) == 0 {
            let dev = safeDeviceID(st.st_dev)
            let ino = UInt64(st.st_ino)
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                let mtime = UInt64(st.st_mtimespec.tv_sec)
            #else
                let mtime = UInt64(st.st_mtim.tv_sec)
            #endif
            return FileMetaKey(dev: dev, ino: ino, mtime: mtime)
        }
        // Fallback – rare (e.g. file deleted between calls)
        return FileMetaKey(
            dev: 0,
            ino: UInt64(url.path.hashValue),
            mtime: 0
        )
    }

    /// Loads .gitignore and/or .repo_ignore content from disk, merges them into a single IgnoreRules.
    package func resolvedIgnoreRules(
        for path: String,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        policy: IgnoreRulePolicy
    ) async throws -> ResolvedIgnoreRules {
        if case let .gitRoot(repositoryRelativeRootPrefix) = policy {
            return try await resolvedGitIgnoreRules(
                loadedPath: path,
                repositoryRelativeRootPrefix: repositoryRelativeRootPrefix,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                policy: policy
            )
        }
        let gitignorePath = (path as NSString).appendingPathComponent(".gitignore")
        let gitignoreContent: String? = if fm.fileExists(atPath: gitignorePath, isDirectory: nil) {
            try await loadFileContent(at: gitignorePath)
        } else {
            nil
        }

        // Always add global ignore defaults from user settings (lower priority)
        let globalIgnoreContent = fetchGlobalDefaults()

        // If enabled and a local .repo_ignore exists, add it with higher priority (overriding global defaults)
        let repoIgnoreContent: String?
        if respectRepoIgnore {
            let repoIgnorePath = (path as NSString).appendingPathComponent(".repo_ignore")
            if fm.fileExists(atPath: repoIgnorePath, isDirectory: nil) {
                repoIgnoreContent = try await loadFileContent(at: repoIgnorePath)
            } else {
                repoIgnoreContent = nil
            }
        } else {
            repoIgnoreContent = nil
        }

        // If enabled and a local .cursorignore exists, add it with highest local priority.
        let cursorignoreContent: String?
        if respectCursorignore {
            let cursorignorePath = (path as NSString).appendingPathComponent(".cursorignore")
            if fm.fileExists(atPath: cursorignorePath, isDirectory: nil) {
                cursorignoreContent = try await loadFileContent(at: cursorignorePath)
            } else {
                cursorignoreContent = nil
            }
        } else {
            cursorignoreContent = nil
        }

        let authority = Self.compileRootAuthority(
            gitignoreContent: gitignoreContent,
            globalIgnoreContent: globalIgnoreContent,
            repoIgnoreContent: repoIgnoreContent,
            cursorignoreContent: cursorignoreContent
        )
        let ignoreRules = Self.makeRootRules(
            authority: authority,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: policy
        )

        return ResolvedIgnoreRules(
            rules: ignoreRules,
            globalIgnoreDefaultsDigest: Self.globalIgnoreDefaultsDigest(for: globalIgnoreContent)
        )
    }

    private func resolvedGitIgnoreRules(
        loadedPath: String,
        repositoryRelativeRootPrefix: any IgnoreRepositoryRootPrefix,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy
    ) async throws -> ResolvedIgnoreRules {
        let loadedRoot = URL(fileURLWithPath: loadedPath).resolvingSymlinksInPath().standardizedFileURL
        let prefixComponents = repositoryRelativeRootPrefix.value.split(separator: "/").map(String.init)
        var repositoryRoot = loadedRoot
        for _ in prefixComponents {
            repositoryRoot.deleteLastPathComponent()
        }
        guard repositoryRootValidator(repositoryRoot)
        else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }

        let globalIgnoreContent = fetchGlobalDefaults()
        let rules = IgnoreRules(policy: policy)
        var directory = repositoryRoot
        var relativeDirectory = ""
        for depth in 0 ... prefixComponents.count {
            let gitignoreURL = directory.appendingPathComponent(".gitignore")
            if try Self.mandatoryGitIgnoreControlExists(at: gitignoreURL) {
                let content = try Self.loadMandatoryGitIgnoreContent(
                    at: gitignoreURL
                )
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                    authority: .mandatoryGit
                )
            }
            if depth == 0 {
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: globalIgnoreContent),
                    authority: .secondary
                )
            }
            if respectRepoIgnore {
                let repoIgnorePath = directory.appendingPathComponent(".repo_ignore").path
                if fm.fileExists(atPath: repoIgnorePath, isDirectory: nil) {
                    let content = try await loadFileContent(at: repoIgnorePath)
                    rules.addCompiledLayer(
                        GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                        authority: .secondary
                    )
                }
            }
            if respectCursorignore {
                let cursorignorePath = directory.appendingPathComponent(".cursorignore").path
                if fm.fileExists(atPath: cursorignorePath, isDirectory: nil) {
                    let content = try await loadFileContent(at: cursorignorePath)
                    rules.addCompiledLayer(
                        GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                        authority: .secondary
                    )
                }
            }
            guard depth < prefixComponents.count else { break }
            let component = prefixComponents[depth]
            directory.appendPathComponent(component, isDirectory: true)
            relativeDirectory = relativeDirectory.isEmpty ? component : relativeDirectory + "/" + component
        }
        guard directory == loadedRoot else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
        return ResolvedIgnoreRules(
            rules: rules,
            globalIgnoreDefaultsDigest: Self.globalIgnoreDefaultsDigest(for: globalIgnoreContent)
        )
    }

    package nonisolated static func globalIgnoreDefaultsDigest(for content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    package nonisolated static func loadMandatoryGitIgnoreContent(
        at url: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MandatoryGitIgnoreControlError.unavailable }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw MandatoryGitIgnoreControlError.unavailable
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw MandatoryGitIgnoreControlError.notRegularFile
        }
        var data = Data()
        var buffer = Data(count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if amount == 0 {
                break
            }
            if amount < 0 {
                if errno == EINTR {
                    continue
                }
                throw MandatoryGitIgnoreControlError.unavailable
            }
            let (nextCount, overflow) = data.count.addingReportingOverflow(amount)
            guard !overflow, nextCount <= maximumBytes else {
                throw MandatoryGitIgnoreControlError.contentLimitExceeded
            }
            data.append(buffer.prefix(amount))
        }
        var after = stat()
        var rebound = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &rebound) == 0,
              rebound.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              rebound.st_dev == before.st_dev,
              rebound.st_ino == before.st_ino
        else { throw MandatoryGitIgnoreControlError.changedDuringRead }
        return try decodeMandatoryGitIgnoreContent(data, maximumBytes: maximumBytes)
    }

    package nonisolated static func decodeMandatoryGitIgnoreContent(
        _ data: Data,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        guard data.count <= maximumBytes else {
            throw MandatoryGitIgnoreControlError.contentLimitExceeded
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw MandatoryGitIgnoreControlError.invalidEncoding
        }
        return content
    }

    private nonisolated static func mandatoryGitIgnoreControlExists(at url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            return true
        }
        guard errno == ENOENT else { throw MandatoryGitIgnoreControlError.unavailable }
        return false
    }

    package nonisolated static func compileRootAuthority(
        gitignoreContent: String?,
        globalIgnoreContent: String,
        repoIgnoreContent: String?,
        cursorignoreContent: String?
    ) -> CompiledRootAuthority {
        CompiledRootAuthority(
            gitignore: gitignoreContent.map { GitignoreCompiler.compile(content: $0) },
            global: GitignoreCompiler.compile(content: globalIgnoreContent),
            repoIgnore: repoIgnoreContent.map { GitignoreCompiler.compile(content: $0) },
            cursorignore: cursorignoreContent.map { GitignoreCompiler.compile(content: $0) }
        )
    }

    /// Builds the authoritative ordinary-crawl root chain. For Git roots, Git's
    /// own ignore chain is a mandatory floor: global/app controls may add
    /// exclusions but their negations cannot re-include a Git-ignored path.
    /// Non-Git callers retain the historical single-chain precedence.
    package nonisolated static func makeRootRules(
        authority: CompiledRootAuthority,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy
    ) -> IgnoreRules {
        let rules = IgnoreRules(policy: policy)
        if let gitignore = authority.gitignore {
            rules.addCompiledLayer(gitignore, authority: .mandatoryGit)
        }
        rules.addCompiledLayer(authority.global, authority: .secondary)
        if respectRepoIgnore, let repoIgnore = authority.repoIgnore {
            rules.addCompiledLayer(repoIgnore, authority: .secondary)
        }
        if respectCursorignore, let cursorignore = authority.cursorignore {
            rules.addCompiledLayer(cursorignore, authority: .secondary)
        }
        return rules
    }

    package func resolvedGlobalIgnoreContent() -> String {
        fetchGlobalDefaults()
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
        globalIgnoreProvider()
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
            guard await ioSemaphore.acquire() else { throw CancellationError() }
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
}
