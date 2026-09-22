import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppCommandLifetimeTests: XCTestCase {
    private let root = WorkspaceRootSetKey(paths: ["/command-lifetime"])

    func testRetryAndCreationAccountingSurviveTransfer() async throws {
        var results: [AppCommandExecutionResult] = []
        let lifetime = makeLifetime { results.append($0) }
        let commandID = lifetime.id
        XCTAssertTrue(lifetime.beginExecution(in: 1))
        let created = resolution(provenance: .created, committed: true)
        _ = try await lifetime.resolvePersistentFolder(expectedRoot: root) { created }
        XCTAssertTrue(lifetime.retry(expectedRoot: root, failure: .workspaceUnavailable, in: 1))
        XCTAssertTrue(lifetime.beginExecution(in: 1))
        XCTAssertTrue(lifetime.transfer(to: 2, route: .authorityExactRoot(expectedRoot: root), from: 1))
        XCTAssertEqual(lifetime.id, commandID)

        // The old owner can neither execute nor fulfill the transferred obligation.
        lifetime.windowClosed(in: 1)
        lifetime.finish(.cancelled, in: 1)
        XCTAssertFalse(lifetime.beginExecution(in: 1))
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(lifetime.beginExecution(in: 2))
        let reused = resolution(provenance: .reused, committed: false)
        _ = try await lifetime.resolvePersistentFolder(expectedRoot: root) { reused }
        lifetime.recordPendingPublicationReuse()

        XCTAssertFalse(lifetime.canForward(to: 1))
        XCTAssertFalse(lifetime.canForward(to: 3))
        XCTAssertFalse(lifetime.retry(expectedRoot: root, failure: .routeChangedAfterRetry, in: 2))
        XCTAssertEqual(results, [.partialSuccess(
            workspaceID: created.workspace.id,
            reason: .failed(.routeChangedAfterRetry)
        )])
        lifetime.finish(.completed(workspaceID: reused.workspace.id), in: 2)
        XCTAssertEqual(results.count, 1)
    }

    func testOnlyCommittedCreationChangesTerminalFailure() async throws {
        for (provenance, committed) in [
            (PersistentFolderOpenProvenance.created, true),
            (.created, false),
            (.reused, false)
        ] {
            for terminal in [AppCommandExecutionResult.cancelled, .failed(.workspaceSwitchBlocked)] {
                var results: [AppCommandExecutionResult] = []
                let lifetime = makeLifetime { results.append($0) }
                XCTAssertTrue(lifetime.beginExecution(in: 1))
                let resolved = resolution(provenance: provenance, committed: committed)
                _ = try await lifetime.resolvePersistentFolder(expectedRoot: root) { resolved }
                lifetime.finish(terminal, in: 1)
                let expected: AppCommandExecutionResult = if committed {
                    .partialSuccess(
                        workspaceID: resolved.workspace.id,
                        reason: terminal == .cancelled ? .cancelled : .failed(.workspaceSwitchBlocked)
                    )
                } else {
                    terminal
                }
                XCTAssertEqual(results, [expected], "\(provenance), committed=\(committed)")
            }
        }
    }

    func testCloseDefersExecutingResolutionAndPreservesFirstCommit() async throws {
        var results: [AppCommandExecutionResult] = []
        let lifetime = makeLifetime { results.append($0) }
        XCTAssertTrue(lifetime.beginExecution(in: 1))
        let created = resolution(provenance: .created, committed: true)
        _ = try await lifetime.resolvePersistentFolder(expectedRoot: root) {
            lifetime.windowClosed(in: 1)
            XCTAssertTrue(results.isEmpty)
            await Task.yield()
            return created
        }
        // Even a later resolution reporting another creation cannot replace the
        // first committed workspace that this command is responsible for reporting.
        _ = try await lifetime.resolvePersistentFolder(expectedRoot: root) {
            self.resolution(provenance: .created, committed: true)
        }
        lifetime.finish(.failed(.windowClosed), in: 1)
        lifetime.windowClosed(in: 1)
        XCTAssertEqual(results, [.partialSuccess(
            workspaceID: created.workspace.id,
            reason: .failed(.windowClosed)
        )])
    }

    func testTransferredPendingCommandIsSettledOnlyByDestinationClose() {
        var results: [AppCommandExecutionResult] = []
        let lifetime = makeLifetime { results.append($0) }
        XCTAssertTrue(lifetime.beginExecution(in: 1))
        XCTAssertFalse(lifetime.canForward(to: 1))
        XCTAssertTrue(lifetime.canForward(to: 2))
        XCTAssertTrue(lifetime.transfer(to: 2, route: .authorityExactRoot(expectedRoot: root), from: 1))
        lifetime.windowClosed(in: 1)
        XCTAssertTrue(results.isEmpty)
        lifetime.windowClosed(in: 2)
        lifetime.windowClosed(in: 2)
        XCTAssertFalse(lifetime.beginExecution(in: 2))
        XCTAssertEqual(results, [.failed(.windowClosed)])
    }

    func testCompletionIsClearedBeforeReentrantCalls() {
        var results: [AppCommandExecutionResult] = []
        var lifetime: AppCommandLifetime!
        lifetime = makeLifetime { result in
            results.append(result)
            lifetime.finish(.cancelled, in: 1)
            lifetime.windowClosed(in: 1)
        }
        // Also exercises enqueue rejection / close before execution, without a window fixture.
        lifetime.windowClosed(in: 1)
        lifetime.finish(.completed(workspaceID: nil), in: 1)
        XCTAssertEqual(results, [.failed(.windowClosed)])
        XCTAssertFalse(lifetime.beginExecution(in: 1))
    }

    func testForwardingAllowanceCannotBeConsumedTwice() {
        var results: [AppCommandExecutionResult] = []
        let lifetime = makeLifetime { results.append($0) }
        XCTAssertTrue(lifetime.beginExecution(in: 1))
        XCTAssertTrue(lifetime.transfer(to: 2, route: .authorityExactRoot(expectedRoot: root), from: 1))
        XCTAssertTrue(lifetime.beginExecution(in: 2))
        XCTAssertFalse(lifetime.transfer(to: 3, route: .authorityExactRoot(expectedRoot: root), from: 2))
        XCTAssertEqual(results, [.failed(.routeChangedAfterRetry)])
        XCTAssertFalse(lifetime.beginExecution(in: 3))
    }

    private func makeLifetime(completion: @escaping AppCommandCompletion) -> AppCommandLifetime {
        AppCommandLifetime(
            command: AppCommand(
                workspaceName: nil,
                fileList: [],
                promptText: nil,
                folderPath: "/command-lifetime",
                newPrompt: nil,
                focus: nil,
                ephemeral: nil,
                persist: nil
            ),
            folderRoute: .unresolved(expectedRoot: root),
            windowID: 1,
            completion: completion
        )
    }

    private func resolution(
        provenance: PersistentFolderOpenProvenance,
        committed: Bool
    ) -> PersistentFolderOpenResolutionDetails {
        PersistentFolderOpenResolutionDetails(
            workspace: WorkspaceModel(name: "Lifetime", repoPaths: ["/command-lifetime"]),
            provenance: provenance,
            operationID: UUID(),
            creationCommitted: committed,
            activationState: FolderOpenActivationState(
                workspaceID: nil,
                declaredRoots: WorkspaceRootSetKey(paths: []),
                loadedRoots: WorkspaceRootSetKey(paths: [])
            )
        )
    }
}
