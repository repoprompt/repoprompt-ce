#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class WorkspaceCodemapGraphIndexDebugEventRingTests: XCTestCase {
        func testRingCoalescesEligibleEventsAndPreservesReasonBoundaries() throws {
            var ring = WorkspaceCodemapGraphIndexDebugEventRing()
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let jobID = UUID()

            ring.append(draft(
                uptime: 10,
                kind: .graphIndexCatalogCandidates,
                rootEpoch: rootEpoch,
                jobID: jobID,
                numericValue: 3
            ))
            let firstCursor = try XCTUnwrap(ring.page(sinceOrdinal: nil, limit: 10).nextOrdinal)
            ring.append(draft(
                uptime: 20,
                kind: .graphIndexCatalogCandidates,
                rootEpoch: rootEpoch,
                jobID: jobID,
                numericValue: 5
            ))
            let coalescedDelta = ring.page(sinceOrdinal: firstCursor, limit: 10)
            XCTAssertEqual(coalescedDelta.events.count, 1)
            XCTAssertEqual(coalescedDelta.events[0].numericValue, 8)
            XCTAssertGreaterThan(coalescedDelta.events[0].ordinal, firstCursor)
            ring.append(draft(
                uptime: 30,
                kind: .graphIndexRetry,
                rootEpoch: rootEpoch,
                jobID: jobID,
                numericValue: 1,
                reason: .retry
            ))

            let page = ring.page(sinceOrdinal: nil, limit: 10)
            XCTAssertEqual(page.events.count, 2)
            XCTAssertEqual(page.events[0].numericValue, 8)
            XCTAssertEqual(page.events[0].coalescedCount, 2)
            XCTAssertEqual(page.events[0].uptimeNanoseconds, 20)
            XCTAssertEqual(page.events[1].reason, .retry)
            XCTAssertLessThan(page.events[0].ordinal, page.events[1].ordinal)
            XCTAssertEqual(page.nextOrdinal, page.events.last?.ordinal)

            var attempt = CodeMapRootManifestDebugAttemptMetrics(
                ordinal: 1,
                startedUptimeNanoseconds: 40
            )
            attempt.completedUptimeNanoseconds = 50
            attempt.succeeded = true
            attempt.published = true
            attempt.mutationCount = 1
            attempt.outputSnapshotRecordCount = 2
            attempt.outputSnapshotEncodedByteCount = 256
            attempt.totalDurationNanoseconds = 10
            for uptime in [UInt64(50), 60] {
                ring.append(draft(
                    uptime: uptime,
                    kind: .manifestStoreAttempt,
                    rootEpoch: rootEpoch,
                    jobID: jobID,
                    numericValue: 1,
                    manifestMeasurementOrigin: .page,
                    manifestMeasurementRetryKind: .deferred,
                    manifestMutationByteCount: 64,
                    manifestStoreAttempt: attempt
                ))
            }
            let measurementPage = ring.page(sinceOrdinal: page.nextOrdinal, limit: 10)
            XCTAssertEqual(measurementPage.events.count, 2)
            XCTAssertTrue(measurementPage.events.allSatisfy { $0.coalescedCount == 1 })
            XCTAssertTrue(measurementPage.events.allSatisfy {
                $0.manifestMeasurementOrigin == .page &&
                    $0.manifestMeasurementRetryKind == .deferred &&
                    $0.manifestMutationByteCount == 64 &&
                    $0.manifestStoreAttempt == attempt
            })
        }

        func testRingBoundsOverwriteAndPagesByExclusiveOrdinal() throws {
            var ring = WorkspaceCodemapGraphIndexDebugEventRing()
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            for index in 0 ..< WorkspaceCodemapGraphIndexDebugEventRing.capacity + 7 {
                ring.append(draft(
                    uptime: UInt64(index + 1),
                    kind: .graphIndexPhaseEntered,
                    rootEpoch: rootEpoch,
                    jobID: UUID(),
                    numericValue: UInt64(index),
                    reason: .phaseEntered
                ))
            }

            let complete = ring.page(sinceOrdinal: nil, limit: 1024)
            XCTAssertEqual(complete.events.count, WorkspaceCodemapGraphIndexDebugEventRing.capacity)
            XCTAssertGreaterThan(complete.firstOrdinal, 1)
            XCTAssertEqual(complete.lastOrdinal, UInt64(WorkspaceCodemapGraphIndexDebugEventRing.capacity + 7))
            XCTAssertEqual(complete.nextOrdinal, complete.events.last?.ordinal)
            XCTAssertEqual(complete.nextOrdinal, complete.lastOrdinal)

            let cursor = try XCTUnwrap(complete.events.dropFirst(10).first?.ordinal)
            let paged = ring.page(sinceOrdinal: cursor, limit: 3)
            XCTAssertEqual(paged.events.count, 3)
            XCTAssertTrue(paged.events.allSatisfy { $0.ordinal > cursor })
            XCTAssertEqual(paged.firstOrdinal, complete.firstOrdinal)
            XCTAssertEqual(paged.lastOrdinal, complete.lastOrdinal)
            XCTAssertEqual(paged.nextOrdinal, paged.events.last?.ordinal)
            XCTAssertLessThan(try XCTUnwrap(paged.nextOrdinal), paged.lastOrdinal)

            let resumed = ring.page(sinceOrdinal: paged.nextOrdinal, limit: 3)
            XCTAssertEqual(resumed.events.first?.ordinal, paged.events.last.map { $0.ordinal + 1 })
        }

        private func draft(
            uptime: UInt64,
            kind: WorkspaceCodemapBindingEngineHookKind,
            rootEpoch: WorkspaceCodemapRootEpoch,
            jobID: UUID,
            numericValue: UInt64,
            reason: WorkspaceCodemapGraphIndexDebugReason? = nil,
            manifestMeasurementOrigin: WorkspaceCodemapManifestMeasurementOrigin? = nil,
            manifestMeasurementRetryKind: WorkspaceCodemapManifestMeasurementRetryKind? = nil,
            manifestMutationByteCount: UInt64? = nil,
            manifestStoreAttempt: CodeMapRootManifestDebugAttemptMetrics? = nil
        ) -> WorkspaceCodemapGraphIndexDebugEventDraft {
            WorkspaceCodemapGraphIndexDebugEventDraft(
                uptimeNanoseconds: uptime,
                kind: kind,
                rootEpoch: rootEpoch,
                jobID: jobID,
                phase: .resolvingArtifacts,
                workerPresent: true,
                isQueuedForAdmission: false,
                queuePosition: nil,
                isActiveBatch: true,
                drainingBatchCount: 0,
                admissionWaitAgeMilliseconds: nil,
                phaseAgeMilliseconds: 1,
                lastProgressAgeMilliseconds: 0,
                pageOrdinal: 1,
                cursorFingerprint: "0123456789abcdef",
                numericValue: numericValue,
                projectedSupportedCandidateTotal: 64,
                processedCandidateCount: 10,
                candidateCount: 64,
                completedCandidateCount: 10,
                retryAttempt: reason == .retry ? 1 : nil,
                retryAfterMilliseconds: reason == .retry ? 250 : nil,
                reason: reason,
                manifestFailureReason: nil,
                manifestFailureOperation: nil,
                currentAuthorityGeneration: nil,
                observedPredecessorAuthorityGeneration: nil,
                manifestAttemptStartedUptimeNanoseconds: nil,
                manifestAttemptCompletedUptimeNanoseconds: nil,
                manifestAttemptDurationNanoseconds: nil,
                manifestMeasurementOrigin: manifestMeasurementOrigin,
                manifestMeasurementRetryKind: manifestMeasurementRetryKind,
                manifestMutationByteCount: manifestMutationByteCount,
                manifestStoreAttempt: manifestStoreAttempt
            )
        }
    }
#endif
