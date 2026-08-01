import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class GitDiffEngineCacheTests: XCTestCase {
        func testHitRefreshesRecencyBeforeEntryLimitEviction() throws {
            var cache = GitDiffEngine.DiffTextCache(
                limits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: .max)
            )
            let first = makeKey("a")
            let second = makeKey("b")
            let third = makeKey("c")

            cache.admit(makeResult("first"), for: first)
            cache.admit(makeResult("second"), for: second)
            XCTAssertEqual(try XCTUnwrap(cache.value(for: first)).text, "first")
            cache.admit(makeResult("third"), for: third)

            XCTAssertNil(cache.value(for: second))
            XCTAssertEqual(cache.value(for: first)?.text, "first")
            XCTAssertEqual(cache.value(for: third)?.text, "third")
            XCTAssertEqual(cache.healthSnapshot.entryCount, 2)
            XCTAssertEqual(cache.healthSnapshot.evictionCount, 1)
        }

        func testRetainedByteLimitCountsFullAndPerFileStringsAndEvictsLRU() throws {
            let firstKey = makeKey("a")
            let secondKey = makeKey("b")
            let thirdKey = makeKey("c")
            let result = makeResult("full", perFile: ["file.swift": "full"])
            let oneEntryBytes = GitDiffEngine.DiffTextCache.retainedUTF8ByteCount(
                for: firstKey,
                result: result
            )
            let expectedBytes = [
                firstKey.repoPath,
                firstKey.targetKey,
                firstKey.selectedPathsKey,
                firstKey.statusHash,
                result.fingerprint.headSHA,
                result.fingerprint.baseRef,
                result.fingerprint.statusHash,
                result.text,
                "file.swift",
                "full"
            ].reduce(0) { $0 + $1.utf8.count }
            XCTAssertEqual(oneEntryBytes, expectedBytes)
            var cache = GitDiffEngine.DiffTextCache(
                limits: .init(maximumEntryCount: 3, maximumRetainedUTF8Bytes: oneEntryBytes * 2)
            )

            cache.admit(result, for: firstKey)
            cache.admit(result, for: secondKey)
            _ = try XCTUnwrap(cache.value(for: firstKey))
            cache.admit(result, for: thirdKey)

            XCTAssertNil(cache.value(for: secondKey))
            XCTAssertNotNil(cache.value(for: firstKey))
            XCTAssertNotNil(cache.value(for: thirdKey))
            XCTAssertEqual(cache.count, 2)
            XCTAssertEqual(cache.retainedUTF8Bytes, oneEntryBytes * 2)
        }

        func testReplacementUpdatesAccountingAndOversizedReplacementRemovesOldValue() {
            let key = makeKey("same")
            let small = makeResult("small")
            let replacement = makeResult("replacement", perFile: ["file": "replacement"])
            let replacementBytes = GitDiffEngine.DiffTextCache.retainedUTF8ByteCount(
                for: key,
                result: replacement
            )
            var cache = GitDiffEngine.DiffTextCache(
                limits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: replacementBytes)
            )

            XCTAssertTrue(cache.admit(small, for: key))
            XCTAssertTrue(cache.admit(replacement, for: key))
            XCTAssertEqual(cache.count, 1)
            XCTAssertEqual(cache.retainedUTF8Bytes, replacementBytes)
            XCTAssertEqual(cache.value(for: key)?.text, "replacement")
            XCTAssertEqual(cache.healthSnapshot.replacementCount, 1)

            let oversized = makeResult(String(repeating: "x", count: replacementBytes + 1))
            XCTAssertFalse(cache.admit(oversized, for: key))
            XCTAssertNil(cache.value(for: key))
            XCTAssertEqual(cache.count, 0)
            XCTAssertEqual(cache.retainedUTF8Bytes, 0)
            XCTAssertEqual(cache.healthSnapshot.oversizedRejectionCount, 1)
        }

        func testByteAccountingSaturatesOnOverflow() {
            XCTAssertEqual(GitDiffEngine.DiffTextCache.saturatingAdd(.max, 1), .max)
            XCTAssertEqual(GitDiffEngine.DiffTextCache.saturatingAdd(.max - 1, 1), .max)
        }

        func testCacheDisabledRequestBypassesLookupButStillAdmitsRecomputedResult() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try makeModifiedRepository(using: fixture)
            let engine = GitDiffEngine(
                vcsService: VCSService(),
                gitService: GitService(),
                cacheLimits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: 1024 * 1024)
            )

            let cached = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo
            )
            let beforeBypass = await engine.cacheHealthSnapshot()

            let bypassed = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo,
                useCache: false
            )

            XCTAssertEqual(bypassed.text, cached.text)
            XCTAssertFalse(bypassed.text.isEmpty)
            XCTAssertFalse(bypassed.perFile?.isEmpty ?? true)
            let snapshot = await engine.cacheHealthSnapshot()
            XCTAssertEqual(snapshot.entryCount, 1)
            XCTAssertEqual(snapshot.hitCount, 0)
            XCTAssertEqual(snapshot.missCount, 1)
            XCTAssertEqual(snapshot.bypassCount, 1)
            // Force refresh must replace the resident entry, not leave it stale.
            XCTAssertEqual(snapshot.admissionCount, beforeBypass.admissionCount + 1)
            XCTAssertEqual(snapshot.replacementCount, 1)
        }

        func testForcedRefreshReplacesStaleSameKeyEntryForLaterCachedReads() {
            // Simulates force-refresh (useCache:false) when fingerprint/statusHash is
            // unchanged across content edits: recompute must admit/replace so the next
            // ordinary lookup returns the refreshed diff.
            let key = makeKey("same-status-hash")
            var cache = GitDiffEngine.DiffTextCache(
                limits: .init(maximumEntryCount: 4, maximumRetainedUTF8Bytes: 1024 * 1024)
            )

            XCTAssertTrue(cache.admit(makeResult("stale-diff"), for: key))
            XCTAssertEqual(cache.value(for: key)?.text, "stale-diff")

            // Forced recompute path: skip lookup, still admit.
            cache.recordBypass()
            XCTAssertTrue(cache.admit(makeResult("fresh-diff"), for: key))

            XCTAssertEqual(cache.value(for: key)?.text, "fresh-diff")
            XCTAssertEqual(cache.count, 1)
            XCTAssertEqual(cache.healthSnapshot.bypassCount, 1)
            XCTAssertEqual(cache.healthSnapshot.replacementCount, 1)
            XCTAssertEqual(cache.healthSnapshot.admissionCount, 2)
        }

        func testForcedRefreshThenOrdinaryRequestReturnsRefreshedDiffText() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try makeModifiedRepository(using: fixture)
            let engine = GitDiffEngine(
                vcsService: VCSService(),
                gitService: GitService(),
                cacheLimits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: 1024 * 1024)
            )

            let initial = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo
            )
            XCTAssertTrue(initial.text.contains("let value = 2"))

            try fixture.write("let value = 3\nlet added = true\nlet more = true\n", to: "Feature.swift", at: repo)

            let forced = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo,
                useCache: false
            )
            XCTAssertTrue(forced.text.contains("let value = 3"))
            XCTAssertFalse(forced.text.contains("+let value = 2"))

            let ordinary = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo,
                useCache: true
            )
            XCTAssertEqual(ordinary.text, forced.text)
            XCTAssertTrue(ordinary.text.contains("let value = 3"))
        }

        func testOversizedResultIsReturnedButNotCached() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let repo = try makeModifiedRepository(using: fixture)
            let engine = GitDiffEngine(
                vcsService: VCSService(),
                gitService: GitService(),
                cacheLimits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: 1)
            )

            let result = try await engine.diffText(
                target: .uncommitted(base: "HEAD"),
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: repo
            )

            XCTAssertFalse(result.text.isEmpty)
            XCTAssertFalse(result.perFile?.isEmpty ?? true)
            let snapshot = await engine.cacheHealthSnapshot()
            XCTAssertEqual(snapshot.entryCount, 0)
            XCTAssertEqual(snapshot.retainedUTF8Bytes, 0)
            XCTAssertEqual(snapshot.oversizedRejectionCount, 1)
        }

        func testConcurrentActorRequestsReturnFullResultsWithinBounds() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            // Distinct paths produce distinct cache keys so concurrent work is not
            // all hits on one identical request under actor isolation.
            let repo = try fixture.makeRepository(
                named: "repo",
                files: [
                    "A.swift": "let a = 1\n",
                    "B.swift": "let b = 1\n",
                    "C.swift": "let c = 1\n"
                ]
            )
            try fixture.write("let a = 2\n", to: "A.swift", at: repo)
            try fixture.write("let b = 2\n", to: "B.swift", at: repo)
            try fixture.write("let c = 2\n", to: "C.swift", at: repo)

            let pathA = repo.appendingPathComponent("A.swift").path
            let pathB = repo.appendingPathComponent("B.swift").path
            let pathC = repo.appendingPathComponent("C.swift").path
            let requests: [(GitDiffScope, [String])] = [
                (.all, []),
                (.selected, [pathA]),
                (.selected, [pathB]),
                (.selected, [pathC]),
                (.all, []),
                (.selected, [pathA]),
                (.selected, [pathB]),
                (.selected, [pathC])
            ]

            let maximumBytes = 1024 * 1024
            let engine = GitDiffEngine(
                vcsService: VCSService(),
                gitService: GitService(),
                cacheLimits: .init(maximumEntryCount: 2, maximumRetainedUTF8Bytes: maximumBytes)
            )

            let results = try await withThrowingTaskGroup(
                of: (Int, GitDiffEngine.DiffTextResult).self
            ) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask {
                        let result = try await engine.diffText(
                            target: .uncommitted(base: "HEAD"),
                            scope: request.0,
                            selectedAbsolutePaths: request.1,
                            repoURL: repo
                        )
                        return (index, result)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }

            XCTAssertEqual(results.count, requests.count)
            for (index, result) in results {
                XCTAssertFalse(result.text.isEmpty, "request \(index) returned empty diff")
                XCTAssertFalse(result.perFile?.isEmpty ?? true, "request \(index) missing per-file map")
            }
            // Distinct selected-path requests must not all collapse to the same body.
            let selectedBodies = results
                .filter { requests[$0.0].0 == .selected }
                .map(\.1.text)
            XCTAssertGreaterThan(Set(selectedBodies).count, 1)

            let snapshot = await engine.cacheHealthSnapshot()
            XCTAssertLessThanOrEqual(snapshot.entryCount, 2)
            XCTAssertLessThanOrEqual(snapshot.retainedUTF8Bytes, maximumBytes)
        }

        private func makeModifiedRepository(using fixture: ReviewGitRepositoryFixture) throws -> URL {
            let repo = try fixture.makeRepository(
                named: "repo",
                files: ["Feature.swift": "let value = 1\n"]
            )
            try fixture.write("let value = 2\nlet added = true\n", to: "Feature.swift", at: repo)
            return repo
        }

        private func makeKey(_ id: String) -> GitDiffEngine.CacheKey {
            GitDiffEngine.CacheKey(
                repoPath: "/repo/\(id)",
                targetKey: "target-\(id)",
                scope: .all,
                selectedPathsKey: "selected-\(id)",
                statusHash: "status-\(id)",
                backendKind: .git
            )
        }

        private func makeResult(
            _ text: String,
            perFile: [String: String]? = nil
        ) -> GitDiffEngine.DiffTextResult {
            GitDiffEngine.DiffTextResult(
                fingerprint: GitDiffFingerprint(
                    headSHA: "head",
                    baseRef: "HEAD",
                    statusHash: "status",
                    generatedAt: Date(timeIntervalSince1970: 0)
                ),
                text: text,
                perFile: perFile
            )
        }
    }
#endif
