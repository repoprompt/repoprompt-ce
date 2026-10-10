import Darwin
import Foundation
import RepoPromptProcess
import RepoPromptProviderQuota

/// Bounded command admission, independent of PTY IO so timing and readiness are testable.
struct ClaudeCLIUsageCollectionState {
    enum Action: Equatable {
        case wait, usage, escape
        case complete(ClaudeCLIUsageRecord)
        case failed(ProviderQuotaReadError)
    }

    private var sentElapsed: TimeInterval?
    private var requestedAt: Date?
    private var escaped = false

    mutating func next(record: ClaudeCLIUsageRecord?, elapsed: TimeInterval, now: Date) -> Action {
        if elapsed >= 30 { return .failed(sentElapsed == nil ? .cliUnavailable : .invalidResponse) }
        if let record, record.isValid, let requestedAt, record.receivedAt >= requestedAt, !record.windows.isEmpty {
            return .complete(record)
        }
        if sentElapsed == nil, let record, record.isValid {
            sentElapsed = elapsed
            requestedAt = now
            return .usage
        }
        if let sentElapsed, !escaped, elapsed - sentElapsed >= 10 {
            escaped = true
            return .escape
        }
        return .wait
    }
}

/// CLI-owned acquisition: no credential reader, account HTTP transport or model turn.
actor ClaudeCLIUsageSource {
    typealias Collect = @Sendable (ClaudeUsageCredentialProfile, URL) async throws -> ClaudeCLIUsageRecord
    private let profileProvider: @Sendable () -> ClaudeUsageCredentialProfile
    private let consentProvider: @Sendable () async -> String?
    private let collect: Collect
    private let cache: ClaudeCLIUsageCache

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RepoPrompt CE/ClaudeUsage", isDirectory: true),
        profileProvider: @escaping @Sendable () -> ClaudeUsageCredentialProfile = { .current() },
        collect: @escaping Collect = { profile, root in try await ClaudeCLIUsageSource.collectUsage(profile: profile, root: root) },
        consentProvider: @escaping @Sendable () async -> String?
    ) {
        self.profileProvider = profileProvider
        self.consentProvider = consentProvider
        self.collect = collect
        cache = ClaudeCLIUsageCache(root: root)
    }

    func cachedSnapshot() async -> ProviderQuotaSnapshot? {
        let profile = profileProvider()
        guard await consentProvider() == profile.id, profileProvider() == profile else { return nil }
        return cache.load(profileID: profile.id)?.snapshot(profileID: profile.id)
    }

    func clearCache() {
        cache.clear()
    }

    func read(_ context: ProviderQuotaReadContext) async throws -> ProviderQuotaSnapshot {
        let profile = profileProvider()
        try await validate(profile)
        let record = try await collect(profile, cache.root)
        try await validate(profile)
        guard record.isValid, !record.windows.isEmpty else { throw ProviderQuotaReadError.invalidResponse }
        // Cache is best effort. A disk failure never hides a successful provider reading.
        try? cache.save(record, profileID: profile.id)
        return record.snapshot(profileID: profile.id)
    }

    private func validate(_ profile: ClaudeUsageCredentialProfile) async throws {
        try Task.checkCancellation()
        guard await consentProvider() == profile.id, profileProvider() == profile else { throw ProviderQuotaReadError.needsConsent }
    }

    /// Creates an explicit user-invoked setup action; never opens Terminal or accepts trust itself.
    func prepareSetup() async throws -> URL {
        let profile = profileProvider()
        try await validate(profile)
        try ProviderProcessLaunchPolicy.check()
        let environment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        let command = CommandPathResolver.resolve(
            "claude",
            environment: environment,
            additionalPaths: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path],
            shellLookupMode: .disabled
        )
        guard FileManager.default.isExecutableFile(atPath: command) else { throw ProviderQuotaReadError.cliUnavailable }
        let root = cache.root
        let workdir = root.appendingPathComponent("workdir", isDirectory: true)
        let setup = root.appendingPathComponent("setup", isDirectory: true)
        try ClaudeCLIUsageFiles.createDirectory(root)
        try ClaudeCLIUsageFiles.createDirectory(workdir)
        try ClaudeCLIUsageFiles.createDirectory(setup)
        let settings = setup.appendingPathComponent("settings.json")
        let mcp = setup.appendingPathComponent("mcp.json")
        try ClaudeCLIUsageFiles.write(Data(#"{"hooks":{}}"#.utf8), to: settings)
        try ClaudeCLIUsageFiles.write(Data(#"{"mcpServers":{}}"#.utf8), to: mcp)
        let script = setup.appendingPathComponent("Set up Claude usage.command")
        try ClaudeCLIUsageFiles.write(Data(Self.setupScript(command: command, profile: profile, workdir: workdir, settings: settings, mcp: mcp).utf8), to: script)
        guard chmod(script.path, 0o700) == 0 else { throw ProviderQuotaReadError.transport }
        try await validate(profile)
        return script
    }

    static func setupScript(command: String, profile: ClaudeUsageCredentialProfile, workdir: URL, settings: URL, mcp: URL) -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var arguments = ["/usr/bin/env"]
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CONFIG_DIR"] {
            arguments += ["-u", key]
        }
        if !profile.isDefault { arguments.append("CLAUDE_CONFIG_DIR=\(profile.directory.path)") }
        arguments += ["DISABLE_AUTOUPDATER=1", command, "--settings", settings.path, "--setting-sources", "", "--tools", "", "--strict-mcp-config", "--mcp-config", mcp.path]
        return "#!/bin/zsh\ncd \(quote(workdir.path)) || exit 1\nprintf '%s\\n' 'Approve this helper folder in Claude if you trust it, and sign in if needed. Do not send a model message. Quit Claude with /exit or Ctrl-C twice when ready, then click Check usage after setup in RepoPrompt.'\nexec \(arguments.map(quote).joined(separator: " "))\n"
    }

    static func collectionSettings(collector: String) throws -> Data {
        // Claude treats statusLine as a hook: disableAllHooks also suppresses this collector.
        // Empty setting sources exclude user/project hooks; managed policy remains authoritative.
        try JSONSerialization.data(withJSONObject: ["hooks": [:], "statusLine": ["type": "command", "command": collector]] as [String: Any])
    }

    static func collectUsage(profile: ClaudeUsageCredentialProfile, root: URL) async throws -> ClaudeCLIUsageRecord {
        try ProviderProcessLaunchPolicy.check()
        try Task.checkCancellation()
        var environment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        let command = CommandPathResolver.resolve(
            "claude",
            environment: environment,
            additionalPaths: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path],
            shellLookupMode: .disabled
        )
        guard FileManager.default.isExecutableFile(atPath: command), let helper = Bundle.main.executableURL else { throw ProviderQuotaReadError.cliUnavailable }
        environment = await ProviderEnvironmentFiltering.filter(environment, for: .claudeCode)
        // This source is for the subscription CLI, never compatible backends or API billing.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            environment[key] = nil
        }
        environment["CLAUDE_CONFIG_DIR"] = profile.isDefault ? nil : profile.directory.path
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["TERM"] = "xterm-256color"
        environment["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "false"
        try ClaudeCLIUsageFiles.createDirectory(root)
        let workdir = root.appendingPathComponent("workdir", isDirectory: true)
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        try ClaudeCLIUsageFiles.createDirectory(workdir)
        try ClaudeCLIUsageFiles.createDirectory(runs)
        let run = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ClaudeCLIUsageFiles.createDirectory(run)
        defer { try? FileManager.default.removeItem(at: run) }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let settings = run.appendingPathComponent("settings.json")
        let collector = "\(quote(helper.path)) \(ClaudeCLIUsageCollector.flag) \(quote(run.path))"
        try ClaudeCLIUsageFiles.write(Self.collectionSettings(collector: collector), to: settings)
        let mcp = run.appendingPathComponent("mcp.json")
        try ClaudeCLIUsageFiles.write(Data(#"{"mcpServers":{}}"#.utf8), to: mcp)
        let child: SpawnedPTYProcess
        do {
            child = try ProcessLauncher.spawnPTY(
                command: command,
                arguments: [
                    "--settings",
                    settings.path,
                    "--setting-sources",
                    "",
                    "--tools",
                    "",
                    "--strict-mcp-config",
                    "--mcp-config",
                    mcp.path
                ],
                environment: environment,
                workingDirectory: workdir.path
            )
        } catch { throw ProviderQuotaReadError.cliUnavailable }
        /// Polling is bounded to this collection. Terminal bytes are discarded, never parsed or logged.
        func finish() async {
            await Task.detached(priority: .utility) {
                close(child.master)
                _ = await ProcessTermination.terminateAndReap(pid: child.pid, processGroupID: child.processGroupID, sigtermGrace: 1, sigkillGrace: 1)
            }.value
        }
        do {
            let clock = ContinuousClock()
            let started = clock.now
            var state = ClaudeCLIUsageCollectionState()
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                try Task.checkCancellation()
                for _ in 0 ..< 16 {
                    if Darwin.read(child.master, &buffer, buffer.count) <= 0 { break }
                }
                let record = ClaudeCLIUsageFiles.read(run.appendingPathComponent("latest.json"))
                    .flatMap { try? JSONDecoder().decode(ClaudeCLIUsageRecord.self, from: $0) }
                let duration = clock.now - started
                let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                let action = state.next(record: record, elapsed: elapsed, now: Date())
                switch action {
                case .wait: break
                case .usage, .escape:
                    let bytes = action == .usage ? Array("/usage\r".utf8) : [UInt8(0x1B)]
                    guard bytes.withUnsafeBytes({ Darwin.write(child.master, $0.baseAddress, bytes.count) }) == bytes.count else { throw ProviderQuotaReadError.transport }
                case let .complete(record):
                    await finish()
                    return record
                case let .failed(error): throw error
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await finish()
            throw error
        }
    }
}
