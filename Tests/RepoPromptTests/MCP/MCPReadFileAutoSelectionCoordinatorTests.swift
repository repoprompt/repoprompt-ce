import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPReadFileAutoSelectionCoordinatorTests: XCTestCase {
    func testCoverageIdentityNormalizesOrderingCoalescingAndRejectsExpansion() throws {
        let firstIntent = MCPReadFileAutoSelectionCoordinator.Intent.slices(entries: [
            WorkspaceSelectionSliceInput(
                path: "Logical/A.swift",
                ranges: [LineRange(start: 10, end: 20), LineRange(start: 18, end: 30)]
            ),
            WorkspaceSelectionSliceInput(path: "Logical/B.swift", ranges: [LineRange(start: 2, end: 4)])
        ])
        let reorderedIntent = MCPReadFileAutoSelectionCoordinator.Intent.slices(entries: [
            WorkspaceSelectionSliceInput(path: "Other/B.swift", ranges: [LineRange(start: 2, end: 4)]),
            WorkspaceSelectionSliceInput(
                path: "Other/A.swift",
                ranges: [LineRange(start: 10, end: 15), LineRange(start: 16, end: 30)]
            )
        ])
        let first = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: firstIntent,
            resolvedPaths: ["/worktree/A.swift", "/worktree/B.swift"]
        ))
        let reordered = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: reorderedIntent,
            resolvedPaths: ["/worktree/B.swift", "/worktree/A.swift"]
        ))
        XCTAssertEqual(first, reordered)

        let expansion = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: .slices(entries: [
                WorkspaceSelectionSliceInput(path: "Logical/A.swift", ranges: [LineRange(start: 10, end: 31)]),
                WorkspaceSelectionSliceInput(path: "Logical/B.swift", ranges: [LineRange(start: 2, end: 4)])
            ]),
            resolvedPaths: ["/worktree/A.swift", "/worktree/B.swift"]
        ))
        XCTAssertNotEqual(first, expansion)

        var expandedBatch = MCPReadFileAutoSelectionCoordinator.CanonicalBatch(
            intent: firstIntent,
            coverageIdentity: first
        )
        let coalescedExpansionIntent = MCPReadFileAutoSelectionCoordinator.Intent.slices(entries: [
            WorkspaceSelectionSliceInput(path: "Logical/A.swift", ranges: [LineRange(start: 25, end: 31)])
        ])
        let coalescedExpansionCoverage = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: coalescedExpansionIntent,
            resolvedPaths: ["/worktree/A.swift"]
        ))
        expandedBatch.merge(coalescedExpansionIntent, coverageIdentity: coalescedExpansionCoverage)
        XCTAssertEqual(expandedBatch.coverageIdentity, expansion)
        XCTAssertNotEqual(expandedBatch.coverageIdentity, first)

        var batch = MCPReadFileAutoSelectionCoordinator.CanonicalBatch(
            intent: firstIntent,
            coverageIdentity: first
        )
        let fullIntent = MCPReadFileAutoSelectionCoordinator.Intent.full(paths: ["Logical/A.swift"])
        let fullCoverage = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: fullIntent,
            resolvedPaths: ["/worktree/A.swift"]
        ))
        batch.merge(fullIntent, coverageIdentity: fullCoverage)
        XCTAssertEqual(batch.coverageIdentity?.fullPaths, ["/worktree/A.swift"])
        XCTAssertEqual(batch.coverageIdentity?.slices.map(\.path), ["/worktree/B.swift"])
    }

    func testCoverageIdentityRequiresExactPhysicalPathsAndChecksFullAndSliceCoverage() throws {
        XCTAssertNil(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: .full(paths: ["A.swift"]),
            resolvedPaths: ["relative/A.swift"]
        ))
        let requested = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: .slices(entries: [
                WorkspaceSelectionSliceInput(path: "A.swift", ranges: [LineRange(start: 100, end: 120)])
            ]),
            resolvedPaths: ["/worktree/A.swift"]
        ))
        XCTAssertTrue(requested.isCovered(by: StoredSelection(selectedPaths: ["/worktree/A.swift"])))
        XCTAssertTrue(requested.isCovered(by: StoredSelection(
            selectedPaths: ["/worktree/A.swift"],
            slices: ["/worktree/A.swift": [LineRange(start: 90, end: 130)]]
        )))
        XCTAssertFalse(requested.isCovered(by: StoredSelection(
            selectedPaths: ["/worktree/A.swift"],
            slices: ["/worktree/A.swift": [LineRange(start: 100, end: 119)]]
        )))
    }

    func testAuthoritativeSelectionPreservationRequiresFullCanonicalSuperset() {
        let expected = StoredSelection(
            selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
            manualCodemapPaths: ["/workspace/C.swift"],
            slices: ["/workspace/B.swift": [LineRange(start: 10, end: 20)]],
            codemapAutoEnabled: true
        )
        let scenarios: [(String, StoredSelection, Bool)] = [
            ("exact", expected, true),
            (
                "additive wider slice",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift", "/workspace/D.swift"],
                    manualCodemapPaths: ["/workspace/C.swift", "/workspace/E.swift"],
                    slices: ["/workspace/B.swift": [LineRange(start: 5, end: 25)]],
                    codemapAutoEnabled: true
                ),
                true
            ),
            (
                "full selection supersedes expected slice",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
                    manualCodemapPaths: ["/workspace/C.swift"],
                    codemapAutoEnabled: true
                ),
                true
            ),
            (
                "unrelated selected path dropped",
                StoredSelection(
                    selectedPaths: ["/workspace/B.swift"],
                    manualCodemapPaths: ["/workspace/C.swift"],
                    slices: ["/workspace/B.swift": [LineRange(start: 10, end: 20)]],
                    codemapAutoEnabled: true
                ),
                false
            ),
            (
                "expected full file demoted to slice",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
                    manualCodemapPaths: ["/workspace/C.swift"],
                    slices: [
                        "/workspace/A.swift": [LineRange(start: 1, end: 2)],
                        "/workspace/B.swift": [LineRange(start: 10, end: 20)]
                    ],
                    codemapAutoEnabled: true
                ),
                false
            ),
            (
                "manual codemap path dropped",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
                    slices: ["/workspace/B.swift": [LineRange(start: 10, end: 20)]],
                    codemapAutoEnabled: true
                ),
                false
            ),
            (
                "slice narrowed",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
                    manualCodemapPaths: ["/workspace/C.swift"],
                    slices: ["/workspace/B.swift": [LineRange(start: 11, end: 20)]],
                    codemapAutoEnabled: true
                ),
                false
            ),
            (
                "codemap mode changed",
                StoredSelection(
                    selectedPaths: ["/workspace/A.swift", "/workspace/B.swift"],
                    manualCodemapPaths: ["/workspace/C.swift"],
                    slices: ["/workspace/B.swift": [LineRange(start: 10, end: 20)]],
                    codemapAutoEnabled: false
                ),
                false
            )
        ]

        for (label, candidate, expectedResult) in scenarios {
            XCTAssertEqual(
                MCPReadFileAutoSelectionCoordinator.authoritativeSelection(
                    expected,
                    isPreservedBy: candidate
                ),
                expectedResult,
                label
            )
        }
    }

    func testDiagnosticsAccountCertificateHitsFallbacksAndMissReasons() async throws {
        let recorder = CoordinatorRecorder()
        let key = contextKey()
        let coverage = try XCTUnwrap(MCPReadFileAutoSelectionCoordinator.CoverageIdentity(
            intent: .full(paths: ["A.swift"]),
            resolvedPaths: ["/worktree/A.swift"]
        ))
        var invocation = 0
        let coordinator = makeCoordinator(recorder: recorder) { _, _ in
            invocation += 1
            return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(
                mirrorKey: nil,
                disposition: .semanticNoOp,
                coverageCertificateOutcome: invocation == 1
                    ? .authoritativeFallback(.noCertificate)
                    : .hit
            )
        }

        for _ in 0 ..< 2 {
            XCTAssertTrue(coordinator.enqueue(
                intent: .full(paths: ["A.swift"]),
                coverageIdentity: coverage,
                for: key
            ))
            let drainResult = await coordinator.drain(.canonicalSelection, for: key)
            XCTAssertEqual(drainResult, .completed)
        }

        let snapshot = try XCTUnwrap(coordinator.debugContextSnapshot(for: key))
        XCTAssertEqual(snapshot.coverageCertificateHitCount, 1)
        XCTAssertEqual(snapshot.authoritativeFallbackCount, 1)
        XCTAssertEqual(snapshot.coverageCertificateMissReasonCounts[.noCertificate], 1)
        XCTAssertEqual(snapshot.mutationSamples.map(\.coverageCertificateOutcome), [
            .authoritativeFallback(.noCertificate),
            .hit
        ])
    }

    func testEnqueueReturnsWhileCanonicalMutationIsBlocked() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            await gate.markStartedAndWaitForRelease()
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()

        XCTAssertEqual(coordinator.debugSnapshot().canonicalWorkerCount, 1)
        let batchesBeforeRelease = await recorder.canonicalBatches()
        XCTAssertTrue(batchesBeforeRelease.isEmpty)

        await gate.release()
        await coordinator.drain(.canonicalSelection, for: key)
        let batchesAfterDrain = await recorder.canonicalBatches()
        XCTAssertEqual(batchesAfterDrain.count, 1)
    }

    func testCanonicalPendingBatchCoalescesAndFullFileWinsOverSlices() async {
        let firstGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            let invocation = await recorder.recordCanonicalAndCount(batch)
            if invocation == 1 {
                await firstGate.markStartedAndWaitForRelease()
            }
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: key))
        await firstGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .slices(entries: [
            WorkspaceSelectionSliceInput(path: "/tmp/A.swift", ranges: [LineRange(start: 1, end: 3)])
        ]), for: key))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        XCTAssertTrue(coordinator.enqueue(intent: .slices(entries: [
            WorkspaceSelectionSliceInput(path: "/tmp/B.swift", ranges: [LineRange(start: 4, end: 6), LineRange(start: 6, end: 8)])
        ]), for: key))
        let blockedSnapshot = coordinator.debugSnapshot()
        XCTAssertEqual(blockedSnapshot.pendingCanonicalBatchCount, 1)
        XCTAssertEqual(blockedSnapshot.canonicalWorkerCount, 1)

        await firstGate.release()
        await coordinator.drain(.canonicalSelection, for: key)

        let batches = await recorder.canonicalBatches()
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].fullPaths, ["/tmp/A.swift"])
        XCTAssertEqual(batches[1].sliceEntries, [
            WorkspaceSelectionSliceInput(path: "/tmp/B.swift", ranges: [LineRange(start: 4, end: 8)])
        ])
        let accounting = try? XCTUnwrap(coordinator.debugContextSnapshot(for: key))
        XCTAssertEqual(accounting?.acceptedIntentCount, 4)
        XCTAssertEqual(accounting?.completedIntentCount, 4)
        XCTAssertEqual(accounting?.canonicalApplyAttemptCount, 2)
        XCTAssertEqual(accounting?.semanticNoOpApplyCount, 2)
        XCTAssertEqual(accounting?.semanticNoOpIntentCount, 4)
        XCTAssertEqual(accounting?.changedApplyCount, 0)
        XCTAssertEqual(accounting?.rejectedApplyCount, 0)
        XCTAssertEqual(accounting?.invalidatedIntentCount, 0)
        XCTAssertEqual(accounting?.mutationSamples.map(\.acceptedIntentCount), [1, 3])
        XCTAssertEqual(accounting?.sampleOverflowCount, 0)
    }

    func testCanonicalIdentityIsConnectionAndRunScopedWhileMirrorsCoalescePerTab() async {
        let mirrorGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let tabID = UUID()
        let workspaceID = UUID()
        let first = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: UUID(), runID: UUID()))
        let second = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: UUID(), runID: UUID()))
        let compatibility = contextKey(tabID: tabID, workspaceID: workspaceID, route: .activeTabCompatibility)
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, batch in
                await recorder.recordKey(key)
                await recorder.recordCanonical(batch)
                return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { key in
                let invocation = await recorder.recordMirror(key)
                if invocation == 1 {
                    await mirrorGate.markStartedAndWaitForRelease()
                }
            }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: first))
        await mirrorGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: second))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/C.swift"]), for: compatibility))
        await Task.yield()
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 3)
        XCTAssertLessThanOrEqual(coordinator.debugSnapshot().pendingMirrorBatchCount, 1)

        await mirrorGate.release()
        await coordinator.drain(.mirroredSelectionAndMetrics, for: first)
        await coordinator.drain(.mirroredSelectionAndMetrics, for: second)
        await coordinator.drain(.mirroredSelectionAndMetrics, for: compatibility)

        let recordedKeys = await recorder.keys()
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(Set(recordedKeys), Set([first, second, compatibility]))
        XCTAssertLessThanOrEqual(mirrorCount, 2)
    }

    func testDrainCapturesFiniteHighWaterMark() async {
        let firstGate = CoordinatorAsyncGate()
        let secondGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            let invocation = await recorder.recordCanonicalAndCount(batch)
            if invocation == 1 {
                await firstGate.markStartedAndWaitForRelease()
            } else if invocation == 2 {
                await secondGate.markStartedAndWaitForRelease()
            }
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: key))
        await firstGate.waitUntilStarted()
        let drainFinished = CoordinatorAsyncSignal()
        let drainTask = Task { @MainActor in
            _ = await coordinator.drain(.canonicalSelection, for: key)
            await drainFinished.mark()
        }
        await Task.yield()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Later.swift"]), for: key))

        await firstGate.release()
        await secondGate.waitUntilStarted()
        let finishedAtCapturedHighWaterMark = await drainFinished.isMarked()
        XCTAssertTrue(finishedAtCapturedHighWaterMark)

        await secondGate.release()
        await drainTask.value
        await coordinator.drain(.canonicalSelection, for: key)
    }

    func testCancelledCanonicalDrainResumesPromptlyWithoutStoppingWorker() async {
        let gate = CoordinatorAsyncGate()
        let coordinator = makeCoordinator(recorder: CoordinatorRecorder()) { _, _ in
            await gate.markStartedAndWaitForRelease()
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.canonicalSelection, for: key)
        }
        let canonicalWaiterRegistered = await waitUntil {
            coordinator.debugSnapshot().canonicalWaiterCount == 1
        }
        XCTAssertTrue(canonicalWaiterRegistered)

        drainTask.cancel()

        let canonicalResult = await drainTask.value
        XCTAssertEqual(canonicalResult, .cancelled)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWorkerCount, 1)

        await gate.release()
        let settledCanonicalResult = await coordinator.drain(.canonicalSelection, for: key)
        XCTAssertEqual(settledCanonicalResult, .completed)
        let canonicalWorkerStopped = await waitUntil {
            coordinator.debugSnapshot().canonicalWorkerCount == 0
        }
        XCTAssertTrue(canonicalWorkerStopped)
    }

    func testCancelledMirrorDrainResumesPromptlyWithoutStoppingWorker() async {
        let mirrorGate = CoordinatorAsyncGate()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, _ in
                MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { _ in
                await mirrorGate.markStartedAndWaitForRelease()
            }
        )
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await mirrorGate.waitUntilStarted()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        }
        let mirrorWaiterRegistered = await waitUntil {
            coordinator.debugSnapshot().mirrorWaiterCount == 1
        }
        XCTAssertTrue(mirrorWaiterRegistered)

        drainTask.cancel()

        let mirrorResult = await drainTask.value
        XCTAssertEqual(mirrorResult, .cancelled)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorWorkerCount, 1)

        await mirrorGate.release()
        let settledMirrorResult = await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        XCTAssertEqual(settledMirrorResult, .completed)
        let mirrorWorkerStopped = await waitUntil {
            coordinator.debugSnapshot().mirrorWorkerCount == 0
        }
        XCTAssertTrue(mirrorWorkerStopped)
    }

    func testCanonicalCompletionCancellationRaceResumesWaiterExactlyOnce() async {
        for iteration in 0 ..< 20 {
            let gate = CoordinatorAsyncGate()
            let coordinator = makeCoordinator(recorder: CoordinatorRecorder()) { _, _ in
                await gate.markStartedAndWaitForRelease()
                return .unchanged
            }
            let key = contextKey()

            XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/\(iteration).swift"]), for: key))
            await gate.waitUntilStarted()
            let drainTask = Task { @MainActor in
                await coordinator.drain(.canonicalSelection, for: key)
            }
            let waiterRegistered = await waitUntil {
                coordinator.debugSnapshot().canonicalWaiterCount == 1
            }
            XCTAssertTrue(waiterRegistered)

            let releaseTask = Task {
                await gate.release()
            }
            drainTask.cancel()
            await releaseTask.value
            await drainTask.value
            await coordinator.drain(.canonicalSelection, for: key)
            let workerStopped = await waitUntil {
                coordinator.debugSnapshot().canonicalWorkerCount == 0
            }

            let snapshot = coordinator.debugSnapshot()
            XCTAssertTrue(workerStopped, "iteration \(iteration)")
            XCTAssertEqual(snapshot.canonicalWaiterCount, 0, "iteration \(iteration)")
        }
    }

    func testDiagnosticsExposeCanonicalAndMirrorHighWaterWaitersAndWorkers() async throws {
        let canonicalGate = CoordinatorAsyncGate()
        let mirrorGate = CoordinatorAsyncGate()
        let diagnostics = CoordinatorDiagnosticRecorder()
        let key = contextKey()
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, _ in
                await canonicalGate.markStartedAndWaitForRelease()
                return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { _ in
                await mirrorGate.markStartedAndWaitForRelease()
            }
        )
        MCPReadFileAutoSelectionDiagnosticTracer.setTestSink { diagnostics.append($0) }
        defer { MCPReadFileAutoSelectionDiagnosticTracer.setTestSink(nil) }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await canonicalGate.waitUntilStarted()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: key)
        }

        let canonicalRegistered = try await diagnostics.waitFor(kind: .waiterRegistered, lane: .canonical)
        XCTAssertEqual(canonicalRegistered.target, 1)
        XCTAssertEqual(canonicalRegistered.acceptedHighWater, 1)
        XCTAssertEqual(canonicalRegistered.completedHighWater, 0)
        XCTAssertEqual(canonicalRegistered.waiterCount, 1)
        XCTAssertTrue(canonicalRegistered.workerActive)

        await canonicalGate.release()
        await mirrorGate.waitUntilStarted()
        let mirrorRegistered = try await diagnostics.waitFor(kind: .waiterRegistered, lane: .mirror)
        XCTAssertEqual(mirrorRegistered.target, 1)
        XCTAssertEqual(mirrorRegistered.acceptedHighWater, 1)
        XCTAssertEqual(mirrorRegistered.completedHighWater, 0)
        XCTAssertEqual(mirrorRegistered.waiterCount, 1)
        XCTAssertTrue(mirrorRegistered.workerActive)

        await mirrorGate.release()
        await drainTask.value
        XCTAssertEqual(coordinator.debugSnapshot().canonicalWaiterCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorWaiterCount, 0)
        _ = try await diagnostics.waitFor(kind: .workerStopped, lane: .canonical)
        _ = try await diagnostics.waitFor(kind: .workerStopped, lane: .mirror)

        let events = diagnostics.snapshot()
        let canonicalResumed = try XCTUnwrap(events.first {
            $0.kind == .waiterResumed && $0.lane == .canonical
        })
        XCTAssertEqual(canonicalResumed.waiterID, canonicalRegistered.waiterID)
        XCTAssertEqual(canonicalResumed.target, canonicalRegistered.target)
        XCTAssertEqual(canonicalResumed.completedHighWater, 1)
        XCTAssertEqual(canonicalResumed.requiredMirrorTicket, 1)

        let mirrorResumed = try XCTUnwrap(events.first {
            $0.kind == .waiterResumed && $0.lane == .mirror
        })
        XCTAssertEqual(mirrorResumed.waiterID, mirrorRegistered.waiterID)
        XCTAssertEqual(mirrorResumed.target, mirrorRegistered.target)
        XCTAssertEqual(mirrorResumed.completedHighWater, 1)

        for lane in [
            MCPReadFileAutoSelectionDiagnosticEvent.Lane.canonical,
            .mirror
        ] {
            let started = try XCTUnwrap(events.first { $0.kind == .workerStarted && $0.lane == lane })
            let stopped = try XCTUnwrap(events.first { $0.kind == .workerStopped && $0.lane == lane })
            XCTAssertEqual(started.workerID, stopped.workerID)
            XCTAssertTrue(started.workerActive)
            XCTAssertFalse(stopped.workerActive)
            XCTAssertTrue(events.contains {
                $0.kind == .acceptedHighWaterAdvanced
                    && $0.lane == lane
                    && $0.previousAcceptedHighWater == 0
                    && $0.acceptedHighWater == 1
            })
            XCTAssertTrue(events.contains {
                $0.kind == .drainHighWaterCaptured
                    && $0.lane == lane
                    && $0.target == 1
            })
        }

        let boundedCoordinator = makeCoordinator(recorder: CoordinatorRecorder())
        let boundedKey = contextKey()
        for ordinal in 0 ..< 258 {
            XCTAssertTrue(boundedCoordinator.enqueue(intent: .full(paths: ["/tmp/Bounded-\(ordinal).swift"]), for: boundedKey))
            let result = await boundedCoordinator.drain(.canonicalSelection, for: boundedKey)
            XCTAssertEqual(result, .completed)
        }
        let bounded = try XCTUnwrap(boundedCoordinator.debugContextSnapshot(for: boundedKey))
        XCTAssertEqual(bounded.acceptedIntentCount, 258)
        XCTAssertEqual(bounded.completedIntentCount, 258)
        XCTAssertEqual(bounded.canonicalApplyAttemptCount, 258)
        XCTAssertEqual(bounded.semanticNoOpIntentCount, 258)
        XCTAssertEqual(bounded.mutationSamples.count, 256)
        XCTAssertEqual(bounded.sampleOverflowCount, 2)
        XCTAssertEqual(bounded.mutationSamples.first?.ordinal, 3)
        XCTAssertEqual(bounded.mutationSamples.last?.ordinal, 258)
    }

    func testInvalidationDropsPendingWorkBeforeStoredCommit() async {
        let recorder = CoordinatorRecorder()
        var currentKey: MCPReadFileAutoSelectionCoordinator.ContextKey?
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == currentKey },
            applyCanonical: { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { _ in }
        )
        let key = contextKey()
        currentKey = key

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        currentKey = nil
        coordinator.invalidate(context: key)
        await coordinator.drain(.canonicalSelection, for: key)
        await Task.yield()

        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertTrue(recordedBatches.isEmpty)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: key))
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 0)
    }

    func testFinishDrainsAcceptedWorkAndRejectsLaterEnqueues() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { key, batch in
            await gate.markStartedAndWaitForRelease()
            await recorder.recordCanonical(batch)
            return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()
        let finishTask = Task { @MainActor in
            await coordinator.finish(context: key)
        }
        await Task.yield()
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: key))

        await gate.release()
        let finishResult = await finishTask.value
        XCTAssertEqual(finishResult, .completed)
        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertEqual(recordedBatches.count, 1)
        await Task.yield()
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().mirrorLaneCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().closingContextCount, 0)
    }

    func testLateLowerCanonicalCommitWaitsForItsOwnTabMirrorTicket() async {
        let firstCanonicalGate = CoordinatorAsyncGate()
        let lateMirrorGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let tabID = UUID()
        let workspaceID = UUID()
        let first = contextKey(tabID: tabID, workspaceID: workspaceID)
        let second = contextKey(tabID: tabID, workspaceID: workspaceID)
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, _ in
                if key == first {
                    await firstCanonicalGate.markStartedAndWaitForRelease()
                }
                return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { key in
                let invocation = await recorder.recordMirror(key)
                if invocation == 2 {
                    await lateMirrorGate.markStartedAndWaitForRelease()
                }
            }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: first))
        await firstCanonicalGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Second.swift"]), for: second))
        await coordinator.drain(.mirroredSelectionAndMetrics, for: second)

        await firstCanonicalGate.release()
        await lateMirrorGate.waitUntilStarted()
        let drainFinished = CoordinatorAsyncSignal()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: first)
            await drainFinished.mark()
        }
        await Task.yield()
        let finishedBeforeLateMirror = await drainFinished.isMarked()
        XCTAssertFalse(finishedBeforeLateMirror)

        await lateMirrorGate.release()
        await drainTask.value
    }

    func testReplacementBindingGenerationDropsOldWorkAndAcceptsNewWork() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let connectionID = UUID()
        let runID = UUID()
        let tabID = UUID()
        let workspaceID = UUID()
        let old = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: connectionID, runID: runID), bindingGeneration: 1)
        let replacement = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: connectionID, runID: runID), bindingGeneration: 2)
        var current = old
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == current },
            applyCanonical: { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { _ in }
        )
        coordinator.setCanonicalApplyGateForTesting {
            await gate.markStartedAndWaitForRelease()
        }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Old.swift"]), for: old))
        await gate.waitUntilStarted()
        current = replacement
        coordinator.invalidate(context: old)
        await gate.release()
        await coordinator.drain(.canonicalSelection, for: old)
        coordinator.setCanonicalApplyGateForTesting(nil)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/New.swift"]), for: replacement))
        await coordinator.drain(.canonicalSelection, for: replacement)
        let batches = await recorder.canonicalBatches()
        XCTAssertEqual(batches.map(\.fullPaths), [["/tmp/New.swift"]])
    }

    func testInvalidationDuringSuspensionPreventsStoredCommit() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()
        coordinator.setCanonicalApplyGateForTesting {
            await gate.markStartedAndWaitForRelease()
        }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()
        coordinator.invalidate(context: key)
        await gate.release()
        await coordinator.drain(.canonicalSelection, for: key)

        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertTrue(recordedBatches.isEmpty)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private func makeCoordinator(
        recorder: CoordinatorRecorder,
        applyCanonical: MCPReadFileAutoSelectionCoordinator.ApplyCanonical? = nil
    ) -> MCPReadFileAutoSelectionCoordinator {
        MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: applyCanonical ?? { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { key in
                _ = await recorder.recordMirror(key)
            }
        )
    }

    private func contextKey(
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        route: MCPReadFileAutoSelectionCoordinator.Route = .bound(connectionID: UUID(), runID: UUID()),
        bindingGeneration: UInt64 = 1
    ) -> MCPReadFileAutoSelectionCoordinator.ContextKey {
        MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            route: route,
            bindingGeneration: bindingGeneration
        )
    }
}

private actor CoordinatorRecorder {
    private var recordedCanonicalBatches: [MCPReadFileAutoSelectionCoordinator.CanonicalBatch] = []
    private var recordedKeys: [MCPReadFileAutoSelectionCoordinator.ContextKey] = []
    private var recordedMirrors: [MCPReadFileAutoSelectionCoordinator.TabMirrorKey] = []

    func recordCanonical(_ batch: MCPReadFileAutoSelectionCoordinator.CanonicalBatch) {
        recordedCanonicalBatches.append(batch)
    }

    func recordCanonicalAndCount(_ batch: MCPReadFileAutoSelectionCoordinator.CanonicalBatch) -> Int {
        recordedCanonicalBatches.append(batch)
        return recordedCanonicalBatches.count
    }

    func canonicalBatches() -> [MCPReadFileAutoSelectionCoordinator.CanonicalBatch] {
        recordedCanonicalBatches
    }

    func recordKey(_ key: MCPReadFileAutoSelectionCoordinator.ContextKey) {
        recordedKeys.append(key)
    }

    func keys() -> [MCPReadFileAutoSelectionCoordinator.ContextKey] {
        recordedKeys
    }

    func recordMirror(_ key: MCPReadFileAutoSelectionCoordinator.TabMirrorKey) -> Int {
        recordedMirrors.append(key)
        return recordedMirrors.count
    }

    func mirrorCount() -> Int {
        recordedMirrors.count
    }
}

private final class CoordinatorDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MCPReadFileAutoSelectionDiagnosticEvent] = []

    func append(_ event: MCPReadFileAutoSelectionDiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [MCPReadFileAutoSelectionDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func waitFor(
        kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
        lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane,
        timeout: Duration = .seconds(10)
    ) async throws -> MCPReadFileAutoSelectionDiagnosticEvent {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let event = snapshot().first(where: { $0.kind == kind && $0.lane == lane }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CoordinatorDiagnosticRecorderError.timedOut(kind: kind, lane: lane)
    }

    private enum CoordinatorDiagnosticRecorderError: Error {
        case timedOut(
            kind: MCPReadFileAutoSelectionDiagnosticEvent.Kind,
            lane: MCPReadFileAutoSelectionDiagnosticEvent.Lane
        )
    }
}

private actor CoordinatorAsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CoordinatorAsyncSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }

    func waitUntilMarked(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if marked {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return marked
    }
}
