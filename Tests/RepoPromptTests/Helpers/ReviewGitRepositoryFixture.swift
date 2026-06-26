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
        files: [String: String] = ["Sources/Feature.swift": "let value = 1\n"]
    ) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try runGit(["init"], at: root)
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

    @discardableResult
    func runGit(_ arguments: [String], at root: URL) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"

        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: root,
            environment: environment
        )
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
}
