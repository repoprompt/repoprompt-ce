import Darwin
import Dispatch
import Foundation

/// Detailed child termination outcome preserving the exited-vs-signaled
/// distinction that the normalized `Int32` APIs collapse into `128 + signal`.
enum ProcessExitStatus: Equatable {
    case exited(code: Int32)
    case uncaughtSignal(signal: Int32)

    /// Matches the historical normalization used by `waitForTermination` and
    /// `terminateAndReap`: exit code as-is, uncaught signals as `128 + signal`.
    var normalizedExitCode: Int32 {
        switch self {
        case let .exited(code):
            code
        case let .uncaughtSignal(signal):
            128 &+ signal
        }
    }

    /// `Process.terminationStatus` parity: the exit code for normal exits and
    /// the raw signal number for uncaught signals.
    var terminationStatus: Int32 {
        switch self {
        case let .exited(code):
            code
        case let .uncaughtSignal(signal):
            signal
        }
    }

    /// `Process.terminationReason` parity.
    var terminationReason: Process.TerminationReason {
        switch self {
        case .exited:
            .exit
        case .uncaughtSignal:
            .uncaughtSignal
        }
    }
}

enum ProcessTerminationError: Error, LocalizedError {
    case childOwnershipLost(pid: pid_t)
    case waitFailed(String)

    var errorDescription: String? {
        switch self {
        case let .childOwnershipLost(pid):
            "waitpid reported ECHILD for sole-reaper child \(pid)"
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
    private static let blockingReapQueue = DispatchQueue(
        label: "com.repoprompt.process-termination.waitpid",
        qos: .userInitiated,
        attributes: .concurrent
    )

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

    /// Decodes a raw `waitpid` status into a detailed exit status. Statuses that
    /// are neither a normal exit nor an uncaught signal (for example a stopped
    /// child) fall back to `.exited(code: rawStatus)`, matching the historical
    /// normalized fallback of returning the raw status unchanged.
    static func decodeWaitStatus(_ rawStatus: Int32) -> ProcessExitStatus {
        if waitStatusExited(rawStatus) { return .exited(code: waitStatusExitCode(rawStatus)) }
        if waitStatusSignaled(rawStatus) { return .uncaughtSignal(signal: waitStatusSignal(rawStatus)) }
        return .exited(code: rawStatus)
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
    static func signalProcessGroupOnly(
        processGroupID: pid_t,
        signal: Int32,
        logger: (String) -> Void = { _ in }
    ) -> Bool {
        guard let processGroupID = safeProcessGroupID(processGroupID) else { return false }
        if killpg(processGroupID, signal) == 0 { return true }
        if errno != ESRCH {
            let message = String(cString: strerror(errno))
            logger("killpg(\(processGroupID), \(signal)) failed: \(message)")
        }
        return false
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
        rootExited: inout Bool,
        deadline: TimeInterval,
        pollIntervalNs: UInt64,
        waitForProcessGroupExit: Bool,
        logger: (String) -> Void
    ) async -> Bool {
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
        await terminateAndReapStatus(
            pid: pid,
            processGroupID: processGroupID,
            status: &status,
            sigtermGrace: sigtermGrace,
            sigkillGrace: sigkillGrace,
            logger: logger
        ).normalizedExitCode
    }

    private static func terminateAndReapStatus(
        pid: pid_t,
        processGroupID: pid_t?,
        status: inout Int32,
        sigtermGrace: TimeInterval,
        sigkillGrace: TimeInterval,
        logger: (String) -> Void
    ) async -> ProcessExitStatus {
        let shortPollNs = UInt64(pollInterval * 1_000_000_000)
        var lastSignal: Int32?
        var rootExited = false

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
            rootExited: &rootExited,
            deadline: sigtermDeadline,
            pollIntervalNs: shortPollNs,
            waitForProcessGroupExit: waitForProcessGroupExit,
            logger: logger
        ) {
            return decodeWaitStatus(status)
        }

        logger("Process \(pid) family did not exit after SIGTERM; sending SIGKILL")
        let sentSIGKILL: Bool = if rootExited {
            if let processGroupID = safeProcessGroupID(processGroupID) {
                signalProcessGroupOnly(
                    processGroupID: processGroupID,
                    signal: SIGKILL,
                    logger: logger
                )
            } else {
                false
            }
        } else {
            signalProcessGroupOrPID(
                pid: pid,
                processGroupID: processGroupID,
                signal: SIGKILL,
                logger: logger
            )
        }
        if sentSIGKILL {
            lastSignal = SIGKILL
        } else {
            logger("Process \(pid) could not be signaled with SIGKILL; waiting for exit/reap")
        }

        let sigkillDeadline = ProcessInfo.processInfo.systemUptime + max(sigkillGrace, 0)
        if await waitForExitUntil(
            pid: pid,
            processGroupID: processGroupID,
            status: &status,
            rootExited: &rootExited,
            deadline: sigkillDeadline,
            pollIntervalNs: shortPollNs,
            waitForProcessGroupExit: waitForProcessGroupExit,
            logger: logger
        ) {
            return decodeWaitStatus(status)
        }

        if let signal = lastSignal {
            return .uncaughtSignal(signal: signal)
        }
        return decodeWaitStatus(status)
    }

    /// Reaps one direct child with a blocking kernel wait performed outside
    /// Swift's cooperative executor. Git owns cancellation and timeout
    /// signaling separately; this method is deliberately the sole waitpid
    /// authority and never abandons the child on task cancellation.
    ///
    /// The callback runs synchronously on the blocking reaper queue after a
    /// successful waitpid and before the async continuation is resumed. This
    /// lets lifecycle owners close their PID-signaling window at the kernel
    /// reap boundary rather than after executor scheduling.
    static func reapChildStatus(
        pid: pid_t,
        onReaped: @escaping @Sendable () -> Void = {}
    ) async throws -> ProcessExitStatus {
        try await withCheckedThrowingContinuation { continuation in
            blockingReapQueue.async {
                var status: Int32 = 0
                while true {
                    let result = waitpid(pid, &status, 0)
                    if result == pid {
                        let exitStatus = decodeWaitStatus(status)
                        onReaped()
                        continuation.resume(returning: exitStatus)
                        return
                    }
                    if result == -1, errno == EINTR {
                        continue
                    }
                    if result == -1, errno == ECHILD {
                        continuation.resume(
                            throwing: ProcessTerminationError.childOwnershipLost(pid: pid)
                        )
                        return
                    }
                    let message = String(cString: strerror(errno))
                    continuation.resume(throwing: ProcessTerminationError.waitFailed(message))
                    return
                }
            }
        }
    }

    /// Cleans descendants after the direct child has already been reaped.
    /// The API intentionally accepts no PID: signaling is process-group-only,
    /// and no second waitpid or reused-PID fallback is possible.
    static func terminateProcessGroupAfterRootReap(
        processGroupID: pid_t?,
        sigtermGrace: TimeInterval? = nil,
        sigkillGrace: TimeInterval? = nil,
        logger: (String) -> Void = { _ in }
    ) async {
        guard let processGroupID = safeProcessGroupID(processGroupID),
              processGroupExists(processGroupID)
        else {
            return
        }

        let timing = currentTiming()
        _ = signalProcessGroupOnly(
            processGroupID: processGroupID,
            signal: SIGTERM,
            logger: logger
        )
        let shortPollNs = UInt64(pollInterval * 1_000_000_000)
        let termDeadline = ProcessInfo.processInfo.systemUptime + max(sigtermGrace ?? timing.sigtermGrace, 0)
        while ProcessInfo.processInfo.systemUptime < termDeadline {
            guard processGroupExists(processGroupID) else { return }
            try? await Task.sleep(nanoseconds: shortPollNs)
        }
        guard processGroupExists(processGroupID) else { return }

        _ = signalProcessGroupOnly(
            processGroupID: processGroupID,
            signal: SIGKILL,
            logger: logger
        )
        let killDeadline = ProcessInfo.processInfo.systemUptime + max(sigkillGrace ?? timing.sigkillGrace, 0)
        while ProcessInfo.processInfo.systemUptime < killDeadline {
            guard processGroupExists(processGroupID) else { return }
            try? await Task.sleep(nanoseconds: shortPollNs)
        }
        if processGroupExists(processGroupID) {
            logger("Process group \(processGroupID) remained after bounded SIGKILL cleanup")
        }
    }

    static func waitForTermination(
        pid: pid_t,
        processGroupID: pid_t?,
        timeout: TimeInterval?,
        logger: (String) -> Void = { _ in }
    ) async throws -> (exitCode: Int32, timedOut: Bool) {
        let outcome = try await waitForTerminationStatus(
            pid: pid,
            processGroupID: processGroupID,
            timeout: timeout,
            logger: logger
        )
        return (outcome.status.normalizedExitCode, outcome.timedOut)
    }

    /// Detailed variant of `waitForTermination` that preserves exited-vs-signaled
    /// semantics. Identical waiting, cancellation, timeout, and escalation
    /// behavior; only the result representation differs.
    static func waitForTerminationStatus(
        pid: pid_t,
        processGroupID: pid_t?,
        timeout: TimeInterval?,
        logger: (String) -> Void = { _ in }
    ) async throws -> (status: ProcessExitStatus, timedOut: Bool) {
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
                    let exitStatus = await terminateAndReapStatus(
                        pid: pid,
                        processGroupID: processGroupID,
                        status: &status,
                        sigtermGrace: timing.sigtermGrace,
                        sigkillGrace: timing.sigkillGrace,
                        logger: logger
                    )
                    return (exitStatus, false)
                }

                let r = waitpid(pid, &status, WNOHANG)
                if r == pid { return (decodeWaitStatus(status), false) }
                if r == 0 {
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        let timing = currentTiming()
                        logger("Process timed out after \(timeout) seconds; sending SIGTERM")
                        let exitStatus = await terminateAndReapStatus(
                            pid: pid,
                            processGroupID: processGroupID,
                            status: &status,
                            sigtermGrace: timing.sigtermGrace,
                            sigkillGrace: timing.sigkillGrace,
                            logger: logger
                        )
                        return (exitStatus, true)
                    }
                    try? await Task.sleep(nanoseconds: currentPollNs())
                    continue
                }
                if r == -1, errno == EINTR { continue }
                if r == -1, errno == ECHILD { return (decodeWaitStatus(status), false) }
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
                let exitStatus = await terminateAndReapStatus(
                    pid: pid,
                    processGroupID: processGroupID,
                    status: &status,
                    sigtermGrace: timing.sigtermGrace,
                    sigkillGrace: timing.sigkillGrace,
                    logger: logger
                )
                return (exitStatus, false)
            }

            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return (decodeWaitStatus(status), false) }
            if r == 0 {
                try? await Task.sleep(nanoseconds: currentPollNs())
                continue
            }
            if r == -1, errno == EINTR { continue }
            if r == -1, errno == ECHILD { return (decodeWaitStatus(status), false) }
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
