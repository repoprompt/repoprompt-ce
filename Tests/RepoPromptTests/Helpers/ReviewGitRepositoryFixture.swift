import Foundation
@testable import RepoPromptApp

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

    func makeRepository(named name: String, files: [String: String]) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try initializeRepository(at: root)
        for (path, contents) in files {
            try write(contents, to: path, at: root)
        }
        _ = try runGit(["add", "-A"], at: root)
        try commit("Initial commit", at: root)
        return root
    }

    func initializeRepository(at root: URL, separateGitDirectory: URL? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var arguments = ["init"]
        if let separateGitDirectory {
            arguments.append("--separate-git-dir=\(separateGitDirectory.path)")
        }
        arguments.append(root.path)
        _ = try runGit(arguments, at: sandbox)
        _ = try runGit(["config", "user.name", "RepoPrompt Test"], at: root)
        _ = try runGit(["config", "user.email", "repoprompt@example.test"], at: root)
        _ = try runGit(["config", "commit.gpgSign", "false"], at: root)
        _ = try runGit(["config", "core.autocrlf", "false"], at: root)
        _ = try runGit(["checkout", "-b", "main"], at: root)
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

    func headBlobOID(for relativePath: String, at root: URL) throws -> String {
        try runGit(["rev-parse", "--verify", "HEAD:\(relativePath)"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    @discardableResult
    func runGit(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["HOME"] = sandbox.path
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
