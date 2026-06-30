import Foundation
@testable import RepoPrompt
import XCTest

final class GitBlobCapabilityBoundCatFileTests: XCTestCase {
    func testCapabilityBoundEnvironmentSanitizesRoutingForOrdinaryAndLinkedWorktrees() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let ordinary = try repositories.makeRepository(named: "ordinary")
        let linked = try repositories.makeLinkedWorktree(
            from: ordinary,
            named: "linked",
            branch: "linked-branch"
        )
        let hostile = try repositories.makeRepository(
            named: "hostile",
            files: ["Sources/Hostile.swift": "let hostile = true\n"]
        )
        let fake = try GitBlobFakeGitFixture(name: #function)
        defer { fake.cleanup() }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(fake.environment(mode: "normal", declaredSize: 4, blobByteCount: 4)) { _, new in new }
        environment["GIT_DIR"] = hostile.appendingPathComponent(".git").path
        environment["GIT_WORK_TREE"] = hostile.path
        environment["GIT_COMMON_DIR"] = hostile.appendingPathComponent(".git").path
        environment["GIT_OBJECT_DIRECTORY"] = hostile.appendingPathComponent(".git/objects").path
        environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = hostile.appendingPathComponent(".git/objects").path
        environment["GIT_INDEX_FILE"] = hostile.appendingPathComponent(".git/index").path
        environment["GIT_QUARANTINE_PATH"] = hostile.appendingPathComponent("quarantine").path
        environment["GIT_NAMESPACE"] = "hostile"
        environment["GIT_REPLACE_REF_BASE"] = "refs/replace-hostile/"
        environment["GIT_CONFIG_PARAMETERS"] = "'core.worktree'='\(hostile.path)'"
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "core.worktree"
        environment["GIT_CONFIG_VALUE_0"] = hostile.path
        environment["GIT_EXEC_PATH"] = hostile.path
        environment["GIT_NO_LAZY_FETCH"] = "0"
        environment["GIT_ALLOW_PROTOCOL"] = "ext:file:ssh:http:https"

        let git = GitService(
            gitExecutableURL: fake.executableURL,
            inheritedProcessEnvironment: environment
        )
        let oid = GitBlobOID.blob(bytes: Data(repeating: 0x78, count: 4), objectFormat: .sha1)
        let layouts = try [ordinary, linked].map { root in
            try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root))
        }
        for layout in layouts {
            let size = try await git.gitBlobObjectSize(in: layout, oid: oid)
            let bytes = try await git.gitBlobObjectBytes(in: layout, oid: oid, expectedByteCount: 4)
            XCTAssertEqual(size, 4)
            XCTAssertEqual(bytes, Data(repeating: 0x78, count: 4))
        }

        let reports = try fake.invocationReports()
        XCTAssertEqual(reports.count, 4)
        for (index, layout) in layouts.enumerated() {
            for report in reports[(index * 2) ..< (index * 2 + 2)] {
                XCTAssertTrue(report.contains("GIT_DIR=\(layout.gitDir.standardizedFileURL.path)"))
                XCTAssertTrue(report.contains("GIT_COMMON_DIR=\(layout.commonDir.standardizedFileURL.path)"))
                XCTAssertTrue(report.contains("GIT_WORK_TREE=\(layout.workTreeRoot.standardizedFileURL.path)"))
                XCTAssertTrue(
                    report.contains(
                        "GIT_OBJECT_DIRECTORY=\(layout.commonDir.appendingPathComponent("objects").standardizedFileURL.path)"
                    )
                )
                XCTAssertTrue(
                    report.contains(
                        "GIT_INDEX_FILE=\(layout.gitDir.appendingPathComponent("index").standardizedFileURL.path)"
                    )
                )
                XCTAssertTrue(report.contains("GIT_NO_LAZY_FETCH=1"))
                XCTAssertTrue(report.contains("GIT_NO_REPLACE_OBJECTS=1"))
                XCTAssertTrue(report.contains("GIT_CONFIG_COUNT=0"))
                XCTAssertTrue(report.contains("GIT_PROTOCOL_FROM_USER=0"))
                XCTAssertTrue(report.contains("GIT_ALLOW_PROTOCOL="))
                XCTAssertFalse(report.contains(hostile.path))
                XCTAssertFalse(report.contains("GIT_ALTERNATE_OBJECT_DIRECTORIES="))
                XCTAssertFalse(report.contains("GIT_QUARANTINE_PATH="))
                XCTAssertFalse(report.contains("GIT_NAMESPACE="))
                XCTAssertFalse(report.contains("GIT_REPLACE_REF_BASE="))
                XCTAssertFalse(report.contains("GIT_CONFIG_KEY_0="))
                XCTAssertFalse(report.contains("GIT_CONFIG_VALUE_0="))
                XCTAssertFalse(report.contains("GIT_CONFIG_PARAMETERS="))
                XCTAssertFalse(report.contains("GIT_EXEC_PATH="))
            }
        }
    }

    func testHostileRepositoryEnvironmentCannotExposeObjectsFromAnotherRepository() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repositoryA = try fixture.makeRepository(
            named: "repository-a",
            files: ["Sources/A.swift": "let repositoryA = true\n"]
        )
        let linkedA = try fixture.makeLinkedWorktree(
            from: repositoryA,
            named: "repository-a-linked",
            branch: "linked-a"
        )
        let repositoryB = try fixture.makeRepository(
            named: "repository-b",
            files: ["Sources/B.swift": "let repositoryBOnly = true\n"]
        )

        let cleanGit = GitService()
        let capabilities = try await [repositoryA, linkedA].asyncMap {
            try await self.capability(at: $0, gitService: cleanGit)
        }
        let aOID = try GitBlobOID(
            objectFormat: .sha1,
            lowercaseHex: fixture.headBlobOID(for: "Sources/A.swift", at: repositoryA)
        )
        let bOID = try GitBlobOID(
            objectFormat: .sha1,
            lowercaseHex: fixture.headBlobOID(for: "Sources/B.swift", at: repositoryB)
        )

        var hostileEnvironment = ProcessInfo.processInfo.environment
        let bGit = repositoryB.appendingPathComponent(".git")
        hostileEnvironment["GIT_DIR"] = bGit.path
        hostileEnvironment["GIT_WORK_TREE"] = repositoryB.path
        hostileEnvironment["GIT_COMMON_DIR"] = bGit.path
        hostileEnvironment["GIT_OBJECT_DIRECTORY"] = bGit.appendingPathComponent("objects").path
        hostileEnvironment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = bGit.appendingPathComponent("objects").path
        hostileEnvironment["GIT_INDEX_FILE"] = bGit.appendingPathComponent("index").path
        hostileEnvironment["GIT_CONFIG_COUNT"] = "1"
        hostileEnvironment["GIT_CONFIG_KEY_0"] = "core.worktree"
        hostileEnvironment["GIT_CONFIG_VALUE_0"] = repositoryB.path
        let service = GitBlobSourceMaterializationService(
            gitService: GitService(inheritedProcessEnvironment: hostileEnvironment)
        )

        for capability in capabilities {
            await XCTAssertThrowsCatFileError(
                .objectUnavailable,
                operation: { try await service.materialize(capability: capability, blobOID: bOID) }
            )
            let validated = try await service.materialize(capability: capability, blobOID: aOID)
            XCTAssertEqual(validated.blobOID, aOID)
            XCTAssertEqual(validated.rawBytes, Data("let repositoryA = true\n".utf8))
        }
    }

    func testPromisorMissingObjectNeverInvokesRemoteHelper() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "partial")
        let objectSource = try fixture.makeRepository(
            named: "object-source",
            files: ["Sources/RemoteOnly.swift": "let remoteOnly = true\n"]
        )
        let missingOID = try GitBlobOID(
            objectFormat: .sha1,
            lowercaseHex: fixture.headBlobOID(for: "Sources/RemoteOnly.swift", at: objectSource)
        )
        let marker = fixture.sandbox.appendingPathComponent("remote-helper-invoked")
        let helper = fixture.sandbox.appendingPathComponent("fake-remote-helper")
        try "#!/bin/sh\n: > \"\(marker.path)\"\nexit 91\n".write(
            to: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: helper.path
        )
        _ = try fixture.runGit(["config", "core.repositoryformatversion", "1"], at: repository)
        _ = try fixture.runGit(["config", "extensions.partialClone", "origin"], at: repository)
        _ = try fixture.runGit(["config", "remote.origin.promisor", "true"], at: repository)
        _ = try fixture.runGit(["config", "remote.origin.partialclonefilter", "blob:none"], at: repository)
        _ = try fixture.runGit(["config", "remote.origin.url", "ext::\(helper.path)"], at: repository)
        _ = try fixture.runGit(["config", "protocol.ext.allow", "always"], at: repository)

        let git = GitService()
        let capability = try await capability(at: repository, gitService: git)
        await XCTAssertThrowsCatFileError(
            .objectUnavailable,
            operation: {
                try await GitBlobSourceMaterializationService(gitService: git)
                    .materialize(capability: capability, blobOID: missingOID)
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "Capability-bound cat-file unexpectedly invoked the promisor remote helper."
        )
    }

    func testCatFileCaptureBoundariesAndUnboundedStderrTerminatePromptly() async throws {
        let fake = try GitBlobFakeGitFixture(name: #function)
        defer { fake.cleanup() }
        let layout = fake.layout
        let oid = GitBlobOID.blob(bytes: Data(repeating: 0x78, count: 4), objectFormat: .sha1)

        let sentinelGit = GitService(
            gitExecutableURL: fake.executableURL,
            inheritedProcessEnvironment: fake.processEnvironment(
                mode: "normal",
                declaredSize: 4,
                blobByteCount: 5
            )
        )
        let sentinelBytes = try await sentinelGit.gitBlobObjectBytes(
            in: layout,
            oid: oid,
            expectedByteCount: 4
        )
        XCTAssertEqual(
            sentinelBytes.count,
            5,
            "The first excess byte is the bounded sentinel returned for typed length validation."
        )

        let overflowGit = GitService(
            gitExecutableURL: fake.executableURL,
            inheritedProcessEnvironment: fake.processEnvironment(
                mode: "normal",
                declaredSize: 4,
                blobByteCount: 6
            )
        )
        await XCTAssertThrowsObjectReadError(.stdoutLimitExceeded) {
            try await overflowGit.gitBlobObjectBytes(in: layout, oid: oid, expectedByteCount: 4)
        }

        let exactStderrGit = GitService(
            gitExecutableURL: fake.executableURL,
            inheritedProcessEnvironment: fake.processEnvironment(
                mode: "bytes_stderr_exact",
                declaredSize: 4,
                blobByteCount: 4
            )
        )
        let exactStderrBytes = try await exactStderrGit.gitBlobObjectBytes(
            in: layout,
            oid: oid,
            expectedByteCount: 4
        )
        XCTAssertEqual(exactStderrBytes.count, 4)

        let stderrOverflowGit = GitService(
            gitExecutableURL: fake.executableURL,
            inheritedProcessEnvironment: fake.processEnvironment(
                mode: "bytes_stderr_overflow",
                declaredSize: 4,
                blobByteCount: 4
            )
        )
        await XCTAssertThrowsObjectReadError(.stderrLimitExceeded) {
            try await stderrOverflowGit.gitBlobObjectBytes(in: layout, oid: oid, expectedByteCount: 4)
        }

        for (mode, expectedError) in [
            ("size_stdout_overflow", GitBlobObjectReadError.stdoutLimitExceeded),
            ("size_stderr_unbounded", GitBlobObjectReadError.stderrLimitExceeded)
        ] {
            let git = GitService(
                gitExecutableURL: fake.executableURL,
                processTerminationGrace: .milliseconds(100),
                inheritedProcessEnvironment: fake.processEnvironment(
                    mode: mode,
                    declaredSize: 4,
                    blobByteCount: 4
                )
            )
            let clock = ContinuousClock()
            let start = clock.now
            await XCTAssertThrowsObjectReadError(expectedError) {
                try await git.gitBlobObjectSize(in: layout, oid: oid)
            }
            XCTAssertLessThan(
                start.duration(to: clock.now),
                .seconds(5),
                "Overflow must terminate the fake Git process promptly instead of buffering unbounded output."
            )
        }
    }

    private func capability(
        at root: URL,
        gitService: GitService
    ) async throws -> GitCodemapRootCapability {
        let state = await WorkspaceCodemapGitCapabilityService(
            gitService: gitService,
            namespaceSalt: Data(repeating: 0x42, count: GitBlobRepositoryNamespace.saltByteCount)
        ).resolve(
            root: WorkspaceCodemapGitCapabilityRequest(
                rootID: UUID(),
                rootLifetimeID: UUID(),
                loadedRootURL: root
            )
        )
        guard case let .eligible(capability) = state else {
            throw NSError(
                domain: "GitBlobCapabilityBoundCatFileTests.capability",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected eligible capability, received \(state)"]
            )
        }
        return capability
    }
}

private final class GitBlobFakeGitFixture {
    let sandbox: URL
    let executableURL: URL
    let reportURL: URL
    let layout: GitRepositoryLayout

    init(name: String) throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        executableURL = sandbox.appendingPathComponent("fake-git")
        reportURL = sandbox.appendingPathComponent("environment-report")
        let worktree = sandbox.appendingPathComponent("worktree", isDirectory: true)
        let gitDirectory = worktree.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        layout = GitRepositoryLayout(
            workTreeRoot: worktree,
            dotGitPath: gitDirectory,
            gitDir: gitDirectory,
            commonDir: gitDirectory,
            isWorktree: false
        )

        let sourceURL = sandbox.appendingPathComponent("fake-git.c")
        let source = #"""
        #include <errno.h>
        #include <signal.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        extern char **environ;

        static int write_all(int fd, const void *buffer, size_t count) {
            const unsigned char *cursor = buffer;
            while (count > 0) {
                ssize_t written = write(fd, cursor, count);
                if (written > 0) {
                    cursor += written;
                    count -= (size_t)written;
                    continue;
                }
                if (written < 0 && errno == EINTR) continue;
                return -1;
            }
            return 0;
        }

        static void report_environment(void) {
            const char *path = getenv("RP_GIT_REPORT");
            if (path == NULL) return;
            FILE *report = fopen(path, "a");
            if (report == NULL) return;
            fputs("--INVOCATION--\n", report);
            for (char **item = environ; *item != NULL; ++item) {
                if (strncmp(*item, "GIT_", 4) == 0) fprintf(report, "%s\n", *item);
            }
            fclose(report);
        }

        static size_t numeric_environment(const char *name, size_t fallback) {
            const char *value = getenv(name);
            if (value == NULL || *value == '\0') return fallback;
            return (size_t)strtoull(value, NULL, 10);
        }

        static int write_repeated(int fd, size_t count, unsigned char byte) {
            unsigned char chunk[4096];
            memset(chunk, byte, sizeof(chunk));
            while (count > 0) {
                size_t next = count < sizeof(chunk) ? count : sizeof(chunk);
                if (write_all(fd, chunk, next) != 0) return -1;
                count -= next;
            }
            return 0;
        }

        int main(int argc, char **argv) {
            report_environment();
            const char *mode = getenv("RP_GIT_MODE");
            if (mode == NULL) mode = "normal";
            if (argc >= 3 && strcmp(argv[1], "cat-file") == 0 && strcmp(argv[2], "-s") == 0) {
                if (strcmp(mode, "size_stdout_overflow") == 0) {
                    return write_repeated(STDOUT_FILENO, 65, '9') == 0 ? 0 : 2;
                }
                if (strcmp(mode, "size_stderr_unbounded") == 0) {
                    unsigned char chunk[4096];
                    memset(chunk, 'e', sizeof(chunk));
                    while (write_all(STDERR_FILENO, chunk, sizeof(chunk)) == 0) {}
                    return 3;
                }
                char size[64];
                int count = snprintf(
                    size,
                    sizeof(size),
                    "%zu\n",
                    numeric_environment("RP_GIT_DECLARED_SIZE", 4)
                );
                return count > 0 && write_all(STDOUT_FILENO, size, (size_t)count) == 0 ? 0 : 4;
            }
            if (argc >= 3 && strcmp(argv[1], "cat-file") == 0 && strcmp(argv[2], "blob") == 0) {
                if (strcmp(mode, "bytes_stderr_exact") == 0 &&
                    write_repeated(STDERR_FILENO, 64 * 1024, 'd') != 0) return 5;
                if (strcmp(mode, "bytes_stderr_overflow") == 0 &&
                    write_repeated(STDERR_FILENO, 64 * 1024 + 1, 'd') != 0) return 6;
                return write_repeated(
                    STDOUT_FILENO,
                    numeric_environment("RP_GIT_BLOB_BYTE_COUNT", 4),
                    'x'
                ) == 0 ? 0 : 7;
            }
            return 8;
        }
        """#
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let compile = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [sourceURL.path, "-o", executableURL.path]
        )
        guard compile.terminationStatus == 0 else {
            throw NSError(
                domain: "GitBlobFakeGitFixture.compile",
                code: Int(compile.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: compile.outputText]
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func environment(mode: String, declaredSize: Int, blobByteCount: Int) -> [String: String] {
        [
            "RP_GIT_REPORT": reportURL.path,
            "RP_GIT_MODE": mode,
            "RP_GIT_DECLARED_SIZE": String(declaredSize),
            "RP_GIT_BLOB_BYTE_COUNT": String(blobByteCount)
        ]
    }

    func processEnvironment(mode: String, declaredSize: Int, blobByteCount: Int) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result.merge(environment(mode: mode, declaredSize: declaredSize, blobByteCount: blobByteCount)) { _, new in new }
        return result
    }

    func invocationReports() throws -> [String] {
        let contents = try String(contentsOf: reportURL, encoding: .utf8)
        return contents.components(separatedBy: "--INVOCATION--\n").filter { !$0.isEmpty }
    }
}

private func XCTAssertThrowsCatFileError(
    _ expected: GitBlobSourceMaterializationError,
    operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        XCTFail("Expected materialization error \(expected)")
    } catch {
        XCTAssertEqual(error as? GitBlobSourceMaterializationError, expected)
    }
}

private func XCTAssertThrowsObjectReadError(
    _ expected: GitBlobObjectReadError,
    operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        XCTFail("Expected Git object read error \(expected)")
    } catch {
        XCTAssertEqual(error as? GitBlobObjectReadError, expected)
    }
}

private extension [URL] {
    func asyncMap<T>(_ transform: (URL) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            try await result.append(transform(element))
        }
        return result
    }
}
