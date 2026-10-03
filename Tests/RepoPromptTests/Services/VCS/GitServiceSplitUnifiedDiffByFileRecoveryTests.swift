import Foundation
@testable import RepoPromptApp
import XCTest

final class GitServiceSplitUnifiedDiffByFileRecoveryTests: XCTestCase {
    func testSplitUnifiedDiffByFileSeparatesModifiedRenameAndDeleteBlocks() {
        let diff = #"""
        warning: ignored preamble
        diff --git a/Sources/One.swift b/Sources/One.swift
        index 1111111..2222222 100644
        --- a/Sources/One.swift
        +++ b/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git "a/Docs/Old Name.md" "b/Docs/New Name.md"
        similarity index 100%
        rename from "Docs/Old Name.md"
        rename to "Docs/New Name.md"
        diff --git a/Docs/Removed.md b/Docs/Removed.md
        deleted file mode 100644
        index 3333333..0000000
        --- a/Docs/Removed.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -deleted
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), [
            "Sources/One.swift",
            "Docs/New Name.md",
            "Docs/Removed.md"
        ])
        XCTAssertFalse(perFile["Sources/One.swift"]?.contains("warning: ignored preamble") ?? true)
        XCTAssertFalse(perFile["Sources/One.swift"]?.contains("Docs/New Name.md") ?? true)
        XCTAssertTrue(perFile["Docs/New Name.md"]?.contains("rename to \"Docs/New Name.md\"") ?? false)
        XCTAssertTrue(perFile["Docs/Removed.md"]?.contains("+++ /dev/null") ?? false)
        XCTAssertFalse(perFile["Docs/Removed.md"]?.hasSuffix("\n") ?? true)
    }

    func testSplitUnifiedDiffByFileNormalizesNumberedNoIndexDotPrefixes() {
        let diff = #"""
        diff --git 1/./Nested/Second File.txt 2/./Nested/Second File.txt
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ 2/./Nested/Second File.txt
        @@ -0,0 +1 @@
        +second
        """#.trimmingCharacters(in: .newlines)

        let normalized = GitService.normalizeBatchedUntrackedDiffPaths(diff)
        let perFile = GitService.splitUnifiedDiffByFile(normalized)

        XCTAssertTrue(normalized.contains("diff --git a/Nested/Second File.txt b/Nested/Second File.txt"))
        XCTAssertFalse(normalized.contains("1/./"))
        XCTAssertFalse(normalized.contains("2/./"))
        XCTAssertEqual(Set(perFile.keys), Set(["Nested/Second File.txt"]))
    }

    func testSplitUnifiedDiffByFileNormalizesMnemonicPrefixes() {
        let diff = #"""
        diff --git i/Sources/One.swift w/Sources/One.swift
        index 1111111..2222222 100644
        --- i/Sources/One.swift
        +++ w/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["Sources/One.swift"]))
    }

    func testSplitUnifiedDiffByFilePreservesUnpairedMnemonicLikeDirectories() {
        let diff = #"""
        diff --git w/Sources/One.swift w/Sources/One.swift
        index 1111111..2222222 100644
        --- w/Sources/One.swift
        +++ w/Sources/One.swift
        @@ -1 +1 @@
        -old
        +new
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["w/Sources/One.swift"]))
    }

    func testSplitUnifiedDiffByFileNormalizesNumberedPrefixesFromHeaderFallback() {
        let diff = #"""
        diff --git 1/./Artifacts/Output.bin 2/./Artifacts/Output.bin
        index 1111111..2222222 100644
        Binary files 1/./Artifacts/Output.bin and 2/./Artifacts/Output.bin differ
        """#.trimmingCharacters(in: .newlines)

        let perFile = GitService.splitUnifiedDiffByFile(diff)

        XCTAssertEqual(Set(perFile.keys), Set(["Artifacts/Output.bin"]))
    }
}

// MARK: - Untracked file statistics

final class GitUntrackedLineStatsTests: XCTestCase {
    func testUntrackedStatsPreserveTextAndBinaryLineCounts() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "UntrackedLineStats")
        defer { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
        let cases: [(name: String, bytes: Data, lines: Int?)] = [
            ("empty.txt", Data(), 0),
            ("unterminated.txt", Data("one\ntwo".utf8), 2),
            ("terminated.txt", Data("one\ntwo\n".utf8), 2),
            ("crlf.txt", Data("one\r\ntwo\r\n".utf8), 2),
            ("newlines.txt", Data("\n\n\n".utf8), 3),
            ("cr.txt", Data("one\rtwo".utf8), 1),
            ("binary.bin", Data([0, 10, 65]), nil),
            ("binary-tail.bin", Data([65, 10, 0]), nil)
        ]
        for value in cases {
            try value.bytes.write(to: root.appendingPathComponent(value.name))
        }
        let service = GitService()
        let files = try await service.getChangedFilesStats(
            compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
        )
        XCTAssertEqual(Set(files.map(\.path)), Set(cases.map(\.name)))
        for value in cases {
            let file = try XCTUnwrap(files.first { $0.path == value.name }, value.name)
            XCTAssertEqual(file.status, "??", value.name)
            XCTAssertEqual(file.additions, value.lines, value.name)
            XCTAssertEqual(file.deletions, value.lines == nil ? nil : 0, value.name)
        }
    }

    func testLargeTextFileStatsRemainStableAcrossRefreshes() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "UntrackedLineStatsLarge")
        defer { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
        let line = Data((String(repeating: "a", count: 63) + "\n").utf8)
        var data = Data()
        for _ in 0 ..< 65536 {
            data.append(line)
        }
        try data.write(to: root.appendingPathComponent("large.txt"))
        let service = GitService()
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< 5 {
            let files = try await service.getChangedFilesStats(
                compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
            )
            XCTAssertEqual(files.count, 1)
            let file = try XCTUnwrap(files.first)
            XCTAssertEqual(file.path, "large.txt")
            XCTAssertEqual(file.additions, 65536)
            XCTAssertEqual(file.deletions, 0)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        print("UNTRACKED_STATS_BENCH bytes=4194304 refreshes=5 elapsed_ns=\(elapsed)")
    }

    #if DEBUG
        func testUntrackedStatsReuseAndFileIdentityInvalidation() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: "UntrackedStatsCacheIdentity")
            defer { fixture.cleanup() }
            let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
            let url = root.appendingPathComponent("file.txt")
            try Data("one\n".utf8).write(to: url)
            let service = GitService()
            _ = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            _ = try await service.getChangedFilesStats(
                compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
            )
            var snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 1, "Both entry points share unchanged-file counts")
            try Data("one\ntwo\n".utf8).write(to: url)
            var files = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            XCTAssertEqual(files.first?.additions, 2)
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 2, "Changed size must reread")
            let modified = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            _ = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 3, "Changed mtime must reread")
            // Atomic replacement keeps size/mtime but changes inode (and normally ctime).
            try Data("abcdefgh".utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            files = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            XCTAssertEqual(files.first?.additions, 1)
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 4)
            try Data([0, 10]).write(to: url)
            for _ in 0 ..< 2 {
                files = try await service.getChangedFilesStats(relativeTo: .head, at: root)
                XCTAssertNil(files.first?.additions)
                XCTAssertNil(files.first?.deletions)
            }
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 5, "A stable binary result is reusable too")
        }

        func testUntrackedCachePrunesFullListingsButNotPathScopedListings() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: "UntrackedStatsCachePruning")
            defer { fixture.cleanup() }
            let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
            for name in ["one.txt", "two.txt"] {
                try Data("line\n".utf8).write(to: root.appendingPathComponent(name))
            }
            let service = GitService()
            _ = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            _ = try await service.getChangedFilesStats(
                compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, paths: ["one.txt"], at: root
            )
            var snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.paths, ["one.txt", "two.txt"])
            XCTAssertEqual(snapshot.reads, 2)
            try FileManager.default.moveItem(at: root.appendingPathComponent("one.txt"), to: root.appendingPathComponent("renamed.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("two.txt"))
            _ = try await service.getChangedFilesStats(
                compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
            )
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.paths, ["renamed.txt"])
            XCTAssertEqual(snapshot.reads, 3)
            await service.invalidateUntrackedStats(at: root)
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertTrue(snapshot.paths.isEmpty)
            _ = try await service.getChangedFilesStats(relativeTo: .head, at: root)
            snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 4, "Repository invalidation discards counts")
        }

        func testUntrackedSymlinkStatsAreNotCached() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: "UntrackedStatsSymlink")
            defer { fixture.cleanup() }
            let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("README.md")
            )
            let service = GitService()
            for (text, lines) in [("one\n", 1), ("one\ntwo\n", 2)] {
                try Data(text.utf8).write(to: root.appendingPathComponent("README.md"))
                let files = try await service.getChangedFilesStats(relativeTo: .head, at: root)
                let link = try XCTUnwrap(files.first { $0.path == "link.txt" })
                XCTAssertEqual(link.additions, lines)
            }
            let snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 2)
            XCTAssertTrue(snapshot.paths.isEmpty)
        }

        func testUntrackedCacheIsBoundedAndSeparatesRepositories() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: "UntrackedStatsCacheBound")
            defer { fixture.cleanup() }
            let service = GitService(untrackedStatsCacheLimit: 1)
            let one = try fixture.makeRepository(named: "one", files: ["README.md": "tracked\n"])
            let two = try fixture.makeRepository(named: "two", files: ["README.md": "tracked\n"])
            for (root, text, lines) in [(one, "one\n", 1), (two, "one\ntwo\n", 2)] {
                try Data(text.utf8).write(to: root.appendingPathComponent("same.txt"))
                let files = try await service.getChangedFilesStats(relativeTo: .head, at: root)
                XCTAssertEqual(files.first?.additions, lines)
            }
            let snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: one)
            XCTAssertEqual(snapshot.count, 1)
            XCTAssertEqual(snapshot.paths, ["same.txt"])
            await service.invalidateUntrackedStats(at: two)
            _ = try await service.getChangedFilesStats(relativeTo: .head, at: one)
            let after = await service.untrackedStatsCacheSnapshotForTesting(at: one)
            XCTAssertEqual(after.reads, 2, "Invalidating another root cannot evict this root")
        }
    #endif

    func testUnchangedUntrackedFilesRefreshMeasurement() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "UntrackedStatsRefresh")
        defer { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
        let bytes = Data((String(repeating: "a", count: 63) + "\n").utf8)
        var data = Data()
        for _ in 0 ..< 4096 {
            data.append(bytes)
        }
        for index in 0 ..< 100 {
            try data.write(to: root.appendingPathComponent("file-\(index).txt"))
        }
        let service = GitService()
        _ = try await service.getChangedFilesStats(
            compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
        )
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< 5 {
            let files = try await service.getChangedFilesStats(
                compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
            )
            XCTAssertEqual(files.count, 100)
            XCTAssertTrue(files.allSatisfy { $0.additions == 4096 && $0.deletions == 0 })
        }
        #if DEBUG
            let snapshot = await service.untrackedStatsCacheSnapshotForTesting(at: root)
            XCTAssertEqual(snapshot.reads, 100, "Warm refreshes must not reopen unchanged files")
        #endif
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        print("UNTRACKED_REFRESH_BENCH files=100 bytes_each=262144 warm_refreshes=5 elapsed_ns=\(elapsed)")
    }

    func testNewlinesAndBinaryBytesAcrossReadChunkBoundaries() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "UntrackedLineStatsChunks")
        defer { fixture.cleanup() }
        let root = try fixture.makeRepository(named: "repo", files: ["README.md": "tracked\n"])
        let boundary = 64 * 1024
        let cases: [(name: String, bytes: Data, lines: Int?)] = [
            ("exact.txt", Data(repeating: 65, count: boundary), 1),
            ("boundary-newlines.txt", Data(repeating: 65, count: boundary - 1) + Data([10, 10, 65]), 3),
            ("boundary-crlf.txt", Data(repeating: 65, count: boundary - 1) + Data([13, 10]), 1),
            ("nul-last.bin", Data(repeating: 65, count: boundary - 1) + Data([0]), nil),
            ("nul-next.bin", Data(repeating: 65, count: boundary) + Data([0]), nil)
        ]
        for value in cases {
            try value.bytes.write(to: root.appendingPathComponent(value.name))
        }
        let service = GitService()
        let files = try await service.getChangedFilesStats(
            compare: .uncommitted(base: "HEAD"), includeUntrackedWhenApplicable: true, at: root
        )
        XCTAssertEqual(Set(files.map(\.path)), Set(cases.map(\.name)))
        for value in cases {
            let file = try XCTUnwrap(files.first { $0.path == value.name }, value.name)
            XCTAssertEqual(file.additions, value.lines, value.name)
            XCTAssertEqual(file.deletions, value.lines == nil ? nil : 0, value.name)
        }
    }
}
