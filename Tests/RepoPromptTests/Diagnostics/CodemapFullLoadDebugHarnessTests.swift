import Foundation
@testable import RepoPromptApp
import XCTest

final class CodemapFullLoadDebugHarnessTests: XCTestCase {
    func testAggregateReadyRequiresEveryRootTerminal() {
        let readyRoot = makeRoot(state: .ready)
        let ineligible = makeRoot(state: .terminalIneligible)

        XCTAssertEqual(
            CodemapFullLoadDebugSupport.aggregateState(for: [readyRoot, ineligible]),
            .ready
        )
        XCTAssertEqual(
            CodemapFullLoadDebugSupport.aggregateState(for: [readyRoot, makeRoot(state: .pending)]),
            .pending
        )
        XCTAssertEqual(
            CodemapFullLoadDebugSupport.aggregateState(for: [readyRoot, makeRoot(state: .failed)]),
            .failed
        )
        XCTAssertEqual(
            CodemapFullLoadDebugSupport.aggregateState(for: []),
            .incompleteDiagnostics
        )
    }

    func testMixedEpochUniverseDoesNotRevalidate() {
        let rootID = UUID()
        let first = CodemapFullLoadRootIdentity(
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: rootID,
                rootLifetimeID: UUID()
            ),
            catalogGeneration: 1,
            ingressGeneration: 1,
            engineIdentity: nil
        )
        let replacement = CodemapFullLoadRootIdentity(
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: rootID,
                rootLifetimeID: UUID()
            ),
            catalogGeneration: 2,
            ingressGeneration: 2,
            engineIdentity: nil
        )

        XCTAssertTrue(CodemapFullLoadDebugSupport.universeMatches([first], [first]))
        XCTAssertFalse(CodemapFullLoadDebugSupport.universeMatches([first], [replacement]))
    }

    func testCorrelationAcceptsOnlyArmedTargetAndOperation() {
        let targetID = UUID()
        let operationID = UUID()
        var correlation = CodemapFullLoadCorrelation(
            armID: UUID(),
            targetWorkspaceID: targetID,
            targetWorkspaceName: "target",
            pollIntervalMilliseconds: 100,
            timeoutMilliseconds: 300_000,
            armedUptimeNanoseconds: 10,
            operationID: nil,
            acceptedUptimeNanoseconds: nil,
            switchResult: .pending,
            invalidReason: nil
        )

        XCTAssertFalse(correlation.recordAccepted(
            operationID: operationID,
            targetWorkspaceID: UUID(),
            uptimeNanoseconds: 20
        ))
        XCTAssertTrue(correlation.recordAccepted(
            operationID: operationID,
            targetWorkspaceID: targetID,
            uptimeNanoseconds: 30
        ))
        XCTAssertFalse(correlation.recordCompletion(
            operationID: UUID(),
            result: .switched
        ))
        XCTAssertTrue(correlation.recordCompletion(
            operationID: operationID,
            result: .switched
        ))
        XCTAssertEqual(correlation.acceptedUptimeNanoseconds, 30)
        XCTAssertEqual(correlation.switchResult, .switched)
        XCTAssertNil(correlation.invalidReason)
    }

    func testStatisticsRetainValidSlowSamples() throws {
        let raw = [100.0, 110.0, 120.0, 130.0, 1000.0]
        let statistics = try XCTUnwrap(CodemapFullLoadDebugSupport.statistics(raw))

        XCTAssertEqual(statistics.raw, raw)
        XCTAssertEqual(statistics.median, 120)
        XCTAssertEqual(statistics.nearestRankP95, 1000)
        XCTAssertEqual(statistics.tukeyOutlierIndices, [4])
        XCTAssertEqual(statistics.reliability, "low")
    }

    func testPrivacySafePayloadOmitsPathsAndSourceText() throws {
        let payload = CodemapFullLoadDebugSupport.privacySafeRootPayload(
            makeRoot(state: .ready)
        )
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("root_path"))
        XCTAssertFalse(json.contains("full_path"))
        XCTAssertFalse(json.contains("source_text"))
        XCTAssertFalse(json.contains("/Users/"))
    }

    private func makeRoot(
        state: CodemapFullLoadRootState
    ) -> CodemapFullLoadRootSnapshot {
        CodemapFullLoadRootSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: UUID(),
                rootLifetimeID: UUID()
            ),
            catalogGeneration: 1,
            ingressGeneration: 1,
            rootKind: "primary_workspace",
            state: state,
            reason: nil,
            launchPhase: "handed_off",
            graphIndexPhase: state == .ready ? "complete" : nil,
            supportedCandidateCount: state == .ready ? 1 : nil,
            processedCandidateCount: state == .ready ? 1 : nil,
            terminalCount: state == .ready ? 1 : nil,
            lastGraphChangeSequence: state == .ready ? 0 : nil,
            readyUptimeNanoseconds: state == .ready ? 100 : nil,
            metrics: [:],
            resources: [:],
            queueWaitMilliseconds: [],
            milestones: []
        )
    }
}
