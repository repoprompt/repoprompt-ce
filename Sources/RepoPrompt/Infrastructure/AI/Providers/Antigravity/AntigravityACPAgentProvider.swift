import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// Google Antigravity's official ACP runtime provider.
/// The runtime is distributed as `agy_acp_server.par` together with
/// `localharness_external`; both are installed by the Antigravity runtime manager.
package struct AntigravityACPAgentProvider: ACPAgentProvider {
    package let providerID: ACPProviderID = .antigravity
    package let executablePath: String
    package let harnessPath: String?
    private let installedRuntime: @Sendable () -> (command: String, harness: String)?
    private let prepareSessionHome: @Sendable () throws -> URL
    private let toolNames: ACPToolNameResolution

    package init(
        executablePath: String,
        harnessPath: String?,
        installedRuntime: @escaping @Sendable () -> (command: String, harness: String)?,
        prepareSessionHome: @escaping @Sendable () throws -> URL,
        toolNames: ACPToolNameResolution
    ) {
        self.executablePath = executablePath
        self.harnessPath = harnessPath
        self.installedRuntime = installedRuntime
        self.prepareSessionHome = prepareSessionHome
        self.toolNames = toolNames
    }

    package func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        let managed = installedRuntime()
        let candidates = [managed?.command, executablePath].compactMap(\.self) + ["/usr/local/bin/agy_acp_server.par", NSHomeDirectory() + "/.local/bin/agy_acp_server.par"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }) else {
            throw AIProviderError.invalidConfiguration(detail: "Google Antigravity ACP runtime not found. Install Antigravity ACP and make agy_acp_server.par available on PATH.")
        }
        return .supported
    }

    package func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let managed = installedRuntime()
        let command = managed?.command ?? executablePath
        let resolvedHarness = harnessPath ?? managed?.harness
        let sessionHome = try prepareSessionHome()
        var environment = ["AGY_ACP_FORCE_FILE_STORAGE": "1", "GEMINI_HOME": sessionHome.path]
        if let resolvedHarness, !resolvedHarness.isEmpty { environment["ANTIGRAVITY_HARNESS_PATH"] = resolvedHarness }
        return ACPLaunchConfiguration(
            providerID: providerID,
            command: command,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: ["~/.local/bin", "/usr/local/bin"],
            enableDebugLogging: false,
            explicitEnvironmentKeys: Set(environment.keys)
        )
    }

    package func makeSessionConfiguration(for request: ACPRunRequest, mcpServer: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let id = request.resumeSessionID, !id.isEmpty { .load(existingSessionID: id) } else { .new }
        // Keep the app-backed MCP contract. The controller injects the current
        // launch carrier before Antigravity starts its MCP child.
        return try ACPSessionConfiguration(mode: mode, workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path, mcpServers: [mcpServer])
    }

    package func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
        try ACPPromptContentBuilder.blocks(text: message.userMessage, attachments: request.attachments)
    }

    package func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID, toolNames: toolNames)
    }

    package func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
        "oauth-personal"
    }

    package func shouldEmitStderrLine(_ line: String) -> Bool {
        // Antigravity writes its Python harness and raw websocket frames to stderr
        // (for example `I0906 ... local_connection.py ... RAW WS MSG`). These are
        // diagnostics, not assistant content, and must never become transcript rows.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAntigravityHarnessLog = trimmed.range(of: #"^I\d{4}\s+\d+\s"#, options: .regularExpression) != nil
        guard isAntigravityHarnessLog else { return true }
        let lowercased = trimmed.lowercased()
        return lowercased.contains("error")
            || lowercased.contains("exception")
            || lowercased.contains("traceback")
            || lowercased.contains("failed")
    }

    package func normalizeError(_ error: Error) -> Error {
        error
    }
}
