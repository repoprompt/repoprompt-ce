import Foundation
@testable import RepoPromptApp
import XCTest

/// Deterministic unit coverage for the release-safe MCP tool-call concurrency
/// evidence layer. The recorder receives explicit durations (no internal clock),
/// so every assertion is exact.
final class MCPToolConcurrencyEvidenceRecorderTests: XCTestCase {
    private func makeTraceEvent(
        toolName: String,
        operationIdentity: MCPToolOperationIdentity? = nil,
        phase: MCPToolExecutionTraceEvent.Phase,
        elapsedMilliseconds: Double
    ) -> MCPToolExecutionTraceEvent {
        MCPToolExecutionTraceEvent(
            toolName: toolName,
            operationIdentity: operationIdentity ?? MCPDomainToolCatalog.operationIdentity(for: toolName, input: .missing),
            connectionID: UUID(),
            invocationID: UUID(),
            runID: nil,
            contractKind: .bounded,
            executionDeadlineSeconds: 30,
            cleanupGraceSeconds: 5,
            cleanupDisposition: .forceDisconnect,
            phase: phase,
            elapsedMilliseconds: elapsedMilliseconds,
            cancellationRequested: nil,
            cancellationOutcome: nil,
            cancellationOrigin: nil,
            settlement: nil,
            graceOutcome: nil,
            escalationReason: nil,
            handlerPhase: nil,
            handlerPhaseAgeMilliseconds: nil
        )
    }

    private func classSnapshot(
        _ snapshot: MCPToolConcurrencyEvidenceSnapshot,
        _ classKey: MCPToolConcurrencyEvidenceClass
    ) -> MCPToolConcurrencyEvidenceSnapshot.ClassSnapshot? {
        snapshot.classes.first { $0.classKey == classKey.rawValue }
    }

    private func operationSnapshot(
        _ snapshot: MCPToolConcurrencyEvidenceSnapshot,
        _ identity: MCPToolOperationIdentity
    ) -> MCPToolConcurrencyEvidenceSnapshot.OperationSnapshot? {
        snapshot.operations.first {
            $0.canonicalTool == identity.canonicalTool
                && $0.normalizedOperation == identity.normalizedOperation
        }
    }

    // MARK: Histogram

    func testHistogramBucketAssignmentIsDeterministicAndBounded() throws {
        var histogram = MCPToolConcurrencyLatencyHistogram()
        XCTAssertEqual(
            histogram.bucketCounts.count,
            MCPToolConcurrencyLatencyHistogram.bucketUpperBoundsMilliseconds.count + 1
        )

        histogram.record(milliseconds: 0)
        histogram.record(milliseconds: 1)
        histogram.record(milliseconds: 1.5)
        histogram.record(milliseconds: 100)
        histogram.record(milliseconds: 59999)
        histogram.record(milliseconds: 1_000_000)
        histogram.record(milliseconds: -5)

        XCTAssertEqual(histogram.count, 7)
        // 0, 1, and clamped -5 land in the <=1ms bucket.
        XCTAssertEqual(histogram.bucketCounts[0], 3)
        // 1.5 lands in the <=2ms bucket.
        XCTAssertEqual(histogram.bucketCounts[1], 1)
        // 100 lands exactly on the <=100ms upper bound.
        let bounds = MCPToolConcurrencyLatencyHistogram.bucketUpperBoundsMilliseconds
        let index100 = try XCTUnwrap(bounds.firstIndex(of: 100))
        XCTAssertEqual(histogram.bucketCounts[index100], 1)
        // 59_999 lands in the <=60_000ms bucket; 1_000_000 overflows.
        let overflowIndex = histogram.bucketCounts.count - 1
        XCTAssertEqual(histogram.bucketCounts[overflowIndex - 1], 1)
        XCTAssertEqual(histogram.bucketCounts[overflowIndex], 1)
        XCTAssertEqual(histogram.maxMilliseconds, 1_000_000)
        let expectedSum = 1_060_101.5
        XCTAssertEqual(histogram.sumMilliseconds, expectedSum)
    }

    func testHistogramQuantileEstimatesUseBucketUpperBounds() {
        var histogram = MCPToolConcurrencyLatencyHistogram()
        XCTAssertNil(histogram.estimatedQuantileMilliseconds(0.5))

        for _ in 0 ..< 9 {
            histogram.record(milliseconds: 3)
        }
        histogram.record(milliseconds: 40000)

        // 9 of 10 samples are <=5ms; the p50 rank falls in the 5ms bucket.
        XCTAssertEqual(histogram.estimatedQuantileMilliseconds(0.5), 5)
        // The p95 rank (ceil(0.95*10)=10) is the 60_000ms bucket sample.
        XCTAssertEqual(histogram.estimatedQuantileMilliseconds(0.95), 60000)
        XCTAssertEqual(histogram.estimatedQuantileMilliseconds(1.0), 60000)
        XCTAssertEqual(histogram.estimatedQuantileMilliseconds(0), 5)
    }

    func testHistogramOverflowQuantileFallsBackToObservedMax() {
        var histogram = MCPToolConcurrencyLatencyHistogram()
        histogram.record(milliseconds: 120_000)
        XCTAssertEqual(histogram.estimatedQuantileMilliseconds(0.99), 120_000)
    }

    // MARK: Lane gauges and counters

    func testLaneLifecycleTracksWaitingAndHeldHighWater() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()

        recorder.recordLaneWaitBegan(classKey: .smallRead)
        recorder.recordLaneWaitBegan(classKey: .smallRead)
        recorder.recordLaneWaitBegan(classKey: .smallRead)
        recorder.recordLaneAdmitted(classKey: .smallRead, waitMilliseconds: 4)
        recorder.recordLaneAdmitted(classKey: .smallRead, waitMilliseconds: 12)
        recorder.recordLaneWaitAbandoned(classKey: .smallRead)
        recorder.recordRejection(classKey: .smallRead, reason: .laneWaitCancelled)
        recorder.recordLanePermitReleased(classKey: .smallRead)

        let snapshot = recorder.snapshot()
        let smallRead = try XCTUnwrap(classSnapshot(snapshot, .smallRead))
        XCTAssertEqual(smallRead.laneWaitingHighWater, 3)
        XCTAssertEqual(smallRead.laneHeldHighWater, 2)
        XCTAssertEqual(smallRead.laneAdmittedCount, 2)
        XCTAssertEqual(smallRead.laneWaitAbandonedCount, 1)
        XCTAssertEqual(
            smallRead.rejectionCounts[
                MCPToolConcurrencyEvidenceRejectionReason.laneWaitCancelled.rawValue
            ],
            1
        )

        let laneWait = try XCTUnwrap(
            smallRead.stageHistograms[MCPToolConcurrencyEvidenceStage.laneWait.rawValue]
        )
        XCTAssertEqual(laneWait.count, 2)
        XCTAssertEqual(laneWait.sumMilliseconds, 16)
    }

    func testGaugesClampAtZeroOnUnpairedReleases() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordLanePermitReleased(classKey: .control)
        recorder.recordLaneWaitAbandoned(classKey: .control)
        recorder.recordLaneAdmitted(classKey: .control, waitMilliseconds: 1)

        let snapshot = recorder.snapshot()
        let control = try XCTUnwrap(classSnapshot(snapshot, .control))
        XCTAssertEqual(control.laneWaitingHighWater, 0)
        XCTAssertEqual(control.laneHeldHighWater, 1)
        XCTAssertEqual(control.laneWaitAbandonedCount, 1)
    }

    // MARK: Lease waits and rejections

    func testLeaseWaitAndRejectionCounters() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordLeaseWait(classKey: .exclusive, milliseconds: 250)
        recorder.recordRejection(classKey: .exclusive, reason: .leaseWaitCancelled)
        recorder.recordRejection(classKey: .unclassified, reason: .unclassifiedTool)

        let snapshot = recorder.snapshot()
        let exclusive = try XCTUnwrap(classSnapshot(snapshot, .exclusive))
        let leaseWait = try XCTUnwrap(
            exclusive.stageHistograms[MCPToolConcurrencyEvidenceStage.leaseWait.rawValue]
        )
        XCTAssertEqual(leaseWait.count, 1)
        XCTAssertEqual(
            exclusive.rejectionCounts[
                MCPToolConcurrencyEvidenceRejectionReason.leaseWaitCancelled.rawValue
            ],
            1
        )
        let unclassified = try XCTUnwrap(classSnapshot(snapshot, .unclassified))
        XCTAssertEqual(
            unclassified.rejectionCounts[
                MCPToolConcurrencyEvidenceRejectionReason.unclassifiedTool.rawValue
            ],
            1
        )
    }

    // MARK: Completion and privacy bounds

    func testCallCompletionCountsClassifiedToolNamesOnly() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordCallCompleted(
            classKey: .fileRead,
            canonicalToolName: MCPWindowToolName.readFile,
            operationIdentity: MCPDomainToolCatalog.operationIdentity(
                for: MCPWindowToolName.readFile,
                input: .missing
            ),
            totalMilliseconds: 42
        )
        recorder.recordCallCompleted(
            classKey: .unclassified,
            canonicalToolName: "some_private_or_future_tool",
            operationIdentity: MCPDomainToolCatalog.operationIdentity(
                for: "some_private_or_future_tool",
                input: .value("private/path/id/prompt")
            ),
            totalMilliseconds: 9
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.completedCallCountsByTool[MCPWindowToolName.readFile], 1)
        XCTAssertNil(snapshot.completedCallCountsByTool["some_private_or_future_tool"])
        XCTAssertEqual(
            snapshot.completedCallCountsByTool[MCPToolConcurrencyEvidenceRecorder.unclassifiedToolKey],
            1
        )
        XCTAssertEqual(snapshot.operations.map(\.canonicalTool).sorted(), [MCPWindowToolName.readFile, "unknown"])
        XCTAssertFalse(snapshot.operations.description.contains("private/path/id/prompt"))
        XCTAssertFalse(snapshot.operations.description.contains("some_private_or_future_tool"))

        let fileRead = try XCTUnwrap(classSnapshot(snapshot, .fileRead))
        let total = try XCTUnwrap(
            fileRead.stageHistograms[MCPToolConcurrencyEvidenceStage.total.rawValue]
        )
        XCTAssertEqual(total.count, 1)
    }

    func testOperationAggregationIncludesEveryStageTerminalCountClassAndLimits() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        let identity = MCPDomainToolCatalog.operationIdentity(
            for: MCPWindowToolName.manageSelection,
            input: .missing
        )

        recorder.recordLaneWaitBegan(classKey: .exclusive)
        recorder.recordLaneAdmitted(
            classKey: .exclusive,
            operationIdentity: identity,
            waitMilliseconds: 4
        )
        recorder.recordLeaseWait(
            classKey: .exclusive,
            operationIdentity: identity,
            milliseconds: 7
        )
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: MCPWindowToolName.manageSelection,
            operationIdentity: identity,
            phase: .handlerCompleted,
            elapsedMilliseconds: 11
        ))
        recorder.recordCallCompleted(
            classKey: .exclusive,
            canonicalToolName: MCPWindowToolName.manageSelection,
            operationIdentity: identity,
            totalMilliseconds: 19
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(MCPToolConcurrencyEvidenceSnapshot.schemaVersion, 2)
        let operation = try XCTUnwrap(operationSnapshot(snapshot, identity))
        XCTAssertEqual(operation.completedCallCount, 1)
        XCTAssertEqual(operation.admissionClass, MCPToolConcurrencyEvidenceClass.exclusive.rawValue)
        XCTAssertEqual(operation.connectionLaneLimit, MCPToolAdmissionPolicy.exclusiveConnectionLimit)
        XCTAssertEqual(operation.resourceLeaseLimit, MCPToolAdmissionPolicy.exclusiveConnectionLimit)
        XCTAssertEqual(operation.resourceLeaseScope, MCPDomainToolResourceLimitScope.window.rawValue)
        XCTAssertEqual(operation.stageHistograms[MCPToolConcurrencyEvidenceStage.laneWait.rawValue]?.sumMilliseconds, 4)
        XCTAssertEqual(operation.stageHistograms[MCPToolConcurrencyEvidenceStage.leaseWait.rawValue]?.sumMilliseconds, 7)
        XCTAssertEqual(operation.stageHistograms[MCPToolConcurrencyEvidenceStage.execution.rawValue]?.sumMilliseconds, 11)
        XCTAssertEqual(operation.stageHistograms[MCPToolConcurrencyEvidenceStage.total.rawValue]?.sumMilliseconds, 19)
        XCTAssertEqual(
            operation.executionTracePhaseCounts[MCPToolExecutionTraceEvent.Phase.handlerCompleted.rawValue],
            1
        )
    }

    func testOperationTerminalAccountingIsExactlyOnceAcrossBoundedTerminalKinds() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        let cases: [(MCPToolOperationIdentity, MCPToolConcurrencyEvidenceClass, String)] = [
            (
                MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.manageSelection, input: .missing),
                .exclusive,
                MCPWindowToolName.manageSelection
            ),
            (
                MCPDomainToolCatalog.operationIdentity(for: MCPGlobalToolName.appSettings, input: .missing),
                .exclusive,
                MCPGlobalToolName.appSettings
            ),
            (
                MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.agentRun, input: .value("cancel")),
                .control,
                MCPWindowToolName.agentRun
            ),
            (
                MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.git, input: .missing),
                .gitRead,
                MCPWindowToolName.git
            )
        ]

        recorder.recordRejection(
            classKey: cases[1].1,
            operationIdentity: cases[1].0,
            reason: .unclassifiedTool
        )
        recorder.recordRejection(
            classKey: cases[2].1,
            operationIdentity: cases[2].0,
            reason: .laneWaitCancelled
        )
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: cases[3].2,
            operationIdentity: cases[3].0,
            phase: .deadlineExpired,
            elapsedMilliseconds: 30000
        ))
        for (identity, classKey, toolName) in cases {
            recorder.recordCallCompleted(
                classKey: classKey,
                canonicalToolName: toolName,
                operationIdentity: identity,
                totalMilliseconds: 1
            )
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.operations.count, cases.count)
        for (identity, _, _) in cases {
            let operation = try XCTUnwrap(operationSnapshot(snapshot, identity))
            XCTAssertEqual(operation.completedCallCount, 1)
            XCTAssertEqual(operation.stageHistograms[MCPToolConcurrencyEvidenceStage.total.rawValue]?.count, 1)
        }
        XCTAssertEqual(
            operationSnapshot(snapshot, cases[1].0)?.rejectionCounts[
                MCPToolConcurrencyEvidenceRejectionReason.unclassifiedTool.rawValue
            ],
            1
        )
        XCTAssertEqual(
            operationSnapshot(snapshot, cases[2].0)?.rejectionCounts[
                MCPToolConcurrencyEvidenceRejectionReason.laneWaitCancelled.rawValue
            ],
            1
        )
        XCTAssertEqual(
            operationSnapshot(snapshot, cases[3].0)?.executionTracePhaseCounts[
                MCPToolExecutionTraceEvent.Phase.deadlineExpired.rawValue
            ],
            1
        )
    }

    // MARK: Execution trace ingestion

    func testExecutionTraceEventsFeedExecutionHistogramAndPhaseCounters() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: MCPWindowToolName.readFile,
            phase: .started,
            elapsedMilliseconds: 0
        ))
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: MCPWindowToolName.readFile,
            phase: .handlerCompleted,
            elapsedMilliseconds: 77
        ))
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: MCPWindowToolName.readFile,
            phase: .deadlineExpired,
            elapsedMilliseconds: 30000
        ))
        recorder.recordExecutionTraceEvent(makeTraceEvent(
            toolName: "some_unknown_tool",
            phase: .connectionForceDisconnectRequested,
            elapsedMilliseconds: 35000
        ))

        let snapshot = recorder.snapshot()
        let fileRead = try XCTUnwrap(classSnapshot(snapshot, .fileRead))
        XCTAssertEqual(
            fileRead.executionTracePhaseCounts[
                MCPToolExecutionTraceEvent.Phase.started.rawValue
            ],
            1
        )
        XCTAssertEqual(
            fileRead.executionTracePhaseCounts[
                MCPToolExecutionTraceEvent.Phase.deadlineExpired.rawValue
            ],
            1
        )
        let execution = try XCTUnwrap(
            fileRead.stageHistograms[MCPToolConcurrencyEvidenceStage.execution.rawValue]
        )
        XCTAssertEqual(execution.count, 1)
        XCTAssertEqual(execution.sumMilliseconds, 77)

        let unclassified = try XCTUnwrap(classSnapshot(snapshot, .unclassified))
        XCTAssertEqual(
            unclassified.executionTracePhaseCounts[
                MCPToolExecutionTraceEvent.Phase.connectionForceDisconnectRequested.rawValue
            ],
            1
        )
    }

    func testTracerEmitFeedsSharedRecorder() {
        let shared = MCPToolConcurrencyEvidenceRecorder.shared
        let phaseKey = MCPToolExecutionTraceEvent.Phase.settledDuringGrace.rawValue
        let before = classSnapshot(shared.snapshot(), .gitRead)?
            .executionTracePhaseCounts[phaseKey] ?? 0

        MCPToolExecutionTracer.emit(makeTraceEvent(
            toolName: MCPWindowToolName.git,
            phase: .settledDuringGrace,
            elapsedMilliseconds: 100
        ))

        let after = classSnapshot(shared.snapshot(), .gitRead)?
            .executionTracePhaseCounts[phaseKey] ?? 0
        XCTAssertEqual(after, before + 1)
    }

    // MARK: Snapshot determinism, reset, and memory bounds

    func testSnapshotIsDeterministicallyOrderedAndResetClearsState() {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        for classKey in MCPToolConcurrencyEvidenceClass.allCases {
            recorder.recordLaneWaitBegan(classKey: classKey)
            recorder.recordLaneAdmitted(classKey: classKey, waitMilliseconds: 5)
        }

        let first = recorder.snapshot()
        let second = recorder.snapshot()
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.classes.map(\.classKey),
            MCPToolConcurrencyEvidenceClass.allCases.map(\.rawValue).sorted()
        )

        recorder.reset()
        let cleared = recorder.snapshot()
        XCTAssertTrue(cleared.classes.isEmpty)
        XCTAssertTrue(cleared.completedCallCountsByTool.isEmpty)
        XCTAssertTrue(cleared.operations.isEmpty)
    }

    func testSnapshotAndResetIsAtomicallyEquivalentToSnapshotThenReset() throws {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordLaneWaitBegan(classKey: .fileRead)
        recorder.recordLaneAdmitted(classKey: .fileRead, waitMilliseconds: 3)
        let identity = MCPDomainToolCatalog.operationIdentity(
            for: MCPWindowToolName.readFile,
            input: .missing
        )
        recorder.recordCallCompleted(
            classKey: .fileRead,
            canonicalToolName: MCPWindowToolName.readFile,
            operationIdentity: identity,
            totalMilliseconds: 20
        )

        let expected = recorder.snapshot()
        let drained = recorder.snapshotAndReset()
        XCTAssertEqual(drained, expected)
        XCTAssertEqual(operationSnapshot(drained, identity)?.completedCallCount, 1)

        let cleared = recorder.snapshot()
        XCTAssertTrue(cleared.classes.isEmpty)
        XCTAssertTrue(cleared.completedCallCountsByTool.isEmpty)
        XCTAssertTrue(cleared.operations.isEmpty)

        // Recording continues normally after an atomic drain.
        recorder.recordLaneWaitBegan(classKey: .control)
        recorder.recordLaneAdmitted(classKey: .control, waitMilliseconds: 1)
        let next = recorder.snapshot()
        XCTAssertEqual(next.classes.map(\.classKey), [MCPToolConcurrencyEvidenceClass.control.rawValue])
        XCTAssertEqual(try XCTUnwrap(classSnapshot(next, .control)).laneAdmittedCount, 1)
    }

    func testCompletionKeepsTotalHistogramAndPerToolCountsConsistent() {
        let recorder = MCPToolConcurrencyEvidenceRecorder()
        recorder.recordCallCompleted(
            classKey: .fileRead,
            canonicalToolName: MCPWindowToolName.readFile,
            totalMilliseconds: 5
        )
        recorder.recordCallCompleted(
            classKey: .smallRead,
            canonicalToolName: MCPWindowToolName.getFileTree,
            totalMilliseconds: 6
        )
        recorder.recordCallCompleted(
            classKey: .gitRead,
            canonicalToolName: MCPWindowToolName.git,
            totalMilliseconds: 7
        )

        let snapshot = recorder.snapshot()
        let totalHistogramCount = snapshot.classes
            .compactMap { $0.stageHistograms[MCPToolConcurrencyEvidenceStage.total.rawValue]?.count }
            .reduce(0, +)
        let perToolCount = snapshot.completedCallCountsByTool.values.reduce(0, +)
        XCTAssertEqual(totalHistogramCount, 3)
        XCTAssertEqual(perToolCount, totalHistogramCount)
        XCTAssertEqual(snapshot.completedCallCountsByTool[MCPWindowToolName.readFile], 1)
        XCTAssertEqual(snapshot.completedCallCountsByTool[MCPWindowToolName.getFileTree], 1)
        XCTAssertEqual(snapshot.completedCallCountsByTool[MCPWindowToolName.git], 1)
    }

    func testLeaseWaitTerminationClassifiesOnlyCancellationAsCancelled() {
        struct SomeLeaseFailure: Error {}
        XCTAssertEqual(
            MCPToolConcurrencyEvidenceRejectionReason.leaseWaitTermination(for: CancellationError()),
            .leaseWaitCancelled
        )
        XCTAssertEqual(
            MCPToolConcurrencyEvidenceRejectionReason.leaseWaitTermination(for: SomeLeaseFailure()),
            .leaseWaitFailed
        )
    }

    func testEvidenceClassMirrorsAdmissionClassification() {
        XCTAssertEqual(
            MCPToolConcurrencyEvidenceClass(admissionClass: .smallRead).rawValue,
            MCPToolAdmissionClass.smallRead.rawValue
        )
        XCTAssertEqual(
            MCPToolConcurrencyEvidenceClass(admissionClass: .fileRead).rawValue,
            MCPToolAdmissionClass.fileRead.rawValue
        )
        XCTAssertEqual(
            MCPToolConcurrencyEvidenceClass(admissionClass: nil),
            .unclassified
        )
        for admissionClass in MCPToolAdmissionClass.allCases {
            XCTAssertEqual(
                MCPToolConcurrencyEvidenceClass(admissionClass: admissionClass).rawValue,
                admissionClass.rawValue
            )
        }
    }
}
