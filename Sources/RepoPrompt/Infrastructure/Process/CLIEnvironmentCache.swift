import Darwin
import Foundation

actor CLIEnvironmentCache {
    static let shared = CLIEnvironmentCache()

    private var cachedSnapshots: [ShellEnvironmentCaptureMode: CLIEnvironmentSnapshot] = [:]
    private var fallbackEnvironments: [ShellEnvironmentCaptureMode: [String: String]] = [:]
    private var loadTasks: [ShellEnvironmentCaptureMode: Task<CLIEnvironmentSnapshot, Never>] = [:]
    private var loadGenerations: [ShellEnvironmentCaptureMode: UInt64] = [:]

    func invalidate() {
        for mode in ShellEnvironmentCaptureMode.allCases {
            loadGenerations[mode, default: 0] &+= 1
            loadTasks[mode]?.cancel()
            loadTasks[mode] = nil
            if let cachedSnapshot = cachedSnapshots[mode] {
                fallbackEnvironments[mode] = cachedSnapshot.environment
            }
            cachedSnapshots[mode] = nil
        }
    }

    func environment(enableLogging: Bool) async -> [String: String] {
        await environmentSnapshot(enableLogging: enableLogging).environment
    }

    func environmentSnapshot(
        enableLogging: Bool,
        forceRefresh: Bool = false,
        captureMode: ShellEnvironmentCaptureMode = .interactiveLoginShell
    ) async -> CLIEnvironmentSnapshot {
        if forceRefresh {
            invalidate(captureMode: captureMode)
        }

        // Return cached result if available.
        if let cachedSnapshot = cachedSnapshots[captureMode] {
            return cachedSnapshot
        }

        // If a load is already in progress for this mode, wait for it.
        if let existingTask = loadTasks[captureMode] {
            return await existingTask.value
        }

        // Start a new load task for this capture mode. Interactive and non-interactive
        // login shells are cached separately so fast Codex app-server launches do not
        // downgrade providers that explicitly need interactive shell initialization.
        let previousEnvironment = fallbackEnvironments[captureMode]
        loadGenerations[captureMode, default: 0] &+= 1
        let generation = loadGenerations[captureMode, default: 0]
        let task = Task<CLIEnvironmentSnapshot, Never> {
            Self.loadLoginShellEnvironment(
                enableLogging: enableLogging,
                previousEnvironment: previousEnvironment,
                captureMode: captureMode
            )
        }
        loadTasks[captureMode] = task
        let snapshot = await task.value
        if loadGenerations[captureMode, default: 0] == generation {
            cachedSnapshots[captureMode] = snapshot
            fallbackEnvironments[captureMode] = snapshot.environment
            loadTasks[captureMode] = nil
        }
        return snapshot
    }

    private func invalidate(captureMode: ShellEnvironmentCaptureMode) {
        loadGenerations[captureMode, default: 0] &+= 1
        loadTasks[captureMode]?.cancel()
        loadTasks[captureMode] = nil
        if let cachedSnapshot = cachedSnapshots[captureMode] {
            fallbackEnvironments[captureMode] = cachedSnapshot.environment
        }
        cachedSnapshots[captureMode] = nil
    }

    private static func log(_ message: @autoclosure () -> String, enabled: Bool) {
        ProcessDebugLogging.log(prefix: "CLIEnvironmentCache", message(), enabled: enabled)
    }

    private static func loadLoginShellEnvironment(
        enableLogging: Bool,
        previousEnvironment: [String: String]?,
        captureMode: ShellEnvironmentCaptureMode
    ) -> CLIEnvironmentSnapshot {
        // Native app launches can inherit a minimal launchd PATH, while terminal launches
        // usually inherit a fully initialized shell PATH. Capture the user's login shell
        // when possible and then enrich with shared native defaults so providers do not
        // each carry stale package-manager or version-manager path guesses.
        let baseEnv = ProcessInfo.processInfo.environment
        func fallbackEnv(_ reason: String) -> CLIEnvironmentSnapshot {
            let source = previousEnvironment == nil ? "base environment" : "last successful environment"
            log("\(reason); falling back to \(source)", enabled: enableLogging)
            if let previousEnvironment {
                return CLIEnvironmentSnapshot(
                    environment: previousEnvironment,
                    source: .previousCapturedFallback
                )
            }
            return CLIEnvironmentSnapshot(
                environment: buildFinalEnvironment(captured: [:], baseEnv: baseEnv, enableLogging: enableLogging),
                source: .enrichedFallback
            )
        }
        guard let shell = userLoginShell() else {
            return fallbackEnv("Unable to determine user login shell")
        }
        log("Launching login shell \(shell) to capture environment mode=\(captureMode)", enabled: enableLogging)
        let seededEnv = composeShellCommandEnvironment(from: baseEnv, shell: shell)
        let primaryArguments: [String] = switch captureMode {
        case .interactiveLoginShell:
            ["-l", "-i", "-c", "env"]
        case .loginShell:
            ["-l", "-c", "env"]
        }
        guard var captured = captureEnvironment(
            shell: shell,
            arguments: primaryArguments,
            environment: seededEnv,
            enableLogging: enableLogging,
            timeout: loginShellCaptureTimeout
        ) else {
            return fallbackEnv("Login shell capture failed or timed out")
        }
        if captureMode == .interactiveLoginShell,
           pathLooksInsufficient(captured["PATH"])
        {
            log("Captured PATH is minimal; retrying without interactive flag", enabled: enableLogging)
            if let retry = captureEnvironment(
                shell: shell,
                arguments: ["-l", "-c", "env"],
                environment: seededEnv,
                enableLogging: enableLogging,
                timeout: loginShellCaptureTimeout
            ) {
                captured = mergeEnvironments(primary: retry, fallback: captured)
            }
        }
        return CLIEnvironmentSnapshot(
            environment: buildFinalEnvironment(captured: captured, baseEnv: baseEnv, enableLogging: enableLogging),
            source: .capturedLoginShell
        )
    }

    private static func captureEnvironment(
        shell: String,
        arguments: [String],
        environment: [String: String],
        enableLogging: Bool,
        timeout: TimeInterval
    ) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let out = stdoutPipe.fileHandleForReading
        let err = stderrPipe.fileHandleForReading
        var stdoutAccum = Data()
        var stderrAccum = Data()
        let group = DispatchGroup()
        let chunkSize = 64 * 1024
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                guard let chunk = try? out.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                stdoutAccum.append(chunk)
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                guard let chunk = try? err.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                stderrAccum.append(chunk)
            }
        }
        defer {
            out.closeFile()
            err.closeFile()
            group.wait()
        }
        let terminationGroup = DispatchGroup()
        terminationGroup.enter()
        process.terminationHandler = { _ in
            terminationGroup.leave()
        }
        var timedOut = false
        do {
            log("Running: \(shell) \(arguments.joined(separator: " "))", enabled: enableLogging)
            try process.run()
        } catch {
            terminationGroup.leave()
            log("Failed to run login shell: \(error)", enabled: enableLogging)
            return nil
        }
        if terminationGroup.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            log("Login shell capture timed out after \(timeout)s; terminating process", enabled: enableLogging)
            if process.isRunning {
                process.terminate()
            }
            let killDeadline = DispatchTime.now() + loginShellTerminationGraceInterval
            if terminationGroup.wait(timeout: killDeadline) == .timedOut {
                log("Login shell did not exit after SIGTERM; sending SIGKILL", enabled: enableLogging)
                kill(process.processIdentifier, SIGKILL)
                terminationGroup.wait()
            }
        }
        process.waitUntilExit()
        if timedOut {
            return nil
        }
        log("Login shell exit status: \(process.terminationStatus)", enabled: enableLogging)
        if !stderrAccum.isEmpty, let errStr = String(data: stderrAccum, encoding: .utf8) {
            log("STDERR from login shell:\n\(errStr)", enabled: enableLogging)
        }
        guard process.terminationStatus == 0 else { return nil }
        var env: [String: String] = [:]
        if let output = String(data: stdoutAccum, encoding: .utf8) {
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let idx = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<idx])
                let value = String(line[line.index(after: idx)...])
                env[key] = value
            }
        }
        log("Captured \(env.count) environment variables", enabled: enableLogging)
        return env
    }

    private static func buildFinalEnvironment(captured: [String: String], baseEnv: [String: String], enableLogging: Bool) -> [String: String] {
        var finalEnv = mergeEnvironments(primary: captured, fallback: baseEnv)
        let home = finalEnv["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        finalEnv["HOME"] = home
        let enriched = enrichedPath(existing: finalEnv["PATH"], home: home, enableLogging: enableLogging)
        finalEnv["PATH"] = enriched
        return finalEnv
    }

    private static func mergeEnvironments(primary: [String: String], fallback: [String: String]) -> [String: String] {
        var merged = fallback
        for (key, value) in primary where !value.isEmpty {
            merged[key] = value
        }
        return merged
    }

    private static func pathLooksInsufficient(_ pathValue: String?) -> Bool {
        guard let pathValue, !pathValue.isEmpty else { return true }
        let components = pathValue.split(separator: ":").map(String.init)
        let nonSystem = components.filter { !standardSystemPaths.contains($0) }
        return nonSystem.isEmpty
    }

    private static func enrichedPath(existing: String?, home: String?, enableLogging: Bool) -> String {
        var components: [String] = []
        var seen = Set<String>()
        func appendComponent(_ value: String) {
            guard !value.isEmpty else { return }
            if seen.insert(value).inserted {
                components.append(value)
            }
        }
        let basePath = (existing?.isEmpty == false ? existing : (defaultSystemPath() ?? fallbackSystemPath)) ?? fallbackSystemPath
        for part in basePath.split(separator: ":") {
            appendComponent(String(part))
        }
        var appendedFallback = false
        for candidate in fallbackPathCandidates {
            let expanded = expandTilde(candidate, home: home)
            guard !expanded.isEmpty else { continue }
            if !FileManager.default.fileExists(atPath: expanded) {
                continue
            }
            if !seen.contains(expanded) {
                appendComponent(expanded)
                appendedFallback = true
            }
        }
        log("Added fallback PATH entries", enabled: enableLogging && appendedFallback)
        return components.joined(separator: ":")
    }

    private static func defaultSystemPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/path_helper")
        process.arguments = ["-s"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        if let range = output.range(of: "PATH=\"") {
            let substring = output[range.upperBound...]
            if let endQuote = substring.firstIndex(of: "\"") {
                return String(substring[..<endQuote])
            }
        }
        return nil
    }

    private static func expandTilde(_ path: String, home: String?) -> String {
        guard path.contains("~") else { return path }
        if let home, path.hasPrefix("~") {
            let suffix = path.dropFirst()
            return home + suffix
        }
        return (path as NSString).expandingTildeInPath
    }

    private static let loginShellCaptureTimeout: TimeInterval = 5
    private static let loginShellTerminationGraceInterval: TimeInterval = 2
    private static let fallbackSystemPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let standardSystemPaths: Set<String> = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
    private static let fallbackPathCandidates: [String] = CLINativePathDefaults.loginShellFallbackCandidates

    #if DEBUG
        @_spi(TestSupport)
        public static func capturedEnvironment(enableLogging: Bool) async -> [String: String] {
            await shared.environment(enableLogging: enableLogging)
        }

        static func test_snapshot(environment: [String: String], source: ShellEnvironmentSource) -> CLIEnvironmentSnapshot {
            CLIEnvironmentSnapshot(environment: environment, source: source)
        }

        static func test_enrichedPath(existing: String?, home: String?) -> String {
            enrichedPath(existing: existing, home: home, enableLogging: false)
        }

        static func test_pathLooksInsufficient(_ value: String?) -> Bool {
            pathLooksInsufficient(value)
        }
    #endif

    private static func composeShellCommandEnvironment(from env: [String: String], shell: String) -> [String: String] {
        var composed = env
        func ensure(_ key: String, value: String) {
            if composed[key]?.isEmpty ?? true {
                composed[key] = value
            }
        }
        ensure("SHELL", value: shell)
        composed["TERM"] = "xterm-256color"
        ensure("TERM_PROGRAM", value: "Apple_Terminal")
        ensure("TERM_PROGRAM_VERSION", value: "1.0")
        ensure("LANG", value: "en_US.UTF-8")
        ensure("LC_CTYPE", value: "en_US.UTF-8")
        ensure("HOME", value: NSHomeDirectory())
        ensure("USER", value: NSUserName())
        if composed["MISE_ACTIVATE_SHELL"] == nil {
            composed["MISE_ACTIVATE_SHELL"] = "1"
        }
        if composed["INTELLIJ_ENVIRONMENT_READER"] == nil {
            composed["INTELLIJ_ENVIRONMENT_READER"] = "1"
        }
        composed["RP_SHELL_LOOKUP"] = "1"
        return composed
    }

    private static func userLoginShell() -> String? {
        guard let passwdPointer = getpwuid(getuid()), let shellPointer = passwdPointer.pointee.pw_shell else { return nil }
        return String(cString: shellPointer)
    }
}
