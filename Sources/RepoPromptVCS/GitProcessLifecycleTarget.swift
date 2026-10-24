import Darwin
import Foundation
import RepoPromptProcess

/// Minimal PID/process-group signal surface for one spawned git child.
///
/// A target with a launcher-supplied process group is group-only for its entire
/// lifetime: an ESRCH from killpg can never fall back to the direct PID. A PID
/// is signalable only when no process group was ever supplied and the root has
/// not been reaped. Finalization deactivates both routes.
package final class GitProcessLifecycleTarget: @unchecked Sendable {
    package let processIdentifier: pid_t
    package let processGroupID: pid_t?

    private let lock = NSLock()
    private var rootReaped = false
    private var active = true

    package init(processIdentifier: pid_t, processGroupID: pid_t?) {
        self.processIdentifier = processIdentifier
        self.processGroupID = processGroupID
    }

    /// True until the sole reaper observes direct-child termination.
    package var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && !rootReaped && processIdentifier > 0
    }

    /// Marks the direct child as reaped. Later lifecycle signals are restricted
    /// to the process group and can never fall back to the now-reusable PID.
    package func markTerminated() {
        lock.lock()
        rootReaped = true
        lock.unlock()
    }

    /// Closes the signaling lifetime at the finalization commit point.
    package func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    @discardableResult
    package func terminate() -> Bool {
        sendSignal(SIGTERM)
    }

    @discardableResult
    package func forceKill() -> Bool {
        sendSignal(SIGKILL)
    }

    /// The target lock covers both the lifecycle check and signal syscall. This
    /// makes deactivation atomic with signaling instead of leaving a PID/PGID
    /// reuse window between an unlocked check and `kill`.
    private func sendSignal(_ signalValue: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }

        if let processGroupID {
            return ProcessTermination.signalProcessGroupOnly(
                processGroupID: processGroupID,
                signal: signalValue
            )
        }

        guard !rootReaped, processIdentifier > 0 else { return false }
        return ProcessTermination.signalProcessGroupOrPID(
            pid: processIdentifier,
            processGroupID: nil,
            signal: signalValue
        )
    }
}
