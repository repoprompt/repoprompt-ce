import Darwin
import Dispatch
import Foundation

/// Tracks launcher-owned children independently of provider actors and terminal publication.
/// Signaling and consuming waits share a lock; exit cleanup never competes with the sole reaper.
/// Groups whose leader was already reaped remain the normal lifecycle owner's responsibility.
package final class AppChildProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [pid_t: pid_t] = [:]
    private var launchesInFlight = 0
    private var exiting = false

    func beginLaunch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exiting else { return false }
        launchesInFlight += 1
        return true
    }

    func finishLaunch() {
        lock.lock()
        launchesInFlight -= 1
        lock.unlock()
    }

    func register(pid: pid_t, processGroupID: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        children[pid] = processGroupID
        if exiting {
            signalOwnedGroup(pid: pid, processGroupID: processGroupID)
        }
    }

    /// Existing callers only wait nonblocking, or after proving terminal state with WNOWAIT.
    /// Keep the syscall nonblocking even if that external proof becomes stale.
    package func waitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ options: Int32) -> pid_t {
        lock.lock()
        if exiting, let groupID = children[pid] {
            signalOwnedGroup(pid: pid, processGroupID: groupID)
        }
        let result = Darwin.waitpid(pid, status, options | WNOHANG)
        let savedErrno = errno
        if result == pid || (result == -1 && errno == ECHILD) {
            children.removeValue(forKey: pid)
        }
        lock.unlock()
        errno = savedErrno
        return result
    }

    /// The unreaped child pins numeric PID/group ownership. Never signal stale registry entries.
    private func signalOwnedGroup(pid: pid_t, processGroupID: pid_t) {
        var info = siginfo_t()
        guard Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            if errno == ECHILD { children.removeValue(forKey: pid) }
            return
        }
        _ = ProcessTermination.signalProcessGroupOnly(processGroupID: processGroupID, signal: SIGKILL)
    }

    private func killOwnedChildren() {
        lock.lock()
        defer { lock.unlock() }
        exiting = true
        for (pid, groupID) in Array(children) {
            signalOwnedGroup(pid: pid, processGroupID: groupID)
        }
    }

    private func ownedChildrenHaveExited() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard launchesInFlight == 0 else { return false }
        return children.keys.allSatisfy { pid in
            var info = siginfo_t()
            let result = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            return (result == 0 && info.si_pid == pid) || (result == -1 && errno == ECHILD)
        }
    }

    package func terminateForAppExit() async {
        // Blocking ACP writes can occupy Swift cooperative workers. Deliver the kill on GCD,
        // independently of that pool and caller cancellation, without blocking MainActor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                killOwnedChildren()
                let deadline = ContinuousClock.now + .milliseconds(500)
                while !ownedChildrenHaveExited(), ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                // Owners keep their full exit status and sole-reap authority. If an owner is stuck,
                // its killed child's zombie is reparented and reaped by the OS on app exit.
                continuation.resume()
            }
        }
    }
}
