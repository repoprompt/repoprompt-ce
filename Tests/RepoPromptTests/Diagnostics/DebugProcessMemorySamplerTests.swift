#if DEBUG
    @testable import RepoPrompt
    import XCTest

    final class DebugProcessMemorySamplerTests: XCTestCase {
        func testCPUUsageDeltaAndAverageCoreUtilizationUseCumulativeValues() throws {
            let baseline = snapshot(timestampMS: 1000, userCPUTimeMS: 100, systemCPUTimeMS: 40)
            let final = snapshot(timestampMS: 1100, userCPUTimeMS: 250, systemCPUTimeMS: 90)

            let delta = try XCTUnwrap(final.cpuUsage.delta(since: baseline.cpuUsage))
            XCTAssertEqual(delta.userMS, 150)
            XCTAssertEqual(delta.systemMS, 50)
            XCTAssertEqual(delta.totalMS, 200)
            XCTAssertEqual(try XCTUnwrap(final.coreUtilizationPercent(since: baseline)), 200)
        }

        func testCoreUtilizationCanExceedOneHundredPercent() throws {
            let baseline = snapshot(timestampMS: 0, userCPUTimeMS: 0, systemCPUTimeMS: 0)
            let final = snapshot(timestampMS: 50, userCPUTimeMS: 90, systemCPUTimeMS: 60)

            XCTAssertEqual(try XCTUnwrap(final.coreUtilizationPercent(since: baseline)), 300)
        }

        func testCoreUtilizationRejectsInvalidWallOrCPUIntervals() {
            let baseline = snapshot(timestampMS: 100, userCPUTimeMS: 100, systemCPUTimeMS: 100)
            let noWallTime = snapshot(timestampMS: 100, userCPUTimeMS: 110, systemCPUTimeMS: 110)
            let regressedCPU = snapshot(timestampMS: 200, userCPUTimeMS: 99, systemCPUTimeMS: 120)

            XCTAssertNil(noWallTime.coreUtilizationPercent(since: baseline))
            XCTAssertNil(regressedCPU.coreUtilizationPercent(since: baseline))
        }

        func testIntervalTrackerRetainsPeakAcrossMoreSamplesThanStorageBound() throws {
            let baseline = snapshot(timestampMS: 0, userCPUTimeMS: 0, systemCPUTimeMS: 0)
            var tracker = DebugProcessCPUIntervalTracker(baseline: baseline)
            tracker.record(snapshot(timestampMS: 100, userCPUTimeMS: 250, systemCPUTimeMS: 0))

            for index in 1 ... 20001 {
                tracker.record(
                    snapshot(
                        timestampMS: Double(100 + index * 100),
                        userCPUTimeMS: Double(250 + index * 10),
                        systemCPUTimeMS: 0
                    )
                )
            }

            XCTAssertEqual(try XCTUnwrap(tracker.peakCoreUtilizationPercent), 250)
        }

        func testSnapshotPayloadContainsOnlyCumulativeCPUValues() {
            let payload = snapshot(
                timestampMS: 10,
                userCPUTimeMS: 12.34,
                systemCPUTimeMS: 5.67
            ).payload()

            XCTAssertEqual(payload["cumulative_user_cpu_ms"] as? Double, 12.3)
            XCTAssertEqual(payload["cumulative_system_cpu_ms"] as? Double, 5.7)
            XCTAssertEqual(payload["cumulative_cpu_ms"] as? Double, 18.0)
        }

        func testBenchmarkSamplerIsRevokedWhenGateDisables() async {
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(true)
            let sampler = DebugProcessMemorySampler.shared
            _ = await sampler.start(label: "gate-revocation", intervalMS: 50, reset: true, benchmarkGate: true)
            WorktreeStartupBenchmarkDiagnostics.setGateEnabled(false)
            let response = await sampler.snapshot(limit: 1)
            guard case let .error(code, _) = response else {
                return XCTFail("Expected revoked benchmark sampler")
            }
            XCTAssertEqual(code, "disabled")
        }

        private func snapshot(
            timestampMS: Double,
            userCPUTimeMS: Double,
            systemCPUTimeMS: Double
        ) -> DebugProcessMemorySnapshot {
            DebugProcessMemorySnapshot(
                timestampMS: timestampMS,
                residentBytes: 1_048_576,
                physicalFootprintBytes: 2_097_152,
                userCPUTimeMS: userCPUTimeMS,
                systemCPUTimeMS: systemCPUTimeMS
            )
        }
    }
#endif
