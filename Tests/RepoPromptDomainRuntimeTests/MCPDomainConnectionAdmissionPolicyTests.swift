import Foundation
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    final class MCPDomainConnectionAdmissionPolicyTests: XCTestCase {
        func testCanonicalClassificationUsesDefaultPhysicalLanesAndRetainsPermitsUntilSettlement() async throws {
            let cases: [(tool: String, lane: MCPDomainConnectionCallLane, limit: Int)] = [
                ("file_actions", .ordinary, 1),
                ("agent_session_link", .control, 8),
                ("get_file_tree", .smallRead, 2),
                ("read_file", .fileRead, ContentReadConcurrencyCapacity.maximumConcurrentReads),
                ("git", .gitRead, 2),
                ("file_search", .fileSearch, 4)
            ]
            XCTAssertEqual(Set(cases.map(\.lane)), Set(MCPDomainConnectionCallLane.allCases))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            for testCase in cases {
                let admissionClass = try XCTUnwrap(MCPDomainToolCatalog.admissionClass(for: testCase.tool))
                XCTAssertEqual(admissionClass.connectionLane, testCase.lane, testCase.tool)
                let limiters = MCPDomainConnectionCallLimiters()
                let limiter = await limiters.limiterForTesting(admissionClass.connectionLane)
                let gate = ConnectionAdmissionSettlementGate()
                let entered = expectation(description: "\(testCase.tool) fills its physical lane")
                entered.expectedFulfillmentCount = testCase.limit
                let owners = (0 ..< testCase.limit).map { index in
                    Task {
                        try await limiters.withPermit(lane: admissionClass.connectionLane) {
                            try Data("effect".utf8).write(to: root.appendingPathComponent("\(testCase.tool)-\(index)"))
                            entered.fulfill()
                            await gate.wait()
                        }
                    }
                }
                await fulfillment(of: [entered], timeout: 5)
                let occupied = await limiter.debugSnapshot()
                XCTAssertEqual(occupied.limit, testCase.limit, testCase.tool)
                XCTAssertEqual(occupied.activePermitCount, testCase.limit, testCase.tool)
                XCTAssertEqual(occupied.permits, 0, testCase.tool)

                let queued = expectation(description: "\(testCase.tool) overflow waits before its effect")
                await limiter.setDebugStateObserver { snapshot in
                    if snapshot.waiterCount == 1 { queued.fulfill() }
                }
                let rejectedFile = root.appendingPathComponent("\(testCase.tool)-cancelled")
                let overflow = Task {
                    try await limiters.withPermit(lane: admissionClass.connectionLane) {
                        try Data("must not execute".utf8).write(to: rejectedFile)
                    }
                }
                await fulfillment(of: [queued], timeout: 5)
                await limiter.setDebugStateObserver(nil)
                overflow.cancel()
                switch await overflow.result {
                case .success:
                    XCTFail("Queued call must cancel without entering its provider: \(testCase.tool)")
                case let .failure(error):
                    XCTAssertTrue(error is CancellationError, "\(error)")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedFile.path))
                // A cancelled running provider is still a physical owner until it returns.
                owners.first?.cancel()
                let cancelling = await limiter.debugSnapshot()
                XCTAssertEqual(cancelling.activePermitCount, testCase.limit, testCase.tool)
                XCTAssertEqual(cancelling.waiterCount, 0, testCase.tool)
                await gate.release()
                for owner in owners {
                    if case let .failure(error) = await owner.result { XCTFail("\(error)") }
                }
                let settled = await limiter.debugSnapshot()
                XCTAssertEqual(settled.activePermitCount, 0, testCase.tool)
                XCTAssertEqual(settled.permits, testCase.limit, testCase.tool)
                let active = await limiters.hasInFlightCalls()
                XCTAssertFalse(active, testCase.tool)
                for index in 0 ..< testCase.limit {
                    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("\(testCase.tool)-\(index)"), encoding: .utf8), "effect")
                }
            }
        }

        func testExplicitTestCapacityOverrideDoesNotChangeOtherCanonicalLanes() async {
            let limiters = MCPDomainConnectionCallLimiters(fileReadLimit: 1)
            let snapshot = await limiters.diagnosticsSnapshot()
            XCTAssertEqual(snapshot.fileRead.limit, 1)
            XCTAssertEqual(snapshot.ordinary.limit, MCPDomainToolAdmissionLimits.exclusiveConnection)
            XCTAssertEqual(snapshot.control.limit, MCPDomainToolAdmissionLimits.controlConnection)
            XCTAssertEqual(snapshot.smallRead.limit, MCPDomainToolAdmissionLimits.smallReadConnection)
            XCTAssertEqual(snapshot.gitRead.limit, MCPDomainToolAdmissionLimits.gitReadConnection)
            XCTAssertEqual(snapshot.fileSearch.limit, MCPDomainToolAdmissionLimits.fileSearchConnection)
        }
    }

    private actor ConnectionAdmissionSettlementGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
#endif
