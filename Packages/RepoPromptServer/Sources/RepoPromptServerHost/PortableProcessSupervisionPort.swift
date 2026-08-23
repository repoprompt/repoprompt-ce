import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptLinuxSupport
import RepoPromptServiceProtocol

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public actor PortableProcessSupervisionPort: ProcessSupervisionPort {
    public struct CapturedProcess: Sendable {
        public let identity: ProcessIdentity
        public let stdoutPath: String
        public let stderrPath: String
    }

    private var processes: [Int32: Process] = [:]
    private var identities: [Int32: ProcessIdentity] = [:]
    private var standardInputs: [Int32: FileHandle] = [:]
    private var standardInputPipes: [Int32: Pipe] = [:]
    private var cgroupPaths: [Int32: String] = [:]
    private var wrapperPIDs: [Int32: Int32] = [:]
    private var leaderPIDsByWrapper: [Int32: Int32] = [:]
    private var launchControlDirectories: [Int32: String] = [:]
    private let bootID: String
    private let delegatedCgroupRoot: String?

    public init(cgroupRoot: String? = ProcessInfo.processInfo.environment["REPOPROMPT_PROVIDER_CGROUP_ROOT"]) throws {
        #if os(Linux)
            guard rp_enable_child_subreaper() == 0 else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Unable to enable Linux child subreaper")
            }
            bootID = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown-linux-boot"
            delegatedCgroupRoot = Self.validatedCgroupV2Root(cgroupRoot)
        #else
            bootID = "darwin-\(ProcessInfo.processInfo.systemUptime)"
            delegatedCgroupRoot = nil
        #endif
    }

    public func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: FileHandle.nullDevice, stdout: FileHandle.nullDevice, stderr: FileHandle.nullDevice)
    }

    public func launchCaptured(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, outputDirectory: String) async throws -> CapturedProcess {
        try Self.prepareOutputDirectory(outputDirectory)
        let id = UUID().uuidString
        let stdoutPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stdout").path
        let stderrPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stderr").path
        guard FileManager.default.createFile(atPath: stdoutPath, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: stderrPath, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output files could not be created")
        }
        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        do {
            let identity = try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: FileHandle.nullDevice, stdout: stdout, stderr: stderr)
            return CapturedProcess(identity: identity, stdoutPath: stdoutPath, stderrPath: stderrPath)
        } catch {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
            throw error
        }
    }

    /// Launches a bidirectional provider protocol while retaining the same
    /// subreaper/process-family identity and captured-output guarantees.
    public func launchInteractiveCaptured(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, outputDirectory: String, captureID: UUID = UUID(), launchValidation: @escaping @Sendable () throws -> Void = {}) async throws -> CapturedProcess {
        try Self.prepareOutputDirectory(outputDirectory)
        let id = captureID.uuidString
        let stdoutPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stdout").path
        let stderrPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stderr").path
        guard FileManager.default.createFile(atPath: stdoutPath, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: stderrPath, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output files could not be created")
        }
        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        let input = Pipe()
        #if os(Linux)
            _ = Glibc.signal(SIGPIPE, SIG_IGN)
        #else
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        do {
            let identity = try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: input, stdout: stdout, stderr: stderr, launchValidation: launchValidation)
            standardInputs[identity.pid] = input.fileHandleForWriting
            // Foundation's Linux Process implementation does not retain the
            // Pipe object after extracting its descriptor. Keep the complete
            // pipe alive; retaining only its write FileHandle lets Pipe deinit
            // close the child input and makes interactive providers exit.
            standardInputPipes[identity.pid] = input
            return CapturedProcess(identity: identity, stdoutPath: stdoutPath, stderrPath: stderrPath)
        } catch {
            try? input.fileHandleForWriting.close()
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
            throw error
        }
    }

    public func write(_ data: Data, to captured: CapturedProcess) throws {
        guard let input = standardInputs[captured.identity.pid] else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol input is closed")
        }
        try input.write(contentsOf: data)
    }

    public func capturedOutput(_ captured: CapturedProcess, after offset: Int, maximumBytes: Int) throws -> (data: Data, nextOffset: Int, running: Bool) {
        let contents = try Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath))
        guard offset <= contents.count else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output stream was truncated")
        }
        let end = min(contents.count, offset + max(1, maximumBytes))
        return (Data(contents[offset ..< end]), end, processes[captured.identity.pid]?.isRunning == true)
    }

    /// Returns bounded captured streams without ever rendering provider output
    /// into an error. Authentication callers reduce these bytes to a closed,
    /// sanitized status before crossing the service boundary.
    public func capturedStreams(_ captured: CapturedProcess, maximumBytes: Int) throws -> (stdout: Data, stderr: Data, running: Bool) {
        let limit = max(1, maximumBytes)
        return (
            try Self.readBoundedFile(captured.stdoutPath, maximumBytes: limit),
            try Self.readBoundedFile(captured.stderrPath, maximumBytes: limit),
            processes[captured.identity.pid]?.isRunning == true
        )
    }

    /// Finalizes a process that has exited and returns only its status. Unlike
    /// `waitForCapturedProcess`, this API can never include stderr in an error.
    public func finalizeCapturedProcess(_ captured: CapturedProcess) async throws -> Int32 {
        guard let process = processes[captured.identity.pid] else {
            cleanupCapturedFiles(captured)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process record is missing")
        }
        guard !process.isRunning else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process is still running")
        }
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        let status = process.terminationStatus
        cleanupCapturedFiles(captured)
        try await reap(pid: captured.identity.pid)
        return status
    }

    /// Cancels a captured process with a bounded TERM/KILL escalation and
    /// removes all private capture files. Linux uses the isolated process group
    /// (or delegated cgroup) so descendants cannot outlive the transaction.
    public func cancelCapturedProcess(_ captured: CapturedProcess, graceMilliseconds: Int = 1_000) async {
        closeInput(captured)
        guard let process = processes[captured.identity.pid] else {
            cleanupCapturedFiles(captured)
            return
        }
        if process.isRunning {
            #if os(Linux)
                let family = [captured.identity] + ((try? await descendants(of: captured.identity.pid)) ?? [])
                if (try? await terminateContainedFamily(leader: captured.identity)) != true {
                    try? await signal(SIGTERM, processGroupID: captured.identity.processGroupID, verifiedMembers: family)
                }
            #else
                process.terminate()
            #endif
            let attempts = max(1, graceMilliseconds / 50)
            for _ in 0 ..< attempts where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                #if os(Linux)
                    let family = [captured.identity] + ((try? await descendants(of: captured.identity.pid)) ?? [])
                    try? await signal(SIGKILL, processGroupID: captured.identity.processGroupID, verifiedMembers: family)
                #else
                    _ = systemKill(captured.identity.pid, SIGKILL)
                #endif
                for _ in 0 ..< 20 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        cleanupCapturedFiles(captured)
        try? await reap(pid: captured.identity.pid)
    }

    public func closeInput(_ captured: CapturedProcess) {
        try? standardInputs.removeValue(forKey: captured.identity.pid)?.close()
        standardInputPipes[captured.identity.pid] = nil
    }

    public func cleanupCapturedFiles(_ captured: CapturedProcess) {
        try? FileManager.default.removeItem(atPath: captured.stdoutPath)
        try? FileManager.default.removeItem(atPath: captured.stderrPath)
    }

    public func waitForCapturedProcess(
        _ captured: CapturedProcess,
        maximumBytes: Int,
        onOutput: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        guard let process = processes[captured.identity.pid] else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process record is missing") }
        while process.isRunning {
            try Task.checkCancellation()
            if let onOutput,
               let data = try? Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath)),
               !data.isEmpty
            {
                await onOutput(String(decoding: data.prefix(max(1, maximumBytes)), as: UTF8.self))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Polling `isRunning` above has already made Foundation observe the
        // child's termination. A second `waitUntilExit()` can deadlock when
        // several Process instances terminate close together because
        // Foundation's shared child-status source has already consumed it.
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        let stdout = (try? Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath))) ?? Data()
        let stderr = (try? Data(contentsOf: URL(fileURLWithPath: captured.stderrPath))) ?? Data()
        if let onOutput, !stdout.isEmpty {
            await onOutput(String(decoding: stdout.prefix(max(1, maximumBytes)), as: UTF8.self))
        }
        try? FileManager.default.removeItem(atPath: captured.stdoutPath)
        try? FileManager.default.removeItem(atPath: captured.stderrPath)
        try await reap(pid: captured.identity.pid)
        guard process.terminationStatus == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider command failed: \(String(decoding: stderr.prefix(8192), as: UTF8.self))")
        }
        return String(decoding: stdout.prefix(max(1, maximumBytes)), as: UTF8.self)
    }

    private nonisolated static func readBoundedFile(_ path: String, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximumBytes else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output exceeded the bounded capture limit")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output exceeded the bounded capture limit")
        }
        return data
    }

    private nonisolated static func prepareOutputDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output directory is not private")
        }
    }

    private func launchProcess(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, stdin: Any, stdout: FileHandle, stderr: FileHandle, launchValidation: @escaping @Sendable () throws -> Void = {}) async throws -> ProcessIdentity {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider executable is unavailable") }
        let process = Process()
        #if os(Linux)
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/setsid"),
                  FileManager.default.isExecutableFile(atPath: "/bin/sh")
            else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Linux setsid executable is required for isolated provider process groups")
            }
            let controlDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-provider-launch", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try Self.prepareOutputDirectory(controlDirectory.path)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
            process.arguments = [
                "--wait",
                "/bin/sh",
                "-c",
                Self.linuxProviderAnchorScript,
                "repoprompt-provider-anchor",
                controlDirectory.path,
                executable,
            ] + arguments
        #else
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        #endif
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Provider processes receive an explicit allowlist assembled by the
        // runtime. Never inherit service signing keys, database credentials,
        // Docker endpoints, or unrelated host secrets.
        var launchEnvironment = environment
        launchEnvironment["REPOPROMPT_HELPER_TOKEN"] = helperToken
        process.environment = launchEnvironment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let digest = CanonicalSigning.bodyDigest(Data(helperToken.utf8))
        do {
            try launchValidation()
            try process.run()
        } catch {
            #if os(Linux)
                try? FileManager.default.removeItem(at: controlDirectory)
            #endif
            throw error
        }
        let pid = process.processIdentifier
        #if !os(Linux)
            processes[pid] = process
            let observed = ProcessIdentity(pid: pid, parentPID: getpid(), processGroupID: getpgid(pid), sessionID: getsid(pid), startTimeTicks: UInt64(ProcessInfo.processInfo.systemUptime * 100), bootID: bootID, executablePath: executable, helperTokenDigest: digest)
            identities[pid] = observed
            return observed
        #else
            do {
                let observed = try await waitForLinuxProviderAnchor(
                    wrapperPID: pid,
                    helperTokenDigest: digest,
                    process: process,
                    controlDirectory: controlDirectory.path
                )
                processes[observed.pid] = process
                identities[observed.pid] = observed
                wrapperPIDs[observed.pid] = pid
                leaderPIDsByWrapper[pid] = observed.pid
                launchControlDirectories[observed.pid] = controlDirectory.path
                try attachToDelegatedCgroupIfAvailable(pid: observed.pid, helperTokenDigest: digest)
                guard FileManager.default.createFile(
                    atPath: controlDirectory.appendingPathComponent("release").path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider launch gate could not be released")
                }
                return observed
            } catch {
                await cleanupFailedLinuxLaunch(
                    process: process,
                    wrapperPID: pid,
                    helperTokenDigest: digest,
                    controlDirectory: controlDirectory.path
                )
                throw error
            }
        #endif
    }

    #if os(Linux)
        /// Foundation launches `setsid` as a process-group leader, so setsid
        /// forks an isolated child and waits for it. The isolated child is a
        /// stable shell anchor: it reports its PID, waits until containment is
        /// recorded, then runs the provider in the foreground. Foreground
        /// execution preserves the provider's bidirectional standard input.
        /// The anchor then execs the provider so the verified PID remains the
        /// process-group leader and no intermediate child can escape reaping.
        private nonisolated static let linuxProviderAnchorScript = """
        set -eu
        control_dir=$1
        shift
        umask 077
        printf '%s\n' "$$" > "$control_dir/pid"
        attempts=0
        while [ ! -e "$control_dir/release" ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 500 ] || exit 125
            sleep 0.01
        done
        exec "$@"
        """

        private func waitForLinuxProviderAnchor(
            wrapperPID: Int32,
            helperTokenDigest: String,
            process: Process,
            controlDirectory: String
        ) async throws -> ProcessIdentity {
            let pidPath = URL(fileURLWithPath: controlDirectory).appendingPathComponent("pid").path
            for _ in 0 ..< 100 {
                if let pidText = try? String(contentsOfFile: pidPath, encoding: .utf8),
                   let anchorPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   anchorPID > 1,
                   let observed = try await inspectLinux(pid: anchorPID, helperTokenDigest: helperTokenDigest),
                   observed.parentPID == wrapperPID,
                   observed.processGroupID == anchorPID,
                   observed.sessionID == anchorPID,
                   URL(fileURLWithPath: observed.executablePath).lastPathComponent != "setsid"
                {
                    return observed
                }
                guard process.isRunning else { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process did not establish a verifiable identity")
        }

        private func cleanupFailedLinuxLaunch(
            process: Process,
            wrapperPID: Int32,
            helperTokenDigest: String,
            controlDirectory: String
        ) async {
            let pidPath = URL(fileURLWithPath: controlDirectory).appendingPathComponent("pid").path
            let anchorPID = (try? String(contentsOfFile: pidPath, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let anchorPID,
               anchorPID > 1,
               let observed = try? await inspectLinux(pid: anchorPID, helperTokenDigest: helperTokenDigest),
               observed.parentPID == wrapperPID,
               observed.processGroupID == anchorPID,
               observed.sessionID == anchorPID
            {
                _ = systemKill(-anchorPID, SIGKILL)
            }
            if process.isRunning {
                process.terminate()
                for _ in 0 ..< 20 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            if let anchorPID {
                processes[anchorPID] = nil
                identities[anchorPID] = nil
                wrapperPIDs[anchorPID] = nil
                launchControlDirectories[anchorPID] = nil
                if let cgroup = cgroupPaths.removeValue(forKey: anchorPID) {
                    try? FileManager.default.removeItem(atPath: cgroup)
                }
            }
            leaderPIDsByWrapper[wrapperPID] = nil
            try? FileManager.default.removeItem(atPath: controlDirectory)
        }
    #endif

    public func inspect(pid: Int32) async throws -> ProcessIdentity? {
        try await inspectLinux(pid: pid, helperTokenDigest: identities[pid]?.helperTokenDigest ?? "")
    }

    public func containmentMode(for leader: ProcessIdentity) async throws -> String {
        cgroupPaths[leader.pid] == nil ? "process-group" : "cgroup-v2"
    }

    public func reconstruct(leader: ProcessIdentity, containmentMode: String) async throws {
        guard let observed = try await inspectLinux(pid: leader.pid, helperTokenDigest: leader.helperTokenDigest),
              observed.representsSameProcessInstance(as: leader)
        else {
            throw ServiceAPIError(code: .staleRevision, message: "Persisted provider process identity no longer matches")
        }
        identities[leader.pid] = observed
        #if os(Linux)
            if containmentMode == "cgroup-v2" {
                guard let path = cgroupPath(helperTokenDigest: leader.helperTokenDigest),
                      FileManager.default.fileExists(atPath: path),
                      try cgroupContains(pid: leader.pid, path: path)
                else {
                    identities[leader.pid] = nil
                    throw ServiceAPIError(code: .staleRevision, message: "Persisted provider cgroup identity no longer matches")
                }
                cgroupPaths[leader.pid] = path
            }
        #endif
    }

    public func descendants(of pid: Int32) async throws -> [ProcessIdentity] {
        #if os(Linux)
            guard let expectedDigest = identities[pid]?.helperTokenDigest, !expectedDigest.isEmpty else { return [] }
            let wrapperPID = wrapperPIDs[pid]
            let proc = try FileManager.default.contentsOfDirectory(atPath: "/proc").compactMap(Int32.init)
            var result: [ProcessIdentity] = []
            for candidate in proc where candidate != pid && candidate != wrapperPID {
                if let identity = try? await inspectLinux(pid: candidate, helperTokenDigest: expectedDigest) {
                    result.append(identity)
                }
            }
            return result
        #else
            return []
        #endif
    }

    public func signal(_ signal: Int32, processGroupID: Int32, verifiedMembers: [ProcessIdentity]) async throws {
        guard !verifiedMembers.isEmpty else { return }
        #if os(Linux)
            guard processGroupID > 1, processGroupID != getpgrp() else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider process group is not isolated from the service")
            }
        #endif
        var hasLiveVerifiedMember = false
        for expected in verifiedMembers {
            guard expected.processGroupID == processGroupID else {
                throw ServiceAPIError(code: .staleRevision, message: "Verified process member does not belong to the requested group")
            }
            guard let observed = try await inspect(pid: expected.pid) else {
                // A member exiting between discovery and signaling is the
                // expected cancellation race, not evidence of PID reuse.
                continue
            }
            guard observed.representsSameProcessInstance(as: expected) else {
                throw ServiceAPIError(code: .staleRevision, message: "Process identity changed before signaling")
            }
            // A live member may move into a newly isolated process group after
            // discovery. Do not authorize its former group with stale data;
            // the supervisor's next scan will target its current group.
            guard observed.processGroupID == processGroupID else { continue }
            hasLiveVerifiedMember = true
        }
        guard hasLiveVerifiedMember else { return }
        guard systemKill(-processGroupID, signal) == 0 || errno == ESRCH else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Unable to signal provider process group") }
    }

    public func terminateContainedFamily(leader: ProcessIdentity) async throws -> Bool {
        #if os(Linux)
            guard let path = cgroupPaths[leader.pid] else { return false }
            let killFile = URL(fileURLWithPath: path).appendingPathComponent("cgroup.kill").path
            guard FileManager.default.isWritableFile(atPath: killFile) else { return false }
            try Data("1\n".utf8).write(to: URL(fileURLWithPath: killFile))
            return true
        #else
            return false
        #endif
    }

    public func reap(pid: Int32) async throws {
        if let leaderPID = leaderPIDsByWrapper[pid], processes[leaderPID] != nil {
            // Foundation owns this wrapper's wait status through the Process
            // stored under the provider anchor. The anchor reap performs the
            // corresponding record cleanup.
            return
        }
        // Foundation owns the wait status for every child launched through
        // `Process`. Reaping it with waitpid, or redundantly waiting after
        // `isRunning` observed exit, can leave another Process blocked.
        if let process = processes[pid] {
            for _ in 0 ..< 20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                process.terminate()
                for _ in 0 ..< 20 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        } else {
            var status: Int32 = 0
            // A verified descendant can still be running when cancellation's
            // final family scan completes. As this process is the Linux child
            // subreaper, wait briefly for that exact PID to become reapable;
            // a single WNOHANG probe leaves a later zombie that can starve
            // Foundation's shared Process status source.
            for attempt in 0 ..< 40 {
                let result = rp_waitpid_nohang(pid, &status)
                if result == pid || result < 0 { break }
                if attempt < 39 {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        processes[pid] = nil
        identities[pid] = nil
        try? standardInputs.removeValue(forKey: pid)?.close()
        standardInputPipes[pid] = nil
        if let cgroup = cgroupPaths.removeValue(forKey: pid) { try? FileManager.default.removeItem(atPath: cgroup) }
        if let wrapperPID = wrapperPIDs.removeValue(forKey: pid) {
            leaderPIDsByWrapper[wrapperPID] = nil
        }
        if let controlDirectory = launchControlDirectories.removeValue(forKey: pid) {
            try? FileManager.default.removeItem(atPath: controlDirectory)
        }
        // Never use waitpid(-1) here. This service also launches short-lived
        // Foundation `Process` commands outside this port (for example CLI
        // health probes). A wildcard wait can consume one of those commands'
        // statuses before Foundation observes it, making healthy providers
        // fail nondeterministically. Provider descendants are discovered by
        // the supervisor and passed back to this method by exact PID instead.
    }

    private func inspectLinux(pid: Int32, helperTokenDigest expectedHelperTokenDigest: String) async throws -> ProcessIdentity? {
        #if os(Linux)
            guard let statLine = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let stat = ProcStatParser.parse(statLine) else { return nil }
            let executable = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) ?? ""
            // `/proc` is inherently racy: a process can disappear after its
            // stat record is read but before its environment is opened.
            // Treat that as a vanished identity rather than leaking a raw
            // filesystem error through provider control or recovery.
            guard let actualHelperDigest = try? helperTokenDigest(pid: pid) else { return nil }
            guard expectedHelperTokenDigest.isEmpty || actualHelperDigest == expectedHelperTokenDigest else { return nil }
            return ProcessIdentity(pid: stat.pid, parentPID: stat.parentPID, processGroupID: stat.processGroupID, sessionID: stat.sessionID, startTimeTicks: stat.startTimeTicks, bootID: bootID, executablePath: executable, helperTokenDigest: actualHelperDigest)
        #else
            guard let identity = identities[pid], processes[pid]?.isRunning == true else { return nil }
            return identity
        #endif
    }

    private func helperTokenDigest(pid: Int32) throws -> String {
        #if os(Linux)
            let environment = try Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/environ"))
            let prefix = Data("REPOPROMPT_HELPER_TOKEN=".utf8)
            for entry in environment.split(separator: 0) where entry.starts(with: prefix) {
                return CanonicalSigning.bodyDigest(Data(entry.dropFirst(prefix.count)))
            }
            return ""
        #else
            return identities[pid]?.helperTokenDigest ?? ""
        #endif
    }

    private func systemKill(_ pid: Int32, _ signal: Int32) -> Int32 {
        #if os(Linux)
            Glibc.kill(pid, signal)
        #else
            Darwin.kill(pid, signal)
        #endif
    }

    private func attachToDelegatedCgroupIfAvailable(pid: Int32, helperTokenDigest: String) throws {
        #if os(Linux)
            guard let path = cgroupPath(helperTokenDigest: helperTokenDigest) else { return }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try Data("\(pid)\n".utf8).write(to: url.appendingPathComponent("cgroup.procs"))
                cgroupPaths[pid] = path
            } catch {
                try? FileManager.default.removeItem(at: url)
                // Lack of delegation is an expected deployment mode. The
                // subreaper + verified ancestry/PGID path remains authoritative.
            }
        #endif
    }

    private func cgroupPath(helperTokenDigest: String) -> String? {
        guard let delegatedCgroupRoot,
              helperTokenDigest.count == 64,
              helperTokenDigest.allSatisfy(\.isHexDigit)
        else { return nil }
        return URL(fileURLWithPath: delegatedCgroupRoot, isDirectory: true)
            .appendingPathComponent("run-\(helperTokenDigest.lowercased())", isDirectory: true)
            .standardizedFileURL.path
    }

    private func cgroupContains(pid: Int32, path: String) throws -> Bool {
        let members = try String(contentsOfFile: URL(fileURLWithPath: path).appendingPathComponent("cgroup.procs").path, encoding: .utf8)
        return members.split(whereSeparator: \.isWhitespace).contains(Substring(String(pid)))
    }

    private static func validatedCgroupV2Root(_ configured: String?) -> String? {
        #if os(Linux)
            guard let configured, !configured.isEmpty else { return nil }
            let root = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("cgroup.controllers").path),
                  FileManager.default.isWritableFile(atPath: root)
            else { return nil }
            return root
        #else
            return nil
        #endif
    }
}
