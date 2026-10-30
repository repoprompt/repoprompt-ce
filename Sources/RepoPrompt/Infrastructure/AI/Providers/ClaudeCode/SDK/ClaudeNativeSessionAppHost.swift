import Darwin
import Foundation
import RepoPromptAIContracts

extension MCPConfigLease: ClaudeNativeConfigLease {}

struct ClaudeNativeSessionAppHost: ClaudeNativeSessionHosting {
    func repoPromptPermissionMatch(toolName: String, requestPayload: [String: Any]) -> ClaudeNativePermissionMatch? {
        guard let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: toolName,
            requestPayload: requestPayload
        ) else { return nil }
        return ClaudeNativePermissionMatch(
            source: match.source.rawValue,
            normalizedToolName: match.normalizedToolName,
            serverIdentifier: match.serverIdentifier
        )
    }

    func filterEnvironment(_ environment: [String: String], variant: ClaudeCodeRuntimeVariant) async -> [String: String] {
        await ProviderEnvironmentFiltering.filter(environment, for: variant.agentKind)
    }

    func mergeCurrentCarrier(into environment: [String: String]) -> [String: String] {
        DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: environment)
    }

    func processEnvironmentOverrides(for context: AgentCLIToolContext) -> [String: String] {
        ClaudeCodeAgentConfig.processEnvironmentOverrides(for: context)
    }

    func supplementedPathHints(_ hints: [String]) -> [String] {
        CLIPathHints.nativeDefaultsSupplemented(with: hints)
    }

    func expectedAgentClientName(for variant: ClaudeCodeRuntimeVariant) -> String? {
        variant.agentKind.mcpClientNameHint
    }

    #if DEBUG
        func debugStatusLineArguments(launchArguments: [String], isFirstParty: Bool, providerArguments: [String]) -> [String] {
            ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(
                launchArguments: launchArguments,
                isFirstParty: isFirstParty,
                providerArguments: providerArguments
            )
        }
    #endif

    func isRawEventFileLoggingEnabled() -> Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: "claudeRawEventLoggingEnabled")
        #else
            false
        #endif
    }

    func makeRawEventLogFileURL(workspacePath _: String?, sessionID: String) -> URL? {
        let overridePath = UserDefaults.standard.string(forKey: "claudeRawEventLogFilePath")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDirectory: URL = {
            if let overridePath, !overridePath.isEmpty {
                let expanded = NSString(string: overridePath).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            return MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent("ClaudeRawEvents", isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        return baseDirectory.appendingPathComponent("claude-session-\(sessionID)-\(timestamp).jsonl")
    }

    func recordLastRawEventLogFileURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "claudeLastRawEventLogFilePath")
    }

    func isReasoningExtractionEnabled() -> Bool {
        ClaudeReasoningExtractionFeature.isEnabled
    }

    func appendReasoningDebug(_ line: String) {
        #if DEBUG
            ClaudeReasoningDebugLog.append(line)
        #endif
    }

    func isRepoPromptToolName(_ name: String) -> Bool {
        MCPIntegrationHelper.isRepoPromptToolName(name)
    }

    func isMCPServerRunning() async -> Bool {
        await ServerNetworkManager.shared.isRunning()
    }

    func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease {
        try await MCPConfigExportService.shared.prepareLaunchConfig()
    }

    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
    }

    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
    }
}
