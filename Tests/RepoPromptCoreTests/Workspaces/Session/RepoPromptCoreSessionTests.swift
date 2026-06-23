@testable import RepoPromptCore
import XCTest

final class RepoPromptCoreSessionTests: XCTestCase {
    func testHydrationAndTeardownAreExactlyOnce() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness()
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)
        let initialOwnership = await host.ownershipSnapshot(sessionID: registration.sessionID)
        let ownershipBeforeHydration = try XCTUnwrap(initialOwnership)
        XCTAssertEqual(ownershipBeforeHydration.selectedBackendCount, 1)
        XCTAssertEqual(ownershipBeforeHydration.lifecycleOwnerCount, 1)
        XCTAssertEqual(ownershipBeforeHydration.writerCount, 1)
        XCTAssertEqual(ownershipBeforeHydration.revisionAuthorityCount, 1)
        XCTAssertEqual(ownershipBeforeHydration.commandIngressCount, 1)
        XCTAssertEqual(ownershipBeforeHydration.releaseCount, 0)
        XCTAssertFalse(ownershipBeforeHydration.isReleased)

        async let first = host.hydrateSession(registration.sessionID)
        async let second = host.hydrateSession(registration.sessionID)
        let hydrationResults = await [first, second]
        for result in hydrationResults {
            guard case .awaitingFirstSnapshotApplication = result else {
                return XCTFail("concurrent hydrate did not share the original result: \(result)")
            }
        }
        let hydrateCalls = await lifecycle.hydrateCalls
        XCTAssertEqual(hydrateCalls.count, 1)

        async let removeOne: Void = host.removeSession(registration.sessionID)
        async let removeTwo: Void = host.removeSession(registration.sessionID)
        _ = await (removeOne, removeTwo)
        let unloadGenerations = await lifecycle.unloadGenerations
        let closeCount = await lifecycle.closeCount
        let registeredSessionCount = await host.registeredSessionCount()
        let admissionAfterClose = await registration.handle.admit()
        let releasedOwnership = await host.ownershipSnapshot(sessionID: registration.sessionID)
        let ownershipAfterClose = try XCTUnwrap(releasedOwnership)
        XCTAssertEqual(unloadGenerations, [1])
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(registeredSessionCount, 0)
        XCTAssertEqual(admissionAfterClose, .notReady(.closed))
        XCTAssertEqual(ownershipAfterClose.releaseCount, 1)
        XCTAssertTrue(ownershipAfterClose.isReleased)
    }

    func testShutdownWaitsForLateHydrationAndUnloadsItsGenerationExactlyOnce() async throws {
        let workspace = makeSessionTestWorkspace()
        let gate = WorkspaceSessionHydrationGate()
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.gated(gate)])
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)
        let hydration = Task { await host.hydrateSession(registration.sessionID) }
        await gate.waitUntilEntered()
        let removal = Task { await host.removeSession(registration.sessionID) }
        await Task.yield()
        await gate.release()
        await removal.value

        guard case .failed = await hydration.value else {
            return XCTFail("late hydration should fail after shutdown begins")
        }
        let unloadGenerations = await lifecycle.unloadGenerations
        let closeCount = await lifecycle.closeCount
        let admission = await registration.handle.admit()
        XCTAssertEqual(unloadGenerations, [1])
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(admission, .notReady(.closed))
    }

    func testRootReadinessFailurePreventsFirstSnapshotAndAdmission() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.failure("root hydration failed")])
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)

        guard case let .failed(failure) = await host.hydrateSession(registration.sessionID) else {
            return XCTFail("expected hydration failure")
        }
        XCTAssertTrue(failure.message.contains("root hydration failed"))
        guard case .notReady(.failed) = await registration.handle.admit() else {
            return XCTFail("failed root readiness must not admit commands")
        }
        let unloadGenerations = await lifecycle.unloadGenerations
        XCTAssertEqual(unloadGenerations, [1])
        await host.shutdown()
    }

    func testStaleLifecycleGenerationFailsClosed() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.staleGeneration(delta: 1)])
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)

        guard case let .failed(failure) = await host.hydrateSession(registration.sessionID) else {
            return XCTFail("expected stale lifecycle generation to fail")
        }
        XCTAssertTrue(failure.message.contains("stale lifecycle generation"))
        let admission = await registration.handle.admit()
        XCTAssertEqual(admission, .notReady(.failed(failure.message)))
        await host.shutdown()
    }

    func testSwitchHydratesTargetBeforeCommitAndDuplicateCommandIsIdempotent() async throws {
        let source = makeSessionTestWorkspace(name: "Source", root: "/tmp/source")
        let target = makeSessionTestWorkspace(name: "Target", root: "/tmp/target")
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.success(catalogGeneration: 10), .success(catalogGeneration: 20)])
        let active = try await makeActiveSession(
            workspaces: [source, target],
            activeWorkspaceID: source.id,
            lifecycle: lifecycle
        )

        let command = WorkspaceSessionCommandEnvelope(
            admissionToken: active.admission,
            expectedGeneration: 1,
            command: .switchWorkspace(
                WorkspaceSwitchCommand(
                    targetWorkspaceID: target.id,
                    shouldSaveCurrentState: false,
                    reason: .user
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case let .committed(receipt) = await active.registration.handle.execute(command) else {
            return XCTFail("switch did not commit")
        }
        XCTAssertEqual(receipt.sessionID, active.registration.sessionID)
        XCTAssertEqual(receipt.activationID, active.admission.activationID)
        guard case let .admitted(postSwitchAdmission) = await active.registration.handle.admit() else {
            return XCTFail("switch must preserve the session activation")
        }
        XCTAssertEqual(postSwitchAdmission.activationID, active.admission.activationID)
        let duplicateResult = await active.registration.handle.execute(command)
        XCTAssertEqual(duplicateResult, .committed(receipt))

        let currentSnapshot = await active.registration.handle.currentSnapshot()
        let snapshot = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(snapshot.activeWorkspaceID, target.id)
        XCTAssertEqual(snapshot.readiness.generation, 2)
        XCTAssertEqual(snapshot.readiness.catalogGeneration, 20)
        XCTAssertTrue(snapshot.readiness.isReady)
        XCTAssertEqual(snapshot.switchState.phase, .committed)
        let unloadGenerations = await lifecycle.unloadGenerations
        let hydrateCallCount = await lifecycle.hydrateCalls.count
        XCTAssertEqual(unloadGenerations, [1])
        XCTAssertEqual(hydrateCallCount, 2)
        await active.host.shutdown()
    }

    func testSwitchTargetAndRecoveryFailureLeavesSessionUnavailable() async throws {
        let source = makeSessionTestWorkspace(name: "Source", root: "/tmp/source")
        let target = makeSessionTestWorkspace(name: "Target", root: "/tmp/target")
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [
            .success(),
            .failure("target failed"),
            .failure("recovery failed")
        ])
        let active = try await makeActiveSession(
            workspaces: [source, target],
            activeWorkspaceID: source.id,
            lifecycle: lifecycle
        )
        let command = WorkspaceSessionCommandEnvelope(
            admissionToken: active.admission,
            expectedGeneration: 1,
            command: .switchWorkspace(
                WorkspaceSwitchCommand(
                    targetWorkspaceID: target.id,
                    shouldSaveCurrentState: false,
                    reason: .user
                )
            ),
            source: WorkspaceSessionCommandSource(kind: "test")
        )

        guard case let .failed(failure) = await active.registration.handle.execute(command) else {
            return XCTFail("expected switch recovery failure")
        }
        XCTAssertTrue(failure.message.contains("recovery failed"))
        let currentSnapshot = await active.registration.handle.currentSnapshot()
        let snapshot = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(snapshot.switchState.phase, .failed)
        XCTAssertFalse(snapshot.readiness.isReady)
        guard case .failed = snapshot.availability else {
            return XCTFail("session should be unavailable after failed recovery")
        }
        guard case .notReady(.failed) = await active.registration.handle.admit() else {
            return XCTFail("failed recovery must invalidate admission")
        }
        let unloadGenerations = await lifecycle.unloadGenerations
        XCTAssertEqual(unloadGenerations, [1, 2, 3])
        await active.host.shutdown()
    }

    func testActiveRootReplacementUsesLifecycleBeforeCanonicalCommit() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.success(), .success(catalogGeneration: 5)])
        let active = try await makeActiveSession(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id,
            lifecycle: lifecycle
        )
        let command = WorkspaceSessionCommandEnvelope(
            admissionToken: active.admission,
            expectedGeneration: 1,
            command: .workspace(.replaceOrderedRoots(workspaceID: workspace.id, roots: ["/tmp/new-root"])),
            source: WorkspaceSessionCommandSource(kind: "test")
        )

        guard case let .committed(receipt) = await active.registration.handle.execute(command) else {
            return XCTFail("root replacement did not commit")
        }
        XCTAssertEqual(receipt.sessionID, active.registration.sessionID)
        let currentSnapshot = await active.registration.handle.currentSnapshot()
        let snapshot = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(snapshot.workspaces.first?.repoPaths, ["/tmp/new-root"])
        XCTAssertEqual(snapshot.readiness.generation, 2)
        XCTAssertEqual(snapshot.readiness.catalogGeneration, 5)
        let unloadGenerations = await lifecycle.unloadGenerations
        let hydrateCallCount = await lifecycle.hydrateCalls.count
        XCTAssertEqual(unloadGenerations, [1])
        XCTAssertEqual(hydrateCallCount, 2)
        await active.host.shutdown()
    }

    func testActiveWorkspaceReloadRehydratesBeforeReplacingCanonicalState() async throws {
        let workspace = makeSessionTestWorkspace()
        var reloaded = workspace
        reloaded.name = "Reloaded"
        reloaded.repoPaths = ["/tmp/reloaded"]
        let bytes = try JSONEncoder().encode(reloaded)
        let url = URL(fileURLWithPath: "/virtual/workspace.json")
        let lifecycle = WorkspaceSessionLifecycleHarness(actions: [.success(), .success(catalogGeneration: 9)])
        let io = WorkspaceSessionPersistenceIO(
            read: { requestedURL in requestedURL == url ? bytes : nil },
            atomicWrite: { _, _ in },
            fingerprint: { _ in nil }
        )
        let host = RepoPromptCoreHost(persistenceIO: io)
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle,
                workspaceURL: { _ in url }
            )
        )
        let registration = try XCTUnwrap(created)
        guard case let .awaitingFirstSnapshotApplication(first) = await host.hydrateSession(registration.sessionID),
              case .activated = await host.acknowledgeFirstSnapshotApplied(
                  sessionID: registration.sessionID,
                  sequence: first.snapshotSequence
              ),
              case let .admitted(admission) = await registration.handle.admit()
        else { return XCTFail("session did not activate") }

        let command = WorkspaceSessionCommandEnvelope(
            admissionToken: admission,
            expectedGeneration: 1,
            command: .persistence(.reloadWorkspace(workspaceID: workspace.id)),
            source: WorkspaceSessionCommandSource(kind: "test")
        )
        guard case .committed = await registration.handle.execute(command) else {
            return XCTFail("active workspace reload did not commit")
        }
        let currentSnapshot = await registration.handle.currentSnapshot()
        let snapshot = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(snapshot.workspaces.first?.name, "Reloaded")
        XCTAssertEqual(snapshot.workspaces.first?.repoPaths, ["/tmp/reloaded"])
        XCTAssertEqual(snapshot.readiness.generation, 2)
        XCTAssertEqual(snapshot.readiness.catalogGeneration, 9)
        let unloadGenerations = await lifecycle.unloadGenerations
        XCTAssertEqual(unloadGenerations, [1])
        await host.shutdown()
    }

    func testQueryFacadeCannotEscalateToLifecycleMutation() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness()
        let active = try await makeActiveSession(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id,
            lifecycle: lifecycle
        )

        let roots = await active.registration.handle.query.roots()
        let availability = await active.registration.handle.query.rootScopeAvailability(.visibleWorkspace)
        let catalogGeneration = await active.registration.handle.query.catalogGeneration()
        let lookup = await active.registration.handle.query.lookupPath(
            WorkspacePathLookupRequest(userPath: "missing.swift")
        )
        let queryCount = await lifecycle.queryCount
        let hydrateCallCount = await lifecycle.hydrateCalls.count
        let unloadGenerations = await lifecycle.unloadGenerations
        XCTAssertTrue(roots.isEmpty)
        XCTAssertEqual(availability, .available)
        XCTAssertEqual(catalogGeneration, 0)
        XCTAssertNil(lookup)
        XCTAssertEqual(queryCount, 4)
        XCTAssertEqual(hydrateCallCount, 1)
        XCTAssertTrue(unloadGenerations.isEmpty)
        await active.host.shutdown()
        let closedRoots = await active.registration.handle.query.roots()
        let queryCountAfterClose = await lifecycle.queryCount
        XCTAssertTrue(closedRoots.isEmpty)
        XCTAssertEqual(queryCountAfterClose, queryCount)
    }

    func testObservationsAreReadOnlyCompleteSnapshotsAndFinishOnShutdown() async throws {
        let workspace = makeSessionTestWorkspace()
        let lifecycle = WorkspaceSessionLifecycleHarness()
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)
        let stream = await registration.handle.observations(after: nil)
        let collector = Task { () -> [WorkspaceSessionSnapshot] in
            var snapshots: [WorkspaceSessionSnapshot] = []
            for await snapshot in stream {
                snapshots.append(snapshot)
            }
            return snapshots
        }

        guard case let .awaitingFirstSnapshotApplication(firstSnapshot) = await host.hydrateSession(registration.sessionID) else {
            return XCTFail("missing first snapshot")
        }
        XCTAssertTrue(firstSnapshot.readiness.isReady)
        _ = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: firstSnapshot.snapshotSequence
        )
        await host.removeSession(registration.sessionID)

        let snapshots = await collector.value
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertEqual(snapshots.map(\.snapshotSequence), snapshots.map(\.snapshotSequence).sorted())
        XCTAssertEqual(snapshots.last?.availability, .closed)
        XCTAssertTrue(snapshots.allSatisfy { $0.sessionID == registration.sessionID })
    }
}

private extension RepoPromptCoreSessionTests {
    struct ActiveSession {
        let host: RepoPromptCoreHost
        let registration: RepoPromptCoreSessionRegistration
        let admission: WorkspaceSessionAdmissionToken
    }

    func makeActiveSession(
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID,
        lifecycle: WorkspaceSessionLifecycleHarness
    ) async throws -> ActiveSession {
        let host = RepoPromptCoreHost(persistenceIO: memorySessionPersistenceIO())
        let created = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: workspaces,
                activeWorkspaceID: activeWorkspaceID,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(created)
        guard case let .awaitingFirstSnapshotApplication(snapshot) = await host.hydrateSession(registration.sessionID) else {
            throw SessionTestFailure.unexpectedResult
        }
        guard case .activated = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: snapshot.snapshotSequence
        ) else { throw SessionTestFailure.unexpectedResult }
        guard case let .admitted(admission) = await registration.handle.admit() else {
            throw SessionTestFailure.unexpectedResult
        }
        return ActiveSession(host: host, registration: registration, admission: admission)
    }
}

private enum SessionTestFailure: Error {
    case unexpectedResult
}

private func makeSessionTestWorkspace(
    name: String = "Session",
    root: String = "/tmp/root"
) -> WorkspaceModel {
    WorkspaceModel(name: name, repoPaths: [root])
}

private func memorySessionPersistenceIO() -> WorkspaceSessionPersistenceIO {
    WorkspaceSessionPersistenceIO(
        read: { _ in nil },
        atomicWrite: { _, _ in },
        fingerprint: { _ in nil }
    )
}
