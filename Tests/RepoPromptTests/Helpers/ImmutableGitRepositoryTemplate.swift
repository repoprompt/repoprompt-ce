import Darwin
import Foundation

enum ImmutableGitRepositoryTemplate {
    enum Kind: String, Hashable {
        case configuredMain
        case gitWorktreeReceiptBase
    }

    private static let cache = Cache()
    private static let cleanupRegistration: Void = {
        atexit {
            ImmutableGitRepositoryTemplate.cleanupForProcessExit()
        }
    }()

    static func copy(_ kind: Kind, to destinationURL: URL) throws {
        _ = cleanupRegistration
        try cache.copy(kind, to: destinationURL.standardizedFileURL)
    }

    private static func cleanupForProcessExit() {
        cache.cleanup()
    }
}

private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var repositories: [ImmutableGitRepositoryTemplate.Kind: TemplateRepository] = [:]

    func copy(_ kind: ImmutableGitRepositoryTemplate.Kind, to destinationURL: URL) throws {
        let repository = try template(for: kind)
        try repository.copy(to: destinationURL)
    }

    func cleanup() {
        lock.lock()
        let repositoriesToRemove = Array(repositories.values)
        repositories.removeAll()
        lock.unlock()

        for repository in repositoriesToRemove {
            repository.cleanup()
        }
    }

    private func template(for kind: ImmutableGitRepositoryTemplate.Kind) throws -> TemplateRepository {
        lock.lock()
        defer { lock.unlock() }
        if let repository = repositories[kind] {
            return repository
        }
        let repository = try TemplateRepository.create(kind: kind)
        repositories[kind] = repository
        return repository
    }
}

private final class TemplateRepository: @unchecked Sendable {
    private struct FileIdentity {
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt64
    }

    private enum GitEnvironment {
        case reviewFixture
        case receiptFixture
    }

    private let kind: ImmutableGitRepositoryTemplate.Kind
    private let containerURL: URL
    private let repositoryURL: URL
    private let environment: GitEnvironment
    private let expectedHead: String?
    private let expectedBranch: String
    private let expectedTrackedPaths: Set<String>
    private let expectedFileContents: [String: String]

    static func create(kind: ImmutableGitRepositoryTemplate.Kind) throws -> TemplateRepository {
        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ImmutableGitRepositoryTemplate-\(kind.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        do {
            let repositoryURL = containerURL.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

            let repository: TemplateRepository
            switch kind {
            case .configuredMain:
                let environment: GitEnvironment = .reviewFixture
                try configureRepository(at: repositoryURL, environment: environment, checkoutMain: true)
                repository = TemplateRepository(
                    kind: kind,
                    containerURL: containerURL,
                    repositoryURL: repositoryURL,
                    environment: environment,
                    expectedHead: nil,
                    expectedBranch: "main",
                    expectedTrackedPaths: [],
                    expectedFileContents: [:]
                )
            case .gitWorktreeReceiptBase:
                let environment: GitEnvironment = .receiptFixture
                try configureRepository(at: repositoryURL, environment: environment, checkoutMain: false)
                let trackedFiles = [
                    "Tracked.swift": "let value = 1\n",
                    ".gitignore": "secret.txt\nnested/ignored.txt\n",
                    ".worktreeinclude": "secret.txt\nnested/ignored.txt\n"
                ]
                let ignoredFiles = [
                    "secret.txt": "ephemeral secret\n",
                    "nested/ignored.txt": "nested ephemeral secret\n"
                ]
                for (path, contents) in trackedFiles.merging(ignoredFiles, uniquingKeysWith: { current, _ in current }) {
                    try write(contents, to: path, at: repositoryURL)
                }
                try runGit(["add", "Tracked.swift", ".gitignore", ".worktreeinclude"], cwd: repositoryURL, environment: environment)
                try runGit(["commit", "-m", "base"], cwd: repositoryURL, environment: environment)
                let expectedHead = try runGit(["rev-parse", "HEAD"], cwd: repositoryURL, environment: environment)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedBranch = try runGit(["branch", "--show-current"], cwd: repositoryURL, environment: environment)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                repository = TemplateRepository(
                    kind: kind,
                    containerURL: containerURL,
                    repositoryURL: repositoryURL,
                    environment: environment,
                    expectedHead: expectedHead,
                    expectedBranch: expectedBranch,
                    expectedTrackedPaths: Set(trackedFiles.keys),
                    expectedFileContents: trackedFiles.merging(ignoredFiles, uniquingKeysWith: { current, _ in current })
                )
            }

            let failures = repository.immutabilityFailures()
            guard failures.isEmpty else {
                throw repository.error(code: 1, message: failures.joined(separator: "; "))
            }
            return repository
        } catch {
            try? FileManager.default.removeItem(at: containerURL)
            throw error
        }
    }

    func copy(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try copyTemplateContentsIntoExistingEmptyDirectory(destinationURL)
        } else {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: repositoryURL, to: destinationURL)
        }
        try validateRepositoryLayout(at: destinationURL)

        let templateFiles = try regularFileIdentities(in: repositoryURL)
        let copiedFiles = try regularFileIdentities(in: destinationURL)
        guard Set(templateFiles.keys) == Set(copiedFiles.keys) else {
            throw error(code: 3, message: "Git template copy did not preserve the exact regular-file set")
        }
        for relativePath in templateFiles.keys.sorted() {
            guard let templateIdentity = templateFiles[relativePath], let copiedIdentity = copiedFiles[relativePath] else {
                continue
            }
            guard templateIdentity.linkCount == 1, copiedIdentity.linkCount == 1 else {
                throw error(code: 4, message: "Hardlinked regular file detected at \(relativePath)")
            }
            guard templateIdentity.device != copiedIdentity.device || templateIdentity.inode != copiedIdentity.inode else {
                throw error(code: 5, message: "Git template and scenario copy share an inode at \(relativePath)")
            }
        }
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: containerURL.path) else { return }
        try? FileManager.default.removeItem(at: containerURL)
    }

    private func copyTemplateContentsIntoExistingEmptyDirectory(_ destinationURL: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error(code: 2, message: "Git template copy destination already exists and is not a directory: \(destinationURL.path)")
        }
        let existingContents = try fileManager.contentsOfDirectory(atPath: destinationURL.path)
        guard existingContents.isEmpty else {
            throw error(code: 3, message: "Git template copy destination is not empty: \(destinationURL.path)")
        }
        let templateContents = try fileManager.contentsOfDirectory(
            at: repositoryURL,
            includingPropertiesForKeys: nil
        )
        for sourceURL in templateContents {
            try fileManager.copyItem(
                at: sourceURL,
                to: destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            )
        }
    }

    private init(
        kind: ImmutableGitRepositoryTemplate.Kind,
        containerURL: URL,
        repositoryURL: URL,
        environment: GitEnvironment,
        expectedHead: String?,
        expectedBranch: String,
        expectedTrackedPaths: Set<String>,
        expectedFileContents: [String: String]
    ) {
        self.kind = kind
        self.containerURL = containerURL
        self.repositoryURL = repositoryURL
        self.environment = environment
        self.expectedHead = expectedHead
        self.expectedBranch = expectedBranch
        self.expectedTrackedPaths = expectedTrackedPaths
        self.expectedFileContents = expectedFileContents
    }

    private func immutabilityFailures() -> [String] {
        var failures: [String] = []
        guard FileManager.default.fileExists(atPath: repositoryURL.path) else {
            return ["immutable Git template repository is missing: \(repositoryURL.path)"]
        }

        if let expectedHead {
            do {
                let head = try Self.runGit(["rev-parse", "HEAD"], cwd: repositoryURL, environment: environment)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if head != expectedHead {
                    failures.append("immutable Git template HEAD changed from \(expectedHead) to \(head)")
                }
            } catch {
                failures.append("read immutable Git template HEAD: \(error.localizedDescription)")
            }
        } else if (try? Self.runGit(["rev-parse", "--verify", "HEAD"], cwd: repositoryURL, environment: environment)) != nil {
            failures.append("immutable Git template unexpectedly gained a HEAD commit")
        }

        do {
            let branch = try Self.runGit(["branch", "--show-current"], cwd: repositoryURL, environment: environment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if branch != expectedBranch {
                failures.append("immutable Git template branch changed from \(expectedBranch) to \(branch)")
            }
        } catch {
            failures.append("read immutable Git template branch: \(error.localizedDescription)")
        }
        do {
            let status = try Self.runGit(["status", "--porcelain"], cwd: repositoryURL, environment: environment)
            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("immutable Git template working tree is dirty: \(status)")
            }
        } catch {
            failures.append("read immutable Git template status: \(error.localizedDescription)")
        }
        do {
            let tracked = try Self.trackedRelativePaths(at: repositoryURL, environment: environment)
            if tracked != expectedTrackedPaths {
                failures.append(
                    "immutable Git template tracked paths changed from \(expectedTrackedPaths.sorted()) to \(tracked.sorted())"
                )
            }
        } catch {
            failures.append("read immutable Git template tracked paths: \(error.localizedDescription)")
        }
        for (path, expectedContents) in expectedFileContents.sorted(by: { $0.key < $1.key }) {
            do {
                let contents = try String(contentsOf: repositoryURL.appendingPathComponent(path), encoding: .utf8)
                if contents != expectedContents {
                    failures.append("immutable Git template contents changed at \(path)")
                }
            } catch {
                failures.append("read immutable Git template file \(path): \(error.localizedDescription)")
            }
        }
        do {
            let output = try Self.runGit(["worktree", "list", "--porcelain"], cwd: repositoryURL, environment: environment)
            let worktrees = output
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let prefix = "worktree "
                    guard line.hasPrefix(prefix) else { return nil }
                    return canonicalPath(URL(fileURLWithPath: String(line.dropFirst(prefix.count))))
                }
            if worktrees != [canonicalPath(repositoryURL)] {
                failures.append("immutable Git template has unexpected worktrees: \(worktrees)")
            }
        } catch {
            failures.append("list immutable Git template worktrees: \(error.localizedDescription)")
        }
        do {
            try validateRepositoryLayout(at: repositoryURL)
            let identities = try regularFileIdentities(in: repositoryURL)
            if let hardlinkedPath = identities.first(where: { $0.value.linkCount != 1 })?.key {
                failures.append("immutable Git template contains a hardlinked regular file: \(hardlinkedPath)")
            }
        } catch {
            failures.append("validate immutable Git template isolation: \(error.localizedDescription)")
        }
        return failures
    }

    private static func configureRepository(
        at repositoryURL: URL,
        environment: GitEnvironment,
        checkoutMain: Bool
    ) throws {
        try runGit(["init"], cwd: repositoryURL, environment: environment)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repositoryURL, environment: environment)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repositoryURL, environment: environment)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repositoryURL, environment: environment)
        try runGit(["config", "core.autocrlf", "false"], cwd: repositoryURL, environment: environment)
        try runGit(["config", "core.eol", "native"], cwd: repositoryURL, environment: environment)
        if checkoutMain {
            try runGit(["checkout", "-b", "main"], cwd: repositoryURL, environment: environment)
        }
    }

    private func validateRepositoryLayout(at repository: URL) throws {
        let fileManager = FileManager.default
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error(code: 6, message: "Copied repository does not have an ordinary .git directory")
        }
        guard !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("objects/info/alternates").path) else {
            throw error(code: 7, message: "Copied repository contains Git object alternates")
        }
        guard !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("worktrees").path),
              !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("commondir").path),
              !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("gitdir").path)
        else {
            throw error(code: 8, message: "Copied repository contains linked-worktree metadata")
        }
        let config = try String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8)
        guard !config.contains("[remote "), !config.contains(repositoryURL.path), !config.contains(containerURL.path) else {
            throw error(code: 9, message: "Copied repository config refers to a remote or immutable template path")
        }
        guard fileManager.isWritableFile(atPath: repository.path), fileManager.isWritableFile(atPath: gitDirectory.path) else {
            throw error(code: 10, message: "Copied repository or .git directory is not writable")
        }
    }

    private func regularFileIdentities(in root: URL) throws -> [String: FileIdentity] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                enumerationError = NSError(
                    domain: "ImmutableGitRepositoryTemplate",
                    code: 13,
                    userInfo: [
                        NSUnderlyingErrorKey: error,
                        NSLocalizedDescriptionKey: "Unable to enumerate repository path \(url.path)"
                    ]
                )
                return false
            }
        ) else {
            throw error(code: 11, message: "Unable to enumerate repository copy at \(root.path)")
        }

        var identities: [String: FileIdentity] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw error(code: 12, message: "Repository copy contains symbolic link: \(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "lstat failed for \(url.path)"]
                )
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            identities[relativePath] = FileIdentity(
                device: UInt64(bitPattern: Int64(metadata.st_dev)),
                inode: UInt64(metadata.st_ino),
                linkCount: UInt64(metadata.st_nlink)
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return identities
    }

    private static func trackedRelativePaths(at repositoryURL: URL, environment: GitEnvironment) throws -> Set<String> {
        let output = try runGit(["ls-files", "-z"], cwd: repositoryURL, environment: environment)
        guard !output.isEmpty else { return [] }
        return Set(output.split(separator: "\0").map(String.init))
    }

    @discardableResult
    private static func runGit(_ arguments: [String], cwd: URL, environment: GitEnvironment) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        if environment == .reviewFixture {
            processEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = processEnvironment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ImmutableGitRepositoryTemplate.git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(arguments.joined(separator: " ")) failed in \(cwd.path): \(text)"
                ]
            )
        }
        return text
    }

    private static func write(_ contents: String, to relativePath: String, at root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private func canonicalPath(_ url: URL) -> String {
        Self.canonicalPath(url)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func error(code: Int, message: String) -> NSError {
        NSError(
            domain: "ImmutableGitRepositoryTemplate.\(kind.rawValue)",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
