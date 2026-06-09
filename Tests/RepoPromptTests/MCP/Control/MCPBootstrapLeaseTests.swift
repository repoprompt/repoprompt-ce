import Foundation
@testable import RepoPrompt
import XCTest

final class MCPBootstrapLeaseTests: XCTestCase {
    func testCleanupWhileQueuedReleasesGateOwnershipThatArrivesLater() async throws {
        #if DEBUG
            let blockerGateID = UUID()
            let leaseGateID = UUID()
            let probeGateID = UUID()
            let runID = UUID()
            let recorder = PolicyRecorder()

            await HeadlessAgentConnectionGate.cancelAll()
            await HeadlessAgentConnectionGate.beginConnection(blockerGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)

            let lease = MCPBootstrapLease(
                spec: MCPBootstrapLeaseSpec(
                    runID: runID,
                    gateID: leaseGateID,
                    windowID: 1,
                    tabID: nil,
                    clientName: "bootstrap-lease-race-test",
                    restrictedTools: [],
                    additionalTools: nil,
                    oneShot: true,
                    reason: "queued cleanup regression",
                    ttl: 10,
                    purpose: .agentModeRun,
                    taskLabelKind: nil,
                    allowsAgentExternalControlTools: false,
                    requiresExpectedAgentPID: false
                ),
                policyInstaller: { _ in await recorder.recordInstall() },
                policyClearer: { _ in await recorder.recordClear() }
            )

            let acquisition = Task { await lease.acquire() }
            var queued = false
            let queueDeadline = Date().addingTimeInterval(2)
            repeat {
                queued = await HeadlessAgentConnectionGate.shared.debugWaitingCount() == 1
                if queued { break }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < queueDeadline
            let activeBeforeCleanup = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(queued, "Expected lease acquisition to queue behind blocker; active=\(String(describing: activeBeforeCleanup))")

            await lease.cancelAndCleanup()
            let activeBlockerID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertEqual(activeBlockerID, blockerGateID)

            await HeadlessAgentConnectionGate.completeConnection(blockerGateID)
            let didAcquireLease = await acquisition.value
            let installCount = await recorder.installCount
            XCTAssertFalse(didAcquireLease)
            XCTAssertEqual(installCount, 0)

            let didAcquireProbe = await HeadlessAgentConnectionGate.acquire(probeGateID)
            let activeProbeID = await HeadlessAgentConnectionGate.shared.debugActiveConnectionID()
            XCTAssertTrue(didAcquireProbe)
            XCTAssertEqual(activeProbeID, probeGateID)
            await HeadlessAgentConnectionGate.completeConnection(probeGateID)
            await MCPRoutingWaiter.cleanup(runID: runID)
        #else
            throw XCTSkip("Gate ownership inspection is DEBUG-only.")
        #endif
    }
}

private actor PolicyRecorder {
    private(set) var installCount = 0
    private(set) var clearCount = 0

    func recordInstall() {
        installCount += 1
    }

    func recordClear() {
        clearCount += 1
    }
}
