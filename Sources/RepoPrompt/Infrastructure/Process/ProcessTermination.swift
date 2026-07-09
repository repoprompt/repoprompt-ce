import Darwin
import Foundation

enum ProcessTerminationError: Error, LocalizedError {
    case waitFailed(String)

    var errorDescription: String? {
        switch self {
        case let .waitFailed(message):
            "waitpid failed: \(message)"
        }
    }
}

enum ProcessTermination {
    private struct TerminationTiming {
        let cooperativeWaitTimeout: TimeInterval
        let sigtermGrace: TimeInterval
        let sigkillGrace: TimeInterval
    }

    private static let pollInterval: TimeInterval = 0.05
    private static let longPollInterval: TimeInterval = 0.2
    private static let longPollThreshold: TimeInterval = 2.0
    private static let defaultSigtermGracePeriod: TimeInterval = 2.0
    private static let defaultSigkillGracePeriod: TimeInterval = 1.0
    private static let defaultCooperativeWaitTimeout: TimeInterval = 3.0
    private static let appTerminationSigtermGracePeriod: TimeInterval = 0.2
    private static let appTerminationSigkillGracePeriod: TimeInterval = 0.2
    private static let appTerminationCooperativeWaitTimeout: TimeInterval = 0.75
    private static let terminationModeLock = NSLock()
    private static var appTerminationFastPathEnabled = false

    static func beginAppTerminationFastPath() {
        terminationModeLock.lock()
        appTerminationFastPathEnabled = true
        terminationModeLock.unlock()
    }

    static func resetAppTerminationFastPath() {
        terminationModeLock.lock()
        appTerminationFastPathEnabled = false
        terminationModeLock.unlock()
    }

    static func cooperativeCancellationWaitTimeout() -> TimeInterval {
        currentTiming().cooperativeWaitTimeout
    }

    private static func currentTiming() -> TerminationTiming {
        terminationModeLock.lock()
        let fastPathEnabled = appTerminationFastPathEnabled
        terminationModeLock.unlock()

        if fastPathEnabled {
            return TerminationTiming(
                cooperativeWaitTimeout: appTerminationCooperativeWaitTimeout,
                sigtermGrace: appTerminationSigtermGracePeriod,
                sigkillGrace: appTerminationSigkillGracePeriod
            )
        }

        return TerminationTiming(
            cooperativeWaitTimeout: defaultCooperativeWaitTimeout,
            sigtermGrace: defaultSigtermGracePeriod,
            sigkillGrace: defaultSigkillGracePeriod
        )
    }

    @inline(__always)
    private static func waitStatusExited(_ status: Int32) -> Bool {
        (status & 0x7F) == 0
    }

    @inline(__always)
    private static func waitStatusExitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xFF
    }

    @inline(__always)
    private static func waitStatusSignaled(_ status: Int32) -> Bool {
        let signal = status & 0x7F
        return signal != 0 && signal != 0x7F
    }

    @inline(__always)
    private static func waitStatusSignal(_ status: Int32) -> Int32 {
        status & 0x7F
    }

    @inline(__always)
    private static func normalizedExitCode(_ rawStatus: Int32) -> Int32 {
        if waitStatusExited(rawStatus) { return waitStatusExitCode(rawStatus) }
        if waitStatusSignaled(rawStatus) { return 128 &+ waitStatusSignal(rawStatus) }
        return rawStatus
    }

    private static func safeProcessGroupID(_ processGroupID: pid_t?) -> pid_t? {
        guard let processGroupID, processGroupID > 0 else { return nil }
        // Never signal our own group; provider cleanup must not be able to take down
        // RepoPrompt or the test runner if metadata is wrong or a PID/PGID was reused.
        // A stale PGID could theoretically be reused by an unrelated process family
        // after the original group exits; cleanup callers keep the TERM→KILL window
        // short and only pass PGIDs returned from ProcessLauncher.spawn.
        guard processGroupID != getpgrp() else { return nil }
        return processGroupID
    }

    private static func processGroupExists(_ processGroupID: pid_t?) -> Bool {
        guard let processGroupID = safeProcessGroupID(processGroupID) else { return false }
        if killpg(processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    @discardableResult
    static func signalProcessGroupOrPID(
        pid: pid_t,
        processGroupID: pid_t?,
        signal: Int32,
        logger: (String) -> Void = { _ in }
    ) -> Bool {
        if let processGroupID = safeProcessGroupID(processGroupID) {
            if killpg(processGroupID, signal) == 0 { return true }
            if errno != ESRCH {
                let message = String(cString: strerror(errno))
                logger("killpg(\(processGroupID), \(signal)) failed: \(message); falling back to pid \(pid)")
            }
        }
        if kill(pid, signal) == 0 { return true }
        if errno != ESRCH {
            let message = String(cString: strerror(errno))
            logger("kill(\(pid), \(signal)) failed: \(message)")
        }
        return false
    }

    private static func waitForExitUntil(
        pid: pid_t,
        processGroupID: pid_t?,
        status: inout Int32,
        deadline: TimeInterval,
        pollIntervalNs: UInt64,
        waitForProcessGroupExit: Bool,
        logger: (String) -> Void
    ) async -> Bool {
        var rootExited = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !rootExited {
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid {
                    rootExited = true
                } else if r == -1, errno == EINTR {
                    continue
                } else if r == -1, errno == ECHILD {
                    rootExited = true
                } else if r == -1 {
                    let message = String(cString: strerror(errno))
                    logger("waitpid failed while reaping process \(pid): \(message)")
                    return false
                }
            }
            if rootExited {
                if !waitForProcessGroupExit || !processGroupExists(processGroupID) {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        return false
    }

    private static func terminateAndReap(
        pid: pid_t,
        processGroupID: pid_t?,
        status: inout Int32,
        sigtermGrace: TimeInterval,
        sigkillGrace: TimeInterval,
        logger: (String) -> Void
    ) async -> Int32 {
        let shortPollNs = UInt64(pollInterval * 1_000_000_000)
        var lastSignal: Int32?

        if signalProcessGroupOrPID(pid: pid, processGroupID: processGroupID, signal: SIGTERM, logger: logger) {
            lastSignal = SIGTERM
        } else {
            logger("Process \(pid) could not be signaled with SIGTERM; waiting for exit/reap")
        }

        let waitForProcessGroupExit = safeProcessGroupID(processGroupID) != nil
        let sigtermDeadline = ProcessInfo.processInfo.systemUptime + max(sigtermGrace, 0)
        if await waitForExitUntil(
            pid: pid,
            processGroupID: processGroupID,
            status: &status,
            deadline: sigtermDeadline,
            pollIntervalNs: shortPollNs,
            waitForProcessGroupExit: waitForProcessGroupExit,
            logger: logger
        ) {
            return normalizedExitCode(status)
        }

        logger("Process \(pid) family did not exit after SIGTERM; sending SIGKILL")
        if signalProcessGroupOrPID(pid: pid, processGroupID: processGroupID, signal: SIGKILL, logger: logger) {
            lastSignal = SIGKILL
        } else {
            logger("Process \(pid) could not be signaled with SIGKILL; waiting for exit/reap")
        }

        let sigkillDeadline = ProcessInfo.processInfo.systemUptime + max(sigkillGrace, 0)
        if await waitForExitUntil(
            pid: pid,
            processGroupID: processGroupID,
            status: &status,
            deadline: sigkillDeadline,
            pollIntervalNs: shortPollNs,
            waitForProcessGroupExit: waitForProcessGroupExit,
            logger: logger
        ) {
            return normalizedExitCode(status)
        }

        if let signal = lastSignal {
            return 128 &+ signal
        }
        return normalizedExitCode(status)
    }

    static func waitForTermination(
        pid: pid_t,
        processGroupID: pid_t?,
        timeout: TimeInterval?,
        logger: (String) -> Void = { _ in }
    ) async throws -> (exitCode: Int32, timedOut: Bool) {
        var status: Int32 = 0
        let start = ProcessInfo.processInfo.systemUptime
        let shortPollNs = UInt64(pollInterval * 1_000_000_000)
        let longPollNs = UInt64(longPollInterval * 1_000_000_000)

        @inline(__always)
        func currentPollNs() -> UInt64 {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            return elapsed < longPollThreshold ? shortPollNs : longPollNs
        }

        if let timeout {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                if Task.isCancelled {
                    let timing = currentTiming()
                    logger("Process cancelled; terminating")
                    let code = await terminateAndReap(
                        pid: pid,
                        processGroupID: processGroupID,
                        status: &status,
                        sigtermGrace: timing.sigtermGrace,
                        sigkillGrace: timing.sigkillGrace,
                        logger: logger
                    )
                    return (code, false)
                }

                let r = waitpid(pid, &status, WNOHANG)
                if r == pid { return (normalizedExitCode(status), false) }
                if r == 0 {
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        let timing = currentTiming()
                        logger("Process timed out after \(timeout) seconds; sending SIGTERM")
                        let code = await terminateAndReap(
                            pid: pid,
                            processGroupID: processGroupID,
                            status: &status,
                            sigtermGrace: timing.sigtermGrace,
                            sigkillGrace: timing.sigkillGrace,
                            logger: logger
                        )
                        return (code, true)
                    }
                    try? await Task.sleep(nanoseconds: currentPollNs())
                    continue
                }
                if r == -1, errno == EINTR { continue }
                if r == -1, errno == ECHILD { return (normalizedExitCode(status), false) }
                if r == -1 {
                    let message = String(cString: strerror(errno))
                    throw ProcessTerminationError.waitFailed(message)
                }
            }
        }

        while true {
            if Task.isCancelled {
                let timing = currentTiming()
                logger("Process cancelled; terminating")
                let code = await terminateAndReap(
                    pid: pid,
                    processGroupID: processGroupID,
                    status: &status,
                    sigtermGrace: timing.sigtermGrace,
                    sigkillGrace: timing.sigkillGrace,
                    logger: logger
                )
                return (code, false)
            }

            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return (normalizedExitCode(status), false) }
            if r == 0 {
                try? await Task.sleep(nanoseconds: currentPollNs())
                continue
            }
            if r == -1, errno == EINTR { continue }
            if r == -1, errno == ECHILD { return (normalizedExitCode(status), false) }
            if r == -1 {
                let message = String(cString: strerror(errno))
                throw ProcessTerminationError.waitFailed(message)
            }
        }
    }

    static func terminateAndReap(
        pid: pid_t,
        processGroupID: pid_t?,
        sigtermGrace: TimeInterval? = nil,
        sigkillGrace: TimeInterval? = nil,
        logger: (String) -> Void = { _ in }
    ) async -> Int32 {
        var status: Int32 = 0
        let timing = currentTiming()
        return await terminateAndReap(
            pid: pid,
            processGroupID: processGroupID,
            status: &status,
            sigtermGrace: sigtermGrace ?? timing.sigtermGrace,
            sigkillGrace: sigkillGrace ?? timing.sigkillGrace,
            logger: logger
        )
    }
}
