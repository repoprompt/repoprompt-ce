@testable import RepoPrompt
import XCTest

final class GitWorktreeIncludeCopyTests: XCTestCase {
    private var fixture: GitWorktreeIncludeFixture!

    override func tearDownWithError() throws {
        fixture?.cleanup()
        fixture = nil
    }

    func testMissingWorktreeIncludeNoOps() async throws {
        fixture = try GitWorktreeIncludeFixture(name: "missing-include")
        try fixture.write(".gitignore", ".env.local\n")
        try fixture.commit(paths: [".gitignore"], message: "Add ignore file")
        try fixture.write(".env.local", "secret\n")

        let result = try await fixture.createManagedWorktree()

        XCTAssertNil(result.includeCopyResult)
        XCTAssertFalse(fixture.fileExists(".env.local", in: result.descriptor))
    }

    func testCopierIgnoresAppManagedContainerInsideSourceRoot() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeIncludeCopyTests-managed-container-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceRoot = sandbox.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = sandbox.appendingPathComponent("destination", isDirectory: true)
        let appManagedContainer = sourceRoot.appendingPathComponent(".repoprompt-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try "**\n".write(
            to: sourceRoot.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try ".repoprompt-worktrees/\n.env.local\n".write(
            to: sourceRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "secret\n".write(
            to: sourceRoot.appendingPathComponent(".env.local"),
            atomically: true,
            encoding: .utf8
        )
        let managedFile = appManagedContainer.appendingPathComponent("repo/rp-worktree/.env.local")
        try FileManager.default.createDirectory(at: managedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "managed secret\n".write(to: managedFile, atomically: true, encoding: .utf8)

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: sourceRoot,
            to: destinationRoot,
            ignoredFilesNULOutput: ".env.local\0.repoprompt-worktrees/repo/rp-worktree/.env.local\0",
            appManagedContainer: appManagedContainer
        ))

        XCTAssertEqual(result.copiedCount, 1)
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertEqual(
            try String(contentsOf: destinationRoot.appendingPathComponent(".env.local"), encoding: .utf8),
            "secret\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationRoot.appendingPathComponent(".repoprompt-worktrees/repo/rp-worktree/.env.local").path
        ))
    }

    func testCopiesOnlyIgnoredFilesThatMatchWorktreeInclude() async throws {
        fixture = try GitWorktreeIncludeFixture(name: "copy-matches")
        try fixture.write(".gitignore", """
        .env.local
        certs/local/
        certs glob/local/**
        secrets/*.txt
        """)
        try fixture.write(".worktreeinclude", """
        .env.local
        certs/local/
        certs glob/local/**
        secrets/*.txt
        unignored.txt
        Tracked.txt
        !certs/local/skip.pem
        """)
        try fixture.write("Tracked.txt", "committed\n")
        try fixture.commit(paths: [".gitignore", ".worktreeinclude", "Tracked.txt"], message: "Initial files")

        try fixture.write(".env.local", "secret\n")
        try fixture.write("certs/local/key.pem", "directory-only pattern\n")
        try fixture.write("certs/local/skip.pem", "negated\n")
        try fixture.write("certs glob/local/key.pem", "globstar pattern\n")
        try fixture.write("secrets/with space.txt", "space path\n")
        try fixture.write("unignored.txt", "should not copy\n")
        try fixture.write("Tracked.txt", "dirty working copy\n")

        let result = try await fixture.createManagedWorktree()

        XCTAssertEqual(result.includeCopyResult?.copiedCount, 4)
        XCTAssertEqual(result.includeCopyResult?.matchedCount, 4)
        XCTAssertNil(result.includeCopyResult?.warningText)
        XCTAssertEqual(try fixture.read(".env.local", in: result.descriptor), "secret\n")
        XCTAssertEqual(try fixture.read("certs/local/key.pem", in: result.descriptor), "directory-only pattern\n")
        XCTAssertEqual(try fixture.read("certs glob/local/key.pem", in: result.descriptor), "globstar pattern\n")
        XCTAssertEqual(try fixture.read("secrets/with space.txt", in: result.descriptor), "space path\n")
        XCTAssertFalse(fixture.fileExists("certs/local/skip.pem", in: result.descriptor))
        XCTAssertFalse(fixture.fileExists("unignored.txt", in: result.descriptor))
        XCTAssertEqual(try fixture.read("Tracked.txt", in: result.descriptor), "committed\n")
    }

    func testExistingDestinationFileIsNotOverwrittenAndWarns() async throws {
        fixture = try GitWorktreeIncludeFixture(name: "existing-destination")
        try fixture.write(".gitignore", "collision.txt\n")
        try fixture.write(".worktreeinclude", "collision.txt\n")
        try fixture.commit(paths: [".gitignore", ".worktreeinclude"], message: "Initial files")

        try fixture.runGit(["checkout", "-b", "with-collision"])
        try fixture.write("collision.txt", "tracked branch\n")
        try fixture.runGit(["add", "-f", "collision.txt"])
        try fixture.runGit(["commit", "-m", "Track collision file"])
        try fixture.runGit(["checkout", "main"])
        try fixture.write("collision.txt", "ignored source\n")

        let result = try await fixture.createManagedWorktree(baseRef: "with-collision")

        XCTAssertEqual(result.includeCopyResult?.copiedCount, 0)
        XCTAssertEqual(result.includeCopyResult?.matchedCount, 1)
        XCTAssertEqual(try fixture.read("collision.txt", in: result.descriptor), "tracked branch\n")
        XCTAssertTrue(result.includeCopyResult?.warningText?.contains("destination already exists") ?? false)
    }

    func testExplicitExternalWorktreePathDoesNotCopyWorktreeIncludeFiles() async throws {
        fixture = try GitWorktreeIncludeFixture(name: "external-path")
        try fixture.write(".gitignore", ".env.local\n")
        try fixture.write(".worktreeinclude", ".env.local\n")
        try fixture.commit(paths: [".gitignore", ".worktreeinclude"], message: "Initial files")
        try fixture.write(".env.local", "secret\n")

        let externalPath = fixture.sandbox.appendingPathComponent("external worktree", isDirectory: true)
        let result = try await fixture.createExternalWorktree(path: externalPath, forceCopyFlag: true)

        XCTAssertFalse(result.descriptor.path.contains(".repoprompt-worktrees"))
        XCTAssertNil(result.includeCopyResult)
        XCTAssertFalse(fixture.fileExists(".env.local", in: result.descriptor))
    }

    func testCopierSkipsDestinationSymlinkAncestor() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeIncludeCopyTests-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceRoot = sandbox.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = sandbox.appendingPathComponent("destination", isDirectory: true)
        let outsideRoot = sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try ".env.local\ncerts/local/key.pem\n".write(
            to: sourceRoot.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        let sourceFile = sourceRoot.appendingPathComponent("certs/local/key.pem")
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "secret\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: destinationRoot.appendingPathComponent("certs"),
            withDestinationURL: outsideRoot
        )

        let result = try XCTUnwrap(GitWorktreeIncludeCopier.copyIncludedFiles(
            from: sourceRoot,
            to: destinationRoot,
            ignoredFilesNULOutput: "certs/local/key.pem\0"
        ))

        XCTAssertEqual(result.copiedCount, 0)
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertTrue(result.warningText?.contains("symlink ancestor") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("local/key.pem").path))
    }
}

private struct GitWorktreeIncludeFixture {
    let sandbox: URL
    let repo: URL

    init(name: String) throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeIncludeCopyTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.runGit(["init"], cwd: repo)
        try Self.runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try Self.runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try Self.runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try Self.runGit(["checkout", "-b", "main"], cwd: repo)
        try write("README.md", "base\n")
        try commit(paths: ["README.md"], message: "Initial commit")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func createManagedWorktree(baseRef: String? = nil) async throws -> GitWorktreeCreateResult {
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: repo,
            baseRef: baseRef,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        XCTAssertTrue(plan.createRequest.copyWorktreeIncludeFiles)
        return try await VCSService().createGitWorktreeWithResult(request: plan.createRequest, at: repo)
    }

    func createExternalWorktree(path: URL, forceCopyFlag: Bool = false) async throws -> GitWorktreeCreateResult {
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: repo,
            explicitPath: path,
            allowExternalPath: true,
            purpose: .standaloneCreate(now: Date(timeIntervalSince1970: 0))
        ))
        XCTAssertFalse(plan.createRequest.copyWorktreeIncludeFiles)
        let request = forceCopyFlag ? GitWorktreeCreateRequest(
            path: plan.createRequest.path,
            branch: plan.createRequest.branch,
            baseRef: plan.createRequest.baseRef,
            detach: plan.createRequest.detach,
            force: plan.createRequest.force,
            lockReason: plan.createRequest.lockReason,
            allowExternalPath: plan.createRequest.allowExternalPath,
            appManagedContainer: plan.createRequest.appManagedContainer,
            mainWorktreeRoot: plan.createRequest.mainWorktreeRoot,
            knownWorktreeRoots: plan.createRequest.knownWorktreeRoots,
            copyWorktreeIncludeFiles: true
        ) : plan.createRequest
        return try await VCSService().createGitWorktreeWithResult(request: request, at: repo)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String, in descriptor: GitWorktreeDescriptor) throws -> String {
        try String(contentsOf: worktreeURL(descriptor).appendingPathComponent(relativePath), encoding: .utf8)
    }

    func fileExists(_ relativePath: String, in descriptor: GitWorktreeDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: worktreeURL(descriptor).appendingPathComponent(relativePath).path)
    }

    func commit(paths: [String], message: String) throws {
        try runGit(["add"] + paths)
        try runGit(["commit", "-m", message])
    }

    func runGit(_ arguments: [String]) throws {
        try Self.runGit(arguments, cwd: repo)
    }

    private func worktreeURL(_ descriptor: GitWorktreeDescriptor) -> URL {
        URL(fileURLWithPath: descriptor.path, isDirectory: true).standardizedFileURL
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "GitWorktreeIncludeCopyTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
    }
}
