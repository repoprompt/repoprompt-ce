#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class WorkspaceFileContextStoreGraphObservabilityTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
        func testCurrentStoreSnapshotExposesRetryExhaustionWithoutArmOrWorkspaceSwitch() async throws {
            let fixture = try CodemapStoreFixture(name: #function)
            addTeardownBlock { await fixture.shutdown() }
            let clock = GraphStoreObservabilityTestClock()
            let retryPolicy = WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy(
                maximumRetryCount: 0,
                initialBackoffNanoseconds: 0,
                maximumBackoffNanoseconds: 0,
                nowNanoseconds: { clock.next() },
                sleep: { _ in }
            )
            let store = fixture.makeStore(
                codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe { _ in
                    .transientUnavailable(.gitProcessUnavailable)
                },
                codemapGraphIndexBuildRetryPolicy: retryPolicy
            )
            let root = try fixture.makePlainRoot(files: [
                "Sources/Seed.swift": SwiftFixtureSource.emptyStruct("Seed")
            ])
            let loaded = try await store.loadRoot(path: root.path)

            let exhaustedEventObserved = await waitForCodemapGraphIndexBuildEvent(
                store: store,
                rootID: loaded.id,
                kind: .retryExhausted
            )
            XCTAssertTrue(exhaustedEventObserved)
            let snapshot = await store.debugCodemapGraphStatusSnapshot(
                rootID: loaded.id,
                includeEvents: true,
                eventLimit: 32
            )
            let rootSnapshot = try XCTUnwrap(snapshot.roots.first)
            let launch = try XCTUnwrap(rootSnapshot.launch)
            let exhausted = try XCTUnwrap(launch.retryExhaustion)
            XCTAssertEqual(launch.phase, .retryExhausted)
            XCTAssertFalse(launch.taskPresent)
            let ordinaryStatus = await store.currentCodemapRootStatusUpdate()
            let ordinaryRoot = try XCTUnwrap(ordinaryStatus.roots.first { $0.rootEpoch.rootID == loaded.id })
            XCTAssertEqual(ordinaryRoot.availability, .unavailable)
            XCTAssertEqual(ordinaryRoot.unavailableReason, .retryExhausted)
            XCTAssertNil(launch.retry)
            XCTAssertEqual(exhausted.attempt, 1)
            XCTAssertLessThanOrEqual(launch.createdUptimeNanoseconds, launch.phaseEnteredUptimeNanoseconds)
            XCTAssertLessThanOrEqual(launch.phaseEnteredUptimeNanoseconds, exhausted.uptimeNanoseconds)
            XCTAssertNil(rootSnapshot.job)
            XCTAssertTrue(rootSnapshot.milestones.contains { $0.kind == "retryExhausted" })
            XCTAssertTrue(snapshot.storeEvents?.events.contains { $0.kind == "retryExhausted" } == true)

            let cursor = try XCTUnwrap(snapshot.storeEvents?.events.first?.ordinal)
            let paged = await store.debugCodemapGraphIndexStoreEvents(
                rootID: loaded.id,
                sinceOrdinal: cursor,
                limit: 1
            )
            XCTAssertEqual(paged.events.count, 1)
            XCTAssertGreaterThan(paged.events[0].ordinal, cursor)
            XCTAssertEqual(paged.nextOrdinal, paged.events.last?.ordinal)
            XCTAssertLessThan(try XCTUnwrap(paged.nextOrdinal), paged.lastOrdinal)

            let prioritizeDisposition = await store.prioritizeCodemapGraphIndexNow(rootID: loaded.id)
            XCTAssertEqual(prioritizeDisposition, .scheduled)
            let prioritizeEventObserved = await waitForCodemapGraphIndexBuildEvent(
                store: store,
                rootID: loaded.id,
                kind: .prioritizeNow
            )
            XCTAssertTrue(prioritizeEventObserved)
        }
    }

    private final class GraphStoreObservabilityTestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 10_000_000

        func next() -> UInt64 {
            lock.withLock {
                value += 1_000_000
                return value
            }
        }
    }
#endif
