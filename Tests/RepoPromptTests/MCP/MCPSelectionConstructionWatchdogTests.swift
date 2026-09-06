import Foundation
@testable import RepoPromptApp
import XCTest

/// Attribution matrix for the `manage_selection` construction interval.
///
/// When one of the three awaited construction dependencies stops observing cancellation, the
/// watchdog packet has to name that dependency instead of the combined interval. Each case here
/// holds exactly one capability across the execution deadline and cleanup grace, then asserts the
/// phase a watchdog packet would carry. Time is virtual and sequencing uses the watchdog's own
/// scheduling hooks, so nothing depends on wall-clock timing.
@MainActor
final class MCPSelectionConstructionWatchdogTests: XCTestCase {
    private enum HeldStage {
        case stabilization
        case gitReviewFreeze
        case artifactResolution
    }

    /// When the held capability is allowed to return.
    private enum ReleasePoint {
        /// Never released by the watchdog run; the test releases after settlement. Models a
        /// dependency that ignores cancellation entirely.
        case afterWatchdogSettles
        /// Released once the watchdog has cancelled the operation but before cleanup grace
        /// begins. Models a dependency that returns late, after cancellation was requested.
        case beforeCleanupGrace
    }

    // MARK: - Synchronisation primitives

    /// One-shot broadcast used to order the operation against watchdog scheduling points.
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                isSignalled = true
                defer { waiters.removeAll() }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if isSignalled { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    /// A capability that suspends until released, standing in for a stalled dependency.
    private final class Gate: @unchecked Sendable {
        let entered = Signal()
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if isReleased { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                } else {
                    entered.signal()
                }
            }
        }

        func release() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                isReleased = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    /// Advances one millisecond per phase report.
    ///
    /// `MCPToolExecutionHandlerPhaseRecorder` timestamps every `report(...)` call through this
    /// closure, so a snapshot's `elapsedMilliseconds` is the 1-based ordinal of the report that
    /// produced it. That turns the latest-snapshot recorder into an exact statement about how many
    /// reports ran, which is how the otherwise unobservable `completed` transitions are pinned.
    private final class VirtualPhaseClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: Int64 = 0

        func tick() -> Duration {
            lock.withLock {
                ticks += 1
                return .milliseconds(ticks)
            }
        }
    }

    /// Report ordinals emitted by `MCPSelectionConstruction.run` for an artifact-aware operation.
    /// Removing or relocating any `completed` report shifts every later ordinal.
    private enum Ordinal {
        static let stabilizationStarted = 2.0
        static let freezeStarted = 5.0
        static let artifactStarted = 8.0
        static let aggregateAfterArtifact = 10.0
        static let aggregateAfterStabilizationOnly = 4.0
    }

    /// Virtual clock for the watchdog itself, distinct from the phase-report clock.
    ///
    /// The watchdog compares an operation's completion timestamp against the deadline instant it
    /// captured at start, so a late completion is only classified as post-deadline if time has
    /// actually moved. A frozen clock would make every completion look timely.
    private final class VirtualWatchdogClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Duration = .zero

        func now() -> Duration {
            lock.withLock { current }
        }

        func advance(to value: Duration) {
            lock.withLock { current = value }
        }
    }

    // MARK: - Observations

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var phases: [String: MCPToolExecutionHandlerPhaseSnapshot] = [:]
        private var selections: [String: [String]] = [:]

        func record(
            _ name: String,
            phase: MCPToolExecutionHandlerPhaseSnapshot?,
            selectedPaths: [String]
        ) {
            lock.withLock {
                names.append(name)
                if let phase { phases[name] = phase }
                selections[name] = selectedPaths
            }
        }

        var ordered: [String] {
            lock.withLock { names }
        }

        func phase(at name: String) -> MCPToolExecutionHandlerPhaseSnapshot? {
            lock.withLock { phases[name] }
        }

        func selectedPaths(at name: String) -> [String]? {
            lock.withLock { selections[name] }
        }
    }

    // MARK: - Fixtures

    /// Distinguishable stages so an identity double cannot hide a lost snapshot update.
    private static let inputPath = "input.swift"
    private static let stabilizedPath = "stabilized.swift"
    private static let physicalPrefix = "physical/"
    private static var physicalizedPath: String {
        physicalPrefix + stabilizedPath
    }

    private static func makeSnapshot() -> MCPServerViewModel.TabContextSnapshot {
        MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 1,
            workspaceID: UUID(),
            promptText: "",
            selection: StoredSelection(selectedPaths: [inputPath]),
            selectedMetaPromptIDs: [],
            tabName: "tab",
            runID: nil,
            explicitlyBound: true
        )
    }

    private static func makeInputs() -> MCPServerViewModel.ManageSelectionInputs {
        MCPServerViewModel.ManageSelectionInputs(
            paths: [inputPath],
            sliceInputs: [],
            sliceErrors: [],
            hadExplicitSliceSpec: false
        )
    }

    private static func resolution() -> MCPManageSelectionArtifactResolution {
        MCPManageSelectionArtifactResolution(
            ordinaryPaths: [inputPath],
            ordinarySliceInputs: [],
            artifacts: [],
            invalidDiagnostics: [],
            fence: nil
        )
    }

    /// Physicalization is a visible, non-identity transform of the stabilized selection.
    private static func physicalize(_ selection: StoredSelection) -> StoredSelection {
        StoredSelection(selectedPaths: selection.selectedPaths.map { physicalPrefix + $0 })
    }

    /// The three injected construction capabilities.
    private struct Capabilities {
        let stabilize: MCPAppPhysicalCapabilityAdapters.StabilizedVirtualSelection
        let freeze: MCPAppPhysicalCapabilityAdapters.FreezePromptGitReviewContext
        let resolve: MCPAppPhysicalCapabilityAdapters.ResolveManageSelectionArtifactInputs
    }

    /// Recorder whose virtual clock advances one millisecond per phase report, which is what makes
    /// a snapshot's `elapsedMilliseconds` the ordinal of the report that produced it.
    private static func makeOrdinalRecorder() -> MCPToolExecutionHandlerPhaseRecorder {
        let clock = VirtualPhaseClock()
        return MCPToolExecutionHandlerPhaseRecorder(origin: .zero, now: { clock.tick() })
    }

    /// Builds the capability doubles. Each records its invocation, the phase in effect when it ran,
    /// and the selection it observed. `heldStage` suspends that one stage on `gate` to model a
    /// dependency that stops responding; `nil` lets every stage run to completion.
    private static func makeCapabilities(
        calls: CallLog,
        recorder: MCPToolExecutionHandlerPhaseRecorder,
        heldStage: HeldStage? = nil,
        gate: Gate? = nil
    ) -> Capabilities {
        let holdIfNeeded: @Sendable (HeldStage) async -> Void = { stage in
            guard stage == heldStage, let gate else { return }
            await gate.wait()
        }
        return Capabilities(
            stabilize: { context in
                calls.record(
                    "stabilize",
                    phase: recorder.snapshot(),
                    selectedPaths: context.selection.selectedPaths
                )
                await holdIfNeeded(.stabilization)
                return StoredSelection(selectedPaths: [stabilizedPath])
            },
            freeze: { context in
                calls.record(
                    "freeze",
                    phase: recorder.snapshot(),
                    selectedPaths: context.selection.selectedPaths
                )
                await holdIfNeeded(.gitReviewFreeze)
                return .automaticOnly()
            },
            resolve: { request in
                calls.record(
                    "resolve",
                    phase: recorder.snapshot(),
                    selectedPaths: request.physicalSelection.selectedPaths
                )
                await holdIfNeeded(.artifactResolution)
                return resolution()
            }
        )
    }

    private func assertOrdinal(
        _ snapshot: MCPToolExecutionHandlerPhaseSnapshot?,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let snapshot else {
            return XCTFail("expected a recorded phase snapshot", file: file, line: line)
        }
        XCTAssertEqual(
            snapshot.elapsedMilliseconds,
            expected,
            accuracy: 0.0001,
            "unexpected phase-report ordinal; a started/completed report was added, removed, or moved",
            file: file,
            line: line
        )
    }

    /// Asserts the snapshot names `expected`, reads `started`, and carries its expected report
    /// ordinal. Covers child and aggregate intervals alike: construction leaves every interval it
    /// owns in `started`, because the aggregate's `completed` is reported later by the provider's
    /// per-operation branches.
    private func assertRecordedPhase(
        _ snapshot: MCPToolExecutionHandlerPhaseSnapshot?,
        _ expected: MCPToolExecutionHandlerPhase,
        ordinal: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot?.phase, expected, file: file, line: line)
        XCTAssertEqual(snapshot?.transition, .started, file: file, line: line)
        assertOrdinal(snapshot, ordinal, file: file, line: line)
    }

    // MARK: - Held capability: never observes cancellation

    func testHeldVirtualSelectionStabilizationIsAttributedAtWatchdogBoundary() async throws {
        try await assertHeldStage(
            .stabilization,
            releaseAt: .afterWatchdogSettles,
            expectedPhase: .manageSelectionConstructionVirtualSelectionStabilization,
            expectedCalls: ["stabilize"],
            expectedOrdinal: Ordinal.stabilizationStarted,
            expectedError: .cleanupUnresponsive
        )
    }

    func testHeldGitReviewContextFreezeIsAttributedAtWatchdogBoundary() async throws {
        try await assertHeldStage(
            .gitReviewFreeze,
            releaseAt: .afterWatchdogSettles,
            expectedPhase: .manageSelectionConstructionGitReviewContextFreeze,
            expectedCalls: ["stabilize", "freeze"],
            expectedOrdinal: Ordinal.freezeStarted,
            expectedError: .cleanupUnresponsive
        )
    }

    func testHeldArtifactInputResolutionIsAttributedAtWatchdogBoundary() async throws {
        try await assertHeldStage(
            .artifactResolution,
            releaseAt: .afterWatchdogSettles,
            expectedPhase: .manageSelectionConstructionArtifactInputResolution,
            expectedCalls: ["stabilize", "freeze", "resolve"],
            expectedOrdinal: Ordinal.artifactStarted,
            expectedError: .cleanupUnresponsive
        )
    }

    // MARK: - Late return after cancellation

    // Each capability returns only after the watchdog has already cancelled the operation. The
    // post-await cancellation check must convert that late return into a cancellation instead of
    // reporting `completed`, so the stalled child stays named in the packet.

    func testLateStabilizationReturnAfterCancellationKeepsChildAttribution() async throws {
        try await assertHeldStage(
            .stabilization,
            releaseAt: .beforeCleanupGrace,
            expectedPhase: .manageSelectionConstructionVirtualSelectionStabilization,
            expectedCalls: ["stabilize"],
            expectedOrdinal: Ordinal.stabilizationStarted,
            expectedError: .executionTimedOut(settlement: .cancellation)
        )
    }

    func testLateGitReviewFreezeReturnAfterCancellationKeepsChildAttribution() async throws {
        try await assertHeldStage(
            .gitReviewFreeze,
            releaseAt: .beforeCleanupGrace,
            expectedPhase: .manageSelectionConstructionGitReviewContextFreeze,
            expectedCalls: ["stabilize", "freeze"],
            expectedOrdinal: Ordinal.freezeStarted,
            expectedError: .executionTimedOut(settlement: .cancellation)
        )
    }

    func testLateArtifactResolutionReturnAfterCancellationKeepsChildAttribution() async throws {
        try await assertHeldStage(
            .artifactResolution,
            releaseAt: .beforeCleanupGrace,
            expectedPhase: .manageSelectionConstructionArtifactInputResolution,
            expectedCalls: ["stabilize", "freeze", "resolve"],
            expectedOrdinal: Ordinal.artifactStarted,
            expectedError: .executionTimedOut(settlement: .cancellation)
        )
    }

    private func assertHeldStage(
        _ held: HeldStage,
        releaseAt: ReleasePoint,
        expectedPhase: MCPToolExecutionHandlerPhase,
        expectedCalls: [String],
        expectedOrdinal: Double,
        expectedError: MCPToolExecutionWatchdogError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let gate = Gate()
        let calls = CallLog()
        let operationBodyFinished = Signal()
        let operationTaskSettled = Signal()
        let operationCompletionConsumed = Signal()
        let recorder = Self.makeOrdinalRecorder()
        let capabilities = Self.makeCapabilities(
            calls: calls,
            recorder: recorder,
            heldStage: held,
            gate: gate
        )

        let deadline = Duration.seconds(30)
        let cancellationGrace = Duration.seconds(5)
        let watchdogClock = VirtualWatchdogClock()

        // Virtual time: sleeps return immediately, except that in the late-return case the grace
        // timer is withheld until the watchdog's main loop has already dequeued the operation's
        // completion. Gating on production of that event would still race, because the producing
        // hook runs one statement before the value is yielded; gating on its consumption means the
        // loop is committed to the completion branch before grace can yield anything.
        let environment = MCPToolExecutionWatchdogEnvironment(
            now: { watchdogClock.now() },
            sleep: { duration in
                if duration == cancellationGrace, releaseAt == .beforeCleanupGrace {
                    await operationCompletionConsumed.wait()
                }
            },
            eventDidProduce: { point in
                switch point {
                case .deadlineExpired:
                    await gate.entered.wait()
                case .cleanupGraceExpired:
                    break
                case .operationCompleted:
                    operationTaskSettled.signal()
                }
            },
            beforeEventConsumption: { point in
                if point == .operationCompleted { operationCompletionConsumed.signal() }
            },
            beforeCleanupGraceTaskRegistration: {
                // The watchdog has cancelled the operation. Move virtual time past the deadline so
                // a late completion is classified as a post-deadline settlement, not a timely one.
                watchdogClock.advance(to: deadline + .milliseconds(1))
                if releaseAt == .beforeCleanupGrace { gate.release() }
            }
        )

        let snapshot = Self.makeSnapshot()
        let inputs = Self.makeInputs()

        var watchdogError: Error?
        do {
            _ = try await MCPToolExecutionWatchdog.execute(
                deadline: deadline,
                cancellationGrace: cancellationGrace,
                cleanupDisposition: .forceDisconnect,
                environment: environment,
                operation: {
                    defer { operationBodyFinished.signal() }
                    try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(recorder) {
                        _ = try await MCPSelectionConstruction.run(
                            snapshot: snapshot,
                            op: "add",
                            mode: "full",
                            parsedInputs: inputs,
                            physicalize: Self.physicalize,
                            stabilizedVirtualSelection: capabilities.stabilize,
                            freezePromptGitReviewContext: capabilities.freeze,
                            resolveManageSelectionArtifactInputs: capabilities.resolve
                        )
                    }
                }
            )
        } catch {
            watchdogError = error
        }

        XCTAssertEqual(
            watchdogError as? MCPToolExecutionWatchdogError,
            expectedError,
            file: file,
            line: line
        )

        let latest = recorder.snapshot()
        XCTAssertEqual(latest?.phase, expectedPhase, file: file, line: line)
        XCTAssertEqual(
            latest?.transition,
            .started,
            "a stalled or late-returning child must never be recorded as completed",
            file: file,
            line: line
        )
        assertOrdinal(latest, expectedOrdinal, file: file, line: line)
        XCTAssertEqual(
            calls.ordered,
            expectedCalls,
            "downstream capabilities must not run while an earlier one is held",
            file: file,
            line: line
        )

        // Teardown: release if the scenario has not already, then await the operation body and the
        // watchdog's operation task completion bookkeeping so no task outlives the test.
        gate.release()
        await operationBodyFinished.wait()
        await operationTaskSettled.wait()
    }

    // MARK: - Successful path

    func testSuccessfulConstructionReportsChildPhasesInOrderAndRestoresAggregate() async throws {
        let calls = CallLog()
        let recorder = Self.makeOrdinalRecorder()
        let capabilities = Self.makeCapabilities(calls: calls, recorder: recorder)

        let outcome = try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(recorder) {
            try await MCPSelectionConstruction.run(
                snapshot: Self.makeSnapshot(),
                op: "add",
                mode: "full",
                parsedInputs: Self.makeInputs(),
                physicalize: Self.physicalize,
                stabilizedVirtualSelection: capabilities.stabilize,
                freezePromptGitReviewContext: capabilities.freeze,
                resolveManageSelectionArtifactInputs: capabilities.resolve
            )
        }

        XCTAssertEqual(calls.ordered, ["stabilize", "freeze", "resolve"])

        // Data path: stabilization replaces the inbound selection, physicalization transforms the
        // stabilized value, and both downstream capabilities observe the transformed snapshot.
        XCTAssertEqual(calls.selectedPaths(at: "stabilize"), [Self.inputPath])
        XCTAssertEqual(calls.selectedPaths(at: "freeze"), [Self.physicalizedPath])
        XCTAssertEqual(calls.selectedPaths(at: "resolve"), [Self.physicalizedPath])
        XCTAssertEqual(outcome.snapshot.selection.selectedPaths, [Self.physicalizedPath])

        // Each child phase is opened immediately before its await, and the ordinals pin the
        // intervening `completed` reports.
        assertRecordedPhase(
            calls.phase(at: "stabilize"),
            .manageSelectionConstructionVirtualSelectionStabilization,
            ordinal: Ordinal.stabilizationStarted
        )
        assertRecordedPhase(
            calls.phase(at: "freeze"),
            .manageSelectionConstructionGitReviewContextFreeze,
            ordinal: Ordinal.freezeStarted
        )
        assertRecordedPhase(
            calls.phase(at: "resolve"),
            .manageSelectionConstructionArtifactInputResolution,
            ordinal: Ordinal.artifactStarted
        )

        // The aggregate interval owns the remaining synchronous construction work.
        assertRecordedPhase(
            recorder.snapshot(),
            .manageSelectionConstruction,
            ordinal: Ordinal.aggregateAfterArtifact
        )

        XCTAssertEqual(outcome.artifactResolution, Self.resolution())
        XCTAssertNotNil(outcome.frozenReviewContext)
    }

    /// Operations outside the artifact-aware set must not consult Git review context or the
    /// artifact resolver at all, while still completing the stabilization child.
    func testNonArtifactOperationSkipsFreezeAndArtifactResolution() async throws {
        let calls = CallLog()
        let recorder = Self.makeOrdinalRecorder()
        let capabilities = Self.makeCapabilities(calls: calls, recorder: recorder)

        let outcome = try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(recorder) {
            try await MCPSelectionConstruction.run(
                snapshot: Self.makeSnapshot(),
                op: "get",
                mode: "full",
                parsedInputs: Self.makeInputs(),
                physicalize: Self.physicalize,
                stabilizedVirtualSelection: capabilities.stabilize,
                freezePromptGitReviewContext: capabilities.freeze,
                resolveManageSelectionArtifactInputs: capabilities.resolve
            )
        }

        XCTAssertEqual(calls.ordered, ["stabilize"])
        XCTAssertNil(outcome.frozenReviewContext)
        XCTAssertEqual(outcome.snapshot.selection.selectedPaths, [Self.physicalizedPath])
        XCTAssertEqual(outcome.artifactResolution.ordinaryPaths, [Self.inputPath])
        XCTAssertTrue(outcome.artifactResolution.artifacts.isEmpty)

        assertRecordedPhase(
            recorder.snapshot(),
            .manageSelectionConstruction,
            ordinal: Ordinal.aggregateAfterStabilizationOnly
        )
    }
}
