import CryptoKit
import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapArtifactBuildCoordinatorTests: XCTestCase {
    func testSameKeyFanInBuildsAndInsertsExactlyOnceAndReturnsJoinProvenance() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("fan-in", root: fixture.root)
        let gate = CoordinatorTestGate()
        let builds = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            await builds.record("build")
            await gate.enter()
            return .readyNoSymbols
        }

        let first = Task { try await coordinator.resolve(request(input)) }
        await gate.waitUntilEntered()
        let joined = (0 ..< 7).map { _ in
            Task { try await coordinator.resolve(request(input)) }
        }
        try await waitUntil {
            await coordinator.accounting().waiterCount == 8
        }
        await gate.release()

        let tasks = [first] + joined
        let results = try await tasks.asyncValues()
        let buildCount = await builds.count
        let resolutions = results.compactMap { ready($0) }
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(resolutions.count(where: { $0.joinedExistingFlight }), 7)
        XCTAssertEqual(resolutions.count(where: { $0.buildProvenance == .performed }), 1)
        XCTAssertEqual(resolutions.count(where: { $0.buildProvenance == .joinedSharedBuild }), 7)

        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.buildsStarted, 1)
        XCTAssertEqual(accounting.counters.casInserted, 1)
        XCTAssertEqual(accounting.counters.joins, 7)
        XCTAssertEqual(accounting.counters.duplicateBuilds, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
    }

    func testDistinctKeysRespectFlightWaiterAndQueueBoundsAndBusyRequestsRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstInput = try makeInput("bounds-first", root: fixture.root)
        let queuedInput = try makeInput("bounds-queued", root: fixture.root)
        let busyInput = try makeInput("bounds-busy", root: fixture.root)
        let gate = CoordinatorTestGate()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: CodeMapArtifactBuildCoordinatorPolicy(
                maximumFlightCount: 3,
                maximumTotalWaiterCount: 3,
                maximumWaitersPerFlight: 2,
                maximumQueuedBuildCount: 1,
                maximumConcurrentBuildCount: 1,
                maximumLocatorIdentitiesPerFlight: 2,
                maximumConsecutiveDemandAdmissions: 2,
                agePromotionNanoseconds: 1_000_000_000,
                retryAfterMilliseconds: 17
            )
        ) { _, _, _ in
            await gate.enter()
            return .readyNoSymbols
        }

        let first = Task { try await coordinator.resolve(request(firstInput)) }
        await gate.waitUntilEntered()
        let queued = Task { try await coordinator.resolve(request(queuedInput)) }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }

        do {
            _ = try await coordinator.resolve(request(busyInput))
            XCTFail("expected queue bound rejection")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactBuildCoordinatorError,
                .busy(retryAfterMilliseconds: 17)
            )
        }

        await gate.release()
        _ = try await first.value
        _ = try await queued.value
        let retried = try await coordinator.resolve(request(busyInput))
        XCTAssertNotNil(ready(retried))

        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.busyRejections, 1)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.queuedBuildCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
    }

    func testCancellingOneWaiterDoesNotCancelSharedWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("cancel-one", root: fixture.root)
        let gate = CoordinatorTestGate()
        let recorder = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            await recorder.record("build")
            await gate.enter()
            return .readyNoSymbols
        }

        let owner = Task { try await coordinator.resolve(request(input)) }
        await gate.waitUntilEntered()
        let cancelled = Task { try await coordinator.resolve(request(input)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        cancelled.cancel()
        await assertCancellation(cancelled)
        await gate.release()

        let ownerResult = try await owner.value
        let recordedBuildCount = await recorder.count
        XCTAssertNotNil(ready(ownerResult))
        XCTAssertEqual(recordedBuildCount, 1)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.waiterCancellations, 1)
        XCTAssertEqual(accounting.counters.lastWaiterCancellations, 0)
        XCTAssertEqual(accounting.counters.sharedTaskCancellations, 0)
    }

    func testLastWaiterCancellationBeforeBuildPerformsNoBuildOrWrite() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let activeInput = try makeInput("active-build", root: fixture.root)
        let cancelledInput = try makeInput("cancelled-before-build", root: fixture.root)
        let gate = CoordinatorTestGate()
        let recorder = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 2)
        ) { input, _, _ in
            await recorder.record(input.artifactKey.storageDigestHex)
            await gate.enter()
            return .readyNoSymbols
        }

        let active = Task { try await coordinator.resolve(request(activeInput)) }
        await gate.waitUntilEntered()
        let queued = Task { try await coordinator.resolve(request(cancelledInput)) }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        queued.cancel()
        await assertCancellation(queued)
        await gate.release()
        _ = try await active.value

        let recordedBuildCount = await recorder.count
        XCTAssertEqual(recordedBuildCount, 1)
        switch try await fixture.artifactStore.lookup(key: cancelledInput.artifactKey) {
        case .miss: break
        case .hit: XCTFail("cancelled queued flight persisted")
        }
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.queuedBuildCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
    }

    func testLastWaiterCancellationDuringNonPreemptiveBuildCompletesAdmittedTransaction() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let alternateRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: alternateRoot) }
        let input = try makeInput("non-preemptive", root: fixture.root, withLocator: true)
        let finalWaiterInput = try makeInput(
            "non-preemptive",
            root: alternateRoot,
            withLocator: true
        )
        XCTAssertEqual(input.artifactKey, finalWaiterInput.artifactKey)
        let gate = CoordinatorTestGate()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            await gate.enter()
            return .readyNoSymbols
        }

        let task = Task { try await coordinator.resolve(request(input)) }
        await gate.waitUntilEntered()
        let finalWaiter = Task { try await coordinator.resolve(request(finalWaiterInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        task.cancel()
        await assertCancellation(task)
        finalWaiter.cancel()
        await assertCancellation(finalWaiter)
        await gate.release()
        try await waitUntil { await coordinator.accounting().activeFlightCount == 0 }

        switch try await fixture.artifactStore.lookup(key: input.artifactKey) {
        case .miss: XCTFail("admitted non-preemptive build did not persist")
        case .hit: break
        }
        let locatorIdentity = try XCTUnwrap(finalWaiterInput.locatorIdentity)
        let locatorResult = try await fixture.locatorStore.read(identity: locatorIdentity)
        XCTAssertEqual(
            locatorResult,
            .hit(input.artifactKey),
            "waiter cancellation must not withdraw admitted locator publication"
        )
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.casInserted, 1)
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
        XCTAssertEqual(accounting.counters.lastWaiterCancellations, 1)
        XCTAssertEqual(accounting.counters.sharedTaskCancellations, 0)
    }

    func testCancellationDuringCASAndLocatorPublicationCompletesStartedAtomicOperation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let casInput = try makeInput("cancel-during-cas", root: fixture.root)
        let insertGate = CoordinatorTestGate()
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                await insertGate.enter()
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let casCoordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let casTask = Task { try await casCoordinator.resolve(request(casInput)) }
        await insertGate.waitUntilEntered()
        casTask.cancel()
        await assertCancellation(casTask)
        await insertGate.release()
        try await waitUntil { await casCoordinator.accounting().activeFlightCount == 0 }
        _ = try await requireHit(fixture.artifactStore, key: casInput.artifactKey)

        let locatedInput = try makeInput("cancel-during-locator", root: fixture.root, withLocator: true)
        _ = try await fixture.artifactStore.insert(
            key: locatedInput.artifactKey,
            deterministicOutcome: .readyNoSymbols
        )
        let locatorGate = CoordinatorTestGate()
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { try await fixture.locatorStore.read(identity: $0) },
            write: { association in
                await locatorGate.enter()
                return try await fixture.locatorStore.write(association: association)
            }
        )
        let locatorCoordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let locatorTask = Task { try await locatorCoordinator.resolve(request(locatedInput)) }
        await locatorGate.waitUntilEntered()
        locatorTask.cancel()
        await assertCancellation(locatorTask)
        await locatorGate.release()
        try await waitUntil { await locatorCoordinator.accounting().activeFlightCount == 0 }
        let publishedLocator = try await fixture.locatorStore.read(
            identity: XCTUnwrap(locatedInput.locatorIdentity)
        )
        XCTAssertEqual(publishedLocator, .hit(locatedInput.artifactKey))
    }

    func testCancelledLocatorWaiterReleasesIntentAndSlotBeforeVerification() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let alternateRoot = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: alternateRoot) }
        let nonLocatorInput = try makeInput("locator-intent-owner", root: fixture.root)
        let cancelledLocatorInput = try makeInput(
            "locator-intent-owner",
            root: fixture.root,
            withLocator: true
        )
        let replacementLocatorInput = try makeInput(
            "locator-intent-owner",
            root: alternateRoot,
            withLocator: true
        )
        XCTAssertEqual(nonLocatorInput.artifactKey, cancelledLocatorInput.artifactKey)
        XCTAssertEqual(nonLocatorInput.artifactKey, replacementLocatorInput.artifactKey)

        let insertGate = CoordinatorTestGate()
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                await insertGate.enter()
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols }),
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 2,
                maximumLocatorIdentitiesPerFlight: 1
            )
        )

        let active = Task { try await coordinator.resolve(request(nonLocatorInput)) }
        await insertGate.waitUntilEntered()
        let cancelled = Task { try await coordinator.resolve(request(cancelledLocatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        cancelled.cancel()
        await assertCancellation(cancelled)

        let replacement = Task { try await coordinator.resolve(request(replacementLocatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        await insertGate.release()
        let activeResult = try await active.value
        let replacementResult = try await replacement.value
        XCTAssertNotNil(ready(activeResult))
        XCTAssertNotNil(ready(replacementResult))

        let cancelledIdentity = try XCTUnwrap(cancelledLocatorInput.locatorIdentity)
        let replacementIdentity = try XCTUnwrap(replacementLocatorInput.locatorIdentity)
        let cancelledLookup = try await fixture.locatorStore.read(identity: cancelledIdentity)
        let replacementLookup = try await fixture.locatorStore.read(identity: replacementIdentity)
        XCTAssertEqual(cancelledLookup, .miss)
        XCTAssertEqual(replacementLookup, .hit(nonLocatorInput.artifactKey))
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
        XCTAssertEqual(accounting.counters.busyRejections, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
    }

    func testSameLocatorIdentityMissThenCorruptCancellationRepairsSurvivingCorruption() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let activeInput = try makeInput("same-identity-miss-corrupt", root: fixture.root)
        let locatorInput = try makeInput(
            "same-identity-miss-corrupt",
            root: fixture.root,
            withLocator: true
        )
        let insertGate = CoordinatorTestGate()
        let writes = CoordinatorTestRecorder()
        let reads = CoordinatorLocatorReadScript([.miss, .corrupt])
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                await insertGate.enter()
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { _ in await reads.next() },
            write: { association in
                await writes.record(association.identity.storageDigestHex)
                return .inserted
            }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )

        let active = Task { try await coordinator.resolve(request(activeInput)) }
        await insertGate.waitUntilEntered()
        let miss = Task { try await coordinator.resolve(request(locatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        let corrupt = Task { try await coordinator.resolve(request(locatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 3 }
        miss.cancel()
        await assertCancellation(miss)
        await insertGate.release()

        let activeResult = try await active.value
        let corruptResult = try await corrupt.value
        XCTAssertNotNil(ready(activeResult))
        let corruptResolution = try XCTUnwrap(ready(corruptResult))
        XCTAssertEqual(corruptResolution.locatorLookup, .corrupt)
        XCTAssertEqual(corruptResolution.locatorPublication, .inserted)
        let recordedWrites = await writes.count
        XCTAssertEqual(recordedWrites, 1)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
        XCTAssertEqual(accounting.activeFlightCount, 0)
    }

    func testSameLocatorIdentityCorruptThenMissCancellationPublishesSurvivingMiss() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let activeInput = try makeInput("same-identity-corrupt-miss", root: fixture.root)
        let locatorInput = try makeInput(
            "same-identity-corrupt-miss",
            root: fixture.root,
            withLocator: true
        )
        let identity = try XCTUnwrap(locatorInput.locatorIdentity)
        let insertGate = CoordinatorTestGate()
        let writes = CoordinatorTestRecorder()
        let reads = CoordinatorLocatorReadScript([.corrupt, .miss])
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                await insertGate.enter()
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { _ in await reads.next() },
            write: { association in
                await writes.record(association.identity.storageDigestHex)
                return .inserted
            }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )

        let active = Task { try await coordinator.resolve(request(activeInput)) }
        await insertGate.waitUntilEntered()
        let corrupt = Task { try await coordinator.resolve(request(locatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        let miss = Task { try await coordinator.resolve(request(locatorInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 3 }
        corrupt.cancel()
        await assertCancellation(corrupt)
        await insertGate.release()

        let activeResult = try await active.value
        let missResult = try await miss.value
        XCTAssertNotNil(ready(activeResult))
        let missResolution = try XCTUnwrap(ready(missResult))
        XCTAssertEqual(missResolution.locatorLookup, .miss)
        XCTAssertEqual(missResolution.locatorPublication, .inserted)
        let recordedWrites = await writes.values
        XCTAssertEqual(recordedWrites, [identity.storageDigestHex])
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
        XCTAssertEqual(accounting.activeFlightCount, 0)
    }

    func testTransientLookupBuildAndPersistenceFailuresRemoveFlightAndRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let lookupInput = try makeInput("retry-lookup", root: fixture.root)
        let lookupFailure = CoordinatorFailOnce()
        let lookupClient = CodeMapArtifactStoreClient(
            lookup: { key in
                if await lookupFailure.take() { throw CoordinatorTestError.transient }
                return try await fixture.artifactStore.lookup(key: key)
            },
            insert: { try await fixture.artifactStore.insert(key: $0, deterministicOutcome: $1) },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let lookupCoordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: lookupClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        await assertTransientFailure { try await lookupCoordinator.resolve(request(lookupInput)) }
        let lookupRetry = try await lookupCoordinator.resolve(request(lookupInput))
        XCTAssertNotNil(ready(lookupRetry))

        let buildInput = try makeInput("retry-build", root: fixture.root)
        let buildFailure = CoordinatorFailOnce()
        let buildCoordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            if await buildFailure.take() { throw CoordinatorTestError.transient }
            return .readyNoSymbols
        }
        await assertTransientFailure { try await buildCoordinator.resolve(request(buildInput)) }
        let buildRetry = try await buildCoordinator.resolve(request(buildInput))
        XCTAssertNotNil(ready(buildRetry))

        let persistInput = try makeInput("retry-persist", root: fixture.root)
        let persistFailure = CoordinatorFailOnce()
        let persistClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                if await persistFailure.take() { throw CoordinatorTestError.transient }
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let persistCoordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: persistClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        await assertTransientFailure { try await persistCoordinator.resolve(request(persistInput)) }
        let persistRetry = try await persistCoordinator.resolve(request(persistInput))
        let persistAccounting = await persistCoordinator.accounting()
        XCTAssertNotNil(ready(persistRetry))
        XCTAssertEqual(persistAccounting.activeFlightCount, 0)
    }

    func testPhase5AQueueFullMapsToBusyForSharedWaitersAndAllowsRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("phase-5a-queue-full", root: fixture.root)
        let failure = CoordinatorFailOnce()
        let gate = CoordinatorTestGate()
        let builder = CodeMapArtifactBuilderClient(execute: { _, _, _ in
            if await failure.take() {
                await gate.enter()
                throw ContentReadSchedulerError.queueFull(retryAfterMilliseconds: 777)
            }
            return CodeMapArtifactBuilderExecution(
                outcome: .readyNoSymbols,
                permitWaitNanoseconds: 0,
                buildNanoseconds: 0
            )
        })
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: builder
        )

        let first = Task { try await coordinator.resolve(request(input)) }
        await gate.waitUntilEntered()
        let joined = Task { try await coordinator.resolve(request(input)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        await gate.release()
        await assertBusy(first, retryAfterMilliseconds: 777)
        await assertBusy(joined, retryAfterMilliseconds: 777)

        let rejectedAccounting = await coordinator.accounting()
        XCTAssertEqual(rejectedAccounting.counters.busyRejections, 1)
        XCTAssertEqual(rejectedAccounting.counters.buildsStarted, 1)
        XCTAssertEqual(rejectedAccounting.counters.buildsFailed, 0)
        XCTAssertEqual(rejectedAccounting.counters.failures, 0)
        XCTAssertEqual(rejectedAccounting.activeFlightCount, 0)
        XCTAssertEqual(rejectedAccounting.queuedBuildCount, 0)
        XCTAssertEqual(rejectedAccounting.activeBuildCount, 0)
        XCTAssertEqual(rejectedAccounting.waiterCount, 0)

        let retryResult = try await coordinator.resolve(request(input))
        XCTAssertNotNil(ready(retryResult))
        let retryAccounting = await coordinator.accounting()
        XCTAssertEqual(retryAccounting.counters.buildsStarted, 2)
        XCTAssertEqual(retryAccounting.counters.buildsSucceeded, 1)
        XCTAssertEqual(retryAccounting.counters.busyRejections, 1)
    }

    func testDefaultBuilderClientPhase5AQueueFullMapsToCoordinatorBusy() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("default-client-queue-full", root: fixture.root)
        let ownerID = UUID()
        let admission = CoordinatorAdmissionRecorder()
        let builder = CodeMapArtifactBuilderClient(withPermit: { receivedOwnerID, priority, _ in
            await admission.record(ownerID: receivedOwnerID, priority: priority)
            throw ContentReadSchedulerError.queueFull(retryAfterMilliseconds: 313)
        })
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: builder
        )
        let task = Task {
            try await coordinator.resolve(request(input, ownerID: ownerID, priority: .demand))
        }
        await assertBusy(task, retryAfterMilliseconds: 313)

        let entries = await admission.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ownerID, ownerID)
        XCTAssertEqual(entries.first?.priority, .userInitiated)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.busyRejections, 1)
        XCTAssertEqual(accounting.counters.buildsFailed, 0)
        XCTAssertEqual(accounting.counters.failures, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.activeBuildCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
    }

    func testPositiveAndEveryNegativeOutcomePersistAndReuse() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let outcomes: [CodeMapSyntaxArtifactOutcome] = [
            .ready(makeArtifact(name: "Ready")),
            .readyNoSymbols,
            .oversize(.utf8Bytes(actual: 2, limit: 1)),
            .oversize(.utf16Units(actual: 3, limit: 2)),
            .oversize(.lines(actual: 4, limit: 3)),
            .decodeFailed(.undecodable),
            .parseFailed(.parserReturnedNilTree),
            .parseFailed(.parserReturnedNilRoot)
        ]

        for (index, outcome) in outcomes.enumerated() {
            let input = try makeInput("outcome-\(index)", root: fixture.root)
            let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in outcome }
            let builtResult = try await coordinator.resolve(request(input))
            let built = try XCTUnwrap(ready(builtResult))
            XCTAssertEqual(built.handle.outcome, outcome)
            XCTAssertEqual(built.casProvenance, .missBuilt)
            let reusedResult = try await coordinator.resolve(
                CodeMapArtifactBuildRequest(
                    ownerID: UUID(),
                    priority: .demand,
                    target: .artifactKey(input.artifactKey)
                )
            )
            let reused = try XCTUnwrap(ready(reusedResult))
            XCTAssertEqual(reused.handle.outcome, outcome)
            XCTAssertEqual(reused.casProvenance, .memoryHit)
            XCTAssertEqual(reused.buildProvenance, .notNeeded)
        }

        let accounting = await fixture.artifactStore.accounting()
        XCTAssertEqual(accounting.livePositiveCount, 1)
        XCTAssertEqual(accounting.liveNegativeCount, 7)
    }

    func testMemoryDiskAndLocatorProvenanceAreReportedSeparately() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("provenance", root: fixture.root, withLocator: true)
        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in .readyNoSymbols }

        let builtResult = try await coordinator.resolve(request(input))
        let built = try XCTUnwrap(ready(builtResult))
        XCTAssertEqual(built.casProvenance, .missBuilt)
        XCTAssertEqual(built.locatorLookup, .miss)
        XCTAssertEqual(built.locatorPublication, .inserted)

        let memoryResult = try await coordinator.resolve(
            CodeMapArtifactBuildRequest(
                ownerID: UUID(),
                priority: .demand,
                target: .artifactKey(input.artifactKey)
            )
        )
        let memory = try XCTUnwrap(ready(memoryResult))
        XCTAssertEqual(memory.casProvenance, .memoryHit)
        XCTAssertEqual(memory.locatorLookup, .notRequested)

        let restartedStore = try CodeMapArtifactStore(rootURL: fixture.root)
        let restarted = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: restartedStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                XCTFail("locator-backed disk hit must not build")
                return .readyNoSymbols
            })
        )
        let locatedResult = try await restarted.resolve(
            CodeMapArtifactBuildRequest(
                ownerID: UUID(),
                priority: .demand,
                target: .locator(XCTUnwrap(input.locatorIdentity))
            )
        )
        let located = try XCTUnwrap(ready(locatedResult))
        XCTAssertEqual(located.casProvenance, .diskHit)
        XCTAssertEqual(located.locatorLookup, .hit)
        XCTAssertEqual(located.locatorPublication, .notNeededExistingAssociation)
    }

    func testValidLocatorWithCorruptCASFailsClosedThenSourceRebuildsVerifiedArtifact() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("corrupt-cas", root: fixture.root, withLocator: true)
        let identity = try XCTUnwrap(input.locatorIdentity)
        let seedCoordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            .ready(self.makeArtifact(name: "seed"))
        }
        _ = try await seedCoordinator.resolve(request(input))

        let artifactURL = try CodeMapArtifactFileStore(rootURL: fixture.root).artifactURL(for: input.artifactKey)
        let corruptHandle = try FileHandle(forWritingTo: artifactURL)
        try corruptHandle.truncate(atOffset: 0)
        try corruptHandle.write(contentsOf: Data("corrupt-cas".utf8))
        try corruptHandle.synchronize()
        try corruptHandle.close()

        let restartedStore = try CodeMapArtifactStore(rootURL: fixture.root)
        let builds = CoordinatorTestRecorder()
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: restartedStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await builds.record("build")
                return .ready(self.makeArtifact(name: "rebuilt"))
            })
        )
        let locatorOnly = try await coordinator.resolve(
            CodeMapArtifactBuildRequest(ownerID: UUID(), priority: .demand, target: .locator(identity))
        )
        XCTAssertEqual(miss(locatorOnly), .locatorHitWithMissingArtifact)
        let buildsAfterLocatorOnly = await builds.count
        XCTAssertEqual(buildsAfterLocatorOnly, 0)

        let sourceResult = try await coordinator.resolve(request(input))
        let sourceResolution = try XCTUnwrap(ready(sourceResult))
        XCTAssertEqual(sourceResolution.casProvenance, .missBuilt)
        XCTAssertEqual(sourceResolution.locatorLookup, .hitButArtifactMissing)
        XCTAssertEqual(sourceResolution.buildProvenance, .performed)
        XCTAssertEqual(sourceResolution.casPublication, .inserted)
        XCTAssertEqual(sourceResolution.locatorPublication, .notNeededExistingAssociation)
        XCTAssertEqual(
            sourceResolution.handle.outcome,
            .ready(makeArtifact(name: "rebuilt"))
        )
        let buildsAfterSource = await builds.count
        XCTAssertEqual(buildsAfterSource, 1)

        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.requests, 2)
        XCTAssertEqual(accounting.counters.readyResults, 1)
        XCTAssertEqual(accounting.counters.misses, 1)
        XCTAssertEqual(accounting.counters.locatorHits, 2)
        XCTAssertEqual(accounting.counters.locatorHitCASMisses, 2)
        XCTAssertEqual(accounting.counters.casMisses, 2)
        XCTAssertEqual(accounting.counters.buildsStarted, 1)
        XCTAssertEqual(accounting.counters.casInserted, 1)
        XCTAssertEqual(accounting.counters.locatorInserted, 0)
        XCTAssertEqual(accounting.artifactStore.corruptPayloadCount, 1)
    }

    func testSourceAuthoritativeResolutionRepairsStaleLocatorAfterVerifiedCAS() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("source-authoritative", root: fixture.root, withLocator: true)
        let identity = try XCTUnwrap(input.locatorIdentity)
        let staleSource = makeSource("stale-associated-source")
        let staleKey = try CodeMapArtifactKey(
            source: staleSource,
            pipelineIdentity: input.pipelineIdentity
        )
        try writeUncheckedLocatorRecord(identity: identity, key: staleKey, store: fixture.locatorStore)

        let builds = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in
            await builds.record("build")
            return .readyNoSymbols
        }
        let staleLocatorOnly = try await coordinator.resolve(
            CodeMapArtifactBuildRequest(ownerID: UUID(), priority: .demand, target: .locator(identity))
        )
        XCTAssertEqual(miss(staleLocatorOnly), .locatorHitWithMissingArtifact)
        let buildsBeforeSource = await builds.count
        XCTAssertEqual(buildsBeforeSource, 0)

        let result = try await coordinator.resolve(request(input))
        let resolution = try XCTUnwrap(ready(result))
        XCTAssertEqual(resolution.casProvenance, .missBuilt)
        XCTAssertEqual(resolution.locatorLookup, .stale)
        XCTAssertEqual(resolution.buildProvenance, .performed)
        XCTAssertEqual(resolution.locatorPublication, .inserted)
        let buildCount = await builds.count
        let repairedLocator = try await fixture.locatorStore.read(identity: identity)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(repairedLocator, .hit(input.artifactKey))

        let locatorOnly = try await coordinator.resolve(
            CodeMapArtifactBuildRequest(ownerID: UUID(), priority: .demand, target: .locator(identity))
        )
        XCTAssertEqual(ready(locatorOnly)?.handle.key, input.artifactKey)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.locatorHits, 3)
        XCTAssertEqual(accounting.counters.misses, 1)
        XCTAssertEqual(accounting.counters.buildsStarted, 1)
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
    }

    func testLocatorPublishesOnlyAfterVerifiedCASAndRepairsCorruptLocator() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("verification-before-locator", root: fixture.root, withLocator: true)
        let writes = CoordinatorTestRecorder()
        let failingStoreClient = CodeMapArtifactStoreClient(
            lookup: { _ in .miss },
            insert: { _, _ in .inserted },
            lease: { _ in throw CoordinatorTestError.transient },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { _ in .miss },
            write: { _ in
                await writes.record("write")
                return .inserted
            }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: failingStoreClient,
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        do {
            _ = try await coordinator.resolve(request(input))
            XCTFail("expected CAS verification failure")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactBuildCoordinatorError,
                .casVerificationFailed
            )
        }
        let locatorWriteCount = await writes.count
        XCTAssertEqual(locatorWriteCount, 0)

        let corruptInput = try makeInput("repair-corrupt", root: fixture.root, withLocator: true)
        let corruptIdentity = try XCTUnwrap(corruptInput.locatorIdentity)
        let recordURL = fixture.locatorStore.recordURL(for: corruptIdentity)
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("bad".utf8).write(to: recordURL)
        XCTAssertEqual(chmod(recordURL.path, 0o600), 0)
        let corruptBytes = try Data(contentsOf: recordURL)
        let realCoordinator = makeCoordinator(fixture: fixture) { _, _, _ in .readyNoSymbols }
        let locatorOnlyBeforeRepair = try await realCoordinator.resolve(
            CodeMapArtifactBuildRequest(
                ownerID: UUID(),
                priority: .demand,
                target: .locator(corruptIdentity)
            )
        )
        XCTAssertEqual(miss(locatorOnlyBeforeRepair), .corruptLocator)
        XCTAssertEqual(try Data(contentsOf: recordURL), corruptBytes)

        let corruptResult = try await realCoordinator.resolve(request(corruptInput))
        let resolution = try XCTUnwrap(ready(corruptResult))
        XCTAssertEqual(resolution.locatorLookup, .corrupt)
        XCTAssertEqual(resolution.locatorPublication, .inserted)
        let repairedLocator = try await fixture.locatorStore.read(identity: corruptIdentity)
        XCTAssertEqual(repairedLocator, .hit(corruptInput.artifactKey))

        let locatorOnly = try await realCoordinator.resolve(
            CodeMapArtifactBuildRequest(
                ownerID: UUID(),
                priority: .demand,
                target: .locator(corruptIdentity)
            )
        )
        XCTAssertEqual(ready(locatorOnly)?.handle.key, corruptInput.artifactKey)
        let accounting = await realCoordinator.accounting()
        XCTAssertEqual(accounting.counters.locatorCorruptResults, 2)
        XCTAssertEqual(accounting.counters.misses, 1)
        XCTAssertEqual(accounting.counters.locatorInserted, 1)
    }

    func testArtifactStoreAloneOwnsResidentEvictionAndExplicitLeaseSurvivesEviction() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactStore(
            rootURL: root,
            policy: artifactPolicy(residentPositiveEntryLimit: 1)
        )
        let locatorStore = try GitBlobCodeMapLocatorStore(rootURL: root)
        let fixture = CoordinatorFixture(root: root, artifactStore: store, locatorStore: locatorStore)
        let firstInput = try makeInput("lease-first", root: root)
        let secondInput = try makeInput("lease-second", root: root)
        let coordinator = makeCoordinator(fixture: fixture) { input, _, _ in
            .ready(self.makeArtifact(name: input.artifactKey.storageDigestHex))
        }

        let firstResult = try await coordinator.resolve(request(firstInput))
        let first = try XCTUnwrap(ready(firstResult))
        let lease = try await coordinator.acquireLease(for: first)
        _ = try await coordinator.resolve(request(secondInput))
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.artifactStore.residentPositiveCount, 1)
        XCTAssertEqual(accounting.artifactStore.activeLeaseCount, 1)
        XCTAssertEqual(first.handle.key, firstInput.artifactKey)
        await lease.close()
        let closedAccounting = await store.accounting()
        XCTAssertEqual(closedAccounting.activeLeaseCount, 0)
    }

    func testDemandPriorityOwnerFairnessAndForegroundSuppression() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let foregroundInput = try makeInput("foreground-suppression", root: fixture.root)
        let defaultCoordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore)
        )
        let foregroundTask = try await FileSystemService.withContentReadForegroundActivity(kind: .rootLoad) {
            let task = Task { try await defaultCoordinator.resolve(request(foregroundInput)) }
            try await waitUntil { await defaultCoordinator.accounting().activeBuildCount == 1 }
            for _ in 0 ..< 100 {
                await Task.yield()
            }
            let suppressedAccounting = await defaultCoordinator.accounting()
            XCTAssertEqual(suppressedAccounting.counters.buildsSucceeded, 0)
            return task
        }
        let foregroundResult = try await foregroundTask.value
        XCTAssertNotNil(ready(foregroundResult))

        let schedulingFixture = try makeFixture()
        defer { schedulingFixture.remove() }
        let blocker = try makeInput("fairness-blocker", root: schedulingFixture.root)
        let explicit = try makeInput("fairness-explicit", root: schedulingFixture.root)
        let demandA = try makeInput("fairness-demand-a", root: schedulingFixture.root)
        let demandB = try makeInput("fairness-demand-b", root: schedulingFixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let schedulingCoordinator = makeCoordinator(
            fixture: schedulingFixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 4)
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let ownerA = UUID()
        let ownerB = UUID()
        let first = Task { try await schedulingCoordinator.resolve(request(blocker, ownerID: ownerA, priority: .explicit)) }
        await gate.waitUntilEntered()
        let low = Task { try await schedulingCoordinator.resolve(request(explicit, ownerID: ownerA, priority: .explicit)) }
        let highA = Task { try await schedulingCoordinator.resolve(request(demandA, ownerID: ownerA, priority: .demand)) }
        let highB = Task { try await schedulingCoordinator.resolve(request(demandB, ownerID: ownerB, priority: .demand)) }
        try await waitUntil { await schedulingCoordinator.accounting().queuedBuildCount == 3 }
        await gate.release()
        _ = try await first.value
        _ = try await highA.value
        _ = try await highB.value
        _ = try await low.value
        let values = await order.values
        XCTAssertEqual(values.first, blocker.artifactKey.storageDigestHex)
        XCTAssertEqual(values.last, explicit.artifactKey.storageDigestHex)
        XCTAssertEqual(Set(values[1 ... 2]), Set([
            demandA.artifactKey.storageDigestHex,
            demandB.artifactKey.storageDigestHex
        ]))
    }

    func testDemandThenExplicitThenBackgroundBeforeAging() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("priority-blocker", root: fixture.root)
        let background = try makeInput("priority-background", root: fixture.root)
        let explicit = try makeInput("priority-explicit", root: fixture.root)
        let demand = try makeInput("priority-demand", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 3),
            clock: clock.clock
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let owner = UUID()
        let blockerTask = Task {
            try await coordinator.resolve(request(blocker, ownerID: owner, priority: .explicit))
        }
        await gate.waitUntilEntered()
        let backgroundTask = Task {
            try await coordinator.resolve(request(background, ownerID: owner, priority: .background))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let explicitTask = Task {
            try await coordinator.resolve(request(explicit, ownerID: owner, priority: .explicit))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        let demandTask = Task {
            try await coordinator.resolve(request(demand, ownerID: owner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 3 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await demandTask.value
        _ = try await explicitTask.value
        _ = try await backgroundTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            demand.artifactKey.storageDigestHex,
            explicit.artifactKey.storageDigestHex,
            background.artifactKey.storageDigestHex
        ])
    }

    func testDemandJoinUpgradesQueuedBackgroundFlight() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("upgrade-blocker", root: fixture.root)
        let shared = try makeInput("upgrade-shared", root: fixture.root)
        let explicit = try makeInput("upgrade-explicit", root: fixture.root)
        let gate = CoordinatorTestGate()
        let builds = CoordinatorBuildRecorder()
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 2),
            clock: clock.clock
        ) { input, ownerID, priority in
            await builds.record(key: input.artifactKey, ownerID: ownerID, priority: priority)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let backgroundOwner = UUID()
        let demandOwner = UUID()
        let blockerTask = Task { try await coordinator.resolve(request(blocker, priority: .explicit)) }
        await gate.waitUntilEntered()
        let backgroundTask = Task {
            try await coordinator.resolve(
                request(shared, ownerID: backgroundOwner, priority: .background)
            )
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let explicitTask = Task { try await coordinator.resolve(request(explicit, priority: .explicit)) }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        let demandTask = Task {
            try await coordinator.resolve(request(shared, ownerID: demandOwner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().waiterCount == 4 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await demandTask.value
        _ = try await backgroundTask.value
        _ = try await explicitTask.value

        let entries = await builds.entries
        XCTAssertEqual(entries.map(\.key), [blocker.artifactKey, shared.artifactKey, explicit.artifactKey])
        let sharedEntry = try XCTUnwrap(entries.first { $0.key == shared.artifactKey })
        XCTAssertEqual(sharedEntry.ownerID, demandOwner)
        XCTAssertEqual(sharedEntry.priority, .demand)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.joins, 1)
        XCTAssertEqual(accounting.counters.demandAdmissions, 1)
    }

    func testDemandRetainerReleaseDowngradesQueuedSharedFlightWithoutRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("downgrade-blocker", root: fixture.root)
        let shared = try makeInput("downgrade-shared", root: fixture.root)
        let explicit = try makeInput("downgrade-explicit", root: fixture.root)
        let gate = CoordinatorTestGate()
        let builds = CoordinatorBuildRecorder()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 2)
        ) { input, ownerID, priority in
            await builds.record(key: input.artifactKey, ownerID: ownerID, priority: priority)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let backgroundOwner = UUID()
        let demandOwner = UUID()
        let blockerTask = Task { try await coordinator.resolve(request(blocker, priority: .explicit)) }
        await gate.waitUntilEntered()
        let backgroundTask = Task {
            try await coordinator.resolve(
                request(shared, ownerID: backgroundOwner, priority: .background)
            )
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let explicitTask = Task { try await coordinator.resolve(request(explicit, priority: .explicit)) }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        let demandTask = Task {
            try await coordinator.resolve(request(shared, ownerID: demandOwner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().waiterCount == 4 }
        demandTask.cancel()
        await assertCancellation(demandTask)
        try await waitUntil { await coordinator.accounting().waiterCount == 3 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await explicitTask.value
        _ = try await backgroundTask.value

        let entries = await builds.entries
        XCTAssertEqual(entries.map(\.key), [blocker.artifactKey, explicit.artifactKey, shared.artifactKey])
        let sharedEntry = try XCTUnwrap(entries.first { $0.key == shared.artifactKey })
        XCTAssertEqual(sharedEntry.ownerID, backgroundOwner)
        XCTAssertEqual(sharedEntry.priority, .background)
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.joins, 1)
        XCTAssertEqual(accounting.counters.buildsStarted, 3)
        XCTAssertEqual(accounting.counters.duplicateBuilds, 0)
        XCTAssertEqual(accounting.counters.demandAdmissions, 0)
    }

    func testAgedBackgroundAdmitsAfterForegroundBound() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("aged-bound-blocker", root: fixture.root)
        let background = try makeInput("aged-bound-background", root: fixture.root)
        let demandA = try makeInput("aged-bound-demand-a", root: fixture.root)
        let demandB = try makeInput("aged-bound-demand-b", root: fixture.root)
        let demandC = try makeInput("aged-bound-demand-c", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 4,
                backgroundAgePromotionNanoseconds: 100,
                maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: 2
            ),
            clock: clock.clock
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let owner = UUID()
        let blockerTask = Task {
            try await coordinator.resolve(request(blocker, ownerID: owner, priority: .explicit))
        }
        await gate.waitUntilEntered()
        let backgroundTask = Task {
            try await coordinator.resolve(request(background, ownerID: owner, priority: .background))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        clock.advance(by: 100)
        let demandATask = Task {
            try await coordinator.resolve(request(demandA, ownerID: owner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        let demandBTask = Task {
            try await coordinator.resolve(request(demandB, ownerID: owner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 3 }
        let demandCTask = Task {
            try await coordinator.resolve(request(demandC, ownerID: owner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 4 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await demandATask.value
        _ = try await demandBTask.value
        _ = try await backgroundTask.value
        _ = try await demandCTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            demandA.artifactKey.storageDigestHex,
            demandB.artifactKey.storageDigestHex,
            background.artifactKey.storageDigestHex,
            demandC.artifactKey.storageDigestHex
        ])
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.consecutiveNonBackgroundAdmissionsWhileBackgroundAged, 0)
        XCTAssertEqual(accounting.counters.agedBackgroundAdmissions, 1)
        XCTAssertEqual(accounting.counters.nonBackgroundAdmissionsWhileBackgroundAged, 2)
    }

    func testAgedBackgroundAdmissionIsOwnerFair() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("aged-owner-blocker", root: fixture.root)
        let repeated = try makeInput("aged-owner-repeated", root: fixture.root)
        let fresh = try makeInput("aged-owner-fresh", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 2,
                backgroundAgePromotionNanoseconds: 10,
                maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: 0
            ),
            clock: clock.clock
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let repeatedOwner = UUID()
        let blockerTask = Task {
            try await coordinator.resolve(request(blocker, ownerID: repeatedOwner, priority: .demand))
        }
        await gate.waitUntilEntered()
        let repeatedTask = Task {
            try await coordinator.resolve(
                request(repeated, ownerID: repeatedOwner, priority: .background)
            )
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let freshTask = Task {
            try await coordinator.resolve(request(fresh, ownerID: UUID(), priority: .background))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        clock.advance(by: 10)
        await gate.release()
        _ = try await blockerTask.value
        _ = try await freshTask.value
        _ = try await repeatedTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            fresh.artifactKey.storageDigestHex,
            repeated.artifactKey.storageDigestHex
        ])
    }

    func testAgedExplicitAdmissionPrecedesNewerDemandDespiteOwnerHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("aged-explicit-blocker", root: fixture.root)
        let agedExplicit = try makeInput("aged-explicit", root: fixture.root)
        let newerDemand = try makeInput("aged-explicit-new-demand", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let testClock = CoordinatorTestClock()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 3,
                agePromotionNanoseconds: 100
            ),
            clock: testClock.clock
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let repeatedOwner = UUID()
        let blockerTask = Task {
            try await coordinator.resolve(request(blocker, ownerID: repeatedOwner, priority: .explicit))
        }
        await gate.waitUntilEntered()
        let agedTask = Task {
            try await coordinator.resolve(request(agedExplicit, ownerID: repeatedOwner, priority: .explicit))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        testClock.advance(by: 100)
        let demandTask = Task {
            try await coordinator.resolve(request(newerDemand, ownerID: UUID(), priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await agedTask.value
        _ = try await demandTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            agedExplicit.artifactKey.storageDigestHex,
            newerDemand.artifactKey.storageDigestHex
        ])
    }

    func testExplicitAdmissionOccursAtConfiguredConsecutiveDemandLimit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("demand-limit-blocker", root: fixture.root)
        let explicit = try makeInput("demand-limit-explicit", root: fixture.root)
        let demandA = try makeInput("demand-limit-a", root: fixture.root)
        let demandB = try makeInput("demand-limit-b", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 3,
                maximumConsecutiveDemandAdmissions: 2
            )
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let blockerTask = Task { try await coordinator.resolve(request(blocker, priority: .explicit)) }
        await gate.waitUntilEntered()
        let explicitTask = Task { try await coordinator.resolve(request(explicit, priority: .explicit)) }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let demandOwner = UUID()
        let demandATask = Task {
            try await coordinator.resolve(request(demandA, ownerID: demandOwner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        let demandBTask = Task {
            try await coordinator.resolve(request(demandB, ownerID: demandOwner, priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 3 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await demandATask.value
        _ = try await demandBTask.value
        _ = try await explicitTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            demandA.artifactKey.storageDigestHex,
            demandB.artifactKey.storageDigestHex,
            explicit.artifactKey.storageDigestHex
        ])
    }

    func testDemandAdmissionUsesLeastRecentlyAdmittedOwnerBeforeEnqueueOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blocker = try makeInput("owner-order-blocker", root: fixture.root)
        let repeatedOwnerDemand = try makeInput("owner-order-repeated", root: fixture.root)
        let freshOwnerDemand = try makeInput("owner-order-fresh", root: fixture.root)
        let gate = CoordinatorTestGate()
        let order = CoordinatorTestRecorder()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(maximumConcurrentBuildCount: 1, maximumQueuedBuildCount: 2)
        ) { input, _, _ in
            await order.record(input.artifactKey.storageDigestHex)
            if input.artifactKey == blocker.artifactKey { await gate.enter() }
            return .readyNoSymbols
        }
        let repeatedOwner = UUID()
        let blockerTask = Task {
            try await coordinator.resolve(request(blocker, ownerID: repeatedOwner, priority: .demand))
        }
        await gate.waitUntilEntered()
        let repeatedTask = Task {
            try await coordinator.resolve(
                request(repeatedOwnerDemand, ownerID: repeatedOwner, priority: .demand)
            )
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 1 }
        let freshTask = Task {
            try await coordinator.resolve(request(freshOwnerDemand, ownerID: UUID(), priority: .demand))
        }
        try await waitUntil { await coordinator.accounting().queuedBuildCount == 2 }
        await gate.release()
        _ = try await blockerTask.value
        _ = try await freshTask.value
        _ = try await repeatedTask.value

        let values = await order.values
        XCTAssertEqual(values, [
            blocker.artifactKey.storageDigestHex,
            freshOwnerDemand.artifactKey.storageDigestHex,
            repeatedOwnerDemand.artifactKey.storageDigestHex
        ])
    }

    func testRetainedInputByteBudgetChargesOneFlightRejectsOverflowAndReleasesForRetry() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstInput = try makeInput("budget-a", root: fixture.root)
        let secondInput = try makeInput("budget-b", root: fixture.root)
        XCTAssertEqual(firstInput.source.rawByteCount, secondInput.source.rawByteCount)
        let gate = CoordinatorTestGate()
        let blockFirstBuild = CoordinatorFailOnce()
        let coordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 2,
                maximumRetainedInputByteCount: firstInput.source.rawByteCount
            )
        ) { _, _, _ in
            if await blockFirstBuild.take() { await gate.enter() }
            return .readyNoSymbols
        }

        let first = Task { try await coordinator.resolve(request(firstInput)) }
        await gate.waitUntilEntered()
        let joined = Task { try await coordinator.resolve(request(firstInput)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        var accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, firstInput.source.rawByteCount)

        do {
            _ = try await coordinator.resolve(request(secondInput))
            XCTFail("expected retained-input byte budget rejection")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactBuildCoordinatorError,
                .busy(retryAfterMilliseconds: 10)
            )
        }
        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, firstInput.source.rawByteCount)
        XCTAssertEqual(accounting.activeFlightCount, 1)

        await gate.release()
        _ = try await first.value
        _ = try await joined.value
        try await waitUntil { await coordinator.accounting().retainedInputByteCount == 0 }

        let retryResult = try await coordinator.resolve(request(secondInput))
        XCTAssertNotNil(ready(retryResult))
        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.busyRejections, 1)
        XCTAssertEqual(accounting.counters.joins, 1)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
    }

    func testSourceJoinDuringCASPersistenceDoesNotReleaseAndReacquireInput() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("persistence-join", root: fixture.root)
        let insertGate = CoordinatorTestGate()
        let builds = CoordinatorTestRecorder()
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { try await fixture.artifactStore.lookup(key: $0) },
            insert: { key, outcome in
                await insertGate.enter()
                return try await fixture.artifactStore.insert(key: key, deterministicOutcome: outcome)
            },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await builds.record("build")
                return .readyNoSymbols
            }),
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 1,
                maximumRetainedInputByteCount: input.source.rawByteCount
            )
        )

        let first = Task { try await coordinator.resolve(request(input)) }
        await insertGate.waitUntilEntered()
        var accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, input.source.rawByteCount)
        XCTAssertEqual(accounting.counters.retainedInputReservations, 1)
        XCTAssertEqual(accounting.counters.retainedInputReleases, 0)

        let joined = Task { try await coordinator.resolve(request(input)) }
        try await waitUntil { await coordinator.accounting().waiterCount == 2 }
        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, input.source.rawByteCount)
        XCTAssertEqual(accounting.counters.retainedInputReservations, 1)
        XCTAssertEqual(accounting.counters.retainedInputReleases, 0)
        XCTAssertEqual(accounting.counters.busyRejections, 0)

        await insertGate.release()
        let firstResult = try await first.value
        let joinedResult = try await joined.value
        XCTAssertNotNil(ready(firstResult))
        XCTAssertEqual(ready(joinedResult)?.buildProvenance, .joinedSharedBuild)
        let buildCount = await builds.count
        XCTAssertEqual(buildCount, 1)

        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
        XCTAssertEqual(accounting.counters.retainedInputReservations, 1)
        XCTAssertEqual(accounting.counters.retainedInputReleases, 1)
        XCTAssertEqual(accounting.counters.joins, 1)
        XCTAssertEqual(accounting.activeFlightCount, 0)
    }

    func testRetainedInputByteBudgetReleasesAfterFailureAndLastWaiterCancellation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let failedInput = try makeInput("budget-failure", root: fixture.root)
        let cancelledInput = try makeInput("budget-cancel", root: fixture.root)
        let budget = max(failedInput.source.rawByteCount, cancelledInput.source.rawByteCount)

        let failure = CoordinatorFailOnce()
        let failureCoordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 1,
                maximumRetainedInputByteCount: budget
            )
        ) { _, _, _ in
            if await failure.take() { throw CoordinatorTestError.transient }
            return .readyNoSymbols
        }
        await assertTransientFailure {
            try await failureCoordinator.resolve(request(failedInput))
        }
        var accounting = await failureCoordinator.accounting()
        XCTAssertEqual(accounting.counters.failures, 1)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
        let failureRetryResult = try await failureCoordinator.resolve(request(failedInput))
        XCTAssertNotNil(ready(failureRetryResult))
        accounting = await failureCoordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, 0)

        let gate = CoordinatorTestGate()
        let cancellationCoordinator = makeCoordinator(
            fixture: fixture,
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 1,
                maximumRetainedInputByteCount: budget
            )
        ) { _, _, _ in
            await gate.enter()
            return .readyNoSymbols
        }
        let cancelled = Task { try await cancellationCoordinator.resolve(request(cancelledInput)) }
        await gate.waitUntilEntered()
        accounting = await cancellationCoordinator.accounting()
        XCTAssertEqual(accounting.retainedInputByteCount, cancelledInput.source.rawByteCount)
        cancelled.cancel()
        await assertCancellation(cancelled)
        await gate.release()
        try await waitUntil {
            let snapshot = await cancellationCoordinator.accounting()
            return snapshot.activeFlightCount == 0 && snapshot.retainedInputByteCount == 0
        }
        let cancellationRetryResult = try await cancellationCoordinator.resolve(request(cancelledInput))
        XCTAssertNotNil(ready(cancellationRetryResult))
        accounting = await cancellationCoordinator.accounting()
        XCTAssertEqual(accounting.counters.lastWaiterCancellations, 1)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
    }

    func testHookOverflowDropsNewestPreservesAcceptedFIFOAndDrainsWithoutLeak() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("hook-overflow", root: fixture.root)
        let lookupGate = CoordinatorTestGate()
        let buildGate = CoordinatorTestGate()
        let consumerGate = CoordinatorTestGate()
        let events = CoordinatorHookRecorder()
        let initialLookup = CoordinatorFailOnce()
        let storeClient = CodeMapArtifactStoreClient(
            lookup: { key in
                if await initialLookup.take() {
                    await lookupGate.enter()
                    return .miss
                }
                return try await fixture.artifactStore.lookup(key: key)
            },
            insert: { try await fixture.artifactStore.insert(key: $0, deterministicOutcome: $1) },
            lease: { try await fixture.artifactStore.lease(handle: $0) },
            accounting: { await fixture.artifactStore.accounting() }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: storeClient,
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildGate.enter()
                return .readyNoSymbols
            }),
            policy: policy(
                maximumConcurrentBuildCount: 1,
                maximumQueuedBuildCount: 1,
                maximumPendingHookEventCount: 3
            ),
            hooks: CodeMapArtifactBuildCoordinatorHooks { event in
                await events.append(event)
                if event.kind == .flightCreated { await consumerGate.enter() }
            }
        )

        let task = Task { try await coordinator.resolve(request(input)) }
        await lookupGate.waitUntilEntered()
        await consumerGate.waitUntilEntered()
        await lookupGate.release()
        await buildGate.waitUntilEntered()

        var accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.pendingHookEventCount, 3)
        XCTAssertTrue(accounting.hookDispatcherIsDraining)
        XCTAssertEqual(accounting.counters.droppedHookEvents, 2)

        await consumerGate.release()
        try await waitUntil {
            let snapshot = await coordinator.accounting()
            let eventCount = await events.events.count
            return eventCount == 4 &&
                snapshot.pendingHookEventCount == 0 &&
                !snapshot.hookDispatcherIsDraining
        }
        let retainedKinds = await events.events.map(\.kind)
        XCTAssertEqual(retainedKinds, [.flightCreated, .phaseChanged, .buildEnqueued, .phaseChanged])

        await buildGate.release()
        let taskResult = try await task.value
        XCTAssertNotNil(ready(taskResult))
        try await waitUntil {
            let snapshot = await coordinator.accounting()
            return snapshot.activeFlightCount == 0 &&
                snapshot.retainedInputByteCount == 0 &&
                snapshot.pendingHookEventCount == 0 &&
                !snapshot.hookDispatcherIsDraining
        }
        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.droppedHookEvents, 2)
    }

    func testEarlyLocatorReadFailureIsTypedAccountedAndRetryable() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("locator-read-failure", root: fixture.root, withLocator: true)
        let failure = CoordinatorFailOnce()
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { identity in
                if await failure.take() { throw CoordinatorTestError.transient }
                return try await fixture.locatorStore.read(identity: identity)
            },
            write: { try await fixture.locatorStore.write(association: $0) }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )

        do {
            _ = try await coordinator.resolve(request(input))
            XCTFail("expected typed locator read failure")
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactBuildCoordinatorError,
                .locatorStoreReadFailed
            )
        }
        var accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.requests, 1)
        XCTAssertEqual(accounting.counters.failures, 1)
        XCTAssertEqual(accounting.counters.readyResults, 0)
        XCTAssertEqual(accounting.counters.misses, 0)
        XCTAssertEqual(accounting.counters.busyRejections, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)

        let retryResult = try await coordinator.resolve(request(input))
        XCTAssertNotNil(ready(retryResult))
        accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.requests, 2)
        XCTAssertEqual(accounting.counters.failures, 1)
        XCTAssertEqual(accounting.counters.readyResults, 1)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
    }

    func testCancellationDuringLocatorReadIsCountedExactlyOnceWithoutDownstreamWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let input = try makeInput("locator-cancellation-telemetry", root: fixture.root, withLocator: true)
        let gate = CoordinatorTestGate()
        let buildCount = CoordinatorTestRecorder()
        let locatorClient = GitBlobCodeMapLocatorStoreClient(
            read: { identity in
                await gate.enter()
                try Task.checkCancellation()
                return try await fixture.locatorStore.read(identity: identity)
            },
            write: { try await fixture.locatorStore.write(association: $0) }
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: locatorClient,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in
                await buildCount.record("build")
                return .readyNoSymbols
            })
        )

        let task = Task { try await coordinator.resolve(request(input)) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.requests, 1)
        XCTAssertEqual(accounting.counters.waiterCancellations, 1)
        XCTAssertEqual(accounting.counters.lastWaiterCancellations, 0)
        XCTAssertEqual(accounting.counters.sharedTaskCancellations, 0)
        XCTAssertEqual(accounting.activeFlightCount, 0)
        XCTAssertEqual(accounting.queuedBuildCount, 0)
        XCTAssertEqual(accounting.waiterCount, 0)
        XCTAssertEqual(accounting.retainedInputByteCount, 0)
        let observedBuildCount = await buildCount.count
        XCTAssertEqual(observedBuildCount, 0)
    }

    func testLocatorInputRequiresExactCleanGitBlobProvenanceForSHA1AndSHA256() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let root = fixture.root
        let namespace = try makeNamespace(root)

        for format in [GitObjectFormat.sha1, .sha256] {
            let source = try makeCleanSource("locator-validation-\(format)", root: root, format: format)
            let pipeline = try SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: source.decoderPolicy
            )
            guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
                XCTFail("expected clean Git blob provenance")
                continue
            }
            let locator = GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: repositoryNamespace,
                blobOID: blobOID,
                pipelineIdentity: pipeline
            )
            XCTAssertNoThrow(try CodeMapArtifactBuildInput(
                source: source,
                language: .swift,
                locatorIdentity: locator
            ))
        }

        let worktreeSource = makeSource("locator-validation-worktree")
        let worktreePipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: worktreeSource.decoderPolicy
        )
        let worktreeLocator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: namespace,
            blobOID: GitBlobOID.blob(bytes: worktreeSource.rawBytes, objectFormat: .sha1),
            pipelineIdentity: worktreePipeline
        )
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: worktreeSource,
            language: .swift,
            locatorIdentity: worktreeLocator
        )) {
            XCTAssertEqual(
                $0 as? CodeMapArtifactBuildCoordinatorError,
                .invalidRequest(.locatorRequiresCleanGitBlob)
            )
        }

        let source = try makeCleanSource("locator-validation", root: root, format: .sha1)
        let swiftPipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        let pythonPipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .python,
            decoderPolicy: source.decoderPolicy
        )
        guard case let .cleanGitBlob(sourceNamespace, sourceOID) = source.provenance else {
            return XCTFail("expected clean Git blob provenance")
        }
        let validLocator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: sourceNamespace,
            blobOID: sourceOID,
            pipelineIdentity: swiftPipeline
        )
        let wrongPipeline = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: sourceNamespace,
            blobOID: sourceOID,
            pipelineIdentity: pythonPipeline
        )
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: wrongPipeline
        )) {
            XCTAssertEqual($0 as? CodeMapArtifactBuildCoordinatorError, .invalidRequest(.pipelineMismatch))
        }

        let otherNamespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "cd", count: 32))
        let wrongNamespace = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: otherNamespace,
            blobOID: sourceOID,
            pipelineIdentity: swiftPipeline
        )
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: wrongNamespace
        )) {
            XCTAssertEqual(
                $0 as? CodeMapArtifactBuildCoordinatorError,
                .invalidRequest(.repositoryNamespaceMismatch)
            )
        }

        let wrongFormat = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: sourceNamespace,
            blobOID: GitBlobOID.blob(bytes: source.rawBytes, objectFormat: .sha256),
            pipelineIdentity: swiftPipeline
        )
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: wrongFormat
        )) {
            XCTAssertEqual($0 as? CodeMapArtifactBuildCoordinatorError, .invalidRequest(.objectFormatMismatch))
        }

        let wrongOID = try GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: sourceNamespace,
            objectFormat: .sha1,
            blobOID: String(repeating: "ab", count: 20),
            pipelineIdentity: swiftPipeline
        )
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: wrongOID
        )) {
            XCTAssertEqual($0 as? CodeMapArtifactBuildCoordinatorError, .invalidRequest(.gitBlobOIDMismatch))
        }

        let otherSource = try makeCleanSource("locator-validation-other", root: root, format: .sha1)
        let otherKey = try CodeMapArtifactKey(source: otherSource, pipelineIdentity: swiftPipeline)
        XCTAssertThrowsError(try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            pipelineIdentity: swiftPipeline,
            artifactKey: otherKey,
            locatorIdentity: validLocator
        )) {
            XCTAssertEqual($0 as? CodeMapArtifactBuildCoordinatorError, .invalidRequest(.artifactKeyMismatch))
        }

        let coordinator = makeCoordinator(fixture: fixture) { _, _, _ in .readyNoSymbols }
        let accounting = await coordinator.accounting()
        XCTAssertEqual(accounting.counters.requests, 0)
        XCTAssertEqual(accounting.counters.failures, 0)
    }

    func testCoordinatorPersistenceContainsNoSourcePaths() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let sentinel = "PRIVATE-WORKTREE-/Users/example/secret.swift"
        let input = try makeInput(sentinel, root: fixture.root, withLocator: true)
        let events = CoordinatorHookRecorder()
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols }),
            hooks: CodeMapArtifactBuildCoordinatorHooks { event in
                await events.append(event)
            }
        )
        _ = try await coordinator.resolve(request(input))
        try await waitUntil { await !(events.events).isEmpty }

        let relativePaths = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(relativePaths.contains { $0.contains(sentinel) })
        for event in await events.events {
            XCTAssertFalse(event.artifactStorageDigest.contains(sentinel))
            XCTAssertEqual(event.artifactStorageDigest.count, 64)
        }
        let files = relativePaths.map { fixture.root.appendingPathComponent($0) }
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            XCTAssertFalse(try Data(contentsOf: file).range(of: Data(sentinel.utf8)) != nil)
        }
    }

    // MARK: - Helpers

    private struct CoordinatorFixture: @unchecked Sendable {
        let root: URL
        let artifactStore: CodeMapArtifactStore
        let locatorStore: GitBlobCodeMapLocatorStore

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum CoordinatorTestError: Error {
        case transient
    }

    private func makeFixture() throws -> CoordinatorFixture {
        let root = try makeSecureRoot()
        return try CoordinatorFixture(
            root: root,
            artifactStore: CodeMapArtifactStore(rootURL: root),
            locatorStore: GitBlobCodeMapLocatorStore(rootURL: root)
        )
    }

    private func makeCoordinator(
        fixture: CoordinatorFixture,
        policy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        clock: CodeMapArtifactBuildCoordinatorClock = .continuous,
        build: @escaping @Sendable (
            CodeMapArtifactBuildInput,
            UUID,
            CodeMapArtifactBuildPriority
        ) async throws -> CodeMapSyntaxArtifactOutcome
    ) -> CodeMapArtifactBuildCoordinator {
        CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: fixture.artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: fixture.locatorStore),
            builder: CodeMapArtifactBuilderClient(build: build),
            policy: policy,
            clock: clock
        )
    }

    private func request(
        _ input: CodeMapArtifactBuildInput,
        ownerID: UUID = UUID(),
        priority: CodeMapArtifactBuildPriority = .demand
    ) -> CodeMapArtifactBuildRequest {
        CodeMapArtifactBuildRequest(ownerID: ownerID, priority: priority, target: .source(input))
    }

    private func policy(
        maximumConcurrentBuildCount: Int,
        maximumQueuedBuildCount: Int,
        maximumLocatorIdentitiesPerFlight: Int = 4,
        maximumRetainedInputByteCount: Int = 128 * 1024 * 1024,
        maximumPendingHookEventCount: Int = 256,
        maximumConsecutiveDemandAdmissions: Int = 2,
        agePromotionNanoseconds: UInt64 = 1_000_000_000,
        backgroundAgePromotionNanoseconds: UInt64 = 1_000_000_000,
        maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: Int = 2
    ) -> CodeMapArtifactBuildCoordinatorPolicy {
        CodeMapArtifactBuildCoordinatorPolicy(
            maximumFlightCount: 16,
            maximumTotalWaiterCount: 32,
            maximumWaitersPerFlight: 8,
            maximumQueuedBuildCount: maximumQueuedBuildCount,
            maximumConcurrentBuildCount: maximumConcurrentBuildCount,
            maximumLocatorIdentitiesPerFlight: maximumLocatorIdentitiesPerFlight,
            maximumRetainedInputByteCount: maximumRetainedInputByteCount,
            maximumPendingHookEventCount: maximumPendingHookEventCount,
            maximumConsecutiveDemandAdmissions: maximumConsecutiveDemandAdmissions,
            agePromotionNanoseconds: agePromotionNanoseconds,
            backgroundAgePromotionNanoseconds: backgroundAgePromotionNanoseconds,
            maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged:
            maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged,
            retryAfterMilliseconds: 10
        )
    }

    private func makeInput(
        _ text: String,
        root: URL,
        withLocator: Bool = false
    ) throws -> CodeMapArtifactBuildInput {
        guard withLocator else {
            return try CodeMapArtifactBuildInput(source: makeSource(text), language: .swift)
        }
        let source = try makeCleanSource(text, root: root, format: .sha1)
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw CoordinatorTestError.transient
        }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        return try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: locator
        )
    }

    private func makeSource(_ text: String) -> CodeMapSourceSnapshot {
        let data = Data(text.utf8)
        let fingerprint = FileContentFingerprint(
            deviceID: 1,
            fileNumber: UInt64(abs(text.hashValue)),
            byteSize: Int64(data.count),
            modificationSeconds: 3,
            modificationNanoseconds: 0,
            statusChangeSeconds: 4,
            statusChangeNanoseconds: 0
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )
    }

    private func makeCleanSource(
        _ text: String,
        root: URL,
        format: GitObjectFormat
    ) throws -> CodeMapSourceSnapshot {
        try WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: Data(text.utf8),
            objectFormat: format,
            namespaceScope: root.path
        )
    }

    private func makeNamespace(_ root: URL) throws -> GitBlobRepositoryNamespace {
        try GitBlobRepositoryNamespace(
            commonDirectory: root,
            salt: Data(repeating: 0x5A, count: GitBlobRepositoryNamespace.saltByteCount)
        )
    }

    private func gitBlobOID(_ bytes: Data, format: GitObjectFormat) -> String {
        var canonical = Data("blob \(bytes.count)\0".utf8)
        canonical.append(bytes)
        let digest = switch format {
        case .sha1: Data(Insecure.SHA1.hash(data: canonical))
        case .sha256: Data(SHA256.hash(data: canonical))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writeUncheckedLocatorRecord(
        identity: GitBlobCodeMapLocatorIdentity,
        key: CodeMapArtifactKey,
        store: GitBlobCodeMapLocatorStore
    ) throws {
        let url = store.recordURL(for: identity)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identityBytes = identity.canonicalBytes
        let keyBytes = key.canonicalBytes
        var record = GitBlobCodeMapLocatorRecordCodec.magic
        appendBigEndian(GitBlobCodeMapLocatorRecordCodec.version, to: &record)
        appendBigEndian(UInt32(identityBytes.count), to: &record)
        appendBigEndian(UInt32(keyBytes.count), to: &record)
        record.append(identityBytes)
        record.append(keyBytes)
        record.append(Data(SHA256.hash(data: record)))
        try record.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func ready(
        _ result: CodeMapArtifactBuildCoordinatorResult
    ) -> CodeMapArtifactCoordinatorResolution? {
        guard case let .ready(resolution) = result else { return nil }
        return resolution
    }

    private func miss(
        _ result: CodeMapArtifactBuildCoordinatorResult
    ) -> CodeMapArtifactCoordinatorMiss? {
        guard case let .miss(miss) = result else { return nil }
        return miss
    }

    private func requireHit(
        _ store: CodeMapArtifactStore,
        key: CodeMapArtifactKey
    ) async throws -> CodeMapArtifactHandle {
        switch try await store.lookup(key: key) {
        case let .hit(_, handle): handle
        case .miss:
            XCTFail("expected artifact hit")
            throw CoordinatorTestError.transient
        }
    }

    private func assertCancellation(
        _ task: Task<CodeMapArtifactBuildCoordinatorResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertBusy(
        _ task: Task<CodeMapArtifactBuildCoordinatorResult, Error>,
        retryAfterMilliseconds: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected busy rejection", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CodeMapArtifactBuildCoordinatorError,
                .busy(retryAfterMilliseconds: retryAfterMilliseconds),
                file: file,
                line: line
            )
        }
    }

    private func assertTransientFailure(
        _ operation: () async throws -> CodeMapArtifactBuildCoordinatorResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected transient failure", file: file, line: line)
        } catch CoordinatorTestError.transient {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 10000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached", file: file, line: line)
        throw CoordinatorTestError.transient
    }

    private func makeSecureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(root.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }

    private func makeArtifact(name: String) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: [],
            exports: [],
            classes: [ClassInfo(name: name, methods: [], properties: [])],
            interfaces: [],
            aliases: [],
            literalUnions: [],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func artifactPolicy(residentPositiveEntryLimit: Int) -> CodeMapArtifactStorePolicy {
        CodeMapArtifactStorePolicy(
            residentPositiveEntryLimit: residentPositiveEntryLimit,
            residentPositiveByteLimit: 64 * 1024 * 1024,
            residentNegativeEntryLimit: 16,
            residentNegativeByteLimit: 1024 * 1024,
            softQuotaBytes: 1024 * 1024,
            hardQuotaBytes: 2 * 1024 * 1024,
            unreferencedGraceSeconds: 100,
            quarantineDelaySeconds: 100,
            negativeQuotaBytes: 1024 * 1024,
            negativeMaximumAgeSeconds: 100,
            maximumCatalogRecordCount: 128,
            maximumCatalogScanByteCount: 1024 * 1024,
            maximumArtifactScanCount: 128,
            maximumArtifactReconciliationByteCount: 2 * 1024 * 1024,
            maximumMaintenanceWriteByteCount: 128 * 1024,
            maximumQuarantineEpochCount: 128,
            maximumMetadataRecordByteCount: 64 * 1024,
            maximumGCStepBudget: 128,
            containerPolicy: .default
        )
    }
}

private actor CoordinatorTestGate {
    private var enteredCount = 0
    private var released = false
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { $0.0 <= enteredCount }
        enteredWaiters.removeAll { $0.0 <= enteredCount }
        ready.forEach { $0.1.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatorTestRecorder {
    private(set) var values: [String] = []

    var count: Int {
        values.count
    }

    func record(_ value: String) {
        values.append(value)
    }
}

private final class CoordinatorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(nowNanoseconds: UInt64 = 0) {
        value = nowNanoseconds
    }

    var clock: CodeMapArtifactBuildCoordinatorClock {
        CodeMapArtifactBuildCoordinatorClock { [self] in nowNanoseconds() }
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value += nanoseconds
        lock.unlock()
    }

    private func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor CoordinatorAdmissionRecorder {
    struct Entry {
        let ownerID: UUID
        let priority: TaskPriority
    }

    private(set) var entries: [Entry] = []

    func record(ownerID: UUID, priority: TaskPriority) {
        entries.append(Entry(ownerID: ownerID, priority: priority))
    }
}

private actor CoordinatorBuildRecorder {
    struct Entry: Equatable {
        let key: CodeMapArtifactKey
        let ownerID: UUID
        let priority: CodeMapArtifactBuildPriority
    }

    private(set) var entries: [Entry] = []

    func record(
        key: CodeMapArtifactKey,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) {
        entries.append(Entry(key: key, ownerID: ownerID, priority: priority))
    }
}

private actor CoordinatorLocatorReadScript {
    private var results: [GitBlobCodeMapLocatorReadResult]

    init(_ results: [GitBlobCodeMapLocatorReadResult]) {
        self.results = results
    }

    func next() -> GitBlobCodeMapLocatorReadResult {
        precondition(!results.isEmpty)
        return results.removeFirst()
    }
}

private actor CoordinatorFailOnce {
    private var remaining = 1

    func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

private actor CoordinatorHookRecorder {
    private(set) var events: [CodeMapArtifactBuildCoordinatorHookEvent] = []

    func append(_ event: CodeMapArtifactBuildCoordinatorHookEvent) {
        events.append(event)
    }
}

private extension [Task<CodeMapArtifactBuildCoordinatorResult, Error>] {
    func asyncValues() async throws -> [CodeMapArtifactBuildCoordinatorResult] {
        var results: [CodeMapArtifactBuildCoordinatorResult] = []
        for task in self {
            try await results.append(task.value)
        }
        return results
    }
}
