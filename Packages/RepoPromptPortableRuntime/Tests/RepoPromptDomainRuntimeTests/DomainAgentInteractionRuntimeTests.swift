import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentRunSessionStoreTests: XCTestCase {
    func testRuntimeGenerationEpochContinuityAndTerminalCommitAreFenced() async throws {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let sessionID = UUID()
        let registration = await store.register(sessionID: sessionID)
        let initial = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ))
        let unrelated = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: initial.activationID,
            expectedCurrentEpoch: initial,
            transitionKind: .unrelated
        ))
        XCTAssertEqual(unrelated.ordinal, initial.ordinal + 1)
        XCTAssertEqual(unrelated.continuityGeneration, initial.continuityGeneration + 1)
        XCTAssertEqual(unrelated.runtimeID, fixture.identity.runtimeID)
        XCTAssertEqual(unrelated.runtimeGeneration, fixture.identity.lifecycleGeneration)

        let terminal = makeSnapshot(sessionID: sessionID, status: .completed)
        let commitID = UUID()
        let accepted = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(accepted, .accepted(successorEpoch: nil))
        let duplicate = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: commitID,
            successorKind: nil
        )
        XCTAssertEqual(duplicate, .accepted(successorEpoch: nil))
        let conflict = await store.publishTerminal(
            .init(epoch: unrelated, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        XCTAssertEqual(conflict, .rejected(reason: "different_commit_already_published"))

        let staleRuntime = DomainAgentSessionRegistration(
            runtimeID: UUID(),
            runtimeGeneration: registration.runtimeGeneration,
            sessionID: sessionID,
            generation: registration.generation
        )
        let staleCursor = await store.currentCursor(for: staleRuntime)
        XCTAssertNil(staleCursor)
        _ = await store.shutdown(deadline: .milliseconds(20))
    }

    func testParkedWaitCancellationAndShutdownDeadlineAreBounded() async throws {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let cancelledRegistration = await store.register(sessionID: UUID())
        let cursor = DomainAgentSessionWaitCursor(registration: cancelledRegistration, epoch: nil)
        let waiter = Task {
            await store.waitUntilInteresting(cursor: cursor, timeoutSeconds: 10)
        }
        let clock = ContinuousClock()
        let waiterDeadline = clock.now.advanced(by: .seconds(1))
        while await store.test_waiterCount(registration: cancelledRegistration) == 0,
              clock.now < waiterDeadline
        {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let waiterCount = await store.test_waiterCount(registration: cancelledRegistration)
        XCTAssertEqual(waiterCount, 1)
        waiter.cancel()
        let cancelledDisposition = await waiter.value
        XCTAssertEqual(cancelledDisposition, .cancelled)

        let interruptedRegistration = await store.register(sessionID: UUID())
        await store.installCancellationHandler(registration: interruptedRegistration) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let started = clock.now
        let result = await store.shutdown(deadline: .milliseconds(20))
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .milliseconds(120))
        XCTAssertTrue(result.interruptedSessionIDs.contains(interruptedRegistration.sessionID))
        let remainsActive = await store.hasActiveRegistration(sessionID: interruptedRegistration.sessionID)
        XCTAssertFalse(remainsActive)
    }

    func testPreCancelledWaitDoesNotRegisterAContinuation() async {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let registration = await store.register(sessionID: UUID())
        let cursor = DomainAgentSessionWaitCursor(registration: registration, epoch: nil)
        let waiter = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return await store.waitUntilInteresting(cursor: cursor, timeoutSeconds: 10)
        }
        waiter.cancel()
        let disposition = await waiter.value
        let waiterCount = await store.test_waiterCount(registration: registration)
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertEqual(waiterCount, 0)
        _ = await store.shutdown(deadline: .milliseconds(20))
    }

    func testShutdownAtomicallyDetachesWaitersAcrossConcurrentSettlementRaces() async throws {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let sessionID = UUID()
        let registration = await store.register(sessionID: sessionID)
        let epoch = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ))
        let cursor = DomainAgentSessionWaitCursor(registration: registration, epoch: epoch)
        let waiterSettled = BoundedAsyncSignal()
        let waiter = Task {
            let disposition = await store.waitUntilInteresting(cursor: cursor, timeoutSeconds: 10)
            await waiterSettled.signal()
            return disposition
        }
        let clock = ContinuousClock()
        let waiterDeadline = clock.now.advanced(by: .seconds(1))
        while await store.test_waiterCount(registration: registration) == 0, clock.now < waiterDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let waiterIDs = await store.test_waiterIDs(registration: registration)
        guard let waiterID = waiterIDs.first else {
            waiter.cancel()
            _ = await waiter.value
            XCTFail("waiter did not park before the bounded deadline")
            return
        }

        let handlerStarted = BoundedAsyncSignal()
        let handlerCancelled = BoundedAsyncSignal()
        let handlerHold = BoundedAsyncSignal()
        await store.installCancellationHandler(registration: registration) {
            await handlerStarted.signal()
            await withTaskCancellationHandler {
                _ = await handlerHold.wait(timeout: .seconds(2))
            } onCancel: {
                Task {
                    await handlerCancelled.signal()
                    await handlerHold.signal()
                }
            }
        }

        let detachReached = BoundedAsyncSignal()
        let detachRelease = BoundedAsyncSignal()
        await store.test_setShutdownAfterDetach {
            await detachReached.signal()
            _ = await detachRelease.wait(timeout: .seconds(2))
        }
        let shutdown = Task {
            await store.shutdown(deadline: .milliseconds(20))
        }
        let reachedDetachBoundary = await detachReached.wait(timeout: .seconds(1))
        XCTAssertTrue(reachedDetachBoundary)

        let detachedState = await store.test_shutdownOwnedState()
        XCTAssertEqual(detachedState.recordCount, 0)
        XCTAssertEqual(detachedState.cancellationHandlerCount, 0)
        let settledBeforeRaces = await waiterSettled.wait(timeout: .milliseconds(20))
        XCTAssertFalse(settledBeforeRaces)

        let terminal = makeSnapshot(sessionID: sessionID, status: .cancelled)
        async let cancellation: Void = store.test_cancelWaiter(sessionID: sessionID, waiterID: waiterID)
        async let publication = store.publishTerminal(
            .init(epoch: epoch, snapshot: terminal),
            registration: registration,
            commitID: UUID(),
            successorKind: nil
        )
        async let ingest: Void = store.noteSnapshot(terminal, cursor: cursor)
        async let wake: Void = store.wakeCurrentWaiters(terminal, cursor: cursor, reason: .steeringRequested)
        await cancellation
        let publicationResult = await publication
        await ingest
        await wake
        waiter.cancel()
        let drainWait = await store.waitUntilInteresting(cursor: cursor, timeoutSeconds: 10)
        let settledByRaces = await waiterSettled.wait(timeout: .milliseconds(20))
        XCTAssertFalse(settledByRaces)

        await detachRelease.signal()
        let waiterDisposition = await waiter.value
        let shutdownResult = await shutdown.value
        let observedHandlerStart = await handlerStarted.wait(timeout: .seconds(1))
        let observedHandlerCancellation = await handlerCancelled.wait(timeout: .seconds(1))
        await handlerHold.signal()
        let waiterCount = await store.test_waiterCount(registration: registration)
        XCTAssertTrue(observedHandlerStart)
        XCTAssertTrue(observedHandlerCancellation)
        XCTAssertEqual(waiterDisposition, .cancelled)
        XCTAssertEqual(drainWait, .cancelled)
        XCTAssertEqual(publicationResult, .rejected(reason: "stale_activation"))
        XCTAssertEqual(shutdownResult.interruptedSessionIDs, [sessionID])
        XCTAssertEqual(waiterCount, 0)
    }

    func testCancellationHandlerInstallationRemovalAndShutdownDrainAreExactlyFenced() async {
        let fixture = makeStoreFixture()
        let store = fixture.store
        let recorder = InvocationRecorder()
        let removed = await store.register(sessionID: UUID())
        let removedInstalled = await store.installCancellationHandler(registration: removed) {
            await recorder.record("removed")
        }
        XCTAssertTrue(removedInstalled)
        await store.removeCancellationHandler(registration: removed)

        let active = await store.register(sessionID: UUID())
        let activeInstalled = await store.installCancellationHandler(registration: active) {
            await recorder.record("active")
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(activeInstalled)
        let stale = DomainAgentSessionRegistration(
            runtimeID: active.runtimeID,
            runtimeGeneration: active.runtimeGeneration,
            sessionID: active.sessionID,
            generation: active.generation &+ 1
        )
        let staleInstalled = await store.installCancellationHandler(registration: stale) {
            await recorder.record("stale")
        }
        XCTAssertFalse(staleInstalled)

        let shutdown = Task {
            await store.shutdown(deadline: .milliseconds(100))
        }
        let clock = ContinuousClock()
        let detachDeadline = clock.now.advanced(by: .seconds(1))
        while await store.hasActiveRegistration(sessionID: active.sessionID), clock.now < detachDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let remainsActiveDuringDrain = await store.hasActiveRegistration(sessionID: active.sessionID)
        XCTAssertFalse(remainsActiveDuringDrain)
        let installedDuringDrain = await store.installCancellationHandler(
            registration: active
        ) {
            await recorder.record("during-drain")
        }
        XCTAssertFalse(installedDuringDrain)
        let result = await shutdown.value
        let calls = await recorder.values()
        XCTAssertEqual(calls, ["active"])
        XCTAssertTrue(result.cooperativeSessionIDs.contains(active.sessionID))
        XCTAssertTrue(result.cooperativeSessionIDs.contains(removed.sessionID))
    }

    func testRestartRestoresMetadataDormantAndRequiresExplicitResumeClaim() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-session-restart"
        let firstIdentity = makeIdentity(runtimeID: UUID(), generation: 4)
        let first = makeSessionStore(identity: firstIdentity, root: root, profile: profile)
        await first.bootstrap()
        let sessionID = UUID()
        let registration = await first.register(sessionID: sessionID)
        _ = await first.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        )
        _ = await first.shutdown(deadline: .milliseconds(10))

        let secondIdentity = makeIdentity(runtimeID: UUID(), generation: 5)
        let second = makeSessionStore(identity: secondIdentity, root: root, profile: profile)
        await second.bootstrap()
        let restoredActive = await second.hasActiveRegistration(sessionID: sessionID)
        XCTAssertFalse(restoredActive)
        let restoredMetadata = await second.restoredMetadata()
        let restored = try XCTUnwrap(restoredMetadata.first(where: { $0.sessionID == sessionID }))
        XCTAssertFalse(restored.isLive)
        XCTAssertEqual(restored.state, .dormant)
        XCTAssertEqual(restored.owningRuntimeID, firstIdentity.runtimeID)
        XCTAssertEqual(restored.owningRuntimeGeneration, firstIdentity.lifecycleGeneration)
        guard case let .accepted(claim) = await second.claimResumableSession(sessionID: sessionID) else {
            return XCTFail("Expected an explicit resumable claim")
        }
        XCTAssertEqual(claim.runtimeID, secondIdentity.runtimeID)
        XCTAssertEqual(claim.runtimeGeneration, secondIdentity.lifecycleGeneration)
        XCTAssertNotEqual(claim, registration)
        let claimedActive = await second.hasActiveRegistration(sessionID: sessionID)
        XCTAssertTrue(claimedActive)
        _ = await second.shutdown(deadline: .milliseconds(10))
    }

    func testCorruptAndFutureMetadataRemainBytePreservedAndDegradedReadOnly() async throws {
        for (profile, data, expectedHealth) in [
            (
                "m5-corrupt",
                Data("{not-json".utf8),
                DomainAgentSessionPersistenceHealth.degradedReadOnly(
                    reason: "agent_session_metadata_decode_failed"
                )
            ),
            (
                "m5-future",
                try JSONSerialization.data(withJSONObject: [
                    "version": 999,
                    "profileIdentifier": "m5-future",
                    "revision": 1,
                    "sessions": [],
                    "updatedAt": 0
                ], options: [.sortedKeys]),
                DomainAgentSessionPersistenceHealth.degradedReadOnly(
                    reason: "future_agent_session_metadata"
                )
            )
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let identity = makeIdentity()
            let persistence = makePersistence(identity: identity, root: root, profile: profile)
            try await persistence.compareAndSwapAgentSessionMetadataData(expectedDigest: nil, data: data)
            let store = makeSessionStore(identity: identity, root: root, profile: profile)
            await store.bootstrap()
            let degradedSnapshot = await store.snapshot()
            XCTAssertEqual(degradedSnapshot.persistenceHealth, expectedHealth)
            _ = await store.register(sessionID: UUID())
            _ = await store.shutdown(deadline: .milliseconds(5))
            let preserved = try await persistence.loadAgentSessionMetadataData()
            XCTAssertEqual(preserved.data, data)
        }
    }

    func testCASMergesDistinctSessionsAndRejectsCompetingOwnershipTransfer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-cas"
        let firstIdentity = makeIdentity(runtimeID: UUID(), generation: 1)
        let secondIdentity = makeIdentity(runtimeID: UUID(), generation: 2)
        let first = makeSessionStore(identity: firstIdentity, root: root, profile: profile)
        let second = makeSessionStore(identity: secondIdentity, root: root, profile: profile)
        await first.bootstrap()
        await second.bootstrap()

        let firstSessionID = UUID()
        let secondSessionID = UUID()
        _ = await first.register(sessionID: firstSessionID)
        _ = await first.shutdown(deadline: .milliseconds(5))
        _ = await second.register(sessionID: secondSessionID)
        _ = await second.shutdown(deadline: .milliseconds(5))

        let verifierIdentity = makeIdentity(runtimeID: UUID(), generation: 3)
        let verifier = makeSessionStore(identity: verifierIdentity, root: root, profile: profile)
        await verifier.bootstrap()
        let mergedMetadata = await verifier.restoredMetadata()
        let mergedIDs = Set(mergedMetadata.map(\.sessionID))
        XCTAssertEqual(mergedIDs, [firstSessionID, secondSessionID])
        _ = await verifier.shutdown(deadline: .milliseconds(5))

        let conflictRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: conflictRoot) }
        let conflictProfile = "m5-cas-conflict"
        let owner = makeSessionStore(identity: firstIdentity, root: conflictRoot, profile: conflictProfile)
        let contender = makeSessionStore(identity: secondIdentity, root: conflictRoot, profile: conflictProfile)
        await owner.bootstrap()
        await contender.bootstrap()
        let contestedSessionID = UUID()
        _ = await owner.register(sessionID: contestedSessionID)
        _ = await contender.register(sessionID: contestedSessionID)
        _ = await owner.shutdown(deadline: .milliseconds(5))
        _ = await contender.shutdown(deadline: .milliseconds(5))
        let contenderSnapshot = await contender.snapshot()
        XCTAssertEqual(
            contenderSnapshot.persistenceHealth,
            .degradedReadOnly(reason: "agent_session_ownership_conflict")
        )
        let conflictVerifier = makeSessionStore(
            identity: verifierIdentity,
            root: conflictRoot,
            profile: conflictProfile
        )
        await conflictVerifier.bootstrap()
        let conflictMetadata = await conflictVerifier.restoredMetadata()
        let contested = try XCTUnwrap(
            conflictMetadata.first { $0.sessionID == contestedSessionID }
        )
        XCTAssertEqual(contested.owningRuntimeID, firstIdentity.runtimeID)
        _ = await conflictVerifier.shutdown(deadline: .milliseconds(5))
    }

    func testPersistedActiveOwnerCannotBeClaimedUntilItDurablyStops() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-live-owner"
        let ownerIdentity = makeIdentity(runtimeID: UUID(), generation: 1)
        let owner = makeSessionStore(identity: ownerIdentity, root: root, profile: profile)
        await owner.bootstrap()
        let sessionID = UUID()
        _ = await owner.register(sessionID: sessionID)
        try await Task.sleep(for: .milliseconds(250))

        let contender = makeSessionStore(
            identity: makeIdentity(runtimeID: UUID(), generation: 2),
            root: root,
            profile: profile
        )
        await contender.bootstrap()
        let liveOwnerClaim = await contender.claimResumableSession(sessionID: sessionID)
        XCTAssertEqual(liveOwnerClaim, .unavailable)

        _ = await owner.shutdown(deadline: .milliseconds(20))
        let successor = makeSessionStore(
            identity: makeIdentity(runtimeID: UUID(), generation: 3),
            root: root,
            profile: profile
        )
        await successor.bootstrap()
        guard case .accepted = await successor.claimResumableSession(sessionID: sessionID) else {
            return XCTFail("A durably stopped owner should become explicitly claimable")
        }
        _ = await contender.shutdown(deadline: .milliseconds(10))
        _ = await successor.shutdown(deadline: .milliseconds(10))
    }

    func testExternallyIntroducedDuplicateSessionIDsDegradeWithoutTrappingOrOverwrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-duplicate-document"
        let identity = makeIdentity()
        let store = makeSessionStore(identity: identity, root: root, profile: profile)
        let persistence = makePersistence(identity: identity, root: root, profile: profile)
        await store.bootstrap()
        _ = await store.register(sessionID: UUID())
        try await Task.sleep(for: .milliseconds(250))

        let valid = try await persistence.loadAgentSessionMetadataData()
        let validData = try XCTUnwrap(valid.data)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        object["sessions"] = sessions + sessions
        let duplicateData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await persistence.compareAndSwapAgentSessionMetadataData(
            expectedDigest: valid.digest,
            data: duplicateData
        )

        _ = await store.register(sessionID: UUID())
        try await Task.sleep(for: .milliseconds(250))
        let snapshot = await store.snapshot()
        XCTAssertEqual(
            snapshot.persistenceHealth,
            .degradedReadOnly(reason: "agent_session_metadata_decode_failed")
        )
        let preserved = try await persistence.loadAgentSessionMetadataData()
        XCTAssertEqual(preserved.data, duplicateData)
        _ = await store.shutdown(deadline: .milliseconds(10))
    }

    func testMutationArrivingDuringFlushAdvancesCommittedBaseWithoutFalseConflict() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-flush-reentrancy"
        let identity = makeIdentity()
        let store = makeSessionStore(identity: identity, root: root, profile: profile)
        await store.bootstrap()
        let registration = await store.register(sessionID: UUID())
        await store.test_setMetadataFlushBeforeCAS {
            await store.test_setMetadataFlushBeforeCAS(nil)
            _ = await store.beginEpoch(
                registration: registration,
                activationID: UUID(),
                expectedCurrentEpoch: nil,
                transitionKind: .initial
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.persistenceHealth, .ready)
        XCTAssertEqual(snapshot.pendingPersistenceCount, 0)
        let persistence = makePersistence(identity: identity, root: root, profile: profile)
        let persisted = try await persistence.loadAgentSessionMetadataData()
        let data = try XCTUnwrap(persisted.data)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["lastEpochOrdinal"] as? Int, 1)
        _ = await store.shutdown(deadline: .milliseconds(10))
    }

    func testDurableMetadataIsBoundedAndTurnWritesAreCoalesced() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = "m5-retention"
        let identity = makeIdentity()
        let store = makeSessionStore(identity: identity, root: root, profile: profile)
        await store.bootstrap()
        let firstSessionID = UUID()
        let registration = await store.register(sessionID: firstSessionID)
        let epoch = try acceptedEpoch(await store.beginEpoch(
            registration: registration,
            activationID: UUID(),
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ))
        await store.noteSnapshot(
            makeSnapshot(sessionID: firstSessionID, status: .running),
            cursor: .init(registration: registration, epoch: epoch)
        )
        try await Task.sleep(for: .milliseconds(250))
        let persistence = makePersistence(identity: identity, root: root, profile: profile)
        let coalescedSnapshot = try await persistence.loadAgentSessionMetadataData()
        let coalescedData = try XCTUnwrap(coalescedSnapshot.data)
        let coalescedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: coalescedData) as? [String: Any]
        )
        XCTAssertEqual(coalescedObject["revision"] as? Int, 1)

        for _ in 0 ..< 520 {
            _ = await store.register(sessionID: UUID())
        }
        _ = await store.shutdown(deadline: .milliseconds(5))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.retainedMetadataCount, 512)
        XCTAssertGreaterThan(snapshot.omittedRetentionCount, 0)
        let boundedPersistenceSnapshot = try await persistence.loadAgentSessionMetadataData()
        let boundedData = try XCTUnwrap(boundedPersistenceSnapshot.data)
        let boundedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: boundedData) as? [String: Any]
        )
        XCTAssertEqual((boundedObject["sessions"] as? [Any])?.count, 512)
    }

    private func acceptedEpoch(
        _ result: DomainAgentRunSessionStore.EpochBeginResult
    ) throws -> DomainAgentRunTurnEpoch {
        guard case let .accepted(epoch) = result else {
            throw TestError.expectedAcceptedEpoch
        }
        return epoch
    }
}

final class DomainInteractionBrokerTests: XCTestCase {
    func testNegotiatedElicitationPrecedesAppUIAndImmediateCompletionIsNotLost() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        await broker.installNegotiatedElicitationProvider(DomainInteractionProvider(
            kind: .elicitation,
            present: { _ in
                await recorder.record("elicitation")
                return .string("elicited")
            }
        ))
        let request = DomainInteractionRequest(
            toolName: "ask_user",
            payload: [:],
            deadline: Date().addingTimeInterval(1)
        )
        let result = await broker.request(
            request,
            appUI: DomainInteractionProvider(kind: .appUI) { _ in
                await recorder.record("app")
                return .string("app")
            }
        )
        XCTAssertEqual(result, .response(.string("elicited"), provider: .elicitation))
        let calls = await recorder.values()
        let brokerSnapshot = await broker.snapshot()
        XCTAssertEqual(calls, ["elicitation"])
        XCTAssertTrue(brokerSnapshot.pendingRequestIDs.isEmpty)
    }

    func testTimeoutCancelsProviderOnceAndIgnoresLateResponse() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        let provider = DomainInteractionProvider(
            kind: .appUI,
            present: { _ in
                try? await Task.sleep(for: .milliseconds(80))
                return .string("late")
            },
            cancel: { _ in await recorder.record("cancel") }
        )
        let result = await broker.request(
            .init(
                toolName: "ask_user",
                payload: [:],
                deadline: Date().addingTimeInterval(0.02)
            ),
            appUI: provider
        )
        XCTAssertEqual(result, .timedOut)
        try? await Task.sleep(for: .milliseconds(30))
        let cancellationCalls = await recorder.values()
        let brokerSnapshot = await broker.snapshot()
        XCTAssertEqual(cancellationCalls, ["cancel"])
        XCTAssertGreaterThanOrEqual(brokerSnapshot.ignoredLateResponseCount, 1)
        let unavailable = await broker.request(
            .init(toolName: "ask_user", payload: [:], deadline: Date().addingTimeInterval(1))
        )
        XCTAssertEqual(unavailable, .unavailable)
    }

    func testConnectionCancellationSettlesOnlyTheExactPendingClient() async {
        let broker = DomainInteractionBroker()
        let cancelled = InvocationRecorder()
        let firstClientID = UUID()
        let secondClientID = UUID()
        let provider = DomainInteractionProvider(
            kind: .elicitation,
            present: { request in
                try? await Task.sleep(for: .milliseconds(50))
                return .string(request.clientID?.uuidString ?? "missing")
            },
            cancel: { _ in await cancelled.record("cancel") }
        )
        await broker.installNegotiatedElicitationProvider(provider, clientID: firstClientID)
        await broker.installNegotiatedElicitationProvider(provider, clientID: secondClientID)

        let first = Task {
            await broker.request(.init(
                toolName: "ask_user",
                clientID: firstClientID,
                payload: [:],
                deadline: Date().addingTimeInterval(1)
            ))
        }
        let second = Task {
            await broker.request(.init(
                toolName: "ask_user",
                clientID: secondClientID,
                payload: [:],
                deadline: Date().addingTimeInterval(1)
            ))
        }
        while await broker.snapshot().pendingRequestIDs.count < 2 {
            await Task.yield()
        }
        await broker.cancel(clientID: firstClientID)

        let firstResult = await first.value
        let secondResult = await second.value
        let cancellationCount = await cancelled.values().count
        let snapshot = await broker.snapshot()
        XCTAssertEqual(firstResult, .cancelled)
        XCTAssertEqual(
            secondResult,
            .response(.string(secondClientID.uuidString), provider: .elicitation)
        )
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
    }

    func testConnectionRemovalDuringAvailabilityBlocksLateWaiterCreation() async {
        let broker = DomainInteractionBroker()
        let clientID = UUID()
        await broker.installNegotiatedElicitationProvider(
            .init(
                kind: .elicitation,
                isAvailable: { _ in
                    try? await Task.sleep(for: .milliseconds(30))
                    return true
                },
                present: { _ in .string("must-not-present") }
            ),
            clientID: clientID
        )
        let request = Task {
            await broker.request(.init(
                toolName: "ask_user",
                clientID: clientID,
                payload: [:],
                deadline: Date().addingTimeInterval(1)
            ))
        }
        try? await Task.sleep(for: .milliseconds(5))
        await broker.cancel(clientID: clientID)
        let result = await request.value
        let snapshot = await broker.snapshot()
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
    }

    func testCallerCancellationSettlesOnceAndLateProviderResponseCannotResurrectRequest() async {
        let broker = DomainInteractionBroker()
        let recorder = InvocationRecorder()
        let request = DomainInteractionRequest(
            toolName: "ask_user",
            payload: [:],
            deadline: Date().addingTimeInterval(1)
        )
        let task = Task {
            await broker.request(
                request,
                appUI: DomainInteractionProvider(
                    kind: .appUI,
                    present: { _ in
                        try? await Task.sleep(for: .milliseconds(80))
                        return .string("late")
                    },
                    cancel: { _ in await recorder.record("cancel") }
                )
            )
        }
        while await broker.snapshot().pendingRequestIDs.isEmpty {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try? await Task.sleep(for: .milliseconds(30))
        let cancellationCalls = await recorder.values()
        let snapshot = await broker.snapshot()
        XCTAssertEqual(cancellationCalls, ["cancel"])
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.ignoredLateResponseCount, 1)
    }

    func testUncooperativeProviderCancellationSettlesWaiterBeforeCleanup() async {
        let broker = DomainInteractionBroker()
        let cleanupStarted = BoundedAsyncSignal()
        let cleanupGate = UncooperativeCleanupGate()
        let cleanupFinished = BoundedAsyncSignal()
        let waiterSettled = BoundedAsyncSignal()
        let recorder = InvocationRecorder()
        let waiter = Task {
            let result = await broker.request(
                .init(
                    toolName: "ask_user",
                    payload: [:],
                    deadline: Date().addingTimeInterval(1)
                ),
                appUI: DomainInteractionProvider(
                    kind: .appUI,
                    present: { _ in
                        try await Task.sleep(for: .seconds(10))
                        return .string("late")
                    },
                    cancel: { _ in
                        await recorder.record("cancel")
                        await cleanupStarted.signal()
                        await cleanupGate.wait()
                        await cleanupFinished.signal()
                    }
                )
            )
            await waiterSettled.signal()
            return result
        }
        while await broker.snapshot().pendingRequestIDs.isEmpty {
            await Task.yield()
        }

        waiter.cancel()
        let cleanupWasStarted = await cleanupStarted.wait(timeout: .seconds(1))
        let settledBeforeCleanupRelease = await waiterSettled.wait(timeout: .milliseconds(100))
        await cleanupGate.release()
        let cleanupDidFinish = await cleanupFinished.wait(timeout: .seconds(1))
        let result = await waiter.value
        let cancellationCalls = await recorder.values()
        let snapshot = await broker.snapshot()

        XCTAssertTrue(cleanupWasStarted)
        XCTAssertTrue(settledBeforeCleanupRelease)
        XCTAssertTrue(cleanupDidFinish)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(cancellationCalls, ["cancel"])
        XCTAssertTrue(snapshot.pendingRequestIDs.isEmpty)
    }
}

final class DomainCredentialAndChildLaunchTests: XCTestCase {
    func testCredentialEnvelopeIsMinimumScopeSingleUseAndRedacted() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let descriptor = try await store.issue(bytes: [1, 2, 3, 4], scope: scope)
        let wrongScope = DomainCredentialScope(
            providerIdentifier: "claude",
            runID: scope.runID,
            principalID: scope.principalID,
            purpose: scope.purpose
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(descriptor, scope: wrongScope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .scopeMismatch)
        }
        let issuedBytes = await store.test_ownedStorageBytes(envelopeID: descriptor.envelopeID)
        XCTAssertEqual(issuedBytes, [1, 2, 3, 4])
        let payload = try await store.redeem(descriptor, scope: scope)
        let consumedStoreBytes = await store.test_ownedStorageBytes(envelopeID: descriptor.envelopeID)
        let consumedStoreIsZeroed = await store.test_isOwnedStorageZeroed(envelopeID: descriptor.envelopeID)
        XCTAssertNil(consumedStoreBytes)
        XCTAssertEqual(consumedStoreIsZeroed, true)
        XCTAssertEqual(payload.test_ownedStorageBytes(), [1, 2, 3, 4])
        let consumed = try payload.withConsumedBytes { Array($0) }
        XCTAssertEqual(consumed, [1, 2, 3, 4])
        XCTAssertEqual(payload.test_ownedStorageBytes(), [0, 0, 0, 0])
        XCTAssertTrue(payload.test_isOwnedStorageZeroed())
        XCTAssertThrowsError(try payload.withConsumedBytes { Array($0) }) {
            XCTAssertEqual($0 as? DomainCredentialPayloadError, .alreadyConsumed)
        }
        XCTAssertEqual(payload.description, "<redacted credential payload: 4 bytes>")

        let throwingDescriptor = try await store.issue(bytes: [9, 8, 7], scope: scope)
        let throwingPayload = try await store.redeem(throwingDescriptor, scope: scope)
        XCTAssertThrowsError(try throwingPayload.withConsumedBytes { _ in
            throw TestError.expectedAcceptedEpoch
        })
        XCTAssertEqual(throwingPayload.test_ownedStorageBytes(), [0, 0, 0])
        XCTAssertTrue(throwingPayload.test_isOwnedStorageZeroed())
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(descriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .alreadyConsumed)
        }

        let revoked = try await store.issue(bytes: [5], scope: scope)
        await store.revoke(revoked.envelopeID)
        let revokedBytes = await store.test_ownedStorageBytes(envelopeID: revoked.envelopeID)
        let revokedIsZeroed = await store.test_isOwnedStorageZeroed(envelopeID: revoked.envelopeID)
        XCTAssertNil(revokedBytes)
        XCTAssertEqual(revokedIsZeroed, true)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(revoked, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .revoked)
        }
        let expired = try await store.issue(bytes: [6], scope: scope, lifetime: .zero)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(expired, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .expired)
        }
        let expiredBytes = await store.test_ownedStorageBytes(envelopeID: expired.envelopeID)
        let expiredIsZeroed = await store.test_isOwnedStorageZeroed(envelopeID: expired.envelopeID)
        XCTAssertNil(expiredBytes)
        XCTAssertEqual(expiredIsZeroed, true)
        let shutdown = try await store.issue(bytes: [7], scope: scope)
        await store.shutdown()
        let shutdownBytes = await store.test_ownedStorageBytes(envelopeID: shutdown.envelopeID)
        let shutdownIsZeroed = await store.test_isOwnedStorageZeroed(envelopeID: shutdown.envelopeID)
        XCTAssertNil(shutdownBytes)
        XCTAssertEqual(shutdownIsZeroed, true)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(shutdown, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .revoked)
        }
    }

    func testCredentialEnvelopeExpiryZeroizesOwnedStorageWithoutRedemption() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let descriptor = try await store.issue(
            bytes: [10, 11, 12],
            scope: scope,
            lifetime: .milliseconds(10)
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await store.test_isOwnedStorageZeroed(envelopeID: descriptor.envelopeID) != true,
              clock.now < deadline
        {
            await Task.yield()
        }
        let isZeroed = await store.test_isOwnedStorageZeroed(envelopeID: descriptor.envelopeID)
        let ownedBytes = await store.test_ownedStorageBytes(envelopeID: descriptor.envelopeID)
        XCTAssertEqual(isZeroed, true)
        XCTAssertNil(ownedBytes)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(descriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .expired)
        }
    }

    func testCredentialEnvelopeRedemptionValidatesStoredDescriptorAndScope() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let descriptor = try await store.issue(bytes: [21, 22], scope: scope)
        let forgedScope = DomainCredentialScope(
            providerIdentifier: "claude",
            runID: scope.runID,
            principalID: scope.principalID,
            purpose: scope.purpose
        )
        let forgedScopeDescriptor = DomainCredentialEnvelopeDescriptor(
            envelopeID: descriptor.envelopeID,
            runtimeID: descriptor.runtimeID,
            runtimeGeneration: descriptor.runtimeGeneration,
            scope: forgedScope,
            expiresAt: descriptor.expiresAt
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(forgedScopeDescriptor, scope: forgedScope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .scopeMismatch)
        }
        let forgedDeadlineDescriptor = DomainCredentialEnvelopeDescriptor(
            envelopeID: descriptor.envelopeID,
            runtimeID: descriptor.runtimeID,
            runtimeGeneration: descriptor.runtimeGeneration,
            scope: scope,
            expiresAt: descriptor.expiresAt.advanced(by: .seconds(60))
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.redeem(forgedDeadlineDescriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .unavailable)
        }
        let ownedBytes = await store.test_ownedStorageBytes(envelopeID: descriptor.envelopeID)
        XCTAssertEqual(ownedBytes, [21, 22])
        let payload = try await store.redeem(descriptor, scope: scope)
        XCTAssertEqual(try payload.withConsumedBytes { Array($0) }, [21, 22])
        await store.shutdown()
    }

    func testRedeemedCredentialPayloadRetainsDeadlineAndZeroizesIndependently() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let descriptor = try await store.issue(
            bytes: [31, 32, 33],
            scope: scope,
            lifetime: .milliseconds(20)
        )
        let payload = try await store.redeem(descriptor, scope: scope)
        XCTAssertEqual(payload.test_expiresAt(), descriptor.expiresAt)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !payload.test_isOwnedStorageZeroed(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(payload.test_isOwnedStorageZeroed())
        XCTAssertThrowsError(try payload.withConsumedBytes { Array($0) }) {
            XCTAssertEqual($0 as? DomainCredentialPayloadError, .alreadyConsumed)
        }
        await store.shutdown()
    }

    func testCredentialEnvelopeBoundsActiveRecordsAndTerminalTombstones() async throws {
        let identity = makeIdentity()
        let store = DomainCredentialEnvelopeStore(identity: identity)
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: UUID(),
            principalID: UUID(),
            purpose: "agent_run"
        )
        let oversized = Array(
            repeating: UInt8(1),
            count: DomainCredentialEnvelopeStore.maximumPayloadBytes + 1
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.issue(bytes: oversized, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .payloadTooLarge)
        }
        for _ in 0 ..< DomainCredentialEnvelopeStore.maximumOutstandingEnvelopeCount {
            _ = try await store.issue(bytes: [41], scope: scope)
        }
        let activeCount = await store.test_activeEnvelopeCount()
        XCTAssertEqual(activeCount, DomainCredentialEnvelopeStore.maximumOutstandingEnvelopeCount)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.issue(bytes: [42], scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .tooManyOutstandingEnvelopes)
        }
        await store.shutdown()
        let shutdownActiveCount = await store.test_activeEnvelopeCount()
        let shutdownTerminalStorageCount = await store.test_terminalStorageCount()
        let shutdownExpiryTaskCount = await store.test_expiryTaskCount()
        let shutdownRecordCount = await store.test_recordCount()
        XCTAssertEqual(shutdownActiveCount, 0)
        XCTAssertEqual(shutdownTerminalStorageCount, 0)
        XCTAssertEqual(shutdownExpiryTaskCount, 0)
        XCTAssertLessThanOrEqual(
            shutdownRecordCount,
            DomainCredentialEnvelopeStore.maximumTombstoneCount
        )

        let tombstoneStore = DomainCredentialEnvelopeStore(identity: identity)
        for _ in 0 ... DomainCredentialEnvelopeStore.maximumTombstoneCount {
            let descriptor = try await tombstoneStore.issue(bytes: [51], scope: scope)
            let payload = try await tombstoneStore.redeem(descriptor, scope: scope)
            _ = try payload.withConsumedBytes { _ in () }
        }
        let tombstoneCount = await tombstoneStore.test_tombstoneCount()
        let tombstoneRecordCount = await tombstoneStore.test_recordCount()
        let tombstoneStorageCount = await tombstoneStore.test_terminalStorageCount()
        let tombstoneExpiryTaskCount = await tombstoneStore.test_expiryTaskCount()
        XCTAssertEqual(tombstoneCount, DomainCredentialEnvelopeStore.maximumTombstoneCount)
        XCTAssertEqual(tombstoneRecordCount, DomainCredentialEnvelopeStore.maximumTombstoneCount)
        XCTAssertEqual(tombstoneStorageCount, 0)
        XCTAssertEqual(tombstoneExpiryTaskCount, 0)
        await tombstoneStore.shutdown()
    }

    func testInjectedPrivateChildHarnessCarriesSingleUseTokenAndEnvelopeReference() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .standalone,
                profileIdentifier: "m5-child-harness",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events"),
                temporaryDirectory: root.appendingPathComponent("Temporary"),
                externalReloadInterval: nil
            ),
            lifecycleGeneration: 7
        )
        try await runtime.start()
        let workspaceID = UUID()
        let contextID = UUID()
        let documentURL = root.appendingPathComponent("child-harness-workspace.json")
        let documentObject: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "M5 Child Harness",
            "repoPaths": [root.path],
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": ""
            ]]
        ]
        let documentBytes = try JSONSerialization.data(withJSONObject: documentObject, options: [.sortedKeys])
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: documentBytes,
            fileURL: documentURL
        )
        let created = await runtime.workspaceStore.execute(.init(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let harness = DomainPrivateChildLaunchHarness(
            endpointDescriptor: "injected-private-child://fixture",
            credentialStore: runtime.credentialEnvelopeStore
        ) { request in
            try await runtime.routingCoordinator.issueLaunchToken(request)
        }
        let request = DomainRunLaunchReservationRequest(
            runID: UUID(),
            context: .init(workspaceID: workspaceID, contextID: contextID),
            expectedContextRevision: 1,
            windowID: nil,
            clientPrincipal: "agent",
            providerIdentifier: "codex",
            runPurpose: "explore",
            restrictedTools: ["file_actions"],
            additionalTools: ["ask_user"]
        )
        let scope = DomainCredentialScope(
            providerIdentifier: "codex",
            runID: request.runID,
            principalID: UUID(),
            purpose: "explore"
        )
        let carrier = try await harness.prepare(
            request: request,
            credential: (bytes: [7, 8], scope: scope)
        )
        XCTAssertEqual(
            carrier.environment[DomainChildLaunchCarrier.endpointEnvironmentKey],
            "injected-private-child://fixture"
        )
        XCTAssertFalse(
            carrier.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]?.isEmpty ?? true
        )
        XCTAssertEqual(
            carrier.environment[DomainChildLaunchCarrier.credentialEnvelopeEnvironmentKey],
            carrier.credentialEnvelope?.envelopeID.uuidString
        )
        let descriptor = try XCTUnwrap(carrier.credentialEnvelope)
        let payload = try await runtime.credentialEnvelopeStore.redeem(descriptor, scope: scope)
        XCTAssertEqual(try payload.withConsumedBytes { Array($0) }, [7, 8])
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.credentialEnvelopeStore.redeem(descriptor, scope: scope)
        } verify: {
            XCTAssertEqual($0 as? DomainCredentialEnvelopeError, .alreadyConsumed)
        }
        let material = try XCTUnwrap(
            carrier.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]
        )
        let accepted = await runtime.routingCoordinator.redeemLaunchToken(
            material: material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        guard case let .accepted(redemption) = accepted else {
            return XCTFail("Injected harness token was not accepted: \(accepted)")
        }
        XCTAssertEqual(redemption.restrictedTools, ["file_actions"])
        XCTAssertEqual(redemption.additionalTools, ["ask_user"])
        let replay = await runtime.routingCoordinator.redeemLaunchToken(
            material: material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        XCTAssertEqual(replay, .alreadyConsumed)

        let foreignRuntimeRequest = DomainRunLaunchReservationRequest(
            runID: UUID(),
            context: request.context,
            expectedContextRevision: request.expectedContextRevision,
            windowID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier,
            runPurpose: "foreign-runtime"
        )
        let foreignRuntimeToken = try await runtime.routingCoordinator.issueLaunchToken(foreignRuntimeRequest)
        let foreignRuntime = await runtime.routingCoordinator.redeemLaunchToken(
            material: foreignRuntimeToken.material,
            runtimeID: UUID(),
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        XCTAssertEqual(foreignRuntime, .generationMismatch)
        let acceptedAfterForeignAttempt = await runtime.routingCoordinator.redeemLaunchToken(
            material: foreignRuntimeToken.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        guard case .accepted = acceptedAfterForeignAttempt else {
            return XCTFail("A foreign-runtime attempt must not consume the token: \(acceptedAfterForeignAttempt)")
        }

        let expiredRequest = DomainRunLaunchReservationRequest(
            runID: UUID(),
            context: request.context,
            expectedContextRevision: request.expectedContextRevision,
            windowID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier,
            runPurpose: "expired",
            lifetime: .zero
        )
        let expiredToken = try await runtime.routingCoordinator.issueLaunchToken(expiredRequest)
        let expiredRedemption = await runtime.routingCoordinator.redeemLaunchToken(
            material: expiredToken.material,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: request.clientPrincipal,
            providerIdentifier: request.providerIdentifier
        )
        XCTAssertEqual(expiredRedemption, .expired)
        _ = await runtime.shutdown()
    }
}

final class DomainActivityAndLongRunningProviderTests: XCTestCase {
    func testActivityPublicationIsMonotonicAndTerminalCommitIsExactlyOnce() async throws {
        let center = DomainActivityCenter(identity: makeIdentity(), terminalLimit: 2)
        let startedToken = await center.begin(kind: .oracle, toolName: "ask_oracle")
        let token = try XCTUnwrap(startedToken)
        let initial = await center.snapshot()
        XCTAssertEqual(initial.publicationSequence, 1)
        let update = await center.update(token, state: .waitingForInteraction)
        XCTAssertEqual(update, .accepted)
        let commitID = UUID()
        let finish = await center.finish(token, state: .completed, commitID: commitID)
        let duplicate = await center.finish(token, state: .completed, commitID: commitID)
        let conflict = await center.finish(token, state: .failed, commitID: UUID())
        XCTAssertEqual(finish, .accepted)
        XCTAssertEqual(duplicate, .duplicateTerminal)
        XCTAssertEqual(conflict, .rejectedTerminalConflict)
        let terminal = await center.snapshot()
        XCTAssertEqual(terminal.publicationSequence, 3)
        XCTAssertTrue(terminal.active.isEmpty)
        XCTAssertEqual(terminal.recentTerminal.first?.state, .completed)
        await center.shutdown()
        let afterShutdown = await center.begin(kind: .agentRun, toolName: "agent_run")
        XCTAssertNil(afterShutdown)
    }

    func testLongRunningProviderPreservesSchemaRequiresApprovalAndCarriesInjectedLaunch() async throws {
        let runtime = makeRuntime(mode: .app)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = InvocationRecorder()
        let carrier = DomainChildLaunchCarrier(
            runID: UUID(),
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [
                DomainChildLaunchCarrier.endpointEnvironmentKey: "injected://child",
                DomainChildLaunchCarrier.launchTokenEnvironmentKey: "token"
            ]
        )
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            prepareChildLaunch: { _, _, _ in carrier }
        )
        let definition = MCPDomainToolDefinition(
            name: "ask_oracle",
            description: "unchanged fixture",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["message": .object(["type": .string("string")])])
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: true)
        )
        let binding = MCPDomainToolBinding(definition: definition) { _ in
            let launch = DomainChildLaunchContext.current
            await recorder.record(launch?.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] ?? "missing")
            return .string("ok")
        }
        let wrapped = provider.wrapping(binding)
        XCTAssertEqual(wrapped.definition, definition)

        do {
            _ = try await wrapped(["message": .string("hello")])
            XCTFail("Unattributed AI work must fail closed")
        } catch {
            XCTAssertEqual(error as? DomainMutationPolicyError, .principalMissing)
        }
        let deniedCalls = await recorder.values()
        XCTAssertTrue(deniedCalls.isEmpty)

        let unroutedSecurity = makeRunSecurityContext(
            identity: runtime.identity,
            grantedTools: ["ask_oracle"],
            hasAuthoritativeRoutingContext: false
        )
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(unroutedSecurity) {
                try await wrapped(["message": .string("hello")])
            }
            XCTFail("Costed work without authoritative routing must fail closed")
        } catch {
            XCTAssertEqual(error as? DomainMutationPolicyError, .routingContextUnavailable)
        }

        let routedSecurity = makeRunSecurityContext(
            identity: runtime.identity,
            grantedTools: ["ask_oracle"],
            hasAuthoritativeRoutingContext: true
        )
        let value = try await MCPDomainInvocationSecurityContext.$current.withValue(routedSecurity) {
            try await wrapped(["message": .string("hello")])
        }
        XCTAssertEqual(value, .string("ok"))
        let successfulCalls = await recorder.values()
        XCTAssertEqual(successfulCalls, ["token"])
        let activities = await runtime.activityCenter.snapshot()
        XCTAssertTrue(activities.active.isEmpty)
        XCTAssertEqual(activities.recentTerminal.map(\.state), [.completed, .failed, .failed])
    }

    func testLongRunningProviderNormalizesOperationBeforeApprovalAndChildLaunch() async throws {
        let runtime = makeRuntime(mode: .app)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = InvocationRecorder()
        let carrier = DomainChildLaunchCarrier(
            runID: UUID(),
            launchTokenID: UUID(),
            credentialEnvelope: nil,
            environment: [
                DomainChildLaunchCarrier.endpointEnvironmentKey: "injected://child",
                DomainChildLaunchCarrier.launchTokenEnvironmentKey: "token"
            ]
        )
        let provider = MCPDomainLongRunningToolProvider(
            identity: runtime.identity,
            policyStore: runtime.mutationPolicyStore,
            interactionBroker: runtime.interactionBroker,
            activityCenter: runtime.activityCenter,
            prepareChildLaunch: { _, _, _ in
                await recorder.record("prepared")
                return carrier
            }
        )
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "agent_run",
                description: "operation normalization fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await recorder.record(
                DomainChildLaunchContext.current?.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey]
                    ?? "missing"
            )
            return .string("ok")
        }
        let wrapped = provider.wrapping(binding)
        let arguments = ["op": Value.string("\n  StEeR \t")]

        do {
            _ = try await wrapped(arguments)
            XCTFail("Case- and whitespace-variant AI work must require approval")
        } catch {
            XCTAssertEqual(error as? DomainMutationPolicyError, .principalMissing)
        }
        let deniedCalls = await recorder.values()
        XCTAssertTrue(deniedCalls.isEmpty)

        let routedSecurity = makeRunSecurityContext(
            identity: runtime.identity,
            grantedTools: ["agent_run"],
            hasAuthoritativeRoutingContext: true
        )
        let value = try await MCPDomainInvocationSecurityContext.$current.withValue(routedSecurity) {
            try await wrapped(arguments)
        }
        XCTAssertEqual(value, .string("ok"))
        let successfulCalls = await recorder.values()
        XCTAssertEqual(successfulCalls, ["prepared", "token"])
    }

    func testAgentManageExtractHandoffAliasSharesApprovalClassification() async throws {
        let runtime = makeRuntime(mode: .app)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "agent_manage",
                description: "handoff alias approval fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            .string("executed")
        }
        let wrapped = runtime.longRunningToolProvider.wrapping(binding)
        for operation in ["handoff", " \nEXTRACT_HANDOFF\t"] {
            do {
                _ = try await wrapped(["op": .string(operation)])
                XCTFail("agent_manage.\(operation) must require the handoff approval classes")
            } catch {
                XCTAssertEqual(error as? DomainMutationPolicyError, .principalMissing)
            }
        }
    }

    func testAskUserUsesInjectedWorkspaceTimeoutAndDismissesOnCallerCancellationOnce() async throws {
        let runtime = makeRuntime(mode: .app)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = InteractionAdapterRecorder()
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_user",
                description: "configured timeout fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await recorder.recordPresentation(
                requestID: DomainInteractionPresentationContext.requestID
            )
            try await Task.sleep(for: .seconds(30))
            return .string("late")
        }
        let adapter = DomainLongRunningInteractionAdapter(
            isAvailable: { request in
                await recorder.recordDeadline(request.deadline)
                return true
            },
            resolveDefaultTimeoutSeconds: { _ in 900 },
            cancel: { requestID in
                await recorder.recordCancellation(requestID: requestID)
            }
        )
        let wrapped = runtime.longRunningToolProvider.wrapping(
            binding,
            interactionAdapter: adapter
        )
        let task = Task {
            try await wrapped(["questions": .array([.object([
                "id": .string("choice"),
                "question": .string("Choose")
            ])])])
        }
        let presentationRequestID = await recorder.waitForPresentation(timeout: .seconds(2))
        XCTAssertNotNil(presentationRequestID)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Caller cancellation must settle ask_user as cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let didCancelPresentation = await recorder.waitForCancellation(timeout: .seconds(2))
        XCTAssertTrue(didCancelPresentation)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.cancellationRequestIDs, [presentationRequestID].compactMap { $0 })
        XCTAssertGreaterThan(snapshot.deadline?.timeIntervalSinceNow ?? 0, 800)
        let brokerSnapshot = await runtime.interactionBroker.snapshot()
        XCTAssertTrue(brokerSnapshot.pendingRequestIDs.isEmpty)
    }

    func testAskUserFallsBackToDefaultTimeoutWhenInteractiveContextIsUnavailable() async throws {
        let runtime = makeRuntime(mode: .standalone)
        try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let recorder = InteractionAdapterRecorder()
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_user",
                description: "headless timeout fallback fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            .string("app")
        }
        let adapter = DomainLongRunningInteractionAdapter(
            isAvailable: { _ in false },
            resolveDefaultTimeoutSeconds: { _ in
                throw TestError.expectedAcceptedEpoch
            },
            cancel: { _ in }
        )
        await runtime.interactionBroker.installNegotiatedElicitationProvider(
            DomainInteractionProvider(kind: .elicitation) { request in
                await recorder.recordDeadline(request.deadline)
                return .string("elicitation")
            }
        )
        let wrapped = runtime.longRunningToolProvider.wrapping(
            binding,
            interactionAdapter: adapter
        )
        let result = try await wrapped(["questions": .array([])])
        XCTAssertEqual(result, .string("elicitation"))
        let snapshot = await recorder.snapshot()
        XCTAssertGreaterThan(snapshot.deadline?.timeIntervalSinceNow ?? 0, 299)
        XCTAssertLessThan(snapshot.deadline?.timeIntervalSinceNow ?? 0, 302)
    }

    func testLongRunningProviderCoversFrozenFamiliesAndInteractionFallbackOrder() async throws {
        XCTAssertEqual(MCPDomainLongRunningToolProvider.toolNames, [
            "oracle_utils",
            "ask_oracle",
            "oracle_send",
            "context_builder",
            "ask_user",
            "agent_explore",
            "agent_run",
            "agent_manage",
            "share_thoughts",
            "set_status",
            "wait_for_next_user_instruction"
        ])
        let runtime = makeRuntime(mode: .standalone)
        try await runtime.start()
        let appRecorder = InvocationRecorder()
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "ask_user",
                description: "frozen ask-user fixture",
                inputSchema: .object(["type": .string("object")])
            )
        ) { _ in
            await appRecorder.record("app")
            return .string("app")
        }
        let wrapped = runtime.longRunningToolProvider.wrapping(binding)
        await runtime.interactionBroker.installNegotiatedElicitationProvider(
            DomainInteractionProvider(kind: .elicitation) { _ in .string("elicitation") }
        )
        let elicited = try await wrapped(["questions": .array([]), "timeout_seconds": .int(1)])
        XCTAssertEqual(elicited, .string("elicitation"))
        let appCallsAfterElicitation = await appRecorder.values()
        XCTAssertTrue(appCallsAfterElicitation.isEmpty)

        await runtime.interactionBroker.installNegotiatedElicitationProvider(nil)
        do {
            _ = try await wrapped(["questions": .array([]), "timeout_seconds": .int(1)])
            XCTFail("Missing elicitation and app UI must fail immediately")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interaction_unavailable"))
        }
        let appCallsAfterUnavailable = await appRecorder.values()
        XCTAssertTrue(appCallsAfterUnavailable.isEmpty)
        _ = await runtime.shutdown()
    }
}

private enum TestError: Error {
    case expectedAcceptedEpoch
}

private actor InteractionAdapterRecorder {
    struct Snapshot {
        let deadline: Date?
        let presentationRequestID: UUID?
        let cancellationRequestIDs: [UUID]
    }

    private var deadline: Date?
    private var presentedRequestID: UUID?
    private var cancelledRequestIDs: [UUID] = []
    private let presentationSignal = BoundedAsyncSignal()
    private let cancellationSignal = BoundedAsyncSignal()

    func recordDeadline(_ deadline: Date) {
        self.deadline = deadline
    }

    func recordPresentation(requestID: UUID?) async {
        presentedRequestID = requestID
        await presentationSignal.signal()
    }

    func recordCancellation(requestID: UUID) async {
        cancelledRequestIDs.append(requestID)
        await cancellationSignal.signal()
    }

    func waitForPresentation(timeout: Duration) async -> UUID? {
        guard await presentationSignal.wait(timeout: timeout) else { return nil }
        return presentedRequestID
    }

    func waitForCancellation(timeout: Duration) async -> Bool {
        await cancellationSignal.wait(timeout: timeout)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            deadline: deadline,
            presentationRequestID: presentedRequestID,
            cancellationRequestIDs: cancelledRequestIDs
        )
    }
}

private actor UncooperativeCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor BoundedAsyncSignal {
    private var isSignalled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        guard !isSignalled else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isSignalled {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[waiterID] = continuation
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        await self?.settle(waiterID: waiterID, result: false)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.settle(waiterID: waiterID, result: false)
            }
        }
    }

    private func settle(waiterID: UUID, result: Bool) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: result)
    }
}

private actor InvocationRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}

private func makeStoreFixture() -> (
    identity: DomainRuntimeIdentity,
    store: DomainAgentRunSessionStore
) {
    let identity = makeIdentity()
    let root = temporaryDirectory()
    return (
        identity,
        makeSessionStore(identity: identity, root: root, profile: "m5-store-fixture")
    )
}

private func makeSessionStore(
    identity: DomainRuntimeIdentity,
    root: URL,
    profile: String
) -> DomainAgentRunSessionStore {
    DomainAgentRunSessionStore(
        identity: identity,
        persistence: makePersistence(identity: identity, root: root, profile: profile),
        profileIdentifier: profile
    )
}

private func makePersistence(
    identity: DomainRuntimeIdentity,
    root: URL,
    profile: String
) -> DomainPersistenceCoordinator {
    let configuration = DomainRuntimeConfiguration(
        mode: identity.mode,
        profileIdentifier: profile,
        storageDirectory: root,
        eventDirectory: root.appendingPathComponent("Events"),
        temporaryDirectory: root.appendingPathComponent("Temporary"),
        externalReloadInterval: nil
    )
    return DomainPersistenceCoordinator(configuration: configuration, identity: identity)
}

private func makeIdentity(
    runtimeID: UUID = UUID(),
    generation: UInt64 = 1,
    mode: DomainRuntimeMode = .standalone
) -> DomainRuntimeIdentity {
    DomainRuntimeIdentity(
        runtimeID: runtimeID,
        lifecycleGeneration: generation,
        processID: 42,
        mode: mode,
        createdAt: Date()
    )
}

private func makeRuntime(mode: DomainRuntimeMode) -> MCPDomainRuntime {
    let root = temporaryDirectory()
    return MCPDomainRuntime(
        configuration: .init(
            mode: mode,
            profileIdentifier: "m5-owner-test",
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("Temporary"),
            externalReloadInterval: nil,
        )
    )
}

private func makeRunSecurityContext(
    identity: DomainRuntimeIdentity,
    grantedTools: Set<String>,
    hasAuthoritativeRoutingContext: Bool
) -> DomainToolInvocationSecurityContext {
    DomainToolInvocationSecurityContext(
        principal: .init(
            principalID: UUID(),
            stableKey: "agent",
            displayName: "Agent",
            kind: .runScoped,
            assurance: .verifiedProcess,
            processID: identity.processID,
            runID: UUID(),
            provider: "fixture",
            verifiedIdentityFingerprint: "fixture"
        ),
        connectionID: UUID(),
        connectionGeneration: 1,
        invocationID: UUID(),
        runtimeID: identity.runtimeID,
        runtimeGeneration: identity.lifecycleGeneration,
        hasAuthoritativeRoutingContext: hasAuthoritativeRoutingContext,
        ephemeralGrantedToolNames: grantedTools
    )
}

private func makeSnapshot(
    sessionID: UUID,
    status: DomainAgentRunSnapshot.Status
) -> DomainAgentRunSnapshot {
    DomainAgentRunSnapshot(
        sessionID: sessionID,
        tabID: nil,
        sessionName: "Fixture",
        agentRaw: "codex",
        agentDisplayName: "Codex",
        modelRaw: "fixture",
        reasoningEffortRaw: nil,
        status: status,
        statusText: status.rawValue,
        latestAssistantPreview: nil,
        interaction: nil,
        transcriptItemCount: 1,
        updatedAt: Date(),
        parentSessionID: nil,
        failureReason: nil,
        worktreeBindings: [],
        activeWorktreeMerges: []
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("repoprompt-m5-\(UUID().uuidString)", isDirectory: true)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
