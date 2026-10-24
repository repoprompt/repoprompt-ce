import Darwin
import Foundation

package struct SpawnedPTYProcess: Sendable {
    package let pid: pid_t
    package let processGroupID: pid_t?
    package let master: Int32
}

extension ProcessLauncher {
    /// Uses the same provider launch policy, signal defaults and private process group as pipes.
    /// Callers own the master and must close it before terminating/reaping the child.
    package static func spawnPTY(command: String, arguments: [String], environment: [String: String], workingDirectory: String,
                                 allowsProviderProcessLaunchForTesting: Bool = false) throws -> SpawnedPTYProcess {
        try ProviderProcessLaunchPolicy.check(allowsLaunchInTests: allowsProviderProcessLaunchForTesting)
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw ProcessLauncherError.spawnFailed(errno: errno) }
        defer { close(slave) }
        do {
            guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0, fcntl(slave, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(master, F_SETFL, O_NONBLOCK) == 0 else { throw ProcessLauncherError.spawnFailed(errno: errno) }
            _ = FDWriteSupport.configureNoSigPipe(fd: master)
            let child = try spawn(command: command, arguments: arguments, environment: environment, workingDirectory: workingDirectory,
                allowsProviderProcessLaunchForTesting: allowsProviderProcessLaunchForTesting, terminalDescriptor: slave)
            try? child.stdin?.close()
            try? child.stdout.close()
            try? child.stderr.close()
            return SpawnedPTYProcess(pid: child.pid, processGroupID: child.processGroupID, master: master)
        } catch {
            close(master)
            throw error
        }
    }
}
