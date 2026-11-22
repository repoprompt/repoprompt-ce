import Darwin
import Foundation
import RepoPromptProcess
import RepoPromptProviderQuota

/// Starts a short-lived, input-free TUI only on an explicit refresh. The managed ACP
/// runtime does not expose this hook; do not substitute model prompts or private APIs.
enum AntigravityCLIUsageSource {
    static func read(_ context: ProviderQuotaReadContext) async throws -> ProviderQuotaSnapshot {
        guard context.userInitiated else { throw ProviderQuotaReadError.needsConsent }
        try ProviderProcessLaunchPolicy.check()
        try Task.checkCancellation()
        var environment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        guard let command = AntigravityCLILocator.installedCommand(environment: environment),
              let helper = Bundle.main.executableURL else { throw ProviderQuotaReadError.antigravityCLIUnavailable }
        environment["TERM"] = "xterm-256color"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RPCE-AgyUsage-\(UUID().uuidString)", isDirectory: true)
        try CLIUsagePrivateFiles.createDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let latest = root.appendingPathComponent("latest.json")
        let settings = try collectionSettings(helper: helper, runDirectory: root)
        try Task.checkCancellation()
        let child: SpawnedPTYProcess
        do {
            let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: command)
            child = try ProcessLauncher.spawnPTY(
                command: identity.canonicalPath,
                arguments: ["--settings", settings, "--log-file", "/dev/null"],
                environment: environment,
                workingDirectory: root.path
            )
        } catch {
            throw launchFailure(for: error)
        }

        let result: Result<ProviderQuotaSnapshot, any Error>
        do {
            result = try await .success(receive(from: child, latest: latest))
        } catch { result = .failure(error) }
        await Task.detached(priority: .utility) {
            close(child.master)
            _ = await ProcessTermination.terminateAndReap(pid: child.pid, processGroupID: child.processGroupID, sigtermGrace: 1, sigkillGrace: 1)
        }.value
        try Task.checkCancellation()
        return try result.get()
    }

    static func launchFailure(for error: any Error) -> ProviderQuotaReadError {
        .antigravityCLILaunchFailed(reason: AntigravityLaunchDiagnostic.message(for: error) ?? "Could not start Antigravity.")
    }

    static func collectionSettings(helper: URL, runDirectory: URL) throws -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let command = "\(quote(helper.path)) \(AntigravityCLIUsageCollector.flag) \(quote(runDirectory.path))"
        let data = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": command, "enabled": true]])
        return String(decoding: data, as: UTF8.self)
    }

    private static func receive(from child: SpawnedPTYProcess, latest: URL) async throws -> ProviderQuotaSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        var buffer = [UInt8](repeating: 0, count: 16384)
        while clock.now < deadline {
            try Task.checkCancellation()
            var terminalClosed = false
            // spawnPTY sets O_NONBLOCK before returning the master. Discard terminal bytes.
            for _ in 0 ..< 16 {
                let count = Darwin.read(child.master, &buffer, buffer.count)
                if count <= 0 {
                    terminalClosed = count == 0 || errno == EIO
                    break
                }
            }
            if let data = CLIUsagePrivateFiles.read(latest),
               let record = try? JSONDecoder().decode(AntigravityCLIUsageRecord.self, from: data),
               let snapshot = record.snapshot() { return snapshot }
            if terminalClosed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProviderQuotaReadError.antigravityUsageNotReported
    }
}

/// Child entry invoked by agy's status line. Never writes the raw stdin or prints it.
enum AntigravityCLIUsageCollector {
    static let flag = "--rpce-antigravity-usage-collector"

    static func runIfInvoked(arguments: [String]) -> Int32? {
        guard arguments.contains(flag) else { return nil }
        guard arguments.count == 3, arguments[1] == flag, arguments[2].hasPrefix("/") else { return 1 }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard CLIUsagePrivateFiles.isPrivateDirectory(root), let data = CLIUsagePrivateFiles.readStatusLineInput() else { return 1 }
        // Early startup and signed-out payloads do not necessarily contain a quota map.
        guard let record = AntigravityCLIUsageRecord.extract(data) else { return 0 }
        guard let output = try? JSONEncoder().encode(record) else { return 1 }
        do {
            try CLIUsagePrivateFiles.write(output, to: root.appendingPathComponent("latest.json"))
            return 0
        } catch { return 1 }
    }
}
