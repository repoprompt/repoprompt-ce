import Foundation
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

#if DEBUG
    final class HeadlessAgentConnectionGateDeadlineTests: XCTestCase {
        /// repoprompt-ce #419: a queued agent_run bootstrap must not wait indefinitely
        /// behind a held gate. It must respect a deadline and fail fast, so one stalled
        /// start cannot block every subsequent start across windows.
        func testQueuedAcquireTimesOutInsteadOfWaitingIndefinitely() async {
            await HeadlessAgentConnectionGate.cancelAll()
            let holderID = UUID()
            let waiterID = UUID()

            let holderAcquired = await HeadlessAgentConnectionGate.shared.acquire(holderID)
            XCTAssertTrue(holderAcquired, "holder should acquire the idle gate immediately")

            // The holder holds for 60s, so the waiter (200ms deadline) must time out, return
            // acquired=false with timedOut=true, and do so promptly — not park on the gate
            // continuation up to the ~30-minute MCP client idle timeout.
            let clock = ContinuousClock()
            let waitStart = clock.now
            let waiterAcquisition = await HeadlessAgentConnectionGate.shared.acquireWithDiagnostics(
                waiterID,
                deadline: .milliseconds(200)
            )
            let waitElapsed = waitStart.duration(to: clock.now)
            XCTAssertFalse(
                waiterAcquisition.acquired,
                "a queued gate acquire must respect its deadline and return acquired=false on timeout (repoprompt-ce #419)"
            )
            XCTAssertTrue(
                waiterAcquisition.timedOut,
                "a deadline expiry must be reported as timedOut=true so callers can distinguish it from cancellation (repoprompt-ce #419)"
            )
            XCTAssertLessThan(
                waitElapsed,
                .seconds(5),
                "a timed-out acquire must fail fast, well under the MCP client idle timeout (repoprompt-ce #419)"
            )

            let queued = await HeadlessAgentConnectionGate.shared.debugWaitingCount()
            XCTAssertEqual(queued, 0, "a timed-out waiter must be removed from the queue (repoprompt-ce #419)")

            await HeadlessAgentConnectionGate.shared.completeConnection(holderID)
            await HeadlessAgentConnectionGate.cancelAll()
        }
    }
#endif
