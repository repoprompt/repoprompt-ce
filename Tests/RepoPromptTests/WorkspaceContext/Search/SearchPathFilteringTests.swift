@testable import RepoPrompt
import XCTest

final class SearchPathFilteringTests: XCTestCase {
    private let rootA = "/tmp/RepoPromptSearchRootA"
    private let rootB = "/tmp/RepoPromptSearchRootB"

    private func snapshot(root: String, relativePath: String, displayPath: String? = nil) -> FileSearchPathSnapshot {
        FileSearchPathSnapshot(
            standardizedFullPath: "\(root)/\(relativePath)",
            standardizedRelativePath: relativePath,
            standardizedRootPath: root,
            clientDisplayPath: displayPath ?? relativePath
        )
    }

    func testExactFileAndFolderMatchesRespectRestrictedRoots() {
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/App/Model.swift"),
            snapshot(root: rootB, relativePath: "Sources/App/View.swift")
        ]

        let exactFile = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .exactFile(
                    absPath: "\(rootB)/Sources/App/View.swift",
                    relPath: "Sources/App/Model.swift",
                    restrictedRootPath: rootA
                )
            ]
        )
        XCTAssertEqual(filterPathIndicesResult(snapshots: snapshots, spec: exactFile).matchedSnapshotIndices, [1, 2])

        let exactFolder = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .exactFolder(
                    absLower: "\(rootA)/sources/app",
                    relLower: "sources/app",
                    restrictedRootPath: rootA
                )
            ]
        )
        XCTAssertEqual(filterPathIndicesResult(snapshots: snapshots, spec: exactFolder).matchedSnapshotIndices, [0, 1])
    }

    func testGlobMatchesDisplayRelativeAndFullPaths() {
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift", displayPath: "App/Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/Domain/Model.swift", displayPath: "App/Sources/Domain/Model.swift"),
            snapshot(root: rootB, relativePath: "Docs/Notes.md", displayPath: "Lib/Docs/Notes.md")
        ]

        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .glob(pattern: "App/**/View.swift", restrictedRootPath: rootA),
                .glob(pattern: "Sources/**/Model.swift", restrictedRootPath: rootA),
                .glob(pattern: "\(rootB)/**/Notes.md", restrictedRootPath: rootB)
            ]
        )

        let result = filterPathIndicesResult(snapshots: snapshots, spec: spec)
        XCTAssertEqual(result.matchedSnapshotIndices, [0, 1, 2])
        XCTAssertEqual(result.visitedSnapshotCount, 3)
        XCTAssertFalse(result.cancelled)
    }

    func testLegacyPrefixMatchesDisplayPathAndDeduplicatesInInputOrder() {
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift", displayPath: "App/Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/App/Model.swift", displayPath: "App/Sources/App/Model.swift"),
            snapshot(root: rootA, relativePath: "Tests/AppTests.swift", displayPath: "App/Tests/AppTests.swift")
        ]

        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .legacyPrefix(candidateLower: "app/sources/app"),
                .exactFile(absPath: "\(rootA)/Sources/App/View.swift", relPath: "Sources/App/View.swift", restrictedRootPath: rootA)
            ]
        )

        let result = filterPathIndicesResult(snapshots: snapshots, spec: spec)
        XCTAssertEqual(result.matchedSnapshotIndices, [0, 1])
        XCTAssertEqual(filterPaths(snapshots: snapshots, spec: spec), [
            "\(rootA)/Sources/App/View.swift",
            "\(rootA)/Sources/App/Model.swift"
        ])
    }

    func testCancelledTaskReportsCancellationMetadata() async {
        let snapshots = (0 ..< 50000).map { index in
            snapshot(root: rootA, relativePath: "Sources/File\(index).swift")
        }
        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [.legacyPrefix(candidateLower: "sources")]
        )

        let cancellationGate = SearchPathFilteringCancellationGate()
        let task = Task.detached(priority: .background) {
            await cancellationGate.waitUntilCancelled()
            return filterPathIndicesResult(snapshots: snapshots, spec: spec)
        }
        await cancellationGate.waitUntilEntered()
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(result.visitedSnapshotCount, snapshots.count)
    }
}

private actor SearchPathFilteringCancellationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilCancelled() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                entered = true
                self.continuation = continuation
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    private func cancel() {
        continuation?.resume()
        continuation = nil
    }
}
