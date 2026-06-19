import AppKit
import Foundation

/// Centralised helpers for installing the RepoPrompt MCP server
/// into third-party editors and copying the JSON configuration.
enum MCPIntegrationHelper {
    private static let codexCommandsVersionDefaultsKey = "CodexCommandsVersion"
    private static let codexCLICommandsVersionDefaultsKey = "CodexCommandsVersionCLI"
    private static let claudeCommandsVersionDefaultsKey = "ClaudeCommandsVersionByWorkspace"
    private static let claudeCLICommandsVersionDefaultsKey = "ClaudeCommandsVersionCLIByWorkspace"
    private static let agentsSkillsVersionDefaultsKey = "AgentsSkillsVersion"
    private static let agentsCLISkillsVersionDefaultsKey = "AgentsSkillsVersionCLI"
    private static let agentsSkillsPerProjectVersionDefaultsKey = "AgentsSkillsVersionByWorkspace"
    private static let agentsCLISkillsPerProjectVersionDefaultsKey = "AgentsSkillsVersionCLIByWorkspace"
    private static let mcpServerInstalledDefaultsKey = "MCPServerInstalled"

    typealias CLIToolContext = AgentCLIToolContext
    typealias CodexServerEntry = CodexIntegrationConfiguration.ServerEntry
    typealias ClaudeCodeInstallResult = ClaudeCodeIntegrationConfiguration.InstallResult
    typealias ClaudeCodeBatchInstallResult = ClaudeCodeIntegrationConfiguration.BatchInstallResult

    static let desiredCodexToolOutputTokenLimit = CodexIntegrationConfiguration.desiredToolOutputTokenLimit
    static var claudeProcessEnvironmentOverridePairs: [(String, String)] {
        ClaudeCodeIntegrationConfiguration.processEnvironmentOverridePairs
    }

    static var claudeProcessEnvironmentOverrides: [String: String] {
        ClaudeCodeIntegrationConfiguration.processEnvironmentOverrides
    }

    static var claudeMCPAddEnvironmentFlagArguments: [String] {
        ClaudeCodeIntegrationConfiguration.mcpAddEnvironmentFlagArguments
    }

    static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
    static let repoPromptToolNames: Set<String> = [
        "ask_user",
        "ask_user_question",
        "get_file_tree",
        "file_search",
        "read_file",
        "get_code_structure",
        "apply_edits",
        "file_actions",

        "manage_selection",
        "prompt",
        "workspace_context",
        "ask_oracle",
        "oracle_send",
        "oracle_utils",
        "oracle_chat_log",
        "git",
        "bind_context",
        "manage_workspaces",
        "context_builder",
        "share_thoughts",
        "wait_for_next_user_instruction",
        "agent_explore",
        "agent_run",
        "agent_manage",
        "set_status",
        "app_settings"
    ]

    // MARK: - Command Install Mode

    /// Install mode for command/prompt files.
    /// Controls whether missing files are created or only existing files are updated.
    enum CommandInstallMode {
        /// Full install: creates missing files and directories, overwrites all managed files.
        /// Used by UI "Install" buttons for explicit user-initiated installation.
        case fullInstall

        /// Update existing only: only updates files that already exist and are RepoPrompt-managed.
        /// Never creates new files or directories. Used by validation to prevent re-adding removed files.
        case updateExistingOnly
    }

    // MARK: - Provider compatibility shims

    /// Returns disallowed tools for Claude Code in the given context.
    /// Pass `allowNativeBashTool: true` to keep Bash/BashOutput/KillShell enabled.
    static func claudeDisallowedTools(
        for context: CLIToolContext,
        allowNativeBashTool: Bool = false
    ) -> [String] {
        ClaudeCodeIntegrationConfiguration.disallowedTools(
            for: context,
            allowNativeBashTool: allowNativeBashTool
        )
    }

    /// Codex config overrides for headless agent runs.
    /// Returns array of "-c" flag arguments.
    static func codexConfigOverrides(for context: CLIToolContext) -> [String] {
        CodexIntegrationConfiguration.configOverrides(for: context)
    }

    struct RepoPromptPermissionAutoApprovalMatch: Equatable {
        enum Source: String {
            case topLevelToolName
            case nestedToolName
            case serverIdentifier
        }

        let source: Source
        let normalizedToolName: String?
        let serverIdentifier: String?
    }

    private struct RepoPromptToolNameResolution {
        let normalizedName: String
        let canonicalName: String?
        let hasExplicitServerPrefix: Bool
    }

    private static func canonicalizedPath(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Stable path exposed via the user-space symlink. Editors should
    /// reference this so app moves or updates don't break integrations.
    /// Falls back to bundle path if symlink is invalid.
    static var repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration {
        .repoPrompt
    }

    static var serverCommand: String {
        repoPromptMCPConfiguration.command
    }

    /// Flat dictionary required by Cursor and Claude.
    static var mcpConfigDict: [String: Any] {
        repoPromptMCPConfiguration.settingsJSONObject
    }

    /// JSON snippet shown to users / copied to clipboard.
    static var jsonSnippet: String {
        (try? repoPromptMCPConfiguration.prettyPrintedWrappedSettingsJSON())
            ?? """
            {
            	"mcpServers": {
            		"\(repoPromptMCPServerName)": {
            			"command": "\(serverCommand)",
            			"args": []
            		}
            	}
            }
            """
    }

    static var isMCPServerInstalled: Bool {
        UserDefaults.standard.bool(forKey: mcpServerInstalledDefaultsKey)
    }

    private static func setMCPServerInstalled() {
        UserDefaults.standard.set(true, forKey: mcpServerInstalledDefaultsKey)
    }

    static func codexCLIPathComponent(forNormalizedServerName name: String) -> String {
        CodexIntegrationConfiguration.cliPathComponent(forNormalizedServerName: name)
    }

    private static func trimmedLowercasedToolName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func stripFunctionsPrefix(from rawName: String) -> String {
        var normalized = rawName
        while normalized.hasPrefix("functions.") {
            normalized = String(normalized.dropFirst("functions.".count))
        }
        return normalized
    }

    private static func stripExplicitRepoPromptPrefix(from rawName: String) -> (normalized: String, explicit: Bool) {
        let server = repoPromptMCPServerName.lowercased()
        let explicitPrefixes = [
            "mcp__\(server)__",
            "mcp_\(server)__",
            "\(server)__",
            "\(server)_"
        ]
        for prefix in explicitPrefixes where rawName.hasPrefix(prefix) {
            return (String(rawName.dropFirst(prefix.count)), true)
        }
        return (rawName, false)
    }

    private static func canonicalRepoPromptToolAlias(for normalizedName: String) -> String? {
        guard repoPromptToolNames.contains(normalizedName) else { return nil }
        switch normalizedName {
        case "ask_user", "ask_user_question":
            return "ask_user"
        default:
            return normalizedName
        }
    }

    private static func resolveRepoPromptToolName(_ rawName: String?) -> RepoPromptToolNameResolution? {
        guard let lowered = trimmedLowercasedToolName(rawName) else { return nil }
        let withoutFunctions = stripFunctionsPrefix(from: lowered)
        let explicit = stripExplicitRepoPromptPrefix(from: withoutFunctions)
        let normalizedName = explicit.normalized
        let canonicalName = canonicalRepoPromptToolAlias(for: normalizedName)
        return RepoPromptToolNameResolution(
            normalizedName: normalizedName,
            canonicalName: canonicalName,
            hasExplicitServerPrefix: explicit.explicit && canonicalName != nil
        )
    }

    static func normalizedRepoPromptToolName(_ rawName: String) -> String {
        resolveRepoPromptToolName(rawName)?.normalizedName
            ?? rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func canonicalRepoPromptToolName(_ rawName: String?) -> String? {
        resolveRepoPromptToolName(rawName)?.canonicalName
    }

    static func canonicalRepoPromptAskUserToolName(_ rawName: String?) -> String? {
        guard canonicalRepoPromptToolName(rawName) == "ask_user" else { return nil }
        return "ask_user"
    }

    static func isRepoPromptAskUserToolName(_ rawName: String?) -> Bool {
        canonicalRepoPromptAskUserToolName(rawName) != nil
    }

    static func isRepoPromptToolName(_ rawName: String) -> Bool {
        resolveRepoPromptToolName(rawName)?.canonicalName != nil
    }

    /// Returns true when the tool name is a known RepoPrompt tool, regardless of whether it
    /// still carries a server prefix or has already been normalized to a plain name like `read_file`.
    /// Use this for contexts where both prefixed and plain RepoPrompt tool names should be treated
    /// equivalently (e.g. transcript finalization).
    static func isRepoPromptToolNameAfterNormalization(_ rawName: String?) -> Bool {
        canonicalRepoPromptToolName(rawName) != nil
    }

    /// Returns true only when the tool name explicitly carries a RepoPrompt server prefix.
    /// This intentionally excludes plain tool names like `read_file`.
    static func isRepoPromptToolNameWithServerPrefix(_ rawName: String) -> Bool {
        resolveRepoPromptToolName(rawName)?.hasExplicitServerPrefix ?? false
    }

    static func isRepoPromptServerIdentifier(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let lowered = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let repoPromptServer = repoPromptMCPServerName.lowercased()
        return lowered == repoPromptServer || lowered.contains(repoPromptServer)
    }

    static func repoPromptPermissionAutoApprovalMatch(
        requestToolName: String?,
        requestPayload: [String: Any]
    ) -> RepoPromptPermissionAutoApprovalMatch? {
        if let requestToolName, isRepoPromptToolName(requestToolName) {
            return RepoPromptPermissionAutoApprovalMatch(
                source: .topLevelToolName,
                normalizedToolName: normalizedRepoPromptToolName(requestToolName),
                serverIdentifier: nil
            )
        }

        if let match = repoPromptPermissionLabelMatch(requestToolName) {
            return match
        }

        for label in permissionRequestLabelCandidates(input: requestPayload) {
            if let match = repoPromptPermissionLabelMatch(label) {
                return match
            }
        }

        for toolName in permissionRequestToolNameCandidates(input: requestPayload) {
            guard isRepoPromptToolName(toolName) else { continue }
            return RepoPromptPermissionAutoApprovalMatch(
                source: .nestedToolName,
                normalizedToolName: normalizedRepoPromptToolName(toolName),
                serverIdentifier: nil
            )
        }

        if let serverName = repoPromptPermissionServerIdentifier(in: requestPayload) {
            return RepoPromptPermissionAutoApprovalMatch(
                source: .serverIdentifier,
                normalizedToolName: nil,
                serverIdentifier: serverName
            )
        }

        return nil
    }

    static func repoPromptPermissionServerIdentifier(in requestPayload: [String: Any]) -> String? {
        for serverName in permissionRequestServerCandidates(input: requestPayload) {
            guard isRepoPromptServerIdentifier(serverName) else { continue }
            return serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func repoPromptPermissionContainsServerPrefixedToolName(in requestPayload: [String: Any]) -> Bool {
        permissionRequestToolNameCandidates(input: requestPayload).contains { toolName in
            MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(toolName)
        }
    }

    private static func repoPromptPermissionLabelMatch(_ rawLabel: String?) -> RepoPromptPermissionAutoApprovalMatch? {
        guard let label = trimmedPermissionRequestString(rawLabel) else { return nil }
        let legacyServerLabel = "(\(repoPromptMCPServerName) MCP Server)"
        if label.localizedCaseInsensitiveContains(legacyServerLabel) {
            return RepoPromptPermissionAutoApprovalMatch(
                source: .serverIdentifier,
                normalizedToolName: nil,
                serverIdentifier: repoPromptMCPServerName
            )
        }

        guard let separatorIndex = label.firstIndex(of: ":") else { return nil }
        let serverLabel = String(label[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let toolLabel = String(label[label.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRepoPromptPermissionServerLabel(serverLabel), canonicalRepoPromptToolName(toolLabel) != nil else {
            return nil
        }

        return RepoPromptPermissionAutoApprovalMatch(
            source: .serverIdentifier,
            normalizedToolName: normalizedRepoPromptToolName(toolLabel),
            serverIdentifier: serverLabel
        )
    }

    private static func isRepoPromptPermissionServerLabel(_ rawLabel: String) -> Bool {
        let lowered = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let repoPromptServer = repoPromptMCPServerName.lowercased()
        return lowered == repoPromptServer
            || lowered.hasPrefix("\(repoPromptServer)-")
            || lowered.hasPrefix("\(repoPromptServer) ")
            || lowered.contains("\(repoPromptServer) mcp server")
    }

    private static func permissionRequestLabelCandidates(input: [String: Any]) -> [String] {
        let values = collectPermissionRequestStrings(
            from: input,
            paths: [
                ["title"],
                ["toolTitle"],
                ["tool_title"],
                ["displayName"],
                ["display_name"],
                ["rawInput", "title"],
                ["rawInput", "toolTitle"],
                ["rawInput", "tool_title"],
                ["toolCall", "title"],
                ["toolCall", "name"],
                ["toolCall", "displayName"],
                ["toolCall", "display_name"],
                ["rawInput", "toolCall", "title"],
                ["rawInput", "toolCall", "name"],
                ["rawInput", "toolCall", "displayName"],
                ["rawInput", "toolCall", "display_name"],
                ["request", "title"],
                ["request", "toolTitle"],
                ["request", "tool_title"],
                ["request", "toolCall", "title"],
                ["request", "toolCall", "name"],
                ["request", "toolCall", "displayName"],
                ["request", "toolCall", "display_name"],
                ["request", "_meta", "tool_title"],
                ["request", "_meta", "tool_description"]
            ]
        )

        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func permissionRequestServerCandidates(input: [String: Any]) -> [String] {
        collectPermissionRequestStrings(
            from: input,
            paths: [
                ["server_name"],
                ["serverName"],
                ["server"],
                ["mcp_server"],
                ["mcpServer"],
                ["rawInput", "server_name"],
                ["rawInput", "serverName"],
                ["rawInput", "server"],
                ["rawInput", "mcp_server"],
                ["rawInput", "mcpServer"],
                ["serverInfo", "name"],
                ["tool", "server"],
                ["tool", "server_name"],
                ["tool", "serverName"],
                ["toolCall", "server"],
                ["toolCall", "server_name"],
                ["toolCall", "serverName"],
                ["rawInput", "toolCall", "server"],
                ["rawInput", "toolCall", "server_name"],
                ["rawInput", "toolCall", "serverName"],
                ["request", "server"],
                ["request", "server_name"],
                ["request", "serverName"],
                ["request", "tool", "server"],
                ["request", "tool", "server_name"],
                ["request", "tool", "serverName"],
                ["request", "toolCall", "server"],
                ["request", "toolCall", "server_name"],
                ["request", "toolCall", "serverName"],
                ["request", "_meta", "connector_name"]
            ]
        )
    }

    private static func permissionRequestToolNameCandidates(input: [String: Any]) -> [String] {
        var values = collectPermissionRequestStrings(
            from: input,
            paths: [
                ["tool_name"],
                ["toolName"],
                ["name"],
                ["rawInput", "tool_name"],
                ["rawInput", "toolName"],
                ["rawInput", "name"],
                ["tool", "tool_name"],
                ["tool", "toolName"],
                ["tool", "name"],
                ["toolCall", "tool_name"],
                ["toolCall", "toolName"],
                ["toolCall", "name"],
                ["toolCall", "title"],
                ["rawInput", "tool", "tool_name"],
                ["rawInput", "tool", "toolName"],
                ["rawInput", "tool", "name"],
                ["rawInput", "toolCall", "tool_name"],
                ["rawInput", "toolCall", "toolName"],
                ["rawInput", "toolCall", "name"],
                ["rawInput", "toolCall", "title"],
                ["request", "tool_name"],
                ["request", "toolName"],
                ["request", "name"],
                ["request", "tool", "tool_name"],
                ["request", "tool", "toolName"],
                ["request", "tool", "name"],
                ["request", "toolCall", "tool_name"],
                ["request", "toolCall", "toolName"],
                ["request", "toolCall", "name"],
                ["request", "toolCall", "title"],
                ["request", "_meta", "tool_title"],
                ["request", "_meta", "tool_description"],
                ["request", "_meta", "connector_name"]
            ]
        )

        if let suggestions = input["permission_suggestions"] as? [[String: Any]] {
            for suggestion in suggestions {
                guard let rules = suggestion["rules"] as? [[String: Any]] else { continue }
                for rule in rules {
                    if let toolName = trimmedPermissionRequestString(rule["toolName"]) {
                        values.append(toolName)
                    }
                }
            }
        }

        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func collectPermissionRequestStrings(
        from input: [String: Any],
        paths: [[String]]
    ) -> [String] {
        var values: [String] = []
        for path in paths {
            guard let value = permissionRequestValue(at: path, in: input),
                  let stringValue = trimmedPermissionRequestString(value)
            else {
                continue
            }
            values.append(stringValue)
        }
        return values
    }

    private static func permissionRequestValue(at path: [String], in input: [String: Any]) -> Any? {
        var current: Any = input
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key]
            else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func trimmedPermissionRequestString(_ value: Any?) -> String? {
        guard let stringValue = value as? String else { return nil }
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: – Installers -------------------------------------------------------

    /// Opens a Cursor deeplink that installs the MCP server config.
    static func installInCursor() {
        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: mcpConfigDict, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        let base64Config = Data(jsonString.utf8).base64EncodedString()
        let urlString = "cursor://anysphere.cursor-deeplink/mcp/install?name=RepoPrompt&config=\(base64Config)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        setMCPServerInstalled()
    }

    /// Attempts to merge RepoPrompt MCP entry into Claude Desktop.
    /// Returns `true` on success. Never creates the "Claude" directory.
    static func installInClaude() -> Bool {
        let success = ClaudeCodeIntegrationConfiguration.installInClaudeDesktop(
            configuration: repoPromptMCPConfiguration
        )
        if success {
            setMCPServerInstalled()
        }
        return success
    }

    /// Opens a VS Code deeplink that installs the RepoPrompt MCP server config.
    ///
    /// VS Code expects a single JSON object containing at least a `name`
    /// field plus the server configuration. Omitting `name` causes the
    /// entry to appear as "undefined" in its UI.
    static func installInVSCode() {
        let payload: [String: Any] = [
            "name": repoPromptMCPConfiguration.name,
            "command": repoPromptMCPConfiguration.command,
            "args": repoPromptMCPConfiguration.args
        ]

        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        // VS Code expects the JSON directly URL-encoded in the query string.
        let percentEncoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "vscode:mcp/install?\(percentEncoded)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        setMCPServerInstalled()
    }

    // MARK: – Codex CLI --------------------------------------------------------

    static func codexMCPServerEntries() -> [CodexServerEntry] {
        CodexIntegrationConfiguration.mcpServerEntries()
    }

    static func codexMCPServerNames() -> [String] {
        CodexIntegrationConfiguration.mcpServerNames()
    }

    /// Installs the RepoPrompt MCP server into Codex CLI (`~/.codex/config.toml`).
    ///
    /// Invoked from the UI when users opt-in to the integration. Ensures our MCP server exists and is
    /// enabled globally so Codex can use it outside of discovery runs.
    @discardableResult
    static func installInCodex() -> (success: Bool, wasAlreadyPresent: Bool) {
        let result = CodexIntegrationConfiguration.installPersistentMCPConfig()
        if result.success {
            // Also install Codex slash commands for MCP tool usage.
            installCodexCommands(useCLIVariant: false)
            setMCPServerInstalled()
        }
        return result
    }

    /// Ensures the RepoPrompt MCP server exists for discovery runs. Newly created entries default to
    /// `enabled = false` so normal Codex usage stays opt-in, while the agent enables it at runtime via
    /// `-c` overrides.
    @discardableResult
    static func ensureCodexServerForDiscovery() -> (success: Bool, wasAlreadyPresent: Bool) {
        CodexIntegrationConfiguration.ensureServerForDiscovery()
    }

    static func codexConfigContainsRepoPrompt() -> Bool {
        CodexIntegrationConfiguration.configContainsRepoPrompt()
    }

    static func removeCodexInstallEntry() {
        CodexIntegrationConfiguration.removeInstallEntry()
    }

    /// Ensures existing Codex CLI configs include the RepoPrompt V5 MCP policy:
    /// the preserved 10,000-active-second server timeout and enabled parallel tool calls.
    /// Codex has no per-tool timeout exemption, so the long timeout protects synchronous
    /// Oracle and Context Builder operations.
    /// - Parameter force: When true, bypasses the once-per-install guard and rechecks the file.
    /// - Returns: `true` if the RepoPrompt entry was located and now has the desired policy.
    @discardableResult
    static func ensureCodexToolTimeout(force: Bool = false) -> Bool {
        CodexIntegrationConfiguration.ensureToolTimeout(force: force)
    }

    // MARK: – Clipboard --------------------------------------------------------

    /// Copies the JSON snippet (uses the stable symlink path) to the clipboard.
    static func copyConfigToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(jsonSnippet, forType: .string)
    }

    // MARK: – OpenCode CLI --------------------------------------------------------

    /// Checks if the OpenCode config contains a RepoPrompt MCP server entry.
    static func openCodeConfigContainsRepoPrompt() -> Bool {
        OpenCodeIntegrationConfiguration.configContainsRepoPrompt()
    }

    /// Installs the RepoPrompt MCP server into OpenCode CLI (`~/.config/opencode/opencode.json`).
    ///
    /// Invoked from the UI when users opt-in to the integration. This persists only the MCP
    /// server entry; RepoPrompt-managed OpenCode agent modes are process-ephemeral.
    @discardableResult
    static func installInOpenCode() -> (success: Bool, wasAlreadyPresent: Bool) {
        do {
            let result = try OpenCodeIntegrationConfiguration.ensurePersistentMCPConfig()
            setMCPServerInstalled()
            return (true, result.wasMCPServerAlreadyPresent)
        } catch {
            print("MCPIntegrationHelper – OpenCode install failed: \(error)")
            return (false, false)
        }
    }

    // MARK: - Command Versioning

    /// All skill names managed by RepoPrompt.
    private static let skillNames = RepoPromptWorkflowID.installOrder.map(\.commandName)

    /// Returns the SKILL.md file URLs for all skills in a parent directory (folder/SKILL.md structure).
    private static func skillFileURLs(in parentDir: URL, suffix: String) -> [URL] {
        skillNames.map { name in
            parentDir
                .appendingPathComponent("\(name)\(suffix)", isDirectory: true)
                .appendingPathComponent("SKILL.md")
        }
    }

    /// Returns the `agents/openai.yaml` policy file URLs for all skills in a parent directory.
    private static func skillPolicyFileURLs(in parentDir: URL, suffix: String) -> [URL] {
        skillNames.map { name in
            parentDir
                .appendingPathComponent("\(name)\(suffix)", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
                .appendingPathComponent("openai.yaml")
        }
    }

    /// Returns the skill directory URLs for all skills in a parent directory.
    private static func skillDirectoryURLs(in parentDir: URL, suffix: String) -> [URL] {
        skillNames.map { name in
            parentDir
                .appendingPathComponent("\(name)\(suffix)", isDirectory: true)
        }
    }

    /// Returns legacy flat file URLs (for migration detection).
    private static func legacyFlatFileURLs(in directory: URL, suffix: String) -> [URL] {
        skillNames.map { name in
            directory.appendingPathComponent("\(name)\(suffix).md")
        }
    }

    private static func skillsExist(in directory: URL, suffix: String) -> Bool {
        let fm = FileManager.default
        let skillFiles = skillFileURLs(in: directory, suffix: suffix)
        let policyFiles = skillPolicyFileURLs(in: directory, suffix: suffix)
        guard skillFiles.count == policyFiles.count else { return false }

        for (skillFile, policyFile) in zip(skillFiles, policyFiles) {
            guard fm.fileExists(atPath: skillFile.path), fm.fileExists(atPath: policyFile.path) else {
                return false
            }
        }
        return true
    }

    /// Checks if all legacy flat files exist (for Codex prompts which use flat .md files).
    private static func flatFilesExist(in directory: URL, suffix: String) -> Bool {
        let fm = FileManager.default
        return legacyFlatFileURLs(in: directory, suffix: suffix).allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - RepoPrompt Managed File Detection

    /// Metadata extracted from YAML frontmatter of a skill file.
    private struct RepoPromptSkillMetadata {
        let isManaged: Bool
        let version: Int?
        let variant: String? // "mcp" or "cli"
    }

    /// Legacy alias for backwards compatibility
    private typealias RepoPromptCommandMetadata = RepoPromptSkillMetadata

    /// Reads RepoPrompt metadata from a skill file's YAML frontmatter.
    /// Returns nil if the file doesn't exist or isn't a RepoPrompt-managed file.
    /// Supports both `repoprompt_skills_version` (new) and `repoprompt_commands_version` (legacy).
    private static func readRepoPromptMetadata(from fileURL: URL) -> RepoPromptSkillMetadata? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        // Check for YAML frontmatter (starts with ---)
        guard content.hasPrefix("---") else {
            return nil
        }

        // Extract frontmatter content (between first and second ---)
        let lines = content.components(separatedBy: "\n")
        var frontmatterLines: [String] = []
        var foundStart = false
        var foundEnd = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                if !foundStart {
                    foundStart = true
                    continue
                } else {
                    foundEnd = true
                    break
                }
            }
            if foundStart {
                frontmatterLines.append(line)
            }
        }

        guard foundEnd else {
            return nil
        }

        // Parse simple key: value pairs from frontmatter
        var isManaged = false
        var version: Int?
        var variant: String?

        for line in frontmatterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("repoprompt_managed:") {
                let value = trimmed.dropFirst("repoprompt_managed:".count).trimmingCharacters(in: .whitespaces)
                isManaged = (value == "true")
            } else if trimmed.hasPrefix("repoprompt_skills_version:") {
                // New key takes precedence
                let value = trimmed.dropFirst("repoprompt_skills_version:".count).trimmingCharacters(in: .whitespaces)
                version = Int(value)
            } else if trimmed.hasPrefix("repoprompt_commands_version:") {
                // Legacy key - only use if skills_version not found
                if version == nil {
                    let value = trimmed.dropFirst("repoprompt_commands_version:".count).trimmingCharacters(in: .whitespaces)
                    version = Int(value)
                }
            } else if trimmed.hasPrefix("repoprompt_variant:") {
                let value = trimmed.dropFirst("repoprompt_variant:".count).trimmingCharacters(in: .whitespaces)
                variant = value
            }
        }

        // Only return metadata if the file is RepoPrompt-managed
        guard isManaged else {
            return nil
        }

        return RepoPromptSkillMetadata(isManaged: isManaged, version: version, variant: variant)
    }

    /// Checks if a command file exists and is RepoPrompt-managed.
    private static func isRepoPromptManagedFile(at url: URL) -> Bool {
        guard let metadata = readRepoPromptMetadata(from: url) else {
            return false
        }
        return metadata.isManaged
    }

    private static func skillBundleContent(_ content: String, baseName: String, useCLIVariant: Bool) -> String {
        guard useCLIVariant else { return content }
        return content.replacingOccurrences(of: "name: \"\(baseName)\"", with: "name: \"\(baseName)-cli\"", options: [.literal])
    }

    /// Checks if any RepoPrompt-managed skill files exist in a directory.
    /// Checks both new folder/SKILL.md structure and legacy flat files.
    private static func anyManagedSkillFilesExist(in directory: URL, suffix: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            return false
        }

        // Check new folder/SKILL.md structure
        for url in skillFileURLs(in: directory, suffix: suffix) {
            if isRepoPromptManagedFile(at: url) {
                return true
            }
        }

        // Also check legacy flat files (for migration detection)
        for url in legacyFlatFileURLs(in: directory, suffix: suffix) {
            if isRepoPromptManagedFile(at: url) {
                return true
            }
        }

        return false
    }

    // MARK: - Legacy Migration

    /// Removes legacy flat .md skill files from a directory (pre-v7 format).
    /// Only removes files that are RepoPrompt-managed.
    /// - Returns: Number of files removed.
    @discardableResult
    private static func removeLegacyFlatFiles(in directory: URL, suffix: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }

        var removedCount = 0
        for url in legacyFlatFileURLs(in: directory, suffix: suffix) {
            if isRepoPromptManagedFile(at: url) {
                do {
                    try fm.removeItem(at: url)
                    removedCount += 1
                } catch {
                    print("MCPIntegrationHelper – Failed to remove legacy file \(url.lastPathComponent): \(error)")
                }
            }
        }
        return removedCount
    }

    /// Migrates legacy `.claude/commands/` flat files to the new `.claude/skills/` folder structure.
    /// Removes old managed files from `.claude/commands/` so they don't conflict with the new skills.
    private static func migrateLegacyClaudeCommands(workspacePath: String, suffix: String) {
        let legacyDir = legacyClaudeCommandsDirectoryURL(workspacePath: workspacePath)
        removeLegacyFlatFiles(in: legacyDir, suffix: suffix)
    }

    private static func codexCommandsVersionKey(useCLIVariant: Bool) -> String {
        useCLIVariant ? codexCLICommandsVersionDefaultsKey : codexCommandsVersionDefaultsKey
    }

    private static func storedCodexCommandsVersion(useCLIVariant: Bool) -> Int? {
        let key = codexCommandsVersionKey(useCLIVariant: useCLIVariant)
        return UserDefaults.standard.object(forKey: key) as? Int
    }

    private static func setCodexCommandsVersion(_ version: Int, useCLIVariant: Bool) {
        let key = codexCommandsVersionKey(useCLIVariant: useCLIVariant)
        UserDefaults.standard.set(version, forKey: key)
    }

    private static func claudeCommandsVersionKey(useCLIVariant: Bool) -> String {
        useCLIVariant ? claudeCLICommandsVersionDefaultsKey : claudeCommandsVersionDefaultsKey
    }

    private static func storedClaudeCommandsVersions(useCLIVariant: Bool) -> [String: Int] {
        let key = claudeCommandsVersionKey(useCLIVariant: useCLIVariant)
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }

        var versions: [String: Int] = [:]
        for (path, value) in raw {
            if let intValue = value as? Int {
                versions[path] = intValue
            } else if let number = value as? NSNumber {
                versions[path] = number.intValue
            } else if let stringValue = value as? String, let intValue = Int(stringValue) {
                versions[path] = intValue
            }
        }
        return versions
    }

    private static func storedClaudeCommandsVersion(for workspacePath: String, useCLIVariant: Bool) -> Int? {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let versions = storedClaudeCommandsVersions(useCLIVariant: useCLIVariant)
        return versions[canonicalPath]
    }

    private static func setClaudeCommandsVersion(_ version: Int, for workspacePath: String, useCLIVariant: Bool) {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let key = claudeCommandsVersionKey(useCLIVariant: useCLIVariant)
        var versions = storedClaudeCommandsVersions(useCLIVariant: useCLIVariant)
        versions[canonicalPath] = version
        UserDefaults.standard.set(versions, forKey: key)
    }

    private static func clearCodexCommandsVersion(useCLIVariant: Bool) {
        let key = codexCommandsVersionKey(useCLIVariant: useCLIVariant)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func clearClaudeCommandsVersion(for workspacePath: String, useCLIVariant: Bool) {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let key = claudeCommandsVersionKey(useCLIVariant: useCLIVariant)
        var versions = storedClaudeCommandsVersions(useCLIVariant: useCLIVariant)
        versions.removeValue(forKey: canonicalPath)
        if versions.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(versions, forKey: key)
        }
    }

    // MARK: - Installation Detection

    /// Returns the URL for the legacy `.claude/commands` workspace commands directory.
    private static func legacyClaudeCommandsDirectoryURL(workspacePath: String) -> URL {
        URL(fileURLWithPath: workspacePath)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
    }

    /// Returns the URL for the `.claude/skills` workspace skills directory.
    private static func claudeSkillsDirectoryURL(workspacePath: String) -> URL {
        URL(fileURLWithPath: workspacePath)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Returns the URL for the Codex prompts directory.
    private static func codexPromptsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
    }

    /// Returns the URL for the global `.agents/skills` directory.
    /// This is the shared skills folder that multiple agents (Codex, Claude, etc.) can read from.
    private static func agentsSkillsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Returns the URL for the per-project `.agents/skills` directory.
    private static func agentsSkillsDirectoryURL(workspacePath: String) -> URL {
        URL(fileURLWithPath: workspacePath)
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Checks if workspace skills are installed for a workspace.
    /// Only returns true if at least one RepoPrompt-managed skill file exists.
    /// This ensures that if the user deletes the files, we don't re-add them.
    /// Checks both new `.claude/skills/` and legacy `.claude/commands/` paths.
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, checks for CLI variant skills.
    /// - Returns: True if any managed skill files exist.
    static func workspaceSkillsInstalled(workspacePath: String, useCLIVariant: Bool) -> Bool {
        let suffix = useCLIVariant ? "-cli" : ""

        // Check new .claude/skills/ path
        let skillsDir = claudeSkillsDirectoryURL(workspacePath: workspacePath)
        if anyManagedSkillFilesExist(in: skillsDir, suffix: suffix) {
            return true
        }

        // Also check legacy .claude/commands/ path (pre-migration)
        let legacyDir = legacyClaudeCommandsDirectoryURL(workspacePath: workspacePath)
        return anyManagedSkillFilesExist(in: legacyDir, suffix: suffix)
    }

    /// Checks if Codex commands are installed.
    /// Only returns true if at least one RepoPrompt-managed command file exists.
    /// This ensures that if the user deletes the files, we don't re-add them.
    /// - Parameter useCLIVariant: If true, checks for CLI variant commands.
    /// - Returns: True if any managed command files exist.
    static func codexCommandsInstalled(useCLIVariant: Bool) -> Bool {
        let suffix = useCLIVariant ? "-cli" : ""
        let promptsDir = codexPromptsDirectoryURL()

        // Only return true if we find RepoPrompt-managed files on disk
        // Do NOT use stored version as proof of installation - this caused the re-add bug
        return anyManagedSkillFilesExist(in: promptsDir, suffix: suffix)
    }

    // MARK: – Workspace Skills ----------------------------------------------------

    /// Installs or updates workspace skills in a workspace directory.
    ///
    /// Creates or overwrites `.claude/skills/rp-investigate/SKILL.md`, `.claude/skills/rp-build/SKILL.md`, etc.
    /// Also migrates any legacy `.claude/commands/` flat files to the new folder structure.
    ///
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, installs CLI variant skills (rpce-cli syntax). Defaults to false (MCP syntax).
    ///   - mode: Installation mode. `.fullInstall` creates missing files (UI buttons), `.updateExistingOnly` only updates existing managed files (validation).
    /// - Returns: Number of skills successfully installed/updated.
    @discardableResult
    static func installWorkspaceSkills(workspacePath: String, useCLIVariant: Bool = false, mode: CommandInstallMode = .fullInstall) -> Int {
        let suffix = useCLIVariant ? "-cli" : ""

        // Migrate legacy .claude/commands/ flat files before installing
        if mode == .fullInstall {
            migrateLegacyClaudeCommands(workspacePath: workspacePath, suffix: suffix)
        }

        let skillsDir = claudeSkillsDirectoryURL(workspacePath: workspacePath)
        return installSkillsToDirectory(
            skillsDir,
            useCLIVariant: useCLIVariant,
            mode: mode,
            storedVersion: storedClaudeCommandsVersion(for: workspacePath, useCLIVariant: useCLIVariant),
            onSuccess: { setClaudeCommandsVersion($0, for: workspacePath, useCLIVariant: useCLIVariant) }
        )
    }

    /// Installs workspace skills in multiple workspace directories.
    ///
    /// - Parameters:
    ///   - workspacePaths: Array of workspace folder paths.
    ///   - useCLIVariant: If true, installs CLI variant commands (rpce-cli syntax). Defaults to false (MCP syntax).
    ///   - mode: Installation mode. `.fullInstall` creates missing files (UI buttons), `.updateExistingOnly` only updates existing managed files (validation).
    /// - Returns: Total number of skills successfully installed across all workspaces.
    @discardableResult
    static func installWorkspaceSkills(workspacePaths: [String], useCLIVariant: Bool = false, mode: CommandInstallMode = .fullInstall) -> Int {
        guard !workspacePaths.isEmpty else { return 0 }

        var totalSuccess = 0
        for path in workspacePaths {
            totalSuccess += installWorkspaceSkills(workspacePath: path, useCLIVariant: useCLIVariant, mode: mode)
        }
        return totalSuccess
    }

    /// Uninstalls workspace skills from a workspace directory.
    /// Removes skill directories from `.claude/skills/` and legacy flat files from `.claude/commands/`.
    /// Only removes files/directories that are RepoPrompt-managed.
    /// Also clears the stored version for that workspace.
    ///
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, uninstalls CLI variant skills. Defaults to false (MCP syntax).
    /// - Returns: Number of skills successfully removed.
    @discardableResult
    static func uninstallWorkspaceSkills(workspacePath: String, useCLIVariant: Bool = false) -> Int {
        let suffix = useCLIVariant ? "-cli" : ""

        // Remove from new .claude/skills/ path
        let skillsDir = claudeSkillsDirectoryURL(workspacePath: workspacePath)
        let removedNew = uninstallSkillsFromDirectory(
            skillsDir,
            useCLIVariant: useCLIVariant,
            onComplete: {}
        )

        // Also remove legacy .claude/commands/ flat files
        let legacyDir = legacyClaudeCommandsDirectoryURL(workspacePath: workspacePath)
        let removedLegacy = removeLegacyFlatFiles(in: legacyDir, suffix: suffix)

        // Clear stored version
        clearClaudeCommandsVersion(for: workspacePath, useCLIVariant: useCLIVariant)

        return removedNew + removedLegacy
    }

    /// Uninstalls workspace skills from multiple workspace directories.
    ///
    /// - Parameters:
    ///   - workspacePaths: Array of workspace folder paths.
    ///   - useCLIVariant: If true, uninstalls CLI variant skills. Defaults to false (MCP syntax).
    /// - Returns: Total number of skills successfully removed across all workspaces.
    @discardableResult
    static func uninstallWorkspaceSkills(workspacePaths: [String], useCLIVariant: Bool = false) -> Int {
        guard !workspacePaths.isEmpty else { return 0 }

        var totalRemoved = 0
        for path in workspacePaths {
            totalRemoved += uninstallWorkspaceSkills(workspacePath: path, useCLIVariant: useCLIVariant)
        }
        return totalRemoved
    }

    // MARK: – Codex CLI Commands --------------------------------------------------

    /// Installs or updates Codex CLI custom commands in the global prompts directory.
    ///
    /// Creates or overwrites the flat Codex prompt files for RepoPrompt-managed workflows.
    /// These appear as slash commands in Codex, for example `/rp-build`, `/rp-review`, and `/rp-orchestrate`.
    ///
    /// - Parameters:
    ///   - useCLIVariant: If true, installs CLI variant commands (rpce-cli syntax). Defaults to true for Codex.
    ///   - mode: Installation mode. `.fullInstall` creates missing files (UI buttons), `.updateExistingOnly` only updates existing managed files (validation).
    /// - Returns: Number of commands successfully installed/updated.
    @discardableResult
    static func installCodexCommands(useCLIVariant: Bool = true, mode: CommandInstallMode = .fullInstall) -> Int {
        let fm = FileManager.default
        let promptsDir = codexPromptsDirectoryURL()

        // In updateExistingOnly mode, don't create directories - just bail if they don't exist
        if mode == .updateExistingOnly {
            guard fm.fileExists(atPath: promptsDir.path) else {
                return 0
            }
        } else {
            // fullInstall mode: create directory if needed
            do {
                try fm.createDirectory(at: promptsDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("MCPIntegrationHelper – Failed to create ~/.codex/prompts directory: \(error)")
                return 0
            }
        }

        var successCount = 0
        let variant: WorkflowPromptVariant = useCLIVariant ? .cli : .mcp
        let suffix = useCLIVariant ? "-cli" : ""
        let currentVersion = RepoPromptWorkflowPrompts.skillsVersion
        let storedVersion = storedCodexCommandsVersion(useCLIVariant: useCLIVariant)

        // In fullInstall mode, check if all commands exist and are up to date
        if mode == .fullInstall {
            let hasAllCommands = flatFilesExist(in: promptsDir, suffix: suffix)
            if storedVersion == currentVersion, hasAllCommands {
                return skillNames.count
            }
        }

        // Define command files with their content generators
        let commands: [(name: String, content: () -> String)] = WorkflowPromptCatalog.installDescriptors.map { descriptor in
            (
                name: descriptor.name,
                content: { RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: variant) }
            )
        }

        for (name, contentGenerator) in commands {
            let fileURL = promptsDir.appendingPathComponent("\(name)\(suffix).md")

            // In updateExistingOnly mode, skip files that don't exist or aren't managed by us
            if mode == .updateExistingOnly {
                guard isRepoPromptManagedFile(at: fileURL) else {
                    continue
                }
            }

            do {
                try contentGenerator().write(to: fileURL, atomically: true, encoding: .utf8)
                successCount += 1
            } catch {
                print("MCPIntegrationHelper – Failed to write \(name)\(suffix).md: \(error)")
            }
        }

        // Only update stored version in fullInstall mode when all commands were written
        if mode == .fullInstall, successCount == skillNames.count {
            setCodexCommandsVersion(currentVersion, useCLIVariant: useCLIVariant)
        }

        return successCount
    }

    /// Uninstalls Codex CLI custom commands from the global prompts directory.
    /// Only removes files that are RepoPrompt-managed (have the repoprompt_managed: true frontmatter).
    /// Also clears the stored version.
    ///
    /// - Parameter useCLIVariant: If true, uninstalls CLI variant commands. Defaults to true for Codex.
    /// - Returns: Number of commands successfully removed.
    @discardableResult
    static func uninstallCodexCommands(useCLIVariant: Bool = true) -> Int {
        let fm = FileManager.default
        let promptsDir = codexPromptsDirectoryURL()
        let suffix = useCLIVariant ? "-cli" : ""

        guard fm.fileExists(atPath: promptsDir.path) else {
            // Clear stored version even if directory doesn't exist
            clearCodexCommandsVersion(useCLIVariant: useCLIVariant)
            return 0
        }

        var removedCount = 0

        for name in skillNames {
            let fileURL = promptsDir.appendingPathComponent("\(name)\(suffix).md")

            // Only remove files that are RepoPrompt-managed
            guard isRepoPromptManagedFile(at: fileURL) else {
                continue
            }

            do {
                try fm.removeItem(at: fileURL)
                removedCount += 1
            } catch {
                print("MCPIntegrationHelper – Failed to remove \(name)\(suffix).md: \(error)")
            }
        }

        // Clear stored version
        clearCodexCommandsVersion(useCLIVariant: useCLIVariant)

        return removedCount
    }

    // MARK: – Agents Skills (.agents/skills) ----------------------------------------

    // MARK: - Agents Skills Version Tracking

    private static func agentsSkillsVersionKey(useCLIVariant: Bool, perProject: Bool) -> String {
        if perProject {
            useCLIVariant ? agentsCLISkillsPerProjectVersionDefaultsKey : agentsSkillsPerProjectVersionDefaultsKey
        } else {
            useCLIVariant ? agentsCLISkillsVersionDefaultsKey : agentsSkillsVersionDefaultsKey
        }
    }

    private static func storedAgentsSkillsVersion(useCLIVariant: Bool) -> Int? {
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: false)
        return UserDefaults.standard.object(forKey: key) as? Int
    }

    private static func setAgentsSkillsVersion(_ version: Int, useCLIVariant: Bool) {
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: false)
        UserDefaults.standard.set(version, forKey: key)
    }

    private static func clearAgentsSkillsVersion(useCLIVariant: Bool) {
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: false)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func storedAgentsSkillsVersions(useCLIVariant: Bool) -> [String: Int] {
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: true)
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }

        var versions: [String: Int] = [:]
        for (path, value) in raw {
            if let intValue = value as? Int {
                versions[path] = intValue
            } else if let number = value as? NSNumber {
                versions[path] = number.intValue
            } else if let stringValue = value as? String, let intValue = Int(stringValue) {
                versions[path] = intValue
            }
        }
        return versions
    }

    private static func storedAgentsSkillsVersion(for workspacePath: String, useCLIVariant: Bool) -> Int? {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let versions = storedAgentsSkillsVersions(useCLIVariant: useCLIVariant)
        return versions[canonicalPath]
    }

    private static func setAgentsSkillsVersion(_ version: Int, for workspacePath: String, useCLIVariant: Bool) {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: true)
        var versions = storedAgentsSkillsVersions(useCLIVariant: useCLIVariant)
        versions[canonicalPath] = version
        UserDefaults.standard.set(versions, forKey: key)
    }

    private static func clearAgentsSkillsVersion(for workspacePath: String, useCLIVariant: Bool) {
        let canonicalPath = canonicalizedPath(for: workspacePath)
        let key = agentsSkillsVersionKey(useCLIVariant: useCLIVariant, perProject: true)
        var versions = storedAgentsSkillsVersions(useCLIVariant: useCLIVariant)
        versions.removeValue(forKey: canonicalPath)
        if versions.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(versions, forKey: key)
        }
    }

    // MARK: - Agents Skills Installation Detection

    /// Checks if global agents skills are installed.
    /// Only returns true if at least one RepoPrompt-managed skill file exists.
    /// - Parameter useCLIVariant: If true, checks for CLI variant skills.
    /// - Returns: True if any managed skill files exist.
    static func agentsSkillsInstalled(useCLIVariant: Bool) -> Bool {
        let suffix = useCLIVariant ? "-cli" : ""
        let skillsDir = agentsSkillsDirectoryURL()
        return anyManagedSkillFilesExist(in: skillsDir, suffix: suffix)
    }

    /// Checks if per-project agents skills are installed.
    /// Only returns true if at least one RepoPrompt-managed skill file exists.
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, checks for CLI variant skills.
    /// - Returns: True if any managed skill files exist.
    static func agentsSkillsInstalled(workspacePath: String, useCLIVariant: Bool) -> Bool {
        let suffix = useCLIVariant ? "-cli" : ""
        let skillsDir = agentsSkillsDirectoryURL(workspacePath: workspacePath)
        return anyManagedSkillFilesExist(in: skillsDir, suffix: suffix)
    }

    // MARK: - Agents Skills Installation

    /// Shared implementation for installing skills to a directory using folder/SKILL.md structure.
    /// Each skill gets its own subdirectory with a `SKILL.md` file and `agents/openai.yaml` policy.
    private static func installSkillsToDirectory(
        _ skillsDir: URL,
        useCLIVariant: Bool,
        mode: CommandInstallMode,
        storedVersion: Int?,
        onSuccess: (Int) -> Void
    ) -> Int {
        let fm = FileManager.default

        // In updateExistingOnly mode, don't create directories
        if mode == .updateExistingOnly {
            guard fm.fileExists(atPath: skillsDir.path) else {
                return 0
            }
        } else {
            do {
                try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("MCPIntegrationHelper – Failed to create \(skillsDir.path): \(error)")
                return 0
            }
        }

        // Migrate legacy flat files in the same directory before installing
        if mode == .fullInstall {
            let suffix = useCLIVariant ? "-cli" : ""
            removeLegacyFlatFiles(in: skillsDir, suffix: suffix)
        }

        let variant: WorkflowPromptVariant = useCLIVariant ? .cli : .mcp
        let suffix = useCLIVariant ? "-cli" : ""
        let currentVersion = RepoPromptWorkflowPrompts.skillsVersion

        // In fullInstall mode, check if all skills exist and are up to date
        if mode == .fullInstall {
            let hasAllSkills = skillsExist(in: skillsDir, suffix: suffix)
            if storedVersion == currentVersion, hasAllSkills {
                return skillNames.count
            }
        }

        // Define skill files with their content generators
        let skills: [(name: String, content: () -> String)] = WorkflowPromptCatalog.installDescriptors.map { descriptor in
            (
                name: descriptor.name,
                content: { RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: variant) }
            )
        }

        var successCount = 0
        for (name, contentGenerator) in skills {
            // Create skill subdirectory: <skillsDir>/<name><suffix>/
            let skillSubdir = skillsDir.appendingPathComponent("\(name)\(suffix)", isDirectory: true)
            let skillFileURL = skillSubdir.appendingPathComponent("SKILL.md")
            let agentsDirectoryURL = skillSubdir.appendingPathComponent("agents", isDirectory: true)
            let skillPolicyFileURL = agentsDirectoryURL.appendingPathComponent("openai.yaml")

            if mode == .updateExistingOnly {
                guard isRepoPromptManagedFile(at: skillFileURL) else {
                    continue
                }
            }

            do {
                try fm.createDirectory(at: agentsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("MCPIntegrationHelper – Failed to create skill directory \(agentsDirectoryURL.path): \(error)")
                continue
            }

            do {
                let skillContent = skillBundleContent(contentGenerator(), baseName: name, useCLIVariant: useCLIVariant)
                try skillContent.write(to: skillFileURL, atomically: true, encoding: .utf8)
                try RepoPromptWorkflowPrompts.codexSkillAgentPolicy(forSkillNamed: name, variant: variant).write(to: skillPolicyFileURL, atomically: true, encoding: .utf8)
                successCount += 1
            } catch {
                print("MCPIntegrationHelper – Failed to write \(name)\(suffix) skill bundle: \(error)")
            }
        }

        if mode == .fullInstall, successCount == skillNames.count {
            onSuccess(currentVersion)
        }

        return successCount
    }

    /// Installs or updates skills in the global `~/.agents/skills` directory.
    ///
    /// Creates or overwrites skill files that can be shared across multiple agents
    /// (Codex, Claude, etc.) following the `.agents/skills` convention.
    ///
    /// - Parameters:
    ///   - useCLIVariant: If true, installs CLI variant skills. Defaults to false (MCP syntax).
    ///   - mode: Installation mode. `.fullInstall` creates missing files, `.updateExistingOnly` only updates existing managed files.
    /// - Returns: Number of skills successfully installed/updated.
    @discardableResult
    static func installAgentsSkills(useCLIVariant: Bool = false, mode: CommandInstallMode = .fullInstall) -> Int {
        installSkillsToDirectory(
            agentsSkillsDirectoryURL(),
            useCLIVariant: useCLIVariant,
            mode: mode,
            storedVersion: storedAgentsSkillsVersion(useCLIVariant: useCLIVariant),
            onSuccess: { setAgentsSkillsVersion($0, useCLIVariant: useCLIVariant) }
        )
    }

    /// Installs or updates skills in a per-project `.agents/skills` directory.
    ///
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, installs CLI variant skills. Defaults to false (MCP syntax).
    ///   - mode: Installation mode. `.fullInstall` creates missing files, `.updateExistingOnly` only updates existing managed files.
    /// - Returns: Number of skills successfully installed/updated.
    @discardableResult
    static func installAgentsSkills(workspacePath: String, useCLIVariant: Bool = false, mode: CommandInstallMode = .fullInstall) -> Int {
        installSkillsToDirectory(
            agentsSkillsDirectoryURL(workspacePath: workspacePath),
            useCLIVariant: useCLIVariant,
            mode: mode,
            storedVersion: storedAgentsSkillsVersion(for: workspacePath, useCLIVariant: useCLIVariant),
            onSuccess: { setAgentsSkillsVersion($0, for: workspacePath, useCLIVariant: useCLIVariant) }
        )
    }

    /// Installs skills in multiple workspace directories.
    ///
    /// - Parameters:
    ///   - workspacePaths: Array of workspace folder paths.
    ///   - useCLIVariant: If true, installs CLI variant skills. Defaults to false (MCP syntax).
    ///   - mode: Installation mode.
    /// - Returns: Total number of skills successfully installed across all workspaces.
    @discardableResult
    static func installAgentsSkills(workspacePaths: [String], useCLIVariant: Bool = false, mode: CommandInstallMode = .fullInstall) -> Int {
        guard !workspacePaths.isEmpty else { return 0 }

        var totalSuccess = 0
        for path in workspacePaths {
            totalSuccess += installAgentsSkills(workspacePath: path, useCLIVariant: useCLIVariant, mode: mode)
        }
        return totalSuccess
    }

    /// Shared implementation for uninstalling skills from a directory.
    /// Removes skill directories (folder/SKILL.md structure) and any legacy flat files.
    private static func uninstallSkillsFromDirectory(
        _ skillsDir: URL,
        useCLIVariant: Bool,
        onComplete: () -> Void
    ) -> Int {
        let fm = FileManager.default
        let suffix = useCLIVariant ? "-cli" : ""

        guard fm.fileExists(atPath: skillsDir.path) else {
            onComplete()
            return 0
        }

        var removedCount = 0

        for name in skillNames {
            // Remove new folder/SKILL.md structure
            let skillSubdir = skillsDir.appendingPathComponent("\(name)\(suffix)", isDirectory: true)
            let skillFileURL = skillSubdir.appendingPathComponent("SKILL.md")

            if isRepoPromptManagedFile(at: skillFileURL) {
                do {
                    try fm.removeItem(at: skillSubdir)
                    removedCount += 1
                } catch {
                    print("MCPIntegrationHelper – Failed to remove \(name)\(suffix)/ directory: \(error)")
                }
            }

            // Also remove legacy flat files if they exist
            let legacyFileURL = skillsDir.appendingPathComponent("\(name)\(suffix).md")
            if isRepoPromptManagedFile(at: legacyFileURL) {
                do {
                    try fm.removeItem(at: legacyFileURL)
                    if removedCount == 0 || !fm.fileExists(atPath: skillSubdir.path) {
                        removedCount += 1
                    }
                } catch {
                    print("MCPIntegrationHelper – Failed to remove legacy \(name)\(suffix).md: \(error)")
                }
            }
        }

        onComplete()
        return removedCount
    }

    /// Uninstalls skills from the global `~/.agents/skills` directory.
    /// Only removes files that are RepoPrompt-managed.
    ///
    /// - Parameter useCLIVariant: If true, uninstalls CLI variant skills.
    /// - Returns: Number of skills successfully removed.
    @discardableResult
    static func uninstallAgentsSkills(useCLIVariant: Bool = false) -> Int {
        uninstallSkillsFromDirectory(
            agentsSkillsDirectoryURL(),
            useCLIVariant: useCLIVariant,
            onComplete: { clearAgentsSkillsVersion(useCLIVariant: useCLIVariant) }
        )
    }

    /// Uninstalls skills from a per-project `.agents/skills` directory.
    /// Only removes files that are RepoPrompt-managed.
    ///
    /// - Parameters:
    ///   - workspacePath: Path to the workspace/project folder.
    ///   - useCLIVariant: If true, uninstalls CLI variant skills.
    /// - Returns: Number of skills successfully removed.
    @discardableResult
    static func uninstallAgentsSkills(workspacePath: String, useCLIVariant: Bool = false) -> Int {
        uninstallSkillsFromDirectory(
            agentsSkillsDirectoryURL(workspacePath: workspacePath),
            useCLIVariant: useCLIVariant,
            onComplete: { clearAgentsSkillsVersion(for: workspacePath, useCLIVariant: useCLIVariant) }
        )
    }

    /// Uninstalls skills from multiple workspace directories.
    ///
    /// - Parameters:
    ///   - workspacePaths: Array of workspace folder paths.
    ///   - useCLIVariant: If true, uninstalls CLI variant skills.
    /// - Returns: Total number of skills successfully removed across all workspaces.
    @discardableResult
    static func uninstallAgentsSkills(workspacePaths: [String], useCLIVariant: Bool = false) -> Int {
        guard !workspacePaths.isEmpty else { return 0 }

        var totalRemoved = 0
        for path in workspacePaths {
            totalRemoved += uninstallAgentsSkills(workspacePath: path, useCLIVariant: useCLIVariant)
        }
        return totalRemoved
    }

    /// Strips YAML frontmatter from a skill string (kept for potential future use).
    private static func stripYAMLFrontmatter(_ content: String) -> String {
        // Pattern: starts with ---, ends with ---
        if content.hasPrefix("---") {
            let lines = content.components(separatedBy: "\n")
            var inFrontmatter = true
            var resultLines: [String] = []
            var foundEndMarker = false

            for (index, line) in lines.enumerated() {
                if index == 0, line == "---" {
                    continue // Skip opening ---
                }
                if inFrontmatter, line == "---" {
                    inFrontmatter = false
                    foundEndMarker = true
                    continue // Skip closing ---
                }
                if !inFrontmatter {
                    resultLines.append(line)
                }
            }

            // If we found and stripped frontmatter, return trimmed result
            if foundEndMarker {
                return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return content
    }

    // MARK: – Claude Code CLI -----------------------------------------------------

    /// Installs the RepoPrompt MCP server in Claude Code (the CLI tool) for a single workspace.
    @discardableResult
    static func installInClaudeCode(workspacePath: String? = nil) async -> ClaudeCodeInstallResult {
        let result = await ClaudeCodeIntegrationConfiguration.installInClaudeCode(
            workspacePath: workspacePath,
            configuration: repoPromptMCPConfiguration
        )
        if result.success {
            setMCPServerInstalled()
        }
        return result
    }

    /// Installs the RepoPrompt MCP server in Claude Code for multiple workspaces.
    @discardableResult
    static func installInClaudeCode(workspacePaths: [String]) async -> ClaudeCodeBatchInstallResult {
        let result = await ClaudeCodeIntegrationConfiguration.installInClaudeCode(
            workspacePaths: workspacePaths,
            configuration: repoPromptMCPConfiguration
        )
        if result.success {
            setMCPServerInstalled()
        }
        return result
    }

    // MARK: - CLI PATH Installation ------------------------------------------------

    /// Installs the CLI to /usr/local/bin as rpce-cli (release) or rpce-cli-debug (debug).
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func installCLIToPath() async throws {
        try await CLIPathInstaller.install()
    }

    /// Uninstalls the CLI from /usr/local/bin.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func uninstallCLIFromPath() async throws {
        try await CLIPathInstaller.uninstall()
    }

    /// Returns the current CLI PATH installation status.
    @MainActor
    static func cliPathInstallStatus() -> CLIPathInstaller.InstallationStatus {
        CLIPathInstaller.checkStatus()
    }

    /// The CLI command name that will be installed (rpce-cli or rpce-cli-debug).
    static var cliCommandName: String {
        CLIPathInstaller.cliCommandName
    }

    /// The directory where the CLI will be installed.
    static var cliInstallDirectory: String {
        CLIPathInstaller.installDirectory
    }

    /// The full path where the CLI will be installed.
    static var cliInstallPath: String {
        CLIPathInstaller.installPath
    }

    // MARK: - claude-rp Wrapper Installation ----------------------------------------

    /// Installs the claude-rp wrapper to /usr/local/bin.
    /// This wrapper runs Claude Code with RepoPrompt's MCP tools preferred over built-in tools.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func installClaudeRP() async throws {
        try await CLIPathInstaller.installClaudeRP()
    }

    /// Uninstalls the claude-rp wrapper from /usr/local/bin.
    /// Uses AppleScript to request admin privileges.
    @MainActor
    static func uninstallClaudeRP() async throws {
        try await CLIPathInstaller.uninstallClaudeRP()
    }

    /// Returns the current claude-rp wrapper installation status.
    @MainActor
    static func claudeRPInstallStatus() -> CLIPathInstaller.ClaudeRPInstallationStatus {
        CLIPathInstaller.checkClaudeRPStatus()
    }

    /// Human-readable description of the claude-rp wrapper status.
    @MainActor
    static func claudeRPStatusDescription() -> String {
        CLIPathInstaller.claudeRPStatusDescription()
    }

    /// The claude-rp command name that will be installed (claude-rpce or claude-rpce-debug).
    static var claudeRPCommandName: String {
        CLIPathInstaller.claudeRPCommandName
    }

    /// The full path where the claude-rp wrapper will be installed.
    static var claudeRPInstallPath: String {
        CLIPathInstaller.claudeRPInstallPath
    }
}
