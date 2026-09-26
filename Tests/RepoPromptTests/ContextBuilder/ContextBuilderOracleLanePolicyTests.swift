import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderOracleLanePolicyTests: XCTestCase {
        private enum SetupFailure: Error { case rejected }

        func testSourceObservationRenewsBeforeDelayedReportingButCannotResurrect() {
            for observation in [599.0, 600, 601] {
                let clock = OracleSupervisionTestClock()
                let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
                let lane = group.makeLane(sessionID: UUID())
                XCTAssertTrue(lane.bind(queryID: UUID()))
                clock.advance(to: observation)
                lane.observeActivity()
                clock.advance(to: 605) // A delayed cumulative report has no renewal API.
                XCTAssertEqual(lane.isLive, observation < 600, "observation=\(observation)")
                if observation >= 600 {
                    XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
                }
            }
        }

        func testBindingAndFirstPhaseTransitionsRenewOnceWithoutResettingOverall() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
            let lane = group.makeLane(sessionID: UUID())
            clock.advance(to: 100)
            XCTAssertTrue(lane.bind(queryID: UUID()))
            clock.advance(to: 699)
            XCTAssertFalse(lane.bind(queryID: UUID()), "Repeated binding cannot renew")
            lane.observeProviderStop()
            clock.advance(to: 1298)
            lane.observeProviderStop() // Duplicate is not activity.
            lane.observeFinalizationStart()
            clock.advance(to: 1897)
            lane.observeFinalizationStart()
            clock.advance(to: 1898)
            XCTAssertFalse(lane.isLive)
            let error = try XCTUnwrap(lane.terminalError as? OracleLaneFailure)
            XCTAssertEqual(error.code, "context_builder_inactivity_timeout")
            XCTAssertTrue(error.message.contains("finalization"))
            XCTAssertLessThan(error.message.count, 512)

            let overallClock = OracleSupervisionTestClock()
            let overallGroup = ContextBuilderOracleGroupSupervision(
                configuration: .init(overallTimeout: 900, inactivityTimeout: 600, checkInterval: 5),
                clock: { overallClock.now }
            )
            let overallLane = overallGroup.makeLane(sessionID: UUID())
            overallClock.advance(to: 500)
            XCTAssertTrue(overallLane.bind(queryID: UUID()))
            overallClock.advance(to: 899)
            overallLane.observeProviderStop()
            overallClock.advance(to: 900)
            overallLane.observeFinalizationStart()
            XCTAssertEqual((overallLane.terminalError as? OracleLaneFailure)?.code, "context_builder_overall_timeout")
        }

        func testAdmissionChecksEqualityAndOverallPrecedenceWithoutPollingOrProducer() throws {
            for (time, code) in [(600.0, "context_builder_inactivity_timeout"), (14400.0, "context_builder_overall_timeout")] {
                for success in [true, false] {
                    let clock = OracleSupervisionTestClock()
                    let lane = ContextBuilderOracleGroupSupervision(clock: { clock.now }).makeLane(sessionID: UUID())
                    clock.advance(to: time)
                    if success { XCTAssertThrowsError(try lane.admitSuccess()) }
                    else { lane.admitFailure(SetupFailure.rejected) }
                    XCTAssertNil(lane.queryID, "A terminal setup branch need not invent a producer")
                    XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, code)
                }
            }
            let lane = ContextBuilderOracleGroupSupervision().makeLane(sessionID: UUID())
            lane.admitFailure(SetupFailure.rejected)
            XCTAssertTrue(lane.terminalError is SetupFailure)
            XCTAssertNil(lane.queryID)
        }

        func testObservableCancellationWinsUnlatchedButLatchedOutcomeIsImmutable() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(clock: { clock.now })
            let cancelled = group.makeLane(sessionID: UUID())
            let timedOut = group.makeLane(sessionID: UUID())
            let succeeded = group.makeLane(sessionID: UUID())
            clock.advance(to: 599)
            try succeeded.admitSuccess()
            clock.advance(to: 600)
            XCTAssertFalse(timedOut.checkDeadlines())
            cancelled.cancellation.request()
            XCTAssertThrowsError(try cancelled.admitSuccess())
            XCTAssertTrue(cancelled.terminalError is CancellationError)
            timedOut.cancellation.request()
            timedOut.admitFailure(CancellationError())
            XCTAssertEqual((timedOut.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
            group.cancellation.request()
            XCTAssertFalse(succeeded.checkDeadlines())
            XCTAssertNil(succeeded.terminalError, "Later cancellation cannot rewrite accepted success")
        }
    }
#endif
