@testable import RepoPromptCore
import XCTest

final class WorkspaceRuntimeLifecycleRegistryTests: XCTestCase {
    func testRegistrationActivationAndTransitionTableFailClosed() async {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let harness = RuntimeSessionHandleHarness(sessionID: sessionID, activationID: activationID)
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        let duplicateRuntimeIDHandle = RuntimeSessionHandleHarness(
            sessionID: WorkspaceSessionID(),
            activationID: UUID()
        )

        let registration = await registry.register(runtimeID: runtimeID, sessionHandle: harness.handle())
        XCTAssertEqual(registration, .registered)
        let duplicateRuntimeRegistration = await registry.register(
            runtimeID: runtimeID,
            sessionHandle: duplicateRuntimeIDHandle.handle()
        )
        XCTAssertEqual(duplicateRuntimeRegistration, .duplicateRuntimeID)
        let duplicateSessionRegistration = await registry.register(
            runtimeID: WorkspaceRuntimeID(),
            sessionHandle: harness.handle()
        )
        XCTAssertEqual(duplicateSessionRegistration, .duplicateLiveSession)
        let createdAdmission = await registry.admit(runtimeID: runtimeID)
        XCTAssertEqual(createdAdmission, .unavailable(.notActive(.created)))

        let foreignSessionAdmission = runtimeSessionAdmission(
            sessionID: WorkspaceSessionID(),
            activationID: activationID
        )
        let foreignActivation = await registry.activate(
            runtimeID: runtimeID,
            initialAdmission: foreignSessionAdmission
        )
        XCTAssertEqual(foreignActivation, .sessionMismatch)
        let activation = runtimeSessionAdmission(sessionID: sessionID, activationID: activationID)
        let firstActivation = await registry.activate(runtimeID: runtimeID, initialAdmission: activation)
        XCTAssertEqual(firstActivation, .activated)
        let repeatedActivation = await registry.activate(runtimeID: runtimeID, initialAdmission: activation)
        XCTAssertEqual(repeatedActivation, .alreadyActive)
        let replacementActivation = await registry.activate(
            runtimeID: runtimeID,
            initialAdmission: runtimeSessionAdmission(sessionID: sessionID, activationID: UUID())
        )
        XCTAssertEqual(replacementActivation, .activationMismatch)

        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .removed)
        let lateActivation = await registry.activate(runtimeID: runtimeID, initialAdmission: activation)
        XCTAssertEqual(lateActivation, .invalidState(.removed))
        let removedAdmission = await registry.admit(runtimeID: runtimeID)
        XCTAssertEqual(removedAdmission, .unavailable(.notActive(.removed)))
        let shutdownCount = await harness.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testAdmittedHandleRebindsCommandsToExactCapturedSessionToken() async throws {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let harness = RuntimeSessionHandleHarness(sessionID: sessionID, activationID: activationID)
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        let registration = await registry.register(runtimeID: runtimeID, sessionHandle: harness.handle())
        XCTAssertEqual(registration, .registered)
        let activation = await registry.activate(
            runtimeID: runtimeID,
            initialAdmission: runtimeSessionAdmission(sessionID: sessionID, activationID: activationID)
        )
        XCTAssertEqual(activation, .activated)
        guard case let .admitted(admitted) = await registry.admit(runtimeID: runtimeID) else {
            return XCTFail("active runtime did not admit")
        }

        let foreignToken = runtimeSessionAdmission(sessionID: WorkspaceSessionID(), activationID: UUID())
        let envelope = WorkspaceSessionCommandEnvelope(
            admissionToken: foreignToken,
            expectedGeneration: 42,
            command: .workspace(.setActive(workspaceID: UUID())),
            source: WorkspaceSessionCommandSource(kind: "runtime-test")
        )
        _ = await admitted.execute(envelope)

        let recordedEnvelope = await harness.lastEnvelope
        let receivedEnvelope = try XCTUnwrap(recordedEnvelope)
        XCTAssertEqual(receivedEnvelope.commandID, envelope.commandID)
        XCTAssertEqual(receivedEnvelope.expectedGeneration, 42)
        XCTAssertEqual(receivedEnvelope.admissionToken, admitted.workspaceSessionToken)
        XCTAssertEqual(admitted.runtimeID, runtimeID)
        XCTAssertEqual(admitted.sessionID, sessionID)
    }

    func testDrainingRetainsAdmittedWorkUntilExactReleaseAndShutsDownOnce() async throws {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let harness = RuntimeSessionHandleHarness(sessionID: sessionID, activationID: activationID)
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        await activate(registry, runtimeID: runtimeID, harness: harness)
        guard case let .admitted(admitted) = await registry.admit(runtimeID: runtimeID) else {
            return XCTFail("active runtime did not admit")
        }

        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .draining(activeAdmissionCount: 1))
        let drainingAdmission = await registry.admit(runtimeID: runtimeID)
        XCTAssertEqual(drainingAdmission, .unavailable(.notActive(.draining)))
        let shutdownCountBeforeRelease = await harness.shutdownCount
        XCTAssertEqual(shutdownCountBeforeRelease, 0)

        let waiter = Task { await registry.waitUntilRemoved(runtimeID: runtimeID) }
        let release = await registry.release(admitted.admissionToken)
        XCTAssertEqual(release, .releasedAndRemoved)
        await waiter.value
        let shutdownCountAfterRelease = await harness.shutdownCount
        XCTAssertEqual(shutdownCountAfterRelease, 1)

        let optionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        XCTAssertEqual(snapshot.state, .removed)
        XCTAssertEqual(snapshot.activeAdmissionCount, 0)
        XCTAssertEqual(snapshot.issuedAdmissionCount, 1)
        XCTAssertEqual(snapshot.releasedAdmissionCount, 1)
        XCTAssertEqual(snapshot.shutdownInvocationCount, 1)
        XCTAssertNotNil(snapshot.drainDuration)
        let duplicateRelease = await registry.release(admitted.admissionToken)
        XCTAssertEqual(duplicateRelease, .duplicate)
        let optionalDuplicateSnapshot = await registry.snapshot(runtimeID: runtimeID)
        let duplicateSnapshot = try XCTUnwrap(optionalDuplicateSnapshot)
        XCTAssertEqual(duplicateSnapshot.duplicateReleaseCount, 1)
        XCTAssertEqual(duplicateSnapshot.releasedAdmissionCount, 1)
    }

    func testAdmissionSuspendedAcrossDrainIsRejectedWithoutRefcount() async throws {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let admissionGate = RuntimeLifecycleGate()
        let harness = RuntimeSessionHandleHarness(
            sessionID: sessionID,
            activationID: activationID,
            admissionGate: admissionGate
        )
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        await activate(registry, runtimeID: runtimeID, harness: harness)

        let admissionTask = Task { await registry.admit(runtimeID: runtimeID) }
        await admissionGate.waitUntilEntered()
        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .removed)
        await admissionGate.release()

        let admissionResult = await admissionTask.value
        XCTAssertEqual(admissionResult, .unavailable(.lifecycleChanged))
        let optionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        XCTAssertEqual(snapshot.issuedAdmissionCount, 0)
        XCTAssertEqual(snapshot.activeAdmissionCount, 0)
        XCTAssertEqual(snapshot.state, .removed)
        let shutdownCount = await harness.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testForeignAndDuplicateReleasesNeverDecrementAdmissionCount() async throws {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let harness = RuntimeSessionHandleHarness(sessionID: sessionID, activationID: activationID)
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        await activate(registry, runtimeID: runtimeID, harness: harness)
        guard case let .admitted(admitted) = await registry.admit(runtimeID: runtimeID) else {
            return XCTFail("active runtime did not admit")
        }

        let foreignToken = WorkspaceRuntimeAdmissionToken(
            runtimeID: runtimeID,
            runtimeEpochID: activationID,
            admissionID: UUID(),
            workspaceSessionToken: admitted.workspaceSessionToken
        )
        let foreignRelease = await registry.release(foreignToken)
        XCTAssertEqual(foreignRelease, .foreign)
        let firstOptionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        var snapshot = try XCTUnwrap(firstOptionalSnapshot)
        XCTAssertEqual(snapshot.activeAdmissionCount, 1)
        XCTAssertEqual(snapshot.foreignReleaseCount, 1)

        let alteredExactIDToken = WorkspaceRuntimeAdmissionToken(
            runtimeID: runtimeID,
            runtimeEpochID: activationID,
            admissionID: admitted.admissionToken.admissionID,
            workspaceSessionToken: runtimeSessionAdmission(
                sessionID: sessionID,
                activationID: activationID,
                generation: 99
            )
        )
        let alteredRelease = await registry.release(alteredExactIDToken)
        XCTAssertEqual(alteredRelease, .foreign)
        let alteredOptionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        snapshot = try XCTUnwrap(alteredOptionalSnapshot)
        XCTAssertEqual(snapshot.activeAdmissionCount, 1)
        XCTAssertEqual(snapshot.foreignReleaseCount, 2)

        let release = await registry.release(admitted.admissionToken)
        XCTAssertEqual(release, .released(remainingAdmissionCount: 0))
        let duplicateRelease = await registry.release(admitted.admissionToken)
        XCTAssertEqual(duplicateRelease, .duplicate)
        let secondOptionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        snapshot = try XCTUnwrap(secondOptionalSnapshot)
        XCTAssertEqual(snapshot.activeAdmissionCount, 0)
        XCTAssertEqual(snapshot.releasedAdmissionCount, 1)
        XCTAssertEqual(snapshot.duplicateReleaseCount, 1)
    }

    func testCancelledOperationUsesSameExactlyOnceReleasePath() async throws {
        let sessionID = WorkspaceSessionID()
        let activationID = UUID()
        let harness = RuntimeSessionHandleHarness(sessionID: sessionID, activationID: activationID)
        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        await activate(registry, runtimeID: runtimeID, harness: harness)
        guard case let .admitted(admitted) = await registry.admit(runtimeID: runtimeID) else {
            return XCTFail("active runtime did not admit")
        }
        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .draining(activeAdmissionCount: 1))

        let operation = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {}
            return await registry.release(admitted.admissionToken)
        }
        operation.cancel()
        let release = await operation.value
        XCTAssertEqual(release, .releasedAndRemoved)
        let shutdownCount = await harness.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        let optionalSnapshot = await registry.snapshot(runtimeID: runtimeID)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        XCTAssertEqual(snapshot.releasedAdmissionCount, 1)
        XCTAssertEqual(snapshot.duplicateReleaseCount, 0)
    }

    func testRegistryStronglyRetainsHandleUntilRemovedTombstoneIsPurged() async throws {
        final class RetentionProbe: @unchecked Sendable {}

        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        weak var weakProbe: RetentionProbe?
        var handle: WorkspaceRuntimeSessionHandle?
        do {
            let probe = RetentionProbe()
            weakProbe = probe
            handle = WorkspaceRuntimeSessionHandle(
                sessionID: sessionID,
                query: emptyRuntimeQueryCapability(),
                currentSnapshot: { nil },
                admit: { .notReady(.created) },
                execute: { _ in .notReady(.created) },
                shutdown: { _ = probe }
            )
        }

        let registration = try await registry.register(runtimeID: runtimeID, sessionHandle: XCTUnwrap(handle))
        XCTAssertEqual(registration, .registered)
        handle = nil
        XCTAssertNotNil(weakProbe)
        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .removed)
        XCTAssertNotNil(weakProbe, "removed tombstone must retain diagnostics and exact handle")
        let purged = await registry.purgeRemoved(runtimeID: runtimeID)
        XCTAssertTrue(purged)
        XCTAssertNil(weakProbe)
    }

    func testCoreHostSessionFinalizesThroughConvertedRuntimeHandleExactlyOnce() async throws {
        let workspace = WorkspaceModel(name: "Runtime", repoPaths: [])
        let lifecycle = WorkspaceSessionLifecycleHarness()
        let host = RepoPromptCoreHost()
        let optionalRegistration = await host.createSession(
            dependencies: makeSessionDependencies(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id,
                lifecycle: lifecycle
            )
        )
        let registration = try XCTUnwrap(optionalRegistration)
        guard case let .awaitingFirstSnapshotApplication(snapshot) = await host.hydrateSession(registration.sessionID) else {
            return XCTFail("session did not hydrate")
        }
        guard case .activated = await host.acknowledgeFirstSnapshotApplied(
            sessionID: registration.sessionID,
            sequence: snapshot.snapshotSequence
        ) else {
            return XCTFail("session did not activate")
        }
        guard case let .admitted(initialAdmission) = await registration.handle.admit() else {
            return XCTFail("session did not admit")
        }

        let registry = WorkspaceRuntimeLifecycleRegistry()
        let runtimeID = WorkspaceRuntimeID()
        let runtimeRegistration = await registry.register(
            runtimeID: runtimeID,
            sessionHandle: registration.handle.runtimeSessionHandle()
        )
        XCTAssertEqual(runtimeRegistration, .registered)
        let runtimeActivation = await registry.activate(
            runtimeID: runtimeID,
            initialAdmission: initialAdmission
        )
        XCTAssertEqual(runtimeActivation, .activated)
        let drain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(drain, .removed)

        let optionalOwnership = await host.ownershipSnapshot(sessionID: registration.sessionID)
        let ownership = try XCTUnwrap(optionalOwnership)
        XCTAssertEqual(ownership.releaseCount, 1)
        XCTAssertTrue(ownership.isReleased)
        let registeredSessionCount = await host.registeredSessionCount()
        XCTAssertEqual(registeredSessionCount, 0)
        let closeCount = await lifecycle.closeCount
        XCTAssertEqual(closeCount, 1)
        let secondDrain = await registry.beginDraining(runtimeID: runtimeID)
        XCTAssertEqual(secondDrain, .removed)
        let secondCloseCount = await lifecycle.closeCount
        XCTAssertEqual(secondCloseCount, 1)
    }

    private func activate(
        _ registry: WorkspaceRuntimeLifecycleRegistry,
        runtimeID: WorkspaceRuntimeID,
        harness: RuntimeSessionHandleHarness
    ) async {
        let registration = await registry.register(runtimeID: runtimeID, sessionHandle: harness.handle())
        XCTAssertEqual(registration, .registered)
        let activation = await registry.activate(
            runtimeID: runtimeID,
            initialAdmission: runtimeSessionAdmission(
                sessionID: harness.sessionID,
                activationID: harness.activationID
            )
        )
        XCTAssertEqual(activation, .activated)
    }
}

private actor RuntimeSessionHandleHarness {
    nonisolated let sessionID: WorkspaceSessionID
    nonisolated let activationID: UUID
    private let admissionGate: RuntimeLifecycleGate?
    private(set) var shutdownCount = 0
    private(set) var lastEnvelope: WorkspaceSessionCommandEnvelope?

    init(
        sessionID: WorkspaceSessionID,
        activationID: UUID,
        admissionGate: RuntimeLifecycleGate? = nil
    ) {
        self.sessionID = sessionID
        self.activationID = activationID
        self.admissionGate = admissionGate
    }

    nonisolated func handle() -> WorkspaceRuntimeSessionHandle {
        WorkspaceRuntimeSessionHandle(
            sessionID: sessionID,
            query: emptyRuntimeQueryCapability(),
            currentSnapshot: { nil },
            admit: { [self] in await admit() },
            execute: { [self] envelope in await execute(envelope) },
            shutdown: { [self] in await shutdown() }
        )
    }

    private func admit() async -> WorkspaceSessionAdmissionResult {
        if let admissionGate { await admissionGate.waitUntilReleased() }
        return .admitted(runtimeSessionAdmission(sessionID: sessionID, activationID: activationID))
    }

    private func execute(_ envelope: WorkspaceSessionCommandEnvelope) -> WorkspaceSessionCommandResult {
        lastEnvelope = envelope
        return .notReady(.active)
    }

    private func shutdown() {
        shutdownCount += 1
    }
}

private actor RuntimeLifecycleGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func runtimeSessionAdmission(
    sessionID: WorkspaceSessionID,
    activationID: UUID,
    generation: UInt64 = 1
) -> WorkspaceSessionAdmissionToken {
    WorkspaceSessionAdmissionToken(
        sessionID: sessionID,
        activationID: activationID,
        admittedGeneration: generation,
        snapshotSequence: generation
    )
}

private func emptyRuntimeQueryCapability() -> WorkspaceSessionQueryCapability {
    WorkspaceSessionQueryCapability(
        roots: { [] },
        rootScopeAvailability: { _ in .available },
        catalogGeneration: { _ in 0 },
        catalogDiagnostics: { scope in
            WorkspaceCatalogDiagnostics(
                generation: 0,
                rootScope: scope,
                rootCount: 0,
                folderCount: 0,
                fileCount: 0
            )
        },
        searchCatalogAccess: { _, _ in
            .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        },
        lookupPath: { _ in nil }
    )
}
