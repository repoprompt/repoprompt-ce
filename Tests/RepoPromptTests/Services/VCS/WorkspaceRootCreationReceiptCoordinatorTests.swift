import CoreServices
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRootCreationReceiptCoordinatorTests: XCTestCase {
    func testActivationUsesExplicitCutAndWaitsForFlushAndCallbackBarrier() throws {
        let fixture = try WitnessFixture(configuration: .init(
            currentEventIDs: [100, 120],
            eventsOnStart: [event("child/pre-start.txt", id: 101)]
        ))
        defer { fixture.cleanup() }

        let session = fixture.start()
        XCTAssertTrue(session.streamStartedBeforeMutation)
        let coverage = fixture.coordinator.finish(session)

        XCTAssertEqual(fixture.backend.requestedSinceWhen, 100)
        XCTAssertEqual(fixture.backend.requestedWatchRootPath, fixture.stableRoot.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            fixture.backend.operations.prefix(5),
            ["current-id", "create", "start", "flush-activation", "barrier-activation"]
        )
        XCTAssertEqual(coverage.startEventID, 100)
        XCTAssertEqual(coverage.acceptedDestinationEventCount, 1)
        XCTAssertTrue(coverage.activationFlushCompleted)
        XCTAssertTrue(coverage.activationCallbackBarrierCompleted)
        XCTAssertEqual(coverage.startAcceptedCallbackWatermark, 1)
        XCTAssertTrue(coverage.provesCreationInterval)
    }

    func testNonexistentStrictDescendantRecordsDestinationCreation() throws {
        let fixture = try WitnessFixture(configuration: .init(
            currentEventIDs: [20, 30],
            eventsOnEndingFlush: [
                event("child", id: 21),
                event("child/nested", id: 22),
                event("child/nested/copied.txt", id: 23)
            ]
        ))
        defer { fixture.cleanup() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let coverage = fixture.coordinator.finish(fixture.start())

        XCTAssertTrue(coverage.destinationWasAbsentBeforeMutation)
        XCTAssertTrue(coverage.destinationWasStrictDescendant)
        XCTAssertEqual(coverage.acceptedDestinationEventCount, 3)
        XCTAssertEqual(coverage.acceptedNonDestinationEventCount, 0)
        XCTAssertTrue(coverage.provesCreationInterval)
    }

    func testDestinationCreatedAfterActivationBarrierCannotIssueReceipt() throws {
        let fixture = try WitnessFixture(configuration: .init(
            currentEventIDs: [20, 30],
            createDestinationAfterActivationBarrier: true
        ))
        defer { fixture.cleanup() }

        let coverage = fixture.coordinator.finish(fixture.start())

        XCTAssertEqual(
            fixture.backend.operations.prefix(6),
            ["current-id", "create", "start", "flush-activation", "barrier-activation", "inject-destination"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertFalse(coverage.destinationWasAbsentBeforeMutation)
        XCTAssertTrue(coverage.hadGap)
        XCTAssertFalse(coverage.provesCreationInterval)
    }

    func testEndCutIncludesFinalFlushEventsAndExcludesPostCutEvents() throws {
        let fixture = try WitnessFixture(configuration: .init(
            currentEventIDs: [100, 150],
            eventsOnEndingFlush: [
                event("child/before-cut.txt", id: 149),
                event("child/at-cut.txt", id: 150),
                event("child/after-cut.txt", id: 151)
            ]
        ))
        defer { fixture.cleanup() }

        let coverage = fixture.coordinator.finish(fixture.start())

        XCTAssertEqual(coverage.endEventID, 150)
        XCTAssertEqual(coverage.acceptedDestinationEventCount, 2)
        XCTAssertEqual(coverage.acceptedCallbackCount, 1)
        XCTAssertEqual(coverage.acceptedEventCount, 3)
        XCTAssertEqual(coverage.endAcceptedCallbackWatermark, 1)
        XCTAssertTrue(coverage.endingFlushCompleted)
        XCTAssertTrue(coverage.endingCallbackBarrierCompleted)
        XCTAssertTrue(coverage.provesCreationInterval)
    }

    func testMustScanSubDirsOnlyToleratesProvenDisjointSibling() throws {
        let flag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let sibling = try WitnessFixture(configuration: .init(
            currentEventIDs: [10, 20],
            eventsOnEndingFlush: [event("sibling", id: 11, flags: flag)]
        ))
        defer { sibling.cleanup() }
        let siblingCoverage = sibling.coordinator.finish(sibling.start())
        XCTAssertFalse(siblingCoverage.mustScanSubDirs)
        XCTAssertTrue(siblingCoverage.provesCreationInterval)

        for relativePath in ["", "child", "child/nested"] {
            let fixture = try WitnessFixture(configuration: .init(
                currentEventIDs: [30, 40],
                eventsOnEndingFlush: [event(relativePath, id: 31, flags: flag)]
            ))
            let coverage = fixture.coordinator.finish(fixture.start())
            fixture.cleanup()
            XCTAssertTrue(coverage.mustScanSubDirs, relativePath)
            XCTAssertTrue(coverage.hadGap, relativePath)
            XCTAssertFalse(coverage.provesCreationInterval, relativePath)
        }
    }

    func testRecoveryFlagsRemainFailClosedWithExpectedClassification() throws {
        struct RecoveryCase {
            let flag: FSEventStreamEventFlags
            let assertClassification: (GitWorktreeCreationWitnessCoverage) -> Bool
            let expectsDrop: Bool
        }
        let cases: [RecoveryCase] = [
            .init(
                flag: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
                assertClassification: { $0.userDropped },
                expectsDrop: true
            ),
            .init(
                flag: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
                assertClassification: { $0.kernelDropped },
                expectsDrop: true
            ),
            .init(
                flag: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                assertClassification: { $0.eventIDsWrapped },
                expectsDrop: false
            ),
            .init(
                flag: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
                assertClassification: { $0.rootChanged },
                expectsDrop: false
            )
        ]

        for testCase in cases {
            let fixture = try WitnessFixture(configuration: .init(
                currentEventIDs: [100, 110],
                eventsOnEndingFlush: [event("sibling", id: 101, flags: testCase.flag)]
            ))
            let coverage = fixture.coordinator.finish(fixture.start())
            fixture.cleanup()
            XCTAssertTrue(testCase.assertClassification(coverage))
            XCTAssertEqual(coverage.hadDrop, testCase.expectsDrop)
            XCTAssertEqual(coverage.hadGap, !testCase.expectsDrop)
            XCTAssertFalse(coverage.provesCreationInterval)
        }
    }

    func testEventIDJumpsSucceedWhileRegressionFails() throws {
        let jumping = try WitnessFixture(configuration: .init(
            currentEventIDs: [100, 1000],
            eventsOnEndingFlush: [
                event("child/a", id: 101),
                event("child/b", id: 900)
            ]
        ))
        defer { jumping.cleanup() }
        let jumpingCoverage = jumping.coordinator.finish(jumping.start())
        XCTAssertFalse(jumpingCoverage.eventIDRegressed)
        XCTAssertTrue(jumpingCoverage.provesCreationInterval)

        let regressing = try WitnessFixture(configuration: .init(
            currentEventIDs: [100, 1000],
            eventsOnEndingFlush: [
                event("child/a", id: 900),
                event("child/b", id: 899)
            ]
        ))
        defer { regressing.cleanup() }
        let regressingCoverage = regressing.coordinator.finish(regressing.start())
        XCTAssertTrue(regressingCoverage.eventIDRegressed)
        XCTAssertTrue(regressingCoverage.hadGap)
        XCTAssertFalse(regressingCoverage.provesCreationInterval)
    }

    func testStreamCutAndBarrierFailuresRemainFailClosed() throws {
        let configurations: [ScriptedWitnessBackend.Configuration] = [
            .init(currentEventIDs: [0]),
            .init(currentEventIDs: [UInt64.max]),
            .init(currentEventIDs: [100], createSucceeds: false),
            .init(currentEventIDs: [100], startSucceeds: false),
            .init(currentEventIDs: [100], failedFlushPhases: [.activation]),
            .init(currentEventIDs: [100], failedBarrierPhases: [.activation]),
            .init(currentEventIDs: [100, 0]),
            .init(currentEventIDs: [100, UInt64.max]),
            .init(currentEventIDs: [100, 99]),
            .init(currentEventIDs: [100, 110], failedFlushPhases: [.ending]),
            .init(currentEventIDs: [100, 110], failedBarrierPhases: [.endCut]),
            .init(currentEventIDs: [100, 110], failedBarrierPhases: [.ending])
        ]

        for configuration in configurations {
            let fixture = try WitnessFixture(configuration: configuration)
            let coverage = fixture.coordinator.finish(fixture.start())
            fixture.cleanup()
            XCTAssertTrue(coverage.hadGap)
            XCTAssertFalse(coverage.provesCreationInterval)
        }
    }

    func testHundredThousandCreationEventsUseBoundedScalarStateWithoutOverflow() throws {
        let eventCount = 100_001
        let fixture = try WitnessFixture(configuration: .init(
            currentEventIDs: [100, UInt64(eventCount + 200)],
            syntheticDestinationEventCount: eventCount
        ))
        defer { fixture.cleanup() }

        let coverage = fixture.coordinator.finish(fixture.start())

        XCTAssertEqual(coverage.acceptedDestinationEventCount, eventCount)
        XCTAssertEqual(coverage.acceptedEventCount, eventCount)
        XCTAssertEqual(coverage.acceptedNonDestinationEventCount, 0)
        XCTAssertFalse(coverage.overflowed)
        XCTAssertTrue(coverage.provesCreationInterval)
        XCTAssertEqual(fixture.backend.maximumSyntheticBatchCount, 1024)
        XCTAssertEqual(fixture.backend.generatedSyntheticEventCount, eventCount)
        XCTAssertEqual(fixture.backend.stopCount, 1)
        XCTAssertEqual(fixture.backend.invalidateCount, 1)
        XCTAssertEqual(fixture.backend.releaseCount, 1)
    }

    func testAdmissionAndStableRootReplacementRemainFailClosed() throws {
        let existingDestination = try WitnessFixture(configuration: .init(currentEventIDs: [10]))
        try FileManager.default.createDirectory(
            at: existingDestination.destination,
            withIntermediateDirectories: true
        )
        let existingCoverage = existingDestination.coordinator.finish(existingDestination.start())
        existingDestination.cleanup()
        XCTAssertFalse(existingCoverage.destinationWasAbsentBeforeMutation)
        XCTAssertFalse(existingCoverage.provesCreationInterval)

        let equalDestination = try WitnessFixture(configuration: .init(currentEventIDs: [10]))
        let equalSession = equalDestination.coordinator.start(
            destinationURL: equalDestination.stableRoot,
            stableWatchRootURL: equalDestination.stableRoot
        )
        let equalCoverage = equalDestination.coordinator.finish(equalSession)
        equalDestination.cleanup()
        XCTAssertFalse(equalCoverage.destinationWasStrictDescendant)
        XCTAssertFalse(equalCoverage.provesCreationInterval)

        let replaced = try WitnessFixture(configuration: .init(currentEventIDs: [10, 20]))
        let replacedSession = replaced.start()
        try FileManager.default.removeItem(at: replaced.stableRoot)
        try FileManager.default.createDirectory(at: replaced.stableRoot, withIntermediateDirectories: true)
        let replacedCoverage = replaced.coordinator.finish(replacedSession)
        replaced.cleanup()
        XCTAssertFalse(replacedCoverage.stableWatchRootUnchangedAfterInitialization)
        XCTAssertTrue(replacedCoverage.hadGap)
        XCTAssertFalse(replacedCoverage.provesCreationInterval)
    }

    func testFinishIsIdempotentAndTearsStreamDownExactlyOnce() throws {
        let fixture = try WitnessFixture(configuration: .init(currentEventIDs: [10, 20]))
        defer { fixture.cleanup() }
        let session = fixture.start()

        let first = fixture.coordinator.finish(session)
        let second = fixture.coordinator.finish(session)

        XCTAssertEqual(first, second)
        XCTAssertEqual(fixture.backend.stopCount, 1)
        XCTAssertEqual(fixture.backend.invalidateCount, 1)
        XCTAssertEqual(fixture.backend.releaseCount, 1)
    }
}

private func event(
    _ relativePath: String,
    id: UInt64,
    flags: FSEventStreamEventFlags = 0
) -> WorkspaceRootCreationFSEvent {
    WorkspaceRootCreationFSEvent(path: relativePath, flags: flags, eventID: id)
}

private final class WitnessFixture {
    let sandbox: URL
    let stableRoot: URL
    let destination: URL
    let backend: ScriptedWitnessBackend
    let coordinator: WorkspaceRootCreationReceiptCoordinator

    init(configuration: ScriptedWitnessBackend.Configuration) throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRootCreationReceiptCoordinatorTests-\(UUID().uuidString)")
        stableRoot = sandbox.appendingPathComponent("managed", isDirectory: true)
        destination = stableRoot.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: stableRoot, withIntermediateDirectories: true)
        backend = ScriptedWitnessBackend(
            stableRootURL: stableRoot,
            configuration: configuration
        )
        coordinator = WorkspaceRootCreationReceiptCoordinator(backend: backend)
    }

    func start() -> WorkspaceRootCreationReceiptCoordinator.Session {
        coordinator.start(destinationURL: destination, stableWatchRootURL: stableRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}

private final class ScriptedWitnessBackend: @unchecked Sendable,
    WorkspaceRootCreationWitnessFSEventsBackend
{
    struct Configuration {
        var currentEventIDs: [UInt64]
        var createSucceeds = true
        var startSucceeds = true
        var failedFlushPhases: Set<WorkspaceRootCreationWitnessFlushPhase> = []
        var failedBarrierPhases: Set<WorkspaceRootCreationWitnessBarrierPhase> = []
        var eventsOnStart: [WorkspaceRootCreationFSEvent] = []
        var eventsOnActivationFlush: [WorkspaceRootCreationFSEvent] = []
        var eventsOnEndingFlush: [WorkspaceRootCreationFSEvent] = []
        var syntheticDestinationEventCount = 0
        var createDestinationAfterActivationBarrier = false
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var currentEventIDs: [UInt64]
        var operations: [String] = []
        var requestedSinceWhen: UInt64?
        var requestedWatchRootPath: String?
        var stopCount = 0
        var invalidateCount = 0
        var releaseCount = 0
        var maximumSyntheticBatchCount = 0
        var generatedSyntheticEventCount = 0

        init(currentEventIDs: [UInt64]) {
            self.currentEventIDs = currentEventIDs
        }
    }

    private let stableRootURL: URL
    private let configuration: Configuration
    private let state: State

    init(stableRootURL: URL, configuration: Configuration) {
        self.stableRootURL = stableRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.configuration = configuration
        state = State(currentEventIDs: configuration.currentEventIDs)
    }

    var operations: [String] {
        state.lock.withLock { state.operations }
    }

    var requestedSinceWhen: UInt64? {
        state.lock.withLock { state.requestedSinceWhen }
    }

    var requestedWatchRootPath: String? {
        state.lock.withLock { state.requestedWatchRootPath }
    }

    var stopCount: Int {
        state.lock.withLock { state.stopCount }
    }

    var invalidateCount: Int {
        state.lock.withLock { state.invalidateCount }
    }

    var releaseCount: Int {
        state.lock.withLock { state.releaseCount }
    }

    var maximumSyntheticBatchCount: Int {
        state.lock.withLock { state.maximumSyntheticBatchCount }
    }

    var generatedSyntheticEventCount: Int {
        state.lock.withLock { state.generatedSyntheticEventCount }
    }

    func currentEventID() -> FSEventStreamEventId {
        state.lock.withLock {
            state.operations.append("current-id")
            guard !state.currentEventIDs.isEmpty else { return 0 }
            return state.currentEventIDs.removeFirst()
        }
    }

    func makeStream(
        watchRootURL: URL,
        sinceWhen: FSEventStreamEventId,
        onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
    ) -> (any WorkspaceRootCreationWitnessEventStream)? {
        state.lock.withLock {
            state.operations.append("create")
            state.requestedWatchRootPath = watchRootURL.path
            state.requestedSinceWhen = sinceWhen
        }
        guard configuration.createSucceeds else { return nil }
        return ScriptedWitnessStream(
            stableRootURL: stableRootURL,
            configuration: configuration,
            state: state,
            onEvents: onEvents
        )
    }

    private final class ScriptedWitnessStream: @unchecked Sendable,
        WorkspaceRootCreationWitnessEventStream
    {
        private let stableRootURL: URL
        private let configuration: Configuration
        private let state: State
        private let onEvents: @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
        private let queue = DispatchQueue(label: "com.repoprompt.tests.scripted-witness")

        init(
            stableRootURL: URL,
            configuration: Configuration,
            state: State,
            onEvents: @escaping @Sendable ([WorkspaceRootCreationFSEvent]) -> Void
        ) {
            self.stableRootURL = stableRootURL
            self.configuration = configuration
            self.state = state
            self.onEvents = onEvents
        }

        func start() -> Bool {
            record("start")
            guard configuration.startSucceeds else { return false }
            enqueue(configuration.eventsOnStart)
            return true
        }

        func flushSync(phase: WorkspaceRootCreationWitnessFlushPhase) -> Bool {
            record(phase == .activation ? "flush-activation" : "flush-ending")
            guard !configuration.failedFlushPhases.contains(phase) else { return false }
            let events = phase == .activation
                ? configuration.eventsOnActivationFlush
                : configuration.eventsOnEndingFlush
            enqueue(events)
            if phase == .ending {
                enqueueSyntheticDestinationEvents(count: configuration.syntheticDestinationEventCount)
            }
            return true
        }

        func synchronizeCallbacks(
            phase: WorkspaceRootCreationWitnessBarrierPhase,
            _ body: @escaping @Sendable () -> Void
        ) -> Bool {
            let label = switch phase {
            case .activation: "barrier-activation"
            case .endCut: "barrier-end-cut"
            case .ending: "barrier-ending"
            }
            record(label)
            guard !configuration.failedBarrierPhases.contains(phase) else { return false }
            queue.sync(execute: body)
            if phase == .activation, configuration.createDestinationAfterActivationBarrier {
                try? FileManager.default.createDirectory(
                    at: stableRootURL.appendingPathComponent("child", isDirectory: true),
                    withIntermediateDirectories: false
                )
                record("inject-destination")
            }
            return true
        }

        func stop() {
            state.lock.withLock {
                state.operations.append("stop")
                state.stopCount += 1
            }
        }

        func invalidate() {
            state.lock.withLock {
                state.operations.append("invalidate")
                state.invalidateCount += 1
            }
        }

        func release() {
            state.lock.withLock {
                state.operations.append("release")
                state.releaseCount += 1
            }
        }

        private func enqueueSyntheticDestinationEvents(count: Int) {
            guard count > 0 else { return }
            let batchLimit = 1024
            queue.async {
                var generated = 0
                while generated < count {
                    let batchCount = min(batchLimit, count - generated)
                    let events = (0 ..< batchCount).map { offset in
                        let index = generated + offset
                        return WorkspaceRootCreationFSEvent(
                            path: self.stableRootURL
                                .appendingPathComponent("child/synthetic-\(index).txt").path,
                            flags: 0,
                            eventID: UInt64(index + 101)
                        )
                    }
                    self.state.lock.withLock {
                        self.state.maximumSyntheticBatchCount = max(
                            self.state.maximumSyntheticBatchCount,
                            batchCount
                        )
                        self.state.generatedSyntheticEventCount += batchCount
                    }
                    self.onEvents(events)
                    generated += batchCount
                }
            }
        }

        private func enqueue(_ events: [WorkspaceRootCreationFSEvent]) {
            guard !events.isEmpty else { return }
            let absoluteEvents = events.map { event in
                let path = event.path.isEmpty
                    ? stableRootURL.path
                    : stableRootURL.appendingPathComponent(event.path).path
                return WorkspaceRootCreationFSEvent(
                    path: path,
                    flags: event.flags,
                    eventID: event.eventID
                )
            }
            queue.async {
                self.onEvents(absoluteEvents)
            }
        }

        private func record(_ operation: String) {
            state.lock.withLock {
                state.operations.append(operation)
            }
        }
    }
}
