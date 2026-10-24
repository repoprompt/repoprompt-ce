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
            let conflicting = GitReadSafety.arguments(["diff", "--no-ext-diff", "--ext-diff", "--no-textconv", "--textconv", "HEAD", "--", "file"])
            let separator = try XCTUnwrap(conflicting.firstIndex(of: "--"))
            XCTAssertEqual(Array(conflicting[..<separator].suffix(3)), ["--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"])
            XCTAssertEqual(GitReadSafety.arguments(conflicting), conflicting)
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
            XCTAssertThrowsError(try GitReadSafety.validateDriverConfiguration(filter, for: ["merge-tree"]))
            XCTAssertFalse(GitReadSafety.needsDriverCheck(["diff-tree", "HEAD"]))
        }

        func testNonconvertingReadsRemainAvailableWithRepositoryDrivers() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            for key in ["filter.inspection.clean", "filter.inspection.smudge", "merge.inspection.driver"] {
                try fixture.runGit(["config", key, shellCommand(script.path)], at: repo)
            }
            try fixture.write("*.txt filter=inspection merge=inspection\n", to: ".git/info/attributes", at: repo)
            let service = GitService()
            let commands = [
                ["show", "-s", "--format=%H", "HEAD"],
                ["log", "-1", "--format=%H"],
                ["cat-file", "blob", "HEAD:file.txt"],
                ["cat-file", "-s", "HEAD:file.txt"],
                ["ls-files", "--stage", "-z"],
                ["ls-files", "--others", "--exclude-standard"],
                ["ls-files", "--eol"]
            ]
            for args in commands {
                XCTAssertFalse(GitReadSafety.needsDriverCheck(args), "\(args)")
                let expected = try fixture.runGit(args, at: repo)
                let (output, _, code) = try await service.runGitDataForTesting(args, at: repo)
                XCTAssertEqual(code, 0, "\(args)")
                XCTAssertEqual(String(decoding: output, as: UTF8.self), expected, "\(args)")
                let (spool, _, spoolCode, _) = try await service.runGitSpoolingForTesting(args, at: repo)
                XCTAssertEqual(spoolCode, 0, "\(args)")
                XCTAssertEqual(try readLease(spool), output, "\(args)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
            for args in [["ls-files", "--modified"], ["ls-files", "-vm"], ["cat-file", "--filters", "HEAD:file.txt"], ["log", "--remerge-diff"], ["show", "--diff-merges=r"], ["log", "-m", "-p"], ["show", "--diff-merges", "remerge"]] {
                XCTAssertTrue(GitReadSafety.needsDriverCheck(args), "\(args)")
                do {
                    _ = try await service.runGitDataForTesting(args, at: repo)
                    XCTFail("Converting/remerge read should refuse local drivers: \(args)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("repository-configured executable"))
                    XCTAssertFalse(error.localizedDescription.contains("explicitly trusted Git workflow"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
            _ = try fixture.runGit(["cat-file", "--filters", "HEAD:file.txt"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "cat-file smudge positive control")
            try FileManager.default.removeItem(at: marker)
            try fixture.runGit(["config", "diff.inspection.textconv", shellCommand(script.path)], at: repo)
            try fixture.write("*.txt diff=inspection\n", to: ".git/info/attributes", at: repo)
            _ = try fixture.runGit(["cat-file", "--textconv", "HEAD:file.txt"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "cat-file textconv positive control")
            try FileManager.default.removeItem(at: marker)
            do {
                _ = try await service.runGitSpoolingForTesting(["cat-file", "--textconv", "HEAD:file.txt"], at: repo)
                XCTFail("Textconv must not execute")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("raw object"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testDirtySubmoduleStatusAndMergeInspectionFailAsIncompleteWithoutChildHelpers() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let childSource = try fixture.makeRepository(named: "child-source", files: ["tracked.txt": "original\n"])
            let repo = try fixture.makeRepository(named: "repo", files: ["parent.txt": "parent\n"])
            try fixture.runGit(["-c", "protocol.file.allow=always", "submodule", "add", childSource.path, "child"], at: repo)
            try fixture.commit("Add submodule", at: repo)
            let linked = fixture.sandbox.appendingPathComponent("linked")
            try fixture.runGit(["worktree", "add", "-b", "source", linked.path], at: repo)
            try fixture.write("source\n", to: "new.txt", at: linked)
            try fixture.stage("new.txt", at: linked)
            try fixture.commit("Source change", at: linked)
            let service = GitService()
            let descriptors = try await service.listWorktrees(at: repo)
            let source = try GitWorktreeMergeEndpoint(descriptor: XCTUnwrap(descriptors.first { !$0.isMain }))
            let target = try GitWorktreeMergeEndpoint(descriptor: XCTUnwrap(descriptors.first { $0.isMain }))
            let child = repo.appendingPathComponent("child")
            let (script, marker) = try makeMarkerScript(fixture)
            for untracked in [false, true] {
                try fixture.write(untracked ? "original\n" : "changed tracked content\n", to: "tracked.txt", at: child)
                if untracked { try fixture.write("untracked\n", to: "untracked.txt", at: child) }
                let control = try fixture.runGit(["status", "--porcelain", "--ignore-submodules=none"], at: repo)
                XCTAssertTrue(control.contains("child"), "actual dirty submodule positive control")
                try fixture.runGit(["config", "core.fsmonitor", shellCommand(script.path)], at: child)
                let partial = try await service.runGitDataForTesting(["status", "--porcelain"], at: repo)
                XCTAssertEqual(partial.2, 0)
                XCTAssertTrue(partial.0.isEmpty, "the fenced low-level view alone is partial, not authoritative")
                for inspection in ["workingStatus", "uncommittedFiles", "statusPorcelain", "changedFiles", "worktreeComparison", "fingerprint"] {
                    do {
                        switch inspection {
                        case "workingStatus": _ = try await service.getWorkingStatus(at: repo)
                        case "uncommittedFiles": _ = try await service.getUncommittedFiles(at: repo)
                        case "statusPorcelain": _ = try await service.getStatusPorcelainZ(at: repo)
                        case "changedFiles": _ = try await service.getChangedFilesStats(relativeTo: .head, at: repo)
                        case "worktreeComparison": _ = try await service.getChangedFilesStats(compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: repo)
                        default: _ = try await service.getStatusFingerprint(at: repo)
                        }
                        XCTFail("Submodule dirtiness must not be reported clean: \(inspection)")
                    } catch {
                        XCTAssertTrue(error.localizedDescription.contains("status is incomplete"), "\(inspection): \(error)")
                    }
                }
                do {
                    _ = try await service.inspectWorktreeMerge(.init(source: source, target: target))
                    XCTFail("An incomplete cleanliness check must not authorize merge")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("status is incomplete"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "child fsmonitor must not run")
                try fixture.runGit(["config", "--unset", "core.fsmonitor"], at: child)
            }
            // Git's index may contain arbitrary pathname bytes, even on a
            // filesystem that cannot materialize them. They must not hide the
            // gitlink by making the entire index listing fail UTF-8 decoding.
            let blob = try fixture.headBlobOID(for: "parent.txt", at: repo)
            var entry = Data("100644 \(blob)\tinvalid-".utf8)
            entry.append(contentsOf: [0xFF, 0])
            let (_, _, updateExit) = try await service.runGitDataForTesting(["update-index", "-z", "--index-info"], at: repo, stdin: entry)
            XCTAssertEqual(updateExit, 0)
            let (rawIndex, _, _) = try await service.runGitDataForTesting(["ls-files", "--stage", "-z"], at: repo)
            XCTAssertNil(String(data: rawIndex, encoding: .utf8), "positive control for undecodable index path")
            do {
                _ = try await service.getWorkingStatus(at: repo)
                XCTFail("Non-UTF-8 paths must not hide a tracked submodule")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("status is incomplete"))
            }
        }

        func testDriverQueryFailurePreservesOnlyBoundedRedactedDiagnostics() async throws {
            let stderr = Data(("fatal: bad config line 42 in file /secret/path?token=private\n" + String(repeating: "sensitive-value\n", count: 2000)).utf8)
            let diagnostic = GitReadSafety.driverQueryFailure(exitCode: 128, stderr: stderr)
            XCTAssertTrue(diagnostic.contains("exit 128"))
            XCTAssertTrue(diagnostic.contains("bad config line 42"))
            XCTAssertLessThan(diagnostic.utf8.count, 1024)
            for secret in ["/secret", "private", "sensitive-value"] {
                XCTAssertFalse(diagnostic.contains(secret))
            }
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            try fixture.write("[invalid-secret-payload\n", to: ".git/config", at: repo)
            for spool in [false, true] {
                do {
                    if spool {
                        _ = try await GitService().runGitSpoolingForTesting(["diff", "HEAD"], at: repo)
                    } else {
                        _ = try await GitService().runGitDataForTesting(["diff", "HEAD"], at: repo)
                    }
                    XCTFail("Malformed driver query must fail closed")
                } catch {
                    let message = error.localizedDescription
                    XCTAssertTrue(message.contains("bad config line 1"), message)
                    XCTAssertTrue(message.contains("git config exit"), message)
                    XCTAssertFalse(message.contains(fixture.sandbox.path))
                    XCTAssertFalse(message.contains("invalid-secret-payload"))
                }
            }
        }

        private func readLease(_ lease: GitRawOutputSpoolLease) throws -> Data {
            var output = Data()
            let reader = try lease.makeReader()
            while let chunk = try reader.nextChunk() {
                output.append(chunk)
            }
            return output
        }

        func testHookPathInspectionReportsConfiguredPathWithoutExecutingHook() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            let service = GitService()
            for hooks in [repo.appendingPathComponent(".git/hooks"), fixture.sandbox.appendingPathComponent("custom-hooks")] {
                try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
                let hook = hooks.appendingPathComponent("post-checkout")
                try FileManager.default.copyItem(at: script, to: hook)
                if hooks.lastPathComponent == "custom-hooks" {
                    try fixture.runGit(["config", "core.hooksPath", hooks.path], at: repo)
                }
                let args = ["rev-parse", "--git-path", "hooks/post-checkout"]
                let expected = try fixture.runGit(args, at: repo)
                let (output, _, code) = try await service.runGitDataForTesting(args, at: repo, env: ["HOME": fixture.sandbox.path])
                XCTAssertEqual(code, 0)
                XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
                let path = expected.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
                XCTAssertEqual(resolved.standardizedFileURL, hook.standardizedFileURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }

        func testMergeTreeRenormalizationRefusesRepositoryFilterIncludingSpoolPath() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "first\nmiddle\nlast\n"])
            try fixture.runGit(["checkout", "-b", "source"], at: repo)
            try fixture.write("source\nmiddle\nlast\n", to: "file.txt", at: repo)
            try fixture.stage("file.txt", at: repo)
            try fixture.commit("Source change", at: repo)
            try fixture.runGit(["checkout", "main"], at: repo)
            try fixture.write("first\nmiddle\ntarget\n", to: "file.txt", at: repo)
            try fixture.stage("file.txt", at: repo)
            try fixture.commit("Target change", at: repo)
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.write("*.txt filter=inspection\n", to: ".git/info/attributes", at: repo)
            try fixture.runGit(["config", "filter.inspection.clean", shellCommand(script.path)], at: repo)
            try fixture.runGit(["config", "merge.renormalize", "true"], at: repo)
            let args = ["merge-tree", "--write-tree", "--name-only", "--no-messages", "main", "source"]
            _ = try? fixture.runGit(args, at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "renormalization positive control")
            try FileManager.default.removeItem(at: marker)
            let service = GitService()
            do {
                _ = try await service.predictWorktreeMergeConflicts(sourceHead: "source", targetHead: "main", at: repo)
                XCTFail("Merge preview must refuse the repository filter")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("repository-configured executable"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            do {
                _ = try await service.runGitSpoolingForTesting(args, at: repo)
                XCTFail("Spooling merge-tree must refuse the repository filter")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("repository-configured executable"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testStatusDoesNotExecuteConfiguredFsmonitorIncludingSpoolPath() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.runGit(["config", "core.fsmonitor", shellCommand(script.path)], at: repo)
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
            try fixture.runGit(["config", "diff.inspection.textconv", shellCommand(script.path)], at: repo)
            try fixture.write("after\n", to: "file.txt", at: repo)
            let service = GitService()
            for arguments in [["diff", "HEAD"], ["log", "-p", "-1"], ["show", "HEAD"], ["blame", "file.txt"], ["diff", "--no-textconv", "--textconv", "HEAD"], ["log", "--no-textconv", "--textconv", "-p", "-1"]] {
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
            try fixture.runGit(["config", "diff.external", shellCommand(script.path)], at: repo)
            try fixture.write("after\n", to: "file.txt", at: repo)
            _ = try fixture.runGit(["diff", "HEAD"], at: repo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control")
            try FileManager.default.removeItem(at: marker)
            let service = GitService()
            for arguments in [["diff", "HEAD"], ["diff", "--no-ext-diff", "--ext-diff", "HEAD"]] {
                let (_, _, exitCode) = try await service.runGitDataForTesting(arguments, at: repo)
                XCTAssertEqual(exitCode, 0)
                let (_, _, spoolCode, _) = try await service.runGitSpoolingForTesting(arguments, at: repo)
                XCTAssertEqual(spoolCode, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }

        func testRepositoryFilterFailsClosedIncludingAnIncludedConfiguration() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try fixture.makeRepository(named: "repo", files: ["file.txt": "before\n"])
            let (script, marker) = try makeMarkerScript(fixture)
            try fixture.write("*.txt filter=inspection\n", to: ".git/info/attributes", at: repo)
            let includedConfig = fixture.sandbox.appendingPathComponent("driver-config")
            let command = shellCommand(script.path)
            try fixture.runGit(["config", "--file", includedConfig.path, "filter.inspection.clean", command], at: repo)
            try fixture.runGit(["config", "--file", includedConfig.path, "filter.inspection.required", "true"], at: repo)
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
            XCTAssertEqual(String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), command)
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
            try fixture.runGit(["config", "filter.inspection.process", shellCommand(script.path)], at: repo)
            try fixture.write("after!\n", to: "file.txt", at: repo)
            // The marker helper deliberately does not implement the filter protocol.
            var controlDiagnostic = ""
            do {
                _ = try fixture.runGit(["diff", "HEAD"], at: repo)
            } catch {
                controlDiagnostic = error.localizedDescription
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "positive control: \(controlDiagnostic)")
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

        private func shellCommand(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
