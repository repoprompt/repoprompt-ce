import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderWatchdogStabilityTests: XCTestCase {
        /// #803: a silent-but-alive lane survives several inactivity budgets.
        /// The ticket lane scope now owns this deadline; provider observation routing
        /// is covered separately by ProviderOracleActivityIntegrationTests.
        func testLivenessRenewedLaneOutlivesSeveralInactivityBudgets() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(
                configuration: .init(overallTimeout: 1000, inactivityTimeout: 10, checkInterval: 1),
                clock: { clock.now }
            )
            let lane = group.makeLane(sessionID: UUID())
            XCTAssertTrue(lane.bind(queryID: UUID()))

            for beat in 1 ... 5 {
                let renewal = TimeInterval(beat) * 8
                clock.advance(to: renewal)
                XCTAssertTrue(lane.observeActivity())
                clock.advance(to: renewal + 7)
                XCTAssertTrue(lane.isLive, "Liveness-renewed lane timed out at beat \(beat)")
            }

            try lane.admitSuccess()
            XCTAssertNil(lane.terminalError)
        }

        /// A process/socket that stops signalling still expires; later activity
        /// and a late completion must not resurrect the already timed-out lane.
        func testLaneThatStopsSignallingLivenessStillTimesOut() throws {
            let clock = OracleSupervisionTestClock()
            let group = ContextBuilderOracleGroupSupervision(
                configuration: .init(overallTimeout: 1000, inactivityTimeout: 10, checkInterval: 1),
                clock: { clock.now }
            )
            let lane = group.makeLane(sessionID: UUID())
            XCTAssertTrue(lane.bind(queryID: UUID()))
            for renewal in [8.0, 16.0] {
                clock.advance(to: renewal)
                XCTAssertTrue(lane.observeActivity())
            }
            clock.advance(to: 25.9)
            XCTAssertTrue(lane.isLive)
            clock.advance(to: 26)
            XCTAssertFalse(lane.isLive)
            XCTAssertEqual((lane.terminalError as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
            clock.advance(to: 27)
            XCTAssertFalse(lane.observeActivity())
            XCTAssertThrowsError(try lane.admitSuccess()) { error in
                XCTAssertEqual((error as? OracleLaneFailure)?.code, "context_builder_inactivity_timeout")
            }
        }
    }
#endif
