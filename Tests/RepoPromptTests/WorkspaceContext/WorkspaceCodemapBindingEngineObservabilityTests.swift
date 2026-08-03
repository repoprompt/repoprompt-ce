#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class WorkspaceCodemapBindingEngineObservabilityTests: CodemapBindingEngineTestCase {
        func testCompletedRetainedWorkerExposesMonotonicLifecycleAndReasonedEvents() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["README.md": "observability fixture\n"]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let clock = GraphObservabilityTestClock()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                uptimeNanoseconds: { clock.next() },
                projectionCatalogFactory: { rootEpoch, _ in
                    let token = WorkspaceCodemapGraphIndexCatalogToken(
                        rootEpoch: rootEpoch,
                        topologyGeneration: 1,
                        appliedIndexGeneration: 1,
                        catalogGeneration: 1,
                        ingressGeneration: 1,
                        graphIndexInvalidationGeneration: 1
                    )
                    return WorkspaceCodemapBindingCatalogClient {
                        _, _ in nil
                    } readGraphIndexCatalogPage: { request -> WorkspaceCodemapGraphIndexCatalogPageDisposition in
                        guard request.rootEpoch == rootEpoch,
                              request.token == nil || request.token == token
                        else { return .stale }
                        switch WorkspaceCodemapGraphIndexCatalogPage.validated(
                            request: request,
                            token: token,
                            entries: [],
                            nextCursor: nil,
                            isEnd: true,
                            supportedCandidateCountThroughPage: 0,
                            projectedSupportedCandidateTotal: 0
                        ) {
                        case let .success(page): return .page(page)
                        case .failure: return .unavailable(.catalogUnavailable)
                        }
                    } revalidateGraphIndexCatalogToken: { epoch, observed in
                        epoch == rootEpoch && observed == token ? .current : .stale
                    } publishMarkerReadiness: {
                        _ in true
                    }
                }
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let launch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(launch, WorkspaceCodemapGraphIndexLaunchPhase.handedOff)

            try await AsyncTestWait.waitUntil("retained graph worker completion", timeout: 10) {
                guard let job = await fixture.engine.debugGraphIndexJobSnapshot(
                    rootEpoch: fixture.rootEpoch
                ) else { return false }
                return job.phase == .complete && !job.workerPresent
            }
            let observedJob = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let job = try XCTUnwrap(observedJob)
            XCTAssertFalse(job.workerPresent)
            XCTAssertEqual(job.lastWorkerCompletionReason, .complete)
            XCTAssertNotNil(job.workerFinishedUptimeNanoseconds)
            XCTAssertLessThanOrEqual(job.scheduledUptimeNanoseconds, job.phaseEnteredUptimeNanoseconds)
            XCTAssertLessThanOrEqual(job.phaseEnteredUptimeNanoseconds, job.lastProgressUptimeNanoseconds)
            XCTAssertLessThanOrEqual(
                job.lastProgressUptimeNanoseconds,
                try XCTUnwrap(job.workerFinishedUptimeNanoseconds)
            )
            XCTAssertEqual(job.lastProjectedSupportedCandidateTotal, 0)
            XCTAssertNil(job.pageStartProcessedCandidateBaseline)
            XCTAssertEqual(job.pageOrdinal, 1)
            XCTAssertTrue(job.checkpointPresent)

            let eventPage = await fixture.engine.debugGraphIndexEvents(
                rootID: fixture.rootEpoch.rootID,
                sinceOrdinal: UInt64?.none,
                limit: 128
            )
            let events = eventPage.events
            XCTAssertEqual(eventPage.nextOrdinal, events.last?.ordinal)
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.scheduled })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.queued })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.admitted })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.pageAccepted })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.checkpointed })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.complete })
            XCTAssertTrue(events.contains { $0.reason == WorkspaceCodemapGraphIndexDebugReason.workerComplete })
            XCTAssertEqual(events.map(\.ordinal), events.map(\.ordinal).sorted())
        }

        func testDeadRetainedGraphWorkerReschedulesFromSameCheckpoint() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["README.md": "fixture"]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: emptyCatalogFactory()
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let acquiredHold = await fixture.engine.debugAcquireGraphIndexAdmissionHold(
                rootEpoch: fixture.rootEpoch,
                expiresAfterMilliseconds: 60000
            )
            let hold = try XCTUnwrap(acquiredHold)
            let initialLaunch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(initialLaunch, .handedOff)
            try await AsyncTestWait.waitUntil("graph worker admission queue", timeout: 5) {
                await fixture.engine.debugGraphIndexJobSnapshot(rootEpoch: fixture.rootEpoch)?
                    .isQueuedForAdmission == true
            }
            let originalSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let original = try XCTUnwrap(originalSnapshot)
            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .admissionUnavailable
            )
            let retainedSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let retained = try XCTUnwrap(retainedSnapshot)
            XCTAssertFalse(retained.workerPresent)
            XCTAssertEqual(retained.jobID, original.jobID)
            XCTAssertEqual(retained.lastWorkerCompletionReason, .admissionUnavailable)

            let restartLaunch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(restartLaunch, .handedOff)
            let restartedSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let restarted = try XCTUnwrap(restartedSnapshot)
            XCTAssertEqual(restarted.jobID, original.jobID)
            XCTAssertTrue(restarted.workerPresent)
            XCTAssertEqual(restarted.workerRecoveryCount, 1)
            _ = await fixture.engine.debugReleaseGraphIndexAdmissionHold(
                hold.holdID,
                rootEpoch: fixture.rootEpoch
            )
        }

        func testNoProgressWatchdogRecoveryIsBounded() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["README.md": "fixture"]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let policy = WorkspaceCodemapBindingEnginePolicy(
                graphIndexWorkerNoProgressTimeoutMilliseconds: 60000,
                maximumGraphIndexWorkerRecoveryCount: 2
            )
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                policy: policy,
                projectionCatalogFactory: emptyCatalogFactory()
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let recoveryUpdates = await fixture.engine.graphIndexWorkerRecoveryUpdates(
                rootEpoch: fixture.rootEpoch
            )
            var recoveryUpdateIterator = recoveryUpdates.makeAsyncIterator()
            let initialRecoveryUpdate = await recoveryUpdateIterator.next()
            XCTAssertEqual(initialRecoveryUpdate, .available)
            let acquiredHold = await fixture.engine.debugAcquireGraphIndexAdmissionHold(
                rootEpoch: fixture.rootEpoch,
                expiresAfterMilliseconds: 60000
            )
            let hold = try XCTUnwrap(acquiredHold)
            let initialLaunch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(initialLaunch, .handedOff)
            try await AsyncTestWait.waitUntil("graph worker admission queue", timeout: 5) {
                await fixture.engine.debugGraphIndexJobSnapshot(rootEpoch: fixture.rootEpoch)?
                    .isQueuedForAdmission == true
            }
            let originalJobSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let originalJob = try XCTUnwrap(originalJobSnapshot)
            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .admissionUnavailable
            )
            let installed = await fixture.engine.debugInstallNonCooperativeGraphIndexWorkerForTesting(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertTrue(installed)
            await fixture.engine.debugSetGraphIndexLastProgressForTesting(
                rootEpoch: fixture.rootEpoch,
                uptimeNanoseconds: 1
            )

            for expectedRecoveryCount in 1 ... 2 {
                let watchdogDisposition = await fixture.engine.debugEvaluateGraphIndexWatchdogForTesting(
                    rootEpoch: fixture.rootEpoch,
                    nowUptimeNanoseconds: 60_000_000_001
                )
                XCTAssertEqual(watchdogDisposition, .restartRequested)
                let recoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                    rootEpoch: fixture.rootEpoch
                )
                let recovery = try XCTUnwrap(recoveryState)
                XCTAssertEqual(recovery.count, UInt64(expectedRecoveryCount))
                XCTAssertFalse(recovery.exhausted)
                XCTAssertTrue(recovery.workerPresent)
                XCTAssertTrue(recovery.watchdogArmed)
            }

            let exhaustedDisposition = await fixture.engine.debugEvaluateGraphIndexWatchdogForTesting(
                rootEpoch: fixture.rootEpoch,
                nowUptimeNanoseconds: 60_000_000_001
            )
            XCTAssertEqual(exhaustedDisposition, .exhausted)
            let observedExhaustedSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let exhaustedSnapshot = try XCTUnwrap(observedExhaustedSnapshot)
            XCTAssertTrue(exhaustedSnapshot.workerPresent)
            XCTAssertEqual(exhaustedSnapshot.workerRecoveryCount, 2)
            XCTAssertEqual(exhaustedSnapshot.lastWorkerCompletionReason, .watchdogRecoveryExhausted)
            let exhaustedRecoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let exhaustedRecovery = try XCTUnwrap(exhaustedRecoveryState)
            XCTAssertTrue(exhaustedRecovery.exhausted)
            XCTAssertFalse(exhaustedRecovery.watchdogArmed)
            let exhaustedRecoveryUpdate = await recoveryUpdateIterator.next()
            XCTAssertEqual(exhaustedRecoveryUpdate, .exhausted)

            let quarantinedSchedule = await fixture.engine.scheduleGraphIndex(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(quarantinedSchedule, .handedOff)
            let quarantinedPrioritize = await fixture.engine.prioritizeGraphIndexNow(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(quarantinedPrioritize, .unavailable)
            let quarantinedRecoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let quarantinedRecovery = try XCTUnwrap(quarantinedRecoveryState)
            XCTAssertEqual(quarantinedRecovery.count, 2)
            XCTAssertTrue(quarantinedRecovery.exhausted)
            XCTAssertTrue(quarantinedRecovery.workerPresent)

            let drainRequested = await fixture.engine.debugDrainNonCooperativeGraphIndexWorkerForTesting(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertTrue(drainRequested)
            try await AsyncTestWait.waitUntil("exhausted graph worker drain", timeout: 5) {
                await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                    rootEpoch: fixture.rootEpoch
                )?.workerPresent == false
            }
            let drainedSchedule = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(drainedSchedule, .handedOff)
            let drainedRecoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let drainedRecovery = try XCTUnwrap(drainedRecoveryState)
            XCTAssertEqual(drainedRecovery.count, 2)
            XCTAssertTrue(drainedRecovery.exhausted)
            XCTAssertFalse(drainedRecovery.workerPresent)

            let restartDisposition = await fixture.engine.prioritizeGraphIndexNow(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(restartDisposition, .restarted)
            let restartedJobSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let restartedJob = try XCTUnwrap(restartedJobSnapshot)
            XCTAssertEqual(restartedJob.jobID, originalJob.jobID)
            XCTAssertEqual(restartedJob.checkpointPresent, originalJob.checkpointPresent)
            XCTAssertTrue(restartedJob.workerPresent)
            let resetRecoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let resetRecovery = try XCTUnwrap(resetRecoveryState)
            XCTAssertEqual(resetRecovery.count, 1)
            XCTAssertFalse(resetRecovery.exhausted)
            let resetRecoveryUpdate = await recoveryUpdateIterator.next()
            XCTAssertEqual(resetRecoveryUpdate, .available)

            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .admissionUnavailable
            )
            await fixture.engine.debugSetGraphIndexLastProgressForTesting(
                rootEpoch: fixture.rootEpoch,
                uptimeNanoseconds: 1
            )
            let maximumRecoveryDisposition = await fixture.engine.debugEvaluateGraphIndexWatchdogForTesting(
                rootEpoch: fixture.rootEpoch,
                nowUptimeNanoseconds: 60_000_000_001
            )
            XCTAssertEqual(maximumRecoveryDisposition, .restarted)
            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .admissionUnavailable
            )
            let installedRunningAtMaximum = await fixture.engine.debugInstallNonCooperativeGraphIndexWorkerForTesting(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertTrue(installedRunningAtMaximum)
            let runningAtMaximumState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let runningAtMaximum = try XCTUnwrap(runningAtMaximumState)
            XCTAssertEqual(runningAtMaximum.count, 2)
            XCTAssertFalse(runningAtMaximum.exhausted)
            XCTAssertTrue(runningAtMaximum.workerPresent)
            let runningAtMaximumPrioritize = await fixture.engine.prioritizeGraphIndexNow(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(runningAtMaximumPrioritize, .promoted)

            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .admissionUnavailable
            )
            let deadAtMaximumSchedule = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(deadAtMaximumSchedule, .handedOff)
            let deadAtMaximumState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let deadAtMaximum = try XCTUnwrap(deadAtMaximumState)
            XCTAssertEqual(deadAtMaximum.count, 2)
            XCTAssertFalse(deadAtMaximum.exhausted)
            XCTAssertFalse(deadAtMaximum.workerPresent)

            let deadAtMaximumPrioritize = await fixture.engine.prioritizeGraphIndexNow(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(deadAtMaximumPrioritize, .restarted)
            let resetAtMaximumState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let resetAtMaximum = try XCTUnwrap(resetAtMaximumState)
            XCTAssertEqual(resetAtMaximum.count, 1)
            XCTAssertFalse(resetAtMaximum.exhausted)
            XCTAssertTrue(resetAtMaximum.workerPresent)
            _ = await fixture.engine.debugReleaseGraphIndexAdmissionHold(
                hold.holdID,
                rootEpoch: fixture.rootEpoch
            )
        }

        func testLateTerminalWorkerCompletionClearsPublishedRecoveryExhaustion() async throws {
            let terminalCases: [
                (phase: WorkspaceCodemapGraphIndexPhase, reason: WorkspaceCodemapGraphIndexWorkerCompletionReason)
            ] = [
                (.complete, .complete),
                (.budgetLimited, .budgetLimited)
            ]

            for (index, terminalCase) in terminalCases.enumerated() {
                let repository = try makeRepositoryFixture(name: "\(#function)-\(index)")
                let root = try repository.makeRepository(
                    named: "repository",
                    files: ["README.md": "fixture"]
                )
                let runtime = try CodeMapArtifactRuntime(
                    rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
                )
                let policy = WorkspaceCodemapBindingEnginePolicy(
                    graphIndexWorkerNoProgressTimeoutMilliseconds: 60000,
                    maximumGraphIndexWorkerRecoveryCount: 1
                )
                let fixture = try await makeEngineFixture(
                    root: root,
                    runtime: runtime,
                    policy: policy,
                    projectionCatalogFactory: emptyCatalogFactory()
                )
                guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                    return XCTFail("Expected graph root registration.")
                }
                let recoveryUpdates = await fixture.engine.graphIndexWorkerRecoveryUpdates(
                    rootEpoch: fixture.rootEpoch
                )
                var recoveryUpdateIterator = recoveryUpdates.makeAsyncIterator()
                let initialRecoveryUpdate = await recoveryUpdateIterator.next()
                XCTAssertEqual(initialRecoveryUpdate, .available)
                let acquiredHold = await fixture.engine.debugAcquireGraphIndexAdmissionHold(
                    rootEpoch: fixture.rootEpoch,
                    expiresAfterMilliseconds: 60000
                )
                let hold = try XCTUnwrap(acquiredHold)
                let scheduleDisposition = await fixture.engine.scheduleGraphIndex(
                    rootEpoch: fixture.rootEpoch
                )
                XCTAssertEqual(scheduleDisposition, .handedOff)
                try await AsyncTestWait.waitUntil("graph worker admission queue", timeout: 5) {
                    await fixture.engine.debugGraphIndexJobSnapshot(rootEpoch: fixture.rootEpoch)?
                        .isQueuedForAdmission == true
                }
                await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                    rootEpoch: fixture.rootEpoch,
                    reason: .admissionUnavailable
                )
                let installedWorker = await fixture.engine.debugInstallNonCooperativeGraphIndexWorkerForTesting(
                    rootEpoch: fixture.rootEpoch,
                    completionReason: terminalCase.reason
                )
                XCTAssertTrue(installedWorker)
                await fixture.engine.debugSetGraphIndexLastProgressForTesting(
                    rootEpoch: fixture.rootEpoch,
                    uptimeNanoseconds: 1
                )
                let restartDisposition = await fixture.engine.debugEvaluateGraphIndexWatchdogForTesting(
                    rootEpoch: fixture.rootEpoch,
                    nowUptimeNanoseconds: 60_000_000_001
                )
                XCTAssertEqual(restartDisposition, .restartRequested)
                let exhaustionDisposition = await fixture.engine.debugEvaluateGraphIndexWatchdogForTesting(
                    rootEpoch: fixture.rootEpoch,
                    nowUptimeNanoseconds: 60_000_000_001
                )
                XCTAssertEqual(exhaustionDisposition, .exhausted)
                let exhaustionUpdate = await recoveryUpdateIterator.next()
                XCTAssertEqual(exhaustionUpdate, .exhausted)
                let setTerminalPhase = await fixture.engine.debugSetGraphIndexTerminalPhaseForTesting(
                    rootEpoch: fixture.rootEpoch,
                    phase: terminalCase.phase
                )
                XCTAssertTrue(setTerminalPhase)
                let drainRequested = await fixture.engine.debugDrainNonCooperativeGraphIndexWorkerForTesting(
                    rootEpoch: fixture.rootEpoch
                )
                XCTAssertTrue(drainRequested)
                try await AsyncTestWait.waitUntil("late terminal graph worker completion", timeout: 5) {
                    await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                        rootEpoch: fixture.rootEpoch
                    )?.workerPresent == false
                }
                let observedRecoveryState = await fixture.engine.debugGraphIndexWorkerRecoveryStateForTesting(
                    rootEpoch: fixture.rootEpoch
                )
                let recoveryState = try XCTUnwrap(observedRecoveryState)
                XCTAssertEqual(recoveryState.count, 0)
                XCTAssertFalse(recoveryState.exhausted)
                let availableUpdate = await recoveryUpdateIterator.next()
                XCTAssertEqual(availableUpdate, .available)
                let observedSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                    rootEpoch: fixture.rootEpoch
                )
                let snapshot = try XCTUnwrap(observedSnapshot)
                XCTAssertEqual(snapshot.phase, terminalCase.phase)
                XCTAssertEqual(snapshot.lastWorkerCompletionReason, terminalCase.reason)
                _ = await fixture.engine.debugReleaseGraphIndexAdmissionHold(
                    hold.holdID,
                    rootEpoch: fixture.rootEpoch
                )
            }
        }

        func testPrioritizeNowClearsBackoffRestartsDeadWorkerAndPromotesWithoutCatalogRead() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["README.md": "fixture"]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let reads = GraphCatalogReadCounter()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: emptyCatalogFactory(onRead: { reads.increment() })
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let acquiredHold = await fixture.engine.debugAcquireGraphIndexAdmissionHold(
                rootEpoch: fixture.rootEpoch,
                expiresAfterMilliseconds: 60000
            )
            let hold = try XCTUnwrap(acquiredHold)
            let initialLaunch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(initialLaunch, .handedOff)
            try await AsyncTestWait.waitUntil("graph worker admission queue", timeout: 5) {
                await fixture.engine.debugGraphIndexJobSnapshot(rootEpoch: fixture.rootEpoch)?
                    .isQueuedForAdmission == true
            }
            await fixture.engine.debugSetGraphIndexRetryForTesting(
                rootEpoch: fixture.rootEpoch,
                attempt: 4
            )
            await fixture.engine.debugSimulateGraphIndexWorkerExitForTesting(
                rootEpoch: fixture.rootEpoch,
                reason: .retryCancelled
            )

            let prioritizeDisposition = await fixture.engine.prioritizeGraphIndexNow(
                rootEpoch: fixture.rootEpoch
            )
            XCTAssertEqual(prioritizeDisposition, .restarted)
            let prioritizedSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let prioritized = try XCTUnwrap(prioritizedSnapshot)
            XCTAssertTrue(prioritized.workerPresent)
            XCTAssertEqual(prioritized.retryAttempt, 0)
            XCTAssertNil(prioritized.retry)
            XCTAssertTrue(prioritized.isPriorityPromoted)
            XCTAssertEqual(reads.value, 0)
            _ = await fixture.engine.debugReleaseGraphIndexAdmissionHold(
                hold.holdID,
                rootEpoch: fixture.rootEpoch
            )
        }

        func testSupersededWorkerExitRecordsReasonInsteadOfSilentRetainedState() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["README.md": "fixture"]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: { _, _ in
                    WorkspaceCodemapBindingCatalogClient { _, _ in nil } readGraphIndexCatalogPage: { _ in
                        .stale
                    } revalidateGraphIndexCatalogToken: { _, _ in
                        .stale
                    } publishMarkerReadiness: { _ in true }
                }
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let launch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(launch, .handedOff)
            try await AsyncTestWait.waitUntil("superseded graph worker exit", timeout: 5) {
                guard let job = await fixture.engine.debugGraphIndexJobSnapshot(rootEpoch: fixture.rootEpoch) else {
                    return false
                }
                return job.phase == .superseded && !job.workerPresent
            }
            let finalSnapshot = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let job = try XCTUnwrap(finalSnapshot)
            XCTAssertEqual(job.lastWorkerCompletionReason, .superseded)
            let events = await fixture.engine.debugGraphIndexEvents(
                rootID: fixture.rootEpoch.rootID,
                sinceOrdinal: nil,
                limit: 128
            )
            XCTAssertTrue(events.events.contains { $0.reason == .workerSuperseded })
        }

        func testManifestFailureClassifierUsesBoundedPrivacySafeReasonTags() {
            let cases: [(Error, WorkspaceCodemapManifestFailureReason, String?)] = [
                (CodeMapRootManifestModelError.staleAuthority, .staleAuthority, nil),
                (CodeMapRootManifestStoreError.staleWriterAuthority, .staleWriterAuthority, nil),
                (CodeMapRootManifestStoreError.quotaExceeded, .quotaExceeded, nil),
                (CodeMapRootManifestModelError.corruptRecord, .corruptRecord, nil),
                (CodeMapRootManifestModelError.invalidContribution, .invalidContribution, nil),
                (CodeMapRootManifestModelError.inputTooLarge, .inputTooLarge, nil),
                (CodeMapRootManifestStoreError.insecureDirectory, .insecureDirectory, nil),
                (CodeMapRootManifestStoreError.insecureLeaf, .insecureLeaf, nil),
                (
                    CodeMapRootManifestStoreError.ioFailure(operation: "manifest-publish", code: EIO),
                    .ioFailure,
                    "manifest-publish"
                ),
                (
                    CodeMapRootManifestStoreError.ioFailure(operation: "/private/user/path", code: EIO),
                    .ioFailure,
                    "other"
                ),
                (
                    CodeMapRootManifestStoreError.ioFailure(operation: "customer_secret_filename", code: EIO),
                    .ioFailure,
                    "other"
                ),
                (CancellationError(), .cancellation, nil),
                (CodeMapRootManifestModelError.invalidAuthority, .other, nil)
            ]

            for (error, expectedReason, expectedOperation) in cases {
                let classified = WorkspaceCodemapManifestFailureClassifier.classify(error)
                XCTAssertEqual(classified.reason, expectedReason)
                XCTAssertEqual(classified.operation, expectedOperation)
            }
            XCTAssertTrue(WorkspaceCodemapManifestFailureReason.allCases.contains(.backpressure))
        }

        func testGraphIndexStaleManifestLoadLiftsAuthorityBeforeRecordsAreMinted() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let path = "Sources/Feature.swift"
            let root = try repository.makeRepository(
                named: "repository",
                files: [path: SwiftFixtureSource.emptyStruct("Feature")]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let baseline = try await makeEngineFixture(root: root, runtime: runtime)
            let capability = try await eligible(baseline.capabilityService.resolve(
                root: baseline.registration.capabilityRequest
            ))
            let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            let namespace = try CodeMapRootManifestNamespace(
                capability: capability,
                pipelineIdentity: pipelineIdentity
            )
            let current = try CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            )
            let stale = try CodeMapRootManifestAuthority(
                authorityGeneration: current.authorityGeneration,
                repositoryBindingEpoch: current.repositoryBindingEpoch,
                worktreeBindingEpoch: current.worktreeBindingEpoch,
                layoutGeneration: current.layoutGeneration,
                indexGeneration: "graph-index-observed-stale",
                checkoutConfigurationGeneration: current.checkoutConfigurationGeneration,
                attributeGeneration: current.attributeGeneration,
                sparseGeneration: current.sparseGeneration,
                metadataGeneration: current.metadataGeneration
            )
            guard case .registered = await baseline.engine.registerRoot(baseline.registration) else {
                return XCTFail("Expected baseline root registration.")
            }
            guard await isReady(baseline.engine.demand(baseline.demand(path: path))) else {
                return XCTFail("Expected baseline manifest persistence.")
            }
            guard case let .hit(snapshot) = try await runtime.manifestStore.loadCurrentManifest(
                namespace: namespace,
                currentAuthority: current
            ) else {
                return XCTFail("Expected baseline manifest snapshot.")
            }
            let staleRecords = try await rebindManifestRecords(
                snapshot.records,
                namespace: namespace,
                authority: stale,
                runtime: runtime
            )
            _ = try await runtime.manifestStore.removeNamespace(namespace)
            _ = try await runtime.manifestStore.updateCurrentManifest(
                namespace: namespace,
                authority: stale,
                records: staleRecords,
                lastAccessEpochSeconds: 1
            )
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: pagedCatalogFactory(root: root, paths: [path])
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let launch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(launch, .handedOff)
            try await AsyncTestWait.waitUntil("graph stale authority lift completion", timeout: 15) {
                guard let job = await fixture.engine.debugGraphIndexJobSnapshot(
                    rootEpoch: fixture.rootEpoch
                ) else { return false }
                return job.phase == .complete && !job.workerPresent
            }
            let authoritySnapshot = await fixture.engine.debugManifestAuthoritySnapshot(
                rootEpoch: fixture.rootEpoch,
                pipelineIdentity: pipelineIdentity
            )
            let authority = try XCTUnwrap(authoritySnapshot)
            XCTAssertEqual(authority.current.authorityGeneration, current.authorityGeneration + 1)
            XCTAssertEqual(authority.current.indexGeneration, current.indexGeneration)
            let accounting = await fixture.engine.accounting()
            XCTAssertEqual(accounting.counters.manifestWrites, 1)
            XCTAssertEqual(accounting.counters.manifestFailures, 0)
        }

        func testVirginManifestAuthorityLiftAdvancesSameGenerationPredecessorOnce() async throws {
            try await assertVirginManifestAuthorityLift(observedGeneration: nil)
        }

        func testVirginManifestAuthorityLiftAdvancesGenerationSevenToEight() async throws {
            try await assertVirginManifestAuthorityLift(observedGeneration: 7)
        }

        func testWarmManifestHitDoesNotLiftAuthority() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let baseline = try await makeEngineFixture(root: root, runtime: runtime)
            let capability = try await eligible(baseline.capabilityService.resolve(
                root: baseline.registration.capabilityRequest
            ))
            let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            let namespace = try CodeMapRootManifestNamespace(
                capability: capability,
                pipelineIdentity: pipelineIdentity
            )
            let authority = try CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            )
            guard case .registered = await baseline.engine.registerRoot(baseline.registration) else {
                return XCTFail("Expected baseline root registration.")
            }
            guard await isReady(baseline.engine.demand(
                baseline.demand(path: "Sources/Feature.swift")
            )) else {
                return XCTFail("Expected baseline manifest persistence.")
            }

            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: pagedCatalogFactory(
                    root: root,
                    paths: ["Sources/Feature.swift"]
                )
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let launch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(launch, .handedOff)
            try await AsyncTestWait.waitUntil("warm graph manifest completion", timeout: 15) {
                guard let job = await fixture.engine.debugGraphIndexJobSnapshot(
                    rootEpoch: fixture.rootEpoch
                ) else { return false }
                return job.phase == .complete && !job.workerPresent
            }
            let observedSnapshot = await fixture.engine.debugManifestAuthoritySnapshot(
                rootEpoch: fixture.rootEpoch,
                pipelineIdentity: pipelineIdentity
            )
            let observed = try XCTUnwrap(observedSnapshot)
            XCTAssertEqual(observed.current, authority)
            XCTAssertEqual(observed.observedPredecessor, authority)
        }

        func testObservedFutureAuthorityFailureTerminallyDiscardsWithoutRetry() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository",
                files: [
                    "Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature"),
                    "Sources/Second.swift": SwiftFixtureSource.emptyStruct("Second")
                ]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let clock = GraphObservabilityTestClock()
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                uptimeNanoseconds: { clock.next() }
            )
            let capability = try await eligible(fixture.capabilityService.resolve(
                root: fixture.registration.capabilityRequest
            ))
            let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            let namespace = try CodeMapRootManifestNamespace(
                capability: capability,
                pipelineIdentity: pipelineIdentity
            )
            let currentToken = capability.repositoryAuthority
            let futureToken = WorkspaceCodemapRepositoryAuthorityToken(
                authorityGeneration: currentToken.authorityGeneration + 1,
                repositoryNamespace: currentToken.repositoryNamespace,
                objectFormat: currentToken.objectFormat,
                repositoryBindingEpoch: currentToken.repositoryBindingEpoch,
                worktreeBindingEpoch: currentToken.worktreeBindingEpoch,
                layoutGeneration: currentToken.layoutGeneration,
                indexGeneration: currentToken.indexGeneration,
                checkoutConfigurationGeneration: currentToken.checkoutConfigurationGeneration,
                attributeGeneration: currentToken.attributeGeneration,
                sparseGeneration: currentToken.sparseGeneration,
                metadataGeneration: currentToken.metadataGeneration
            )
            let futureAuthority = try CodeMapRootManifestAuthority(
                namespace: namespace,
                token: futureToken
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            guard case .ready = await fixture.engine.demand(
                fixture.demand(path: "Sources/Feature.swift")
            ) else {
                return XCTFail("Expected initial manifest persistence.")
            }
            _ = try await runtime.manifestStore.updateCurrentManifest(
                namespace: namespace,
                authority: futureAuthority,
                records: [],
                lastAccessEpochSeconds: 1
            )
            guard case .ready = await fixture.engine.demand(
                fixture.demand(path: "Sources/Second.swift")
            ) else {
                return XCTFail("Expected overlay readiness despite terminal manifest cache failure.")
            }

            let accounting = await fixture.engine.accounting()
            XCTAssertEqual(accounting.counters.manifestWrites, 1)
            XCTAssertEqual(accounting.counters.manifestFailures, 1)
            XCTAssertEqual(accounting.counters.manifestWriteBatches, 2)
            XCTAssertEqual(accounting.counters.manifestWriteRetries, 0)
            XCTAssertEqual(accounting.counters.manifestWriteItems, 2)

            let manifest = await fixture.engine.debugManifestFailureSnapshot(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(manifest.counts[.staleAuthority], 1)
            let lastFailure = try XCTUnwrap(manifest.lastFailure)
            XCTAssertEqual(lastFailure.reason, .staleAuthority)
            XCTAssertEqual(lastFailure.currentAuthorityGeneration, currentToken.authorityGeneration)
            XCTAssertEqual(
                lastFailure.observedPredecessorAuthorityGeneration,
                futureToken.authorityGeneration
            )
            XCTAssertGreaterThan(lastFailure.attemptDurationNanoseconds, 0)
            XCTAssertEqual(
                lastFailure.attemptDurationNanoseconds,
                lastFailure.attemptCompletedUptimeNanoseconds -
                    lastFailure.attemptStartedUptimeNanoseconds
            )

            let eventPage = await fixture.engine.debugGraphIndexEvents(
                rootID: fixture.rootEpoch.rootID,
                sinceOrdinal: UInt64?.none,
                limit: 128
            )
            let failures = eventPage.events.filter { $0.kind == .manifestFailure }
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures.allSatisfy { $0.manifestFailureReason == .staleAuthority })
            XCTAssertTrue(failures.allSatisfy {
                $0.currentAuthorityGeneration == currentToken.authorityGeneration &&
                    $0.observedPredecessorAuthorityGeneration == futureToken.authorityGeneration &&
                    ($0.manifestAttemptDurationNanoseconds ?? 0) > 0
            })
        }

        func testGraphIndexManifestPersistenceOccursOnceAtEnumerationSeal() async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let paths = (0 ..< 2).map { "Sources/Feature\($0).swift" }
            let root = try repository.makeRepository(
                named: "repository",
                files: Dictionary(uniqueKeysWithValues: paths.enumerated().map { index, path in
                    (path, SwiftFixtureSource.emptyStruct("Feature\(index)"))
                })
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let fixture = try await makeEngineFixture(
                root: root,
                runtime: runtime,
                projectionCatalogFactory: pagedCatalogFactory(root: root, paths: paths, pageSize: 1)
            )
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            let launch = await fixture.engine.scheduleGraphIndex(rootEpoch: fixture.rootEpoch)
            XCTAssertEqual(launch, .handedOff)
            try await AsyncTestWait.waitUntil("graph manifest red characterization", timeout: 30) {
                guard let job = await fixture.engine.debugGraphIndexJobSnapshot(
                    rootEpoch: fixture.rootEpoch
                ) else { return false }
                return job.phase == .complete && !job.workerPresent
            }
            let counters = await fixture.engine.accounting().counters
            XCTAssertEqual(counters.graphIndexCatalogPages, 2)
            XCTAssertEqual(counters.graphIndexPageManifestLoads, 1)
            XCTAssertEqual(counters.graphIndexPageManifestSubmissions, 0)
            XCTAssertEqual(counters.graphIndexPageManifestWaits, 0)
            XCTAssertEqual(counters.graphIndexPageManifestWrites, 0)
            XCTAssertEqual(counters.graphIndexPageManifestSnapshotRecordVolume, 0)
            XCTAssertEqual(counters.graphIndexPageManifestSnapshotByteVolume, 0)
            XCTAssertEqual(counters.graphIndexSealManifestSubmissions, 1)
            XCTAssertEqual(counters.graphIndexSealManifestWaits, 1)
            XCTAssertEqual(counters.graphIndexSealManifestWrites, 1)
            let retainedManifestSnapshot = await fixture.engine.debugGraphIndexManifestRetentionForTesting(
                rootEpoch: fixture.rootEpoch
            )
            let retainedManifest = try XCTUnwrap(retainedManifestSnapshot)
            XCTAssertEqual(retainedManifest.stageCount, 0)
            XCTAssertEqual(retainedManifest.cachedRecordCount, 0)
            XCTAssertEqual(retainedManifest.stagedRecordCount, 0)
            XCTAssertEqual(retainedManifest.stagedByteCount, 0)
            XCTAssertEqual(retainedManifest.globalStagedByteCount, 0)

            let observedJob = await fixture.engine.debugGraphIndexJobSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let job = try XCTUnwrap(observedJob)
            let jobMeasurements = job.manifestMeasurements
            XCTAssertEqual(jobMeasurements.loadCount, 1)
            XCTAssertEqual(jobMeasurements.submissionCount, 1)
            XCTAssertEqual(jobMeasurements.waitCount, 1)
            XCTAssertEqual(jobMeasurements.storeAttemptCount, 1)
            XCTAssertEqual(jobMeasurements.writeCount, 1)
            XCTAssertEqual(jobMeasurements.failureCount, 0)
            XCTAssertEqual(jobMeasurements.retryAttemptCount, 0)
            XCTAssertEqual(jobMeasurements.mutationCountVolume, 2)
            XCTAssertGreaterThan(jobMeasurements.mutationByteVolume, 0)
            XCTAssertEqual(jobMeasurements.inputSnapshotRecordVolume, 0)
            XCTAssertEqual(jobMeasurements.attemptedOutputSnapshotRecordVolume, 2)
            XCTAssertEqual(jobMeasurements.outputSnapshotRecordVolume, 2)
            XCTAssertEqual(jobMeasurements.inputSnapshotByteVolume, 0)
            XCTAssertGreaterThanOrEqual(jobMeasurements.decodedByteVolume, 0)
            XCTAssertGreaterThan(jobMeasurements.outputSnapshotByteVolume, 0)

            let rootMeasurements = await fixture.engine.debugManifestMeasurementSnapshot(
                rootEpoch: fixture.rootEpoch
            )
            let pageMeasurements = try XCTUnwrap(rootMeasurements.byOrigin[.page])
            XCTAssertEqual(pageMeasurements.loadCount, 1)
            XCTAssertEqual(pageMeasurements.submissionCount, 0)
            XCTAssertEqual(pageMeasurements.waitCount, 0)
            XCTAssertEqual(pageMeasurements.storeAttemptCount, 0)
            XCTAssertEqual(pageMeasurements.writeCount, 0)
            let sealMeasurements = try XCTUnwrap(rootMeasurements.byOrigin[.seal])
            XCTAssertEqual(sealMeasurements.loadCount, 0)
            XCTAssertEqual(sealMeasurements.submissionCount, 1)
            XCTAssertEqual(sealMeasurements.waitCount, 1)
            XCTAssertEqual(sealMeasurements.storeAttemptCount, 1)
            XCTAssertEqual(sealMeasurements.writeCount, 1)
            XCTAssertNil(rootMeasurements.byOrigin[.adoption])
            XCTAssertNil(rootMeasurements.byOrigin[.demand])

            let events = await fixture.engine.debugGraphIndexEvents(
                rootID: fixture.rootEpoch.rootID,
                sinceOrdinal: nil,
                limit: 128
            ).events.filter { $0.kind == .manifestStoreAttempt }
            XCTAssertEqual(events.count, 1)
            for event in events {
                XCTAssertEqual(event.manifestMeasurementOrigin, .seal)
                XCTAssertEqual(
                    event.manifestMeasurementRetryKind,
                    WorkspaceCodemapManifestMeasurementRetryKind.none
                )
                XCTAssertGreaterThan(event.manifestMutationByteCount ?? 0, 0)
                XCTAssertEqual(event.manifestStoreAttempt?.published, true)
            }
            let attempts = events.compactMap(\.manifestStoreAttempt)
            XCTAssertEqual(attempts.map(\.outputSnapshotRecordCount), [2])
            XCTAssertEqual(
                jobMeasurements.totalDurationNanoseconds,
                attempts.reduce(UInt64(0)) { partial, attempt in
                    let (sum, overflow) = partial.addingReportingOverflow(
                        attempt.totalDurationNanoseconds
                    )
                    return overflow ? .max : sum
                }
            )
        }

        private func rebindManifestRecords(
            _ records: [CodeMapRootManifestRecord],
            namespace: CodeMapRootManifestNamespace,
            authority: CodeMapRootManifestAuthority,
            runtime: CodeMapArtifactRuntime
        ) async throws -> [CodeMapRootManifestRecord] {
            var rebound: [CodeMapRootManifestRecord] = []
            rebound.reserveCapacity(records.count)
            for record in records {
                let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                    ownerID: UUID(),
                    priority: .explicit,
                    target: .artifactKey(record.artifactKey)
                ))
                guard case let .ready(resolution) = result else {
                    throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
                }
                let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                    identity: record.locatorIdentity,
                    artifactKey: record.artifactKey,
                    casHandle: resolution.handle
                )
                let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
                case let .ready(artifact):
                    CodeMapSelectionGraphContribution(
                        artifactKey: association.artifactKey,
                        artifact: artifact
                    )
                case .readyNoSymbols:
                    CodeMapSelectionGraphContribution(
                        artifactKey: association.artifactKey,
                        definitions: [],
                        references: []
                    )
                case .oversize, .decodeFailed, .parseFailed:
                    nil
                }
                try rebound.append(CodeMapRootManifestRecord.verifiedClean(
                    namespace: namespace,
                    repositoryRelativePath: record.repositoryRelativePath,
                    gitMode: record.gitMode,
                    association: association,
                    contribution: contribution,
                    authority: authority,
                    bindingGeneration: record.bindingGeneration
                ))
            }
            return rebound
        }

        private func pagedCatalogFactory(
            root: URL,
            paths: [String],
            availableCount: Int? = nil,
            pageSize: Int? = nil
        ) -> (WorkspaceCodemapRootEpoch, EngineFileIDs) -> WorkspaceCodemapBindingCatalogClient {
            { rootEpoch, fileIDs in
                let token = WorkspaceCodemapGraphIndexCatalogToken(
                    rootEpoch: rootEpoch,
                    topologyGeneration: 1,
                    appliedIndexGeneration: 1,
                    catalogGeneration: 1,
                    ingressGeneration: 1,
                    graphIndexInvalidationGeneration: 1
                )
                let candidates = paths.map { path in
                    let identity = WorkspaceCodemapArtifactBindingIdentity(
                        rootID: rootEpoch.rootID,
                        rootLifetimeID: rootEpoch.rootLifetimeID,
                        fileID: fileIDs.id(for: path),
                        standardizedRootPath: root.path,
                        standardizedRelativePath: path,
                        standardizedFullPath: root.appendingPathComponent(path).path
                    )!
                    return WorkspaceCodemapGraphIndexCatalogCandidate(
                        identity: identity,
                        language: .swift,
                        requestGeneration: 1,
                        pathGeneration: 1
                    )
                }
                return WorkspaceCodemapBindingCatalogClient {
                    _, _ in nil
                } readGraphIndexCatalogPage: { request in
                    guard request.rootEpoch == rootEpoch,
                          request.token == nil || request.token == token
                    else { return .stale }
                    let start: Int
                    if let cursor = request.cursor {
                        guard let index = candidates.firstIndex(where: {
                            $0.identity.standardizedRelativePath == cursor.standardizedRelativePath &&
                                $0.identity.fileID == cursor.fileID
                        }) else { return .stale }
                        start = index + 1
                    } else {
                        start = 0
                    }
                    let visibleEnd = min(candidates.count, availableCount ?? candidates.count)
                    guard start < visibleEnd || visibleEnd == candidates.count else {
                        return .unavailable(.catalogUnavailable)
                    }
                    let end = min(
                        visibleEnd,
                        start + min(request.maximumEntryCount, pageSize ?? request.maximumEntryCount)
                    )
                    let entries = Array(candidates[start ..< end])
                    let isEnd = end == candidates.count
                    let nextCursor = isEnd ? nil : entries.last.map {
                        WorkspaceCodemapGraphIndexCatalogCursor(
                            standardizedRelativePath: $0.identity.standardizedRelativePath,
                            fileID: $0.identity.fileID
                        )
                    }
                    switch WorkspaceCodemapGraphIndexCatalogPage.validated(
                        request: request,
                        token: token,
                        entries: entries,
                        nextCursor: nextCursor,
                        isEnd: isEnd,
                        supportedCandidateCountThroughPage: UInt64(end),
                        projectedSupportedCandidateTotal: UInt64(candidates.count)
                    ) {
                    case let .success(page): return .page(page)
                    case .failure: return .unavailable(.catalogUnavailable)
                    }
                } revalidateGraphIndexCatalogToken: { epoch, observed in
                    epoch == rootEpoch && observed == token ? .current : .stale
                } publishMarkerReadiness: {
                    _ in true
                }
            }
        }

        private func emptyCatalogFactory(
            onRead: @escaping @Sendable () -> Void = {}
        ) -> (WorkspaceCodemapRootEpoch, EngineFileIDs) -> WorkspaceCodemapBindingCatalogClient {
            { rootEpoch, _ in
                let token = WorkspaceCodemapGraphIndexCatalogToken(
                    rootEpoch: rootEpoch,
                    topologyGeneration: 1,
                    appliedIndexGeneration: 1,
                    catalogGeneration: 1,
                    ingressGeneration: 1,
                    graphIndexInvalidationGeneration: 1
                )
                return WorkspaceCodemapBindingCatalogClient { _, _ in nil } readGraphIndexCatalogPage: { request in
                    onRead()
                    guard request.rootEpoch == rootEpoch else { return .stale }
                    return switch WorkspaceCodemapGraphIndexCatalogPage.validated(
                        request: request,
                        token: token,
                        entries: [],
                        nextCursor: nil,
                        isEnd: true,
                        supportedCandidateCountThroughPage: 0,
                        projectedSupportedCandidateTotal: 0
                    ) {
                    case let .success(page): .page(page)
                    case .failure: .unavailable(.catalogUnavailable)
                    }
                } revalidateGraphIndexCatalogToken: { epoch, observed in
                    epoch == rootEpoch && observed == token ? .current : .stale
                } publishMarkerReadiness: { _ in true }
            }
        }

        private func assertVirginManifestAuthorityLift(
            observedGeneration: UInt64?
        ) async throws {
            let repository = try makeRepositoryFixture(name: #function)
            let root = try repository.makeRepository(
                named: "repository-\(observedGeneration ?? 1)",
                files: ["Sources/Feature.swift": SwiftFixtureSource.emptyStruct("Feature")]
            )
            let runtime = try CodeMapArtifactRuntime(
                rootURL: makeSecureDirectory(in: repository.sandbox, named: "artifacts")
            )
            let baseline = try await makeEngineFixture(root: root, runtime: runtime)
            let capability = try await eligible(baseline.capabilityService.resolve(
                root: baseline.registration.capabilityRequest
            ))
            let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            let namespace = try CodeMapRootManifestNamespace(
                capability: capability,
                pipelineIdentity: pipelineIdentity
            )
            let current = try CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            )
            let predecessorGeneration = observedGeneration ?? current.authorityGeneration
            let predecessor = try CodeMapRootManifestAuthority(
                authorityGeneration: predecessorGeneration,
                repositoryBindingEpoch: current.repositoryBindingEpoch,
                worktreeBindingEpoch: current.worktreeBindingEpoch,
                layoutGeneration: current.layoutGeneration,
                indexGeneration: "observed-stale-index-\(predecessorGeneration)",
                checkoutConfigurationGeneration: current.checkoutConfigurationGeneration,
                attributeGeneration: current.attributeGeneration,
                sparseGeneration: current.sparseGeneration,
                metadataGeneration: current.metadataGeneration
            )
            guard case .registered = await baseline.engine.registerRoot(baseline.registration) else {
                return XCTFail("Expected baseline root registration.")
            }
            guard await isReady(baseline.engine.demand(
                baseline.demand(path: "Sources/Feature.swift")
            )) else {
                return XCTFail("Expected baseline manifest persistence.")
            }
            guard case let .hit(snapshot) = try await runtime.manifestStore.loadCurrentManifest(
                namespace: namespace,
                currentAuthority: current
            ) else {
                return XCTFail("Expected baseline manifest snapshot.")
            }
            await runtime.manifestStore.waitForPendingAccessRefreshesForTesting()
            let predecessorRecords = try await rebindManifestRecords(
                snapshot.records,
                namespace: namespace,
                authority: predecessor,
                runtime: runtime
            )
            _ = try await runtime.manifestStore.removeNamespace(namespace)
            let predecessorWrite = try await runtime.manifestStore.updateCurrentManifest(
                namespace: namespace,
                authority: predecessor,
                records: predecessorRecords,
                lastAccessEpochSeconds: 1
            )
            guard case .inserted = predecessorWrite else {
                return XCTFail("Expected synthetic predecessor manifest write.")
            }
            guard case let .stale(installedAuthority) = try await runtime.manifestStore.loadCurrentManifest(
                namespace: namespace,
                currentAuthority: current
            ) else {
                return XCTFail("Expected synthetic predecessor manifest to load as stale.")
            }
            XCTAssertEqual(installedAuthority, predecessor)

            let fixture = try await makeEngineFixture(root: root, runtime: runtime)
            guard case .registered = await fixture.engine.registerRoot(fixture.registration) else {
                return XCTFail("Expected graph root registration.")
            }
            guard await isReady(fixture.engine.demand(
                fixture.demand(path: "Sources/Feature.swift", priority: .explicit)
            )) else {
                return XCTFail("Expected explicit readiness after authority lift.")
            }
            let authoritySnapshot = await fixture.engine.debugManifestAuthoritySnapshot(
                rootEpoch: fixture.rootEpoch,
                pipelineIdentity: pipelineIdentity
            )
            let authority = try XCTUnwrap(authoritySnapshot)
            XCTAssertEqual(authority.current.authorityGeneration, predecessorGeneration + 1)
            XCTAssertEqual(authority.current.repositoryBindingEpoch, current.repositoryBindingEpoch)
            XCTAssertEqual(authority.current.worktreeBindingEpoch, current.worktreeBindingEpoch)
            XCTAssertEqual(authority.current.layoutGeneration, current.layoutGeneration)
            XCTAssertEqual(authority.current.indexGeneration, current.indexGeneration)
            XCTAssertEqual(authority.current.checkoutConfigurationGeneration, current.checkoutConfigurationGeneration)
            XCTAssertEqual(authority.current.attributeGeneration, current.attributeGeneration)
            XCTAssertEqual(authority.current.sparseGeneration, current.sparseGeneration)
            XCTAssertEqual(authority.current.metadataGeneration, current.metadataGeneration)
            XCTAssertEqual(authority.observedPredecessor, predecessor)

            guard await isReady(fixture.engine.demand(
                fixture.demand(path: "Sources/Feature.swift")
            )) else {
                return XCTFail("Expected idempotent second demand readiness.")
            }
            let secondSnapshot = await fixture.engine.debugManifestAuthoritySnapshot(
                rootEpoch: fixture.rootEpoch,
                pipelineIdentity: pipelineIdentity
            )
            let second = try XCTUnwrap(secondSnapshot)
            XCTAssertEqual(second.current, authority.current)
            let accounting = await fixture.engine.accounting()
            XCTAssertEqual(accounting.counters.manifestWrites, 1)
            XCTAssertEqual(accounting.counters.manifestFailures, 0)
        }
    }

    private final class GraphCatalogReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.withLock { storage }
        }

        func increment() {
            lock.withLock { storage += 1 }
        }
    }

    private final class GraphObservabilityTestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000_000

        func next() -> UInt64 {
            lock.withLock {
                value += 1_000_000
                return value
            }
        }
    }
#endif
