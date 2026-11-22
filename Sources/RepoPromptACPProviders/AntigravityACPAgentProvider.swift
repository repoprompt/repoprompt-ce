import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess

/// Google Antigravity's official ACP runtime provider.
/// Uses the installed CLI or the managed runtime retained for existing profiles.
package struct AntigravityACPAgentProvider: ACPAgentProvider {
    package let providerID: ACPProviderID = .antigravity
    package let executablePath: String
    package let harnessPath: String?
    private let installedRuntime: @Sendable () -> (command: String, harness: String)?
    private let prepareSessionHome: @Sendable () throws -> URL
    private let installedCLI: @Sendable () -> String?
    private let includeRepoPromptMCPServer: Bool
    private let isolatedProfile: URL?
    private let customAgentName: String?
    private let toolNames: ACPToolNameResolution

    package init(
        executablePath: String,
        harnessPath: String?,
        installedRuntime: @escaping @Sendable () -> (command: String, harness: String)?,
        prepareSessionHome: @escaping @Sendable () throws -> URL,
        toolNames: ACPToolNameResolution,
        installedCLI: @escaping @Sendable () -> String? = { nil },
        includeRepoPromptMCPServer: Bool = true,
        isolatedProfile: URL? = nil,
        customAgentName: String? = nil
    ) {
        self.executablePath = executablePath
        self.harnessPath = harnessPath
        self.installedRuntime = installedRuntime
        self.prepareSessionHome = prepareSessionHome
        self.toolNames = toolNames
        self.installedCLI = installedCLI
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.isolatedProfile = isolatedProfile
        self.customAgentName = customAgentName
    }

    package func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        if installedCLI() != nil { return .supported }
        guard isolatedProfile == nil else {
            throw AIProviderError.invalidConfiguration(detail: "Install the Antigravity CLI and sign in with agy to run this task.")
        }
        let managed = installedRuntime()
        let candidates = [managed?.command, executablePath].compactMap(\.self) + ["/usr/local/bin/agy_acp_server.par", NSHomeDirectory() + "/.local/bin/agy_acp_server.par"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }) else {
            throw AIProviderError.invalidConfiguration(detail: "Google Antigravity ACP runtime not found. Install Antigravity ACP and make agy_acp_server.par available on PATH.")
        }
        return .supported
    }

    package func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let managed = installedRuntime()
        // Existing managed profiles retain their original runtime and session storage.
        // Isolated runs require the current CLI's explicit profile/customization controls.
        if managed == nil || isolatedProfile != nil, let cli = installedCLI() {
            let identity = try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: cli)
            var arguments = ["acp"]
            if let isolatedProfile {
                arguments += ["--gemini-dir", isolatedProfile.path]
            }
            if isolatedProfile != nil || !includeRepoPromptMCPServer {
                arguments.append("--include-default-customizations=false")
            }
            if let customAgentName {
                arguments += ["--agent", customAgentName]
            }
            return ACPLaunchConfiguration(
                providerID: providerID,
                command: cli,
                arguments: arguments,
                environment: [:],
                workingDirectory: request.workspacePath,
                additionalPathHints: [],
                enableDebugLogging: false,
                expectedExecutableIdentity: identity
            )
        }
        guard isolatedProfile == nil else {
            throw AIProviderError.invalidConfiguration(detail: "The installed Antigravity CLI is unavailable.")
        }
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
        return try ACPSessionConfiguration(mode: mode, workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path, mcpServers: includeRepoPromptMCPServer ? [mcpServer] : [])
    }

    package func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = request.resumeSessionID == nil && !systemPrompt.isEmpty
            ? systemPrompt + "\n\n" + message.userMessage
            : message.userMessage
        return try ACPPromptContentBuilder.blocks(
            text: text,
            attachments: request.attachments,
            oracleAttachments: message.attachments
        )
    }

    package func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID, toolNames: toolNames)
    }

    package func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
        if isolatedProfile != nil || (installedCLI() != nil && installedRuntime() == nil) {
            return nil
        }
        return "oauth-personal"
    }

    package func shouldEmitStderrLine(_ line: String) -> Bool {
        stderrLineDisposition(line) == .transcript
    }

    package func stderrLineDisposition(_ line: String) -> ACPStderrLineDisposition {
        // Antigravity writes its Python harness and raw websocket frames to stderr
        // (for example `I0906 ... local_connection.py ... RAW WS MSG`).
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Classify the record header, never the frame payload: it can contain
        // arbitrary assistant text, tool errors, and even whole prompt bodies.
        let harnessPrefix = #"^[DIWEF]\d{4}\s+(?:\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+)?\d+\s+"#
        guard trimmed.range(of: harnessPrefix, options: .regularExpression) != nil else { return .transcript }
        let frameHeader = harnessPrefix + #"local_connection\.py(?::\d+\])?\s+RAW WS MSG\b"#
        if trimmed.range(of: frameHeader, options: .regularExpression) != nil { return .discard }
        guard trimmed.first == "I" || trimmed.first == "D" else { return .transcript }
        let lowercased = trimmed.lowercased()
        let isFailure = lowercased.contains("error")
            || lowercased.contains("exception")
            || lowercased.contains("traceback")
            || lowercased.contains("failed")
        return isFailure ? .transcript : .diagnosticsOnly
    }

    package func normalizeError(_ error: Error) -> Error {
        error
    }
}
