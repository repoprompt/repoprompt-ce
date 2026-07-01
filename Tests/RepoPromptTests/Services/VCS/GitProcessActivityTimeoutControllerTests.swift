import Foundation
@testable import RepoPrompt
import XCTest

#if DEBUG
    final class GitProcessActivityTimeoutControllerTests: XCTestCase {
        func testRescheduleFencesSupersededActivityTimeoutBeforeTerminateClaim() async {
            let driver = TimeoutCheckpointDriver()
            let signals = TimeoutSignalRecorder()
            let controller = makeController(driver: driver, signals: signals)
            let process = Process()

            controller.schedule(
                process: process,
                processIdentifier: 101,
                timeout: .seconds(30),
                terminationGrace: .seconds(1)
            )
            await driver.waitFor(.sleep(1, .activityTimeout))
            await driver.release(.sleep(1, .activityTimeout))
            await driver.waitFor(.beforeTimeoutClaim(1))

            controller.schedule(
                process: process,
                processIdentifier: 101,
                timeout: .seconds(30),
                terminationGrace: .seconds(1)
            )
            await driver.release(.beforeTimeoutClaim(1))
            await driver.waitFor(.timeoutClaimResult(1, false))

            XCTAssertEqual(signals.terminateCount, 0)
            XCTAssertFalse(controller.didTimeOut)
            await cancelAndDrain(controller: controller, driver: driver, generation: 2)
        }

        func testLateOutputAfterSIGTERMPreservesTimeoutAndSIGKILLEscalation() async {
            let driver = TimeoutCheckpointDriver()
            let signals = TimeoutSignalRecorder()
            let controller = makeController(driver: driver, signals: signals)
            let process = Process()

            controller.schedule(
                process: process,
                processIdentifier: 202,
                timeout: .seconds(30),
                terminationGrace: .seconds(1)
            )
            await driver.waitFor(.sleep(1, .activityTimeout))
            await driver.release(.sleep(1, .activityTimeout))
            await driver.waitFor(.beforeTimeoutClaim(1))
            await driver.release(.beforeTimeoutClaim(1))
            await driver.waitFor(.timeoutClaimResult(1, true))
            XCTAssertEqual(signals.terminateCount, 1)
            XCTAssertTrue(controller.didTimeOut)

            await driver.waitFor(.sleep(1, .terminationGrace))
            controller.schedule(
                process: process,
                processIdentifier: 202,
                timeout: .seconds(30),
                terminationGrace: .seconds(1)
            )
            XCTAssertTrue(controller.didTimeOut)

            await driver.release(.sleep(1, .terminationGrace))
            await driver.waitFor(.beforeKillClaim(1))
            await driver.release(.beforeKillClaim(1))
            await driver.waitFor(.killClaimResult(1, true))

            XCTAssertEqual(signals.forceKillCount, 1)
            XCTAssertTrue(controller.didTimeOut)
        }

        func testCancelFencesPendingActivityTimeoutBeforeTerminateClaim() async {
            let driver = TimeoutCheckpointDriver()
            let signals = TimeoutSignalRecorder()
            let controller = makeController(driver: driver, signals: signals)
            let process = Process()

            controller.schedule(
                process: process,
                processIdentifier: 303,
                timeout: .seconds(30),
                terminationGrace: .seconds(1)
            )
            await driver.waitFor(.sleep(1, .activityTimeout))
            await driver.release(.sleep(1, .activityTimeout))
            await driver.waitFor(.beforeTimeoutClaim(1))

            controller.cancel()
            await driver.release(.beforeTimeoutClaim(1))
            await driver.waitFor(.timeoutClaimResult(1, false))

            XCTAssertEqual(signals.terminateCount, 0)
            XCTAssertEqual(signals.forceKillCount, 0)
            XCTAssertFalse(controller.didTimeOut)
        }

        private func makeController(
            driver: TimeoutCheckpointDriver,
            signals: TimeoutSignalRecorder
        ) -> GitProcessActivityTimeoutController {
            GitProcessActivityTimeoutController(testingHooks: .init(
                sleep: { _, generation, phase in
                    await driver.pause(.sleep(generation, phase))
                },
                beforeTimeoutClaim: { generation in
                    await driver.pause(.beforeTimeoutClaim(generation))
                },
                afterTimeoutClaim: { generation, claimed in
                    await driver.signal(.timeoutClaimResult(generation, claimed))
                },
                beforeKillClaim: { generation in
                    await driver.pause(.beforeKillClaim(generation))
                },
                afterKillClaim: { generation, claimed in
                    await driver.signal(.killClaimResult(generation, claimed))
                },
                isProcessRunning: { _ in true },
                terminate: { _ in signals.recordTerminate() },
                forceKill: { processIdentifier in signals.recordForceKill(processIdentifier) }
            ))
        }

        private func cancelAndDrain(
            controller: GitProcessActivityTimeoutController,
            driver: TimeoutCheckpointDriver,
            generation: UInt64
        ) async {
            await driver.waitFor(.sleep(generation, .activityTimeout))
            controller.cancel()
            await driver.release(.sleep(generation, .activityTimeout))
            await driver.waitFor(.beforeTimeoutClaim(generation))
            await driver.release(.beforeTimeoutClaim(generation))
            await driver.waitFor(.timeoutClaimResult(generation, false))
        }
    }

    private enum TimeoutCheckpoint: Hashable {
        case sleep(UInt64, GitProcessActivityTimeoutController.TestingSleepPhase)
        case beforeTimeoutClaim(UInt64)
        case timeoutClaimResult(UInt64, Bool)
        case beforeKillClaim(UInt64)
        case killClaimResult(UInt64, Bool)
    }

    private actor TimeoutCheckpointDriver {
        private var arrived: Set<TimeoutCheckpoint> = []
        private var arrivalWaiters: [TimeoutCheckpoint: [CheckedContinuation<Void, Never>]] = [:]
        private var blocked: [TimeoutCheckpoint: [CheckedContinuation<Void, Never>]] = [:]
        private var released: Set<TimeoutCheckpoint> = []

        func pause(_ checkpoint: TimeoutCheckpoint) async {
            signal(checkpoint)
            if released.remove(checkpoint) != nil {
                return
            }
            await withCheckedContinuation { continuation in
                blocked[checkpoint, default: []].append(continuation)
            }
        }

        func signal(_ checkpoint: TimeoutCheckpoint) {
            arrived.insert(checkpoint)
            let waiters = arrivalWaiters.removeValue(forKey: checkpoint) ?? []
            waiters.forEach { $0.resume() }
        }

        func waitFor(_ checkpoint: TimeoutCheckpoint) async {
            if arrived.contains(checkpoint) {
                return
            }
            await withCheckedContinuation { continuation in
                arrivalWaiters[checkpoint, default: []].append(continuation)
            }
        }

        func release(_ checkpoint: TimeoutCheckpoint) {
            let waiters = blocked.removeValue(forKey: checkpoint) ?? []
            if waiters.isEmpty {
                released.insert(checkpoint)
            } else {
                waiters.forEach { $0.resume() }
            }
        }
    }

    private final class TimeoutSignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var terminateSignals = 0
        private var forceKillSignals: [pid_t] = []

        var terminateCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return terminateSignals
        }

        var forceKillCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return forceKillSignals.count
        }

        func recordTerminate() {
            lock.lock()
            terminateSignals += 1
            lock.unlock()
        }

        func recordForceKill(_ processIdentifier: pid_t) {
            lock.lock()
            forceKillSignals.append(processIdentifier)
            lock.unlock()
        }
    }
#endif
