import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptVCS
import XCTest

final class GitProcessPipeDrainTests: XCTestCase {
    func testReadabilityCallbackAfterFinishCannotConsumeOrAppendData() async {
        let (stream, drain) = GitProcessPipeDrain.makeStream()
        let tailData = Data("tail".utf8)
        var didReadAfterFinish = false

        drain.finish { tailData }
        drain.consume {
            didReadAfterFinish = true
            return Data("late".utf8)
        }

        XCTAssertFalse(didReadAfterFinish)
        let output = await Self.collect(stream)
        XCTAssertEqual(output, tailData)
    }

    func testByteLimitRetainsExactBoundaryAndFlagsFirstExcessByte() async throws {
        for (payload, expected, didExceed) in [
            (Data("four".utf8), Data("four".utf8), false),
            (Data("five!".utf8), Data("five".utf8), true)
        ] {
            let pipe = Pipe()
            let (stream, drain) = try GitProcessPipeDrain.makeStream(
                readingFrom: pipe.fileHandleForReading,
                byteLimit: 4
            )
            let collected = Task { await Self.collect(stream) }
            pipe.fileHandleForWriting.write(payload)
            pipe.fileHandleForWriting.closeFile()
            while !drain.consumeAvailableData() {}

            let output = await collected.value
            XCTAssertEqual(output, expected)
            XCTAssertEqual(drain.didExceedByteLimit, didExceed)
        }
    }

    func testCancelClosesOwnedDuplicateWithoutClosingOriginalDescriptor() throws {
        let pipe = Pipe()
        let originalDescriptor = pipe.fileHandleForReading.fileDescriptor
        let (_, drain) = try GitProcessPipeDrain.makeStream(readingFrom: pipe.fileHandleForReading)
        let ownedDescriptor = try XCTUnwrap(drain.ownedDescriptorForTesting)
        XCTAssertNotEqual(ownedDescriptor, originalDescriptor)
        XCTAssertGreaterThanOrEqual(fcntl(ownedDescriptor, F_GETFD), 0)

        drain.cancel()

        errno = 0
        XCTAssertEqual(fcntl(ownedDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertGreaterThanOrEqual(fcntl(originalDescriptor, F_GETFD), 0)
        pipe.fileHandleForWriting.closeFile()
    }

    private static func collect(_ stream: AsyncStream<Data>) async -> Data {
        var result = Data()
        for await chunk in stream {
            result.append(chunk)
        }
        return result
    }
}

#if DEBUG
    final class GitReadSafetyTests: XCTestCase {
        func testReadPolicyRecognizesBuilderPrefixesAndLeavesMutationsAlone() throws {
            let status = ["-c", "core.fsmonitor=false", "status", "--porcelain=v2"]
            XCTAssertTrue(GitReadSafety.isRead(status))
            XCTAssertTrue(GitReadSafety.needsDriverCheck(status))
            XCTAssertTrue(GitReadSafety.isRead(["--git-dir", "/repo/.git", "config", "--get", "core.bare"]))
            for arguments in [["fetch", "--all"], ["worktree", "add", "path"], ["commit", "-m", "message"]] {
                XCTAssertFalse(GitReadSafety.isRead(arguments))
                XCTAssertEqual(GitReadSafety.arguments(arguments), arguments)
            }
            let diff = GitReadSafety.arguments(["diff", "HEAD", "--", "file"])
            XCTAssertTrue(diff.contains("--no-textconv"))
            XCTAssertEqual(GitReadSafety.arguments(diff), diff)
            XCTAssertLessThan(try XCTUnwrap(diff.firstIndex(of: "--no-textconv")), try XCTUnwrap(diff.firstIndex(of: "--")))
            XCTAssertEqual(GitReadSafety.arguments(["config", "--get", "core.fsmonitor"]), ["config", "--get", "core.fsmonitor"])
            let show = GitReadSafety.arguments(["show", "-s", "--end-of-options", "HEAD"])
            XCTAssertLessThan(try XCTUnwrap(show.firstIndex(of: "--no-textconv")), try XCTUnwrap(show.firstIndex(of: "--end-of-options")))
            XCTAssertEqual(GitReadSafety.arguments(show), show)
            XCTAssertTrue(show.contains("core.hooksPath=/dev/null"))
        }

        func testDriverScopeParserFailsClosedWithoutDiscardingUserOnlyDrivers() throws {
            try GitReadSafety.validateDriverConfiguration(Data("global\0filter.lfs.process\nuser-filter\0".utf8))
            try GitReadSafety.validateDriverConfiguration(Data("local\0filter.a=b.c.clean\n\0".utf8))
            for text in [
                "local\0filter.a=b.c.clean\nprogram\0",
                "worktree\0merge.custom.driver\nprogram\0",
                "local\0filter.custom.process\0",
                "unknown\0filter.custom.clean\nprogram\0",
                "local\0filter.custom.clean\nprogram"
            ] {
                XCTAssertThrowsError(try GitReadSafety.validateDriverConfiguration(Data(text.utf8)))
            }
            XCTAssertThrowsError(try GitReadSafety.validateDriverConfiguration(Data([0xFF, 0])))
            let filter = Data("local\0filter.custom.clean\nprogram\0".utf8)
            let merge = Data("local\0merge.custom.driver\nprogram\0".utf8)
            try GitReadSafety.validateDriverConfiguration(filter, for: ["log", "-1"])
            try GitReadSafety.validateDriverConfiguration(merge, for: ["status", "--porcelain"])
            XCTAssertThrowsError(try GitReadSafety.validateDriverConfiguration(filter, for: ["status"]))
            XCTAssertThrowsError(try GitReadSafety.validateDriverConfiguration(merge, for: ["merge-tree"]))
            XCTAssertFalse(GitReadSafety.needsDriverCheck(["diff-tree", "HEAD"]))
        }

        func testStatusDoesNotExecuteConfiguredFsmonitorIncludingSpoolPath() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.runGit(["config", "core.fsmonitor", script.path], at: repo)
            _ = try fixture.runGit(["status", "--porcelain"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            let service = GitService()
            let (_, _, exitCode) = try await service.runGitDataForTesting(["status", "--porcelain"], at: repo)
            XCTAssertEqual(exitCode, 0)
            let (_, _, spoolExitCode, _) = try await service.runGitSpoolingForTesting(["status", "--porcelain"], at: repo)
            XCTAssertEqual(spoolExitCode, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testDiffLogShowAndBlameDoNotRunTextConversion() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.write("*.txt diff=inspection\n", to: ".git/info/attributes", at: repo)
            try fixture.runGit(["config", "diff.inspection.textconv", script.path], at: repo)
            try fixture.write("after\n", to: "file.txt", at: repo)
            let service = GitService()
            for arguments in [["diff", "HEAD"], ["log", "-p", "-1"], ["show", "HEAD"], ["blame", "file.txt"]] {
                _ = try fixture.runGit(arguments, at: repo)
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control: \(arguments[0])")
                try FileManager.default.removeItem(at: marker)
                let (_, _, exitCode) = try await service.runGitDataForTesting(arguments, at: repo)
                XCTAssertEqual(exitCode, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), arguments[0])
            }
        }

        func testExternalDiffDoesNotRun() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.runGit(["config", "diff.external", script.path], at: repo)
            try fixture.write("after\n", to: "file.txt", at: repo)
            _ = try fixture.runGit(["diff", "HEAD"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            let (_, _, exitCode) = try await GitService().runGitDataForTesting(["diff", "HEAD"], at: repo)
            XCTAssertEqual(exitCode, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testRepositoryFilterFailsClosedIncludingAnIncludedConfiguration() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.write("*.txt filter=inspection\n", to: ".git/info/attributes", at: repo)
            let includedConfig = fixture.sandbox.appendingPathComponent("driver-config")
            try "[filter \"inspection\"]\n clean = \(script.path)\n required = true\n".write(to: includedConfig, atomically: true, encoding: .utf8)
            try fixture.runGit(["config", "include.path", includedConfig.path], at: repo)
            try fixture.write("after!\n", to: "file.txt", at: repo)
            _ = try fixture.runGit(["diff", "HEAD"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            let service = GitService()
            for arguments in [["status", "--porcelain"], ["diff", "HEAD"], ["blame", "file.txt"]] {
                do {
                    _ = try await service.runGitDataForTesting(arguments, at: repo)
                    XCTFail("Repository driver should fail closed")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("repository-configured executable"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
            // A config read reports the real value; it must not execute it.
            let (value, _, code) = try await service.runGitDataForTesting(["config", "--get", "filter.inspection.clean"], at: repo)
            XCTAssertEqual(code, 0)
            XCTAssertEqual(String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), script.path)
        }

        func testPassivePopoverAndRemoteComparisonDoNotFetchButExplicitFetchIsUnchanged() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.runGit(["config", "protocol.ext.allow", "always"], at: repo)
            try fixture.runGit(["remote", "add", "origin", "ext::\(script.path)"], at: repo)
            try fixture.runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)
            let vcs = VCSService()
            let engine = GitDiffEngine(vcsService: vcs)
            let status = GitStatusActor(vcsService: vcs, diffEngine: engine)
            _ = await status.updateRoots([repo.path])
            await status.setSelectedRoot(repo.path)
            _ = await status.refresh(trigger: .popoverOpen)
            _ = await status.generateDiff(rootPath: repo.path, inclusionMode: .all, selectedAbsolutePaths: [], vsBranch: "origin/main")
            for target: GitDiffTarget in [.uncommitted(base: "origin/main"), .uncommittedMergeBase(base: "origin/main")] {
                _ = try await engine.diffText(target: target, scope: .all, selectedAbsolutePaths: [], repoURL: repo, allowCachedResult: false)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            // The offline transport intentionally cannot speak Git. Its marker
            // proves that an explicitly requested fetch still reaches transport.
            do { try await GitService().fetch(at: repo) } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "explicit fetch control")
            await status.shutdown()
        }

        func testRepositoryProcessFilterDoesNotStartDuringInspection() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.write("*.txt filter=inspection\n", to: ".git/info/attributes", at: repo)
            try fixture.runGit(["config", "filter.inspection.process", script.path], at: repo)
            try fixture.write("after!\n", to: "file.txt", at: repo)
            // The marker helper deliberately does not implement the filter protocol.
            _ = try? fixture.runGit(["diff", "HEAD"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            do {
                _ = try await GitService().runGitDataForTesting(["diff", "HEAD"], at: repo)
                XCTFail("Process filter must fail closed")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("repository-configured executable"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testStatusDoesNotRunPostIndexChangeHook() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            let hooks = fixture.sandbox.appendingPathComponent("hooks", isDirectory: true)
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: script, to: hooks.appendingPathComponent("post-index-change"))
            try fixture.runGit(["config", "core.hooksPath", hooks.path], at: repo)
            let file = repo.appendingPathComponent("file.txt")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: file.path)
            _ = try fixture.runGit(["status", "--porcelain"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: file.path)
            let (_, _, code) = try await GitService().runGitDataForTesting(["status", "--porcelain"], at: repo)
            XCTAssertEqual(code, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testMissingObjectCannotStartLazyTransport() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            let oid = try fixture.headBlobOID(for: "file.txt", at: repo)
            try fixture.runGit(["config", "core.repositoryformatversion", "1"], at: repo)
            try fixture.runGit(["config", "extensions.partialClone", "origin"], at: repo)
            try fixture.runGit(["config", "remote.origin.promisor", "true"], at: repo)
            try fixture.runGit(["config", "remote.origin.url", "ext::\(script.path)"], at: repo)
            try fixture.runGit(["config", "protocol.ext.allow", "always"], at: repo)
            let object = repo.appendingPathComponent(".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
            try FileManager.default.removeItem(at: object)
            _ = try? fixture.runGit(["show", "HEAD:file.txt"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            let (_, _, code) = try await GitService().runGitDataForTesting(["show", "HEAD:file.txt"], at: repo)
            XCTAssertNotEqual(code, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        private func makeMarkerScript(_ fixture: ReviewGitRepositoryFixture) throws -> (URL, URL) {
            let marker = fixture.sandbox.appendingPathComponent("helper-marker")
            let script = fixture.sandbox.appendingPathComponent("helper")
            try "#!/bin/sh\n: > '\(marker.path)'\nprintf 'converted\\n'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return (script, marker)
        }
    }
#endif
