import CryptoKit
import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin // for stat()
#else
    import Glibc
#endif

/// Shared defaults and legacy key handling for app-wide ignore preferences.
///
/// Kept outside `IgnoreRulesManager` so JSON-backed settings, legacy mirrors,
/// and runtime ignore-rule loading agree on the canonical defaults/version.
enum IgnoreSettingsDefaults {
    static let globalIgnoreDefaultsKey = "globalIgnoreDefaults"
    static let globalIgnoreDefaultsVersionKey = "globalIgnoreDefaultsVersion"
    /// Bump when we add new "required by default" patterns.
    static let currentGlobalIgnoreDefaultsVersion = 2

    /// Canonical default patterns (do NOT include `.git`; that is always ignored separately).
    /// These mirror our "big dirs" heuristic plus a few common temp files.
    static let canonicalGlobalIgnoreDefaults: String = """
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

    static func resolvedGlobalIgnoreDefaults(defaults: UserDefaults = .standard) -> String {
        let storedObject = defaults.object(forKey: globalIgnoreDefaultsKey)
        let stored = defaults.string(forKey: globalIgnoreDefaultsKey)
        let storedVersion = defaults.object(forKey: globalIgnoreDefaultsVersionKey) as? Int ?? 0

        guard storedObject != nil, let stored else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        guard storedVersion < currentGlobalIgnoreDefaultsVersion else {
            return stored
        }

        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        let have = normalizedPatterns(stored)
        let required = normalizedPatterns(canonicalGlobalIgnoreDefaults)
        let missing = required.subtracting(have)

        guard !missing.isEmpty else {
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return stored
        }

        let upgraded = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n# (Auto-upgraded to v\(currentGlobalIgnoreDefaultsVersion))\n"
            + missing.sorted().joined(separator: "\n")
            + "\n"
        defaults.set(upgraded, forKey: globalIgnoreDefaultsKey)
        defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
        return upgraded
    }

    private static func normalizedPatterns(_ text: String) -> Set<String> {
        Set(
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }
}

enum IgnoreRulePolicyResolutionError: Error {
    case ambiguousGitTopology
}

enum MandatoryGitIgnoreControlError: Error {
    case unavailable
    case notRegularFile
    case contentLimitExceeded
    case invalidEncoding
    case changedDuringRead
}

extension IgnoreRulePolicy {
    static func resolvingLoadedRoot(_ rawRoot: URL) throws -> IgnoreRulePolicy {
        let loadedRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        var loadedStatus = stat()
        guard lstat(loadedRoot.path, &loadedStatus) == 0,
              loadedStatus.st_mode & S_IFMT == S_IFDIR
        else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }

        var candidate = loadedRoot
        while true {
            let dotGit = candidate.appendingPathComponent(".git")
            var dotGitStatus = stat()
            if lstat(dotGit.path, &dotGitStatus) == 0 {
                let kind = dotGitStatus.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG,
                      let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate),
                      validatedContainingGitLayout(layout)
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let repositoryRoot = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
                guard repositoryRoot == candidate,
                      loadedRoot.path == repositoryRoot.path
                      || loadedRoot.path.hasPrefix(repositoryRoot.path + "/")
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let relativePath = loadedRoot.path == repositoryRoot.path
                    ? ""
                    : String(loadedRoot.path.dropFirst(repositoryRoot.path.count + 1))
                let prefix = try GitRepositoryRelativeRootPrefix(relativePath)
                guard prefix.value.split(separator: "/").first != ".git" else {
                    throw IgnoreRulePolicyResolutionError.ambiguousGitTopology
                }
                return .gitRoot(repositoryRelativeRootPrefix: prefix)
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard candidate.path != "/" else { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return .nonGitRoot
    }

    private static func validatedContainingGitLayout(_ layout: GitRepositoryLayout) -> Bool {
        func isRegularFile(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
        }
        func isDirectory(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
        }
        return isDirectory(layout.gitDir)
            && isDirectory(layout.commonDir)
            && isRegularFile(layout.gitDir.appendingPathComponent("HEAD"))
            && isRegularFile(layout.commonDir.appendingPathComponent("config"))
            && isDirectory(layout.commonDir.appendingPathComponent("objects"))
    }
}

/// A lightweight manager that builds `IgnoreRules` on demand, with no caching.
actor IgnoreRulesManager {
    struct CompiledRootAuthority {
        let gitignore: CompiledIgnoreRules?
        let global: CompiledIgnoreRules
        let repoIgnore: CompiledIgnoreRules?
        let cursorignore: CompiledIgnoreRules?
    }

    struct ResolvedIgnoreRules {
        let rules: IgnoreRules
        let globalIgnoreDefaultsDigest: String
    }

    static let shared = IgnoreRulesManager()
    private let fileManager = FileManager.default

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

    private init() {}

    #if DEBUG
        /// Detect if we're running under XCTest to make ignore behavior deterministic
        private static let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #endif

    // MARK: - File metadata helper

    /// Compute a unique cache key based on (device, inode, modification time).
    /// Falls back to a hash of the path if `stat()` fails.
    private func fileMetaKey(for url: URL) -> FileMetaKey {
        var st = stat()
        if stat(url.path, &st) == 0 {
            let dev = UInt64(st.st_dev)
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
    func resolvedIgnoreRules(
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
        } else { nil }

        // Always add global ignore defaults from user settings (lower priority)
        let globalIgnoreContent = fetchGlobalDefaults()

        // If enabled and a local .repo_ignore exists, add it with higher priority (overriding global defaults)
        let repoIgnoreContent: String?
        if respectRepoIgnore {
            let repoIgnorePath = (path as NSString).appendingPathComponent(".repo_ignore")
            if fm.fileExists(atPath: repoIgnorePath, isDirectory: nil) {
                repoIgnoreContent = try await loadFileContent(at: repoIgnorePath)
            } else { repoIgnoreContent = nil }
        } else { repoIgnoreContent = nil }

        // If enabled and a local .cursorignore exists, add it with highest local priority.
        let cursorignoreContent: String?
        if respectCursorignore {
            let cursorignorePath = (path as NSString).appendingPathComponent(".cursorignore")
            if fm.fileExists(atPath: cursorignorePath, isDirectory: nil) {
                cursorignoreContent = try await loadFileContent(at: cursorignorePath)
            } else { cursorignoreContent = nil }
        } else { cursorignoreContent = nil }

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
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
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
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repositoryRoot),
              layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL == repositoryRoot
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

    nonisolated static func globalIgnoreDefaultsDigest(for content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func loadMandatoryGitIgnoreContent(
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
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
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

    nonisolated static func decodeMandatoryGitIgnoreContent(
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
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else { throw MandatoryGitIgnoreControlError.unavailable }
        return false
    }

    nonisolated static func compileRootAuthority(
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
    nonisolated static func makeRootRules(
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

    func resolvedGlobalIgnoreContent() -> String {
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
        #if DEBUG
            // In test runs, always return canonical defaults to ensure deterministic behavior.
            // This prevents user-customized patterns from leaking into tests.
            if Self.isRunningTests {
                return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
            }
        #endif

        return IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: .standard)
    }

    /// Asynchronously compile a `.gitignore` / `.repo_ignore` file.
    /// The first caller starts the compilation task; subsequent callers await
    /// the same task, ensuring the file is compiled exactly once.
    func compiledIgnoreFile(at url: URL) async throws -> CompiledIgnoreRules {
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
}
