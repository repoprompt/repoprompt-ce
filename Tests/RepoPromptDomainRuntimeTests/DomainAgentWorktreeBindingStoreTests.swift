import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentWorktreeBindingStoreTests: XCTestCase {
    func testBindingsPersistAcrossRuntimeInstancesAndRemoval() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "worktree-bindings"
        let sessionID = UUID()
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-1",
            logicalRootPath: "/workspace/repo",
            logicalRootName: "repo",
            worktreeID: "worktree-1",
            worktreeRootPath: "/workspace/repo-worktree",
            worktreeName: "feature",
            branch: "feature/test",
            head: "abc123",
            visualLabel: "Test",
            visualColorHex: "#123456",
            source: "test"
        )

        let first = makeStore(root: root, profile: profile)
        await first.bootstrap()
        let insertedRevision = try await first.upsert(sessionID: sessionID, binding: binding)
        XCTAssertEqual(insertedRevision, 1)
        let firstBindings = await first.bindings(sessionID: sessionID)
        XCTAssertEqual(firstBindings, [binding])

        let second = makeStore(root: root, profile: profile)
        await second.bootstrap()
        let persistedBindings = await second.bindings(sessionID: sessionID)
        XCTAssertEqual(persistedBindings, [binding])
        let removedRevision = try await second.remove(sessionID: sessionID, repositoryID: binding.repositoryID)
        XCTAssertEqual(removedRevision, 2)

        let third = makeStore(root: root, profile: profile)
        await third.bootstrap()
        let remainingBindings = await third.bindings(sessionID: sessionID)
        XCTAssertTrue(remainingBindings.isEmpty)
    }

    private func makeStore(root: URL, profile: String) -> DomainAgentWorktreeBindingStore {
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
        let configuration = DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: profile,
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil
        )
        return DomainAgentWorktreeBindingStore(
            persistence: DomainPersistenceCoordinator(configuration: configuration, identity: identity),
            profileIdentifier: profile
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainAgentWorktreeBindingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
