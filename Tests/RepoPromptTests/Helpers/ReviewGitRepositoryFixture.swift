import Foundation
@testable import RepoPrompt

final class ReviewGitRepositoryFixture {
    let sandbox: URL

    init(name: String = "ReviewGitRepositoryFixture") throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: sandbox.path) else { return }
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeRepository(
        named name: String,
        files: [String: String] = ["Sources/Feature.swift": "let value = 1\n"],
        objectFormat: GitObjectFormat? = nil
    ) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var initArguments = ["init"]
        if let objectFormat {
            initArguments.append("--object-format=\(objectFormat.rawValue)")
        }
        _ = try runGit(initArguments, at: root)
        _ = try runGit(["config", "user.name", "RepoPrompt Test"], at: root)
        _ = try runGit(["config", "user.email", "repoprompt@example.test"], at: root)
        _ = try runGit(["config", "commit.gpgSign", "false"], at: root)
        _ = try runGit(["checkout", "-b", "main"], at: root)

        for (path, contents) in files {
            try write(contents, to: path, at: root)
        }
        _ = try runGit(["add", "."], at: root)
        _ = try runGit(["commit", "-m", "Initial commit"], at: root)
        return root
    }

    func makeLinkedWorktree(
        from repository: URL,
        named name: String,
        branch: String
    ) throws -> URL {
        let worktree = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        _ = try runGit(["worktree", "add", "-b", branch, worktree.path, "HEAD"], at: repository)
        return worktree
    }

    func write(_ contents: String, to relativePath: String, at root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func write(_ data: Data, to relativePath: String, at root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
    }

    func stage(_ relativePath: String, at root: URL) throws {
        _ = try runGit(["add", "--", relativePath], at: root)
    }

    func commit(_ message: String, at root: URL) throws {
        _ = try runGit(["commit", "-m", message], at: root)
    }

    func head(at root: URL) throws -> String {
        try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func headBlobOID(for relativePath: String, at root: URL) throws -> String {
        let oid = try runGit(["rev-parse", "--verify", "HEAD:\(relativePath)"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard [40, 64].contains(oid.count), oid.allSatisfy(\.isHexDigit) else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected blob OID for \(relativePath): \(oid)"]
            )
        }
        return oid
    }

    func isTracked(_ relativePath: String, at root: URL) throws -> Bool {
        let output = try runGit(["ls-files", "--", relativePath], at: root)
        return output.split(whereSeparator: \.isNewline).contains(Substring(relativePath))
    }

    func porcelainStatus(for relativePath: String, at root: URL) throws -> String {
        try runGit(
            ["status", "--porcelain=v1", "--untracked-files=all", "--", relativePath],
            at: root
        ).trimmingCharacters(in: .newlines)
    }

    @discardableResult
    func createUntrackedFile(_ contents: String, at relativePath: String, root: URL) throws -> URL {
        guard try !isTracked(relativePath, at: root) else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Expected untracked path: \(relativePath)"]
            )
        }
        try write(contents, to: relativePath, at: root)
        return root.appendingPathComponent(relativePath).standardizedFileURL
    }

    @discardableResult
    func runGit(_ arguments: [String], at root: URL) throws -> String {
        let result = try runGitResult(arguments, at: root)
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: Int(result.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(arguments.joined(separator: " ")) failed in \(root.path): \(result.outputText)"
                ]
            )
        }
        return result.outputText
    }

    func runGitResult(_ arguments: [String], at root: URL) throws -> TestProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"

        return try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: root,
            environment: environment
        )
    }
}
