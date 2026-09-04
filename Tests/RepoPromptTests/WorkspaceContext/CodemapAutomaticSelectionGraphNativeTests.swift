import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapAutomaticSelectionGraphNativeTests: XCTestCase {
    func testNestedRepositoryGraphUsesValidatedWorktreeBytesAndCompletesWithoutRetry() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let relativePath = "Nested/Sources/Feature.swift"
        let rootURL = try repository.makeRepository(
            named: "outer",
            files: [relativePath: "struct OuterBlobOnly { let value: Int }\n"]
        )
        let nestedRoot = rootURL.appendingPathComponent("Nested", isDirectory: true)
        try repository.initializeRepository(at: nestedRoot)
        try repository.write(
            "struct NestedWorktreeOnly { let value: Int }\n",
            to: "Sources/Feature.swift",
            at: nestedRoot
        )
        try repository.stage("Sources/Feature.swift", at: nestedRoot)
        try repository.commit("Nested worktree content", at: nestedRoot)

        let outerBlob = try repository.runGit(["show", "HEAD:\(relativePath)"], at: rootURL)
        let worktreeBytes = try String(
            contentsOf: rootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        XCTAssertTrue(outerBlob.contains("OuterBlobOnly"))
        XCTAssertTrue(worktreeBytes.contains("NestedWorktreeOnly"))

        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock {
            await store.unloadRoot(id: loaded.id)
            await fixture.shutdown()
            repository.cleanup()
        }

        let files = await store.files(inRoot: loaded.id)
        let nestedFile = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == relativePath
        })
        let engine = try fixture.runtime().bindingEngine()
        let rootAccounting = try await waitForGraphCompletion(
            engine: engine,
            rootID: loaded.id
        )

        XCTAssertEqual(rootAccounting.phase, .complete)
        XCTAssertEqual(rootAccounting.retryAttempt, 0)
        XCTAssertNil(rootAccounting.retry)
        XCTAssertNotNil(rootAccounting.progress.catalogCompletion)
        XCTAssertEqual(rootAccounting.progress.counts.transientCount, 0)
        XCTAssertEqual(rootAccounting.progress.counts.terminalExcludedCount, 0)

        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.counters.graphIndexRetries, 0)
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootAccounting.rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        let pinned: WorkspaceCodemapGraphPinnedSnapshot
        switch await graph.latestSnapshot() {
        case let .ready(snapshot):
            pinned = snapshot
        case .pending:
            return XCTFail("Completed graph index should publish a graph snapshot")
        case let .revoked(reason):
            return XCTFail("Completed graph index should not be revoked: \(reason)")
        }

        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(pinned.snapshot.coverage.terminalExcludedCount, 0)
        let node = try XCTUnwrap(pinned.snapshot.nodesByFileID[nestedFile.id])
        XCTAssertTrue(node.contribution.sortedUniqueDefinitions.contains("NestedWorktreeOnly"))
        XCTAssertFalse(node.contribution.sortedUniqueDefinitions.contains("OuterBlobOnly"))
        guard case .contributed = pinned.snapshot.slotsByFileID[nestedFile.id]?.state else {
            return XCTFail("Nested source should contribute to the completed graph")
        }
        XCTAssertFalse(pinned.snapshot.slotsByFileID.values.contains { slot in
            if case .terminalExcluded(.repositoryBoundary) = slot.state { return true }
            return false
        })
        XCTAssertTrue(fixture.builtSourceTexts.values.contains { $0.contains("NestedWorktreeOnly") })
        XCTAssertFalse(fixture.builtSourceTexts.values.contains { $0.contains("OuterBlobOnly") })
    }

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: { $0.rootEpoch.rootID == rootID }),
               root.phase == .complete
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GraphWaitError.timedOut
    }
}

private enum GraphWaitError: Error {
    case timedOut
}
