import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class MergeRecoveryTests: XCTestCase {
    func testAuthorityRoutesFencedConflictedMergeAbort() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-merge-recovery-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let owned = directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        addTeardownBlock { try await store.close() }
        let actor = ExternalActor(userID: "owner", username: "owner", displayName: "Owner")
        let service = try WorktreeRuntimeService(baseDirectory: owned.path, runner: ConflictingMergeRunner(preMergeHead: "abc123"), resources: store)
        let authority = RepoPromptHeadlessAuthority(store: store, worktreeService: service)
        let project = try await authority.createProject(
            input: .init(name: "Project", roots: [.init(logicalName: "source", path: target.path, writable: false)]),
            externalActor: actor,
            idempotencyKey: "project",
            requestDigest: "project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "session",
            requestDigest: "session"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let binding = WorktreeBindingSnapshot(
            bindingID: UUID(),
            projectID: project.projectID,
            rootID: rootID,
            sessionID: session.sessionID,
            baseRef: "main",
            branch: "feature",
            physicalPath: owned.appendingPathComponent("binding").path,
            ownershipState: .active,
            mergeState: .clean,
            revision: 1
        )
        _ = try await store.persistWorktree(binding, actor: actor, correlationID: UUID())
        do {
            _ = try await authority.execute(
                command: .mergeWorktree(bindingID: binding.bindingID, strategy: "merge", expectedRevision: 1),
                sessionID: session.sessionID,
                externalActor: actor,
                idempotencyKey: "merge",
                requestDigest: "merge"
            )
            XCTFail("expected merge conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .worktreeConflict)
        }
        let activeLeases = try await store.worktreeMergeLeases(nonterminalOnly: true)
        let lease = try XCTUnwrap(activeLeases.first)
        let receipt = try await authority.execute(
            command: .abortConflictedMerge(bindingID: binding.bindingID, leaseID: lease.leaseID, expectedRevision: 1),
            sessionID: session.sessionID,
            externalActor: actor,
            idempotencyKey: "abort",
            requestDigest: "abort"
        )
        XCTAssertEqual(receipt.operation, "abortConflictedMerge")
        let recovered = try await authority.worktreeSnapshot(projectID: project.projectID, bindingID: binding.bindingID)
        XCTAssertEqual(recovered.mergeState, .clean)
        XCTAssertEqual(recovered.revision, 2)
        let allLeases = try await store.worktreeMergeLeases(nonterminalOnly: false)
        XCTAssertEqual(allLeases.first?.state, .aborted)
        try await service.removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: [])
        try FileManager.default.removeItem(at: directory)
    }

    func testMergeConflictLeasePublishesArtifactAndSupportsVerifiedAbortRecovery() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-merge-recovery-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let owned = directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = ConflictingMergeRunner(preMergeHead: "abc123")
        let service = try WorktreeRuntimeService(baseDirectory: owned.path, runner: runner, resources: store)
        let binding = WorktreeBindingSnapshot(
            bindingID: UUID(),
            projectID: UUID(),
            rootID: UUID(),
            sessionID: UUID(),
            baseRef: "main",
            branch: "feature",
            physicalPath: owned.appendingPathComponent("binding").path,
            ownershipState: .active,
            mergeState: .clean,
            revision: 1
        )
        do {
            _ = try await service.merge(binding, targetPath: target.path, strategy: "merge")
            XCTFail("expected merge conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .worktreeConflict)
        }
        let leases = try await store.worktreeMergeLeases(nonterminalOnly: true)
        let conflict = try XCTUnwrap(leases.first)
        XCTAssertEqual(conflict.state, .conflicted)
        let conflictPath = try XCTUnwrap(conflict.conflictArtifactPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictPath))
        let conflictResource = try await store.ownedResource(externalID: conflict.leaseID, kind: .mergeConflict)
        XCTAssertEqual(conflictResource?.lifecycleState, .active)

        let recovered = try await service.abortConflictedMerge(
            binding,
            targetPath: target.path,
            leaseID: conflict.leaseID
        )
        XCTAssertEqual(recovered.mergeState, .clean)
        XCTAssertEqual(recovered.revision, 2)
        let allLeases = try await store.worktreeMergeLeases(nonterminalOnly: false)
        XCTAssertEqual(allLeases.first?.state, .aborted)
        try await store.close()
    }
}

private actor ConflictingMergeRunner: WorkspaceCommandRunning {
    private let preMergeHead: String

    init(preMergeHead: String) {
        self.preMergeHead = preMergeHead
    }

    func run(
        executable _: String,
        arguments: [String],
        workingDirectory: String,
        maximumBytes _: Int
    ) async throws -> String {
        if arguments.contains("--show-toplevel") { return workingDirectory }
        if arguments.suffix(2) == ["rev-parse", "HEAD"] { return preMergeHead }
        if arguments.contains("--abort") { return "" }
        if arguments.contains("merge") {
            throw ServiceAPIError(code: .worktreeConflict, message: "injected merge conflict")
        }
        return ""
    }
}
