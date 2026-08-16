import Foundation

struct GrokBuildACPAgentProvider: ACPAgentProvider {
    private let config: GrokBuildAgentConfig
    private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
    private let launchResolver: GrokBuildACPLaunchResolver

    #if DEBUG
        var test_config: GrokBuildAgentConfig {
            config
        }
    #endif

    init(
        config: GrokBuildAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: GrokBuildACPLaunchResolver = GrokBuildACPLaunchResolver()
    ) {
        self.config = config
        self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
        self.launchResolver = launchResolver
    }

    var providerID: ACPProviderID {
        .grokBuild
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        try await launchResolver.probeSupport(for: config)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
        let resolvedLaunch = try launchResolver.resolvedLaunch(for: config)

        var arguments = resolvedLaunch.arguments
        if config.alwaysApproveTools || request.autoApproveAllToolPermissions {
            // Approval flags belong to the parent `grok agent` command, not `stdio`.
            if let agentIndex = arguments.firstIndex(of: "agent"), !arguments.contains("--always-approve") {
                arguments.insert("--always-approve", at: agentIndex + 1)
            }
        }

        var environment: [String: String] = [:]
        if let apiKey = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            // Never log this value; it exists only as a child-process launch override.
            environment["XAI_API_KEY"] = apiKey
        }

        return ACPLaunchConfiguration(
            providerID: providerID,
            command: resolvedLaunch.command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            additionalPathHints: resolvedLaunch.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            cleanupArtifact: nil,
            expectedExecutableIdentity: resolvedLaunch.executableIdentity
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    !resume.isEmpty
        {
            .load(existingSessionID: resume)
        } else {
            .new
        }

        return try ACPSessionConfiguration(
            mode: mode,
            workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
            mcpServers: config.includeRepoPromptMCPServer ? [repoPromptMCPConfiguration] : []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        // Grok Build 1.0.3 advertises promptCapabilities.image = false over ACP, so v1 is
        // text-only: reject attachments explicitly instead of silently dropping them.
        guard request.attachments.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build does not advertise image support over ACP; remove attachments and retry."
            )
        }

        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String = if isFollowUp || systemPrompt.isEmpty {
            userMessage.isEmpty ? message.userMessage : userMessage
        } else if userMessage.isEmpty {
            systemPrompt
        } else {
            "\(systemPrompt)\n\n\(userMessage)"
        }

        return try ACPPromptContentBuilder.blocks(
            text: text,
            attachments: request.attachments
        )
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        GrokBuildACPEventNormalizer.normalize(payload)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        // grok's background workers (its own configured MCP servers, auth refresh, leader)
        // log fatal-looking transport errors to stderr when THEY fail; the ACP session
        // itself is unaffected and reports real failures over JSON-RPC. Suppress that
        // noise; everything else still surfaces.
        !line.contains("worker quit with fatal: Transport channel closed")
    }

    func preferredAuthMethodID(context _: ACPAuthenticationContext) -> String? {
        // Never send ACP `authenticate`: Grok's own credential precedence (config.toml key →
        // ~/.grok/auth.json session token → XAI_API_KEY env) is authoritative, and a stored
        // RepoPrompt key arrives as the XAI_API_KEY launch-environment override.
        nil
    }

    func normalizeError(_ error: Error) -> Error {
        if error is AIProviderError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(detail: "Grok Build CLI ACP server not found. Install Grok Build (`npm i -g @xai-official/grok` or https://x.ai/cli/install.sh) and ensure `grok agent stdio` is available.")
        }
        if error is GrokBuildACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = description.lowercased()
        if lower.contains("run `grok login`")
            || lower.contains("authorizationrequired")
            || lower.contains("authentication required")
            || lower.contains("not authenticated")
        {
            return AIProviderError.invalidConfiguration(
                detail: "Grok Build is not authenticated. Run `grok login` or set `XAI_API_KEY`."
            )
        }
        if lower.contains("session/set_model")
            || lower.contains("session model")
        {
            return AIProviderError.invalidConfiguration(detail: description)
        }
        return AIProviderError.apiError(source: error)
    }

    private func standardizedWorkingDirectory(from workspacePath: String?) throws -> String {
        if let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrokBuildACPPreflight", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}

// MARK: - ACPDirectSessionModelProvider

extension GrokBuildACPAgentProvider: ACPDirectSessionModelProvider {
    /// Parses Grok's top-level `models` (`SessionModelState`) from a `session/new` or
    /// `session/load` response. Verified against grok 1.0.3: the response carries
    /// `{sessionId, models: {currentModelId, availableModels: [{modelId, name, description?,
    /// _meta?}]}, _meta}` and no modern `configOptions`.
    func parseDirectSessionModelSnapshot(
        from sessionResponse: [String: Any]
    ) -> ACPProviderModelSnapshotResult {
        guard let modelsValue = sessionResponse["models"] else {
            return .absent
        }
        guard let models = modelsValue as? [String: Any] else {
            return .malformed(reason: "Grok `models` metadata is not an object.")
        }
        guard let available = models["availableModels"] as? [[String: Any]] else {
            return .malformed(reason: "Grok `models.availableModels` is missing or not an array.")
        }

        var options: [AgentModelOption] = []
        var variants: [AgentModelOption] = []
        var seen = Set<String>()
        // Per-model advertised effort id→value pairs, retained for resolving the session
        // config's selected mode: the wire exposes `id` and `value` separately and nothing
        // guarantees they are equal.
        var effortPairsByModelRaw: [String: [(id: String, effort: CodexReasoningEffort)]] = [:]
        for entry in available {
            guard let rawID = (entry["modelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawID.isEmpty
            else {
                continue
            }
            guard seen.insert(rawID).inserted else { continue }
            func nonEmpty(_ value: String?) -> String? {
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
                return trimmed
            }
            let displayName = nonEmpty(entry["name"] as? String) ?? rawID
            let description = nonEmpty(entry["description"] as? String)

            // `_meta.reasoningEfforts` (live-verified grok 1.0.4): each base model advertises
            // its supported efforts + per-model default. Effort metadata is honored only
            // when the model opts in, and a default outside the advertised list is dropped
            // rather than trusted — grok silently ignores unknown efforts, so nothing
            // unadvertised may ever leave the client. Variants surface as compound raws
            // (`grok-4.6-low`); a variant whose compound would collide with a real
            // advertised base id is skipped so the base stays unambiguous.
            let meta = entry["_meta"] as? [String: Any]
            let supportsEffort = (meta?["supportsReasoningEffort"] as? Bool) == true
            let effortEntries = supportsEffort ? (meta?["reasoningEfforts"] as? [[String: Any]] ?? []) : []
            var supportedEfforts: [CodexReasoningEffort] = []
            var wireDefaultEffort: CodexReasoningEffort?
            var effortPairs: [(id: String, effort: CodexReasoningEffort)] = []
            for effortEntry in effortEntries {
                guard let effort = CodexReasoningEffort.parse(effortEntry["value"] as? String) else { continue }
                supportedEfforts.append(effort)
                if let id = (effortEntry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                    effortPairs.append((id: id, effort: effort))
                }
                if wireDefaultEffort == nil, (effortEntry["default"] as? Bool) == true {
                    wireDefaultEffort = effort
                }
            }
            effortPairsByModelRaw[rawID] = effortPairs
            let declaredDefault = supportsEffort
                ? CodexReasoningEffort.parse(meta?["reasoningEffort"] as? String)
                : nil
            let defaultEffort = [declaredDefault, wireDefaultEffort]
                .compactMap(\.self)
                .first(where: { supportedEfforts.contains($0) })

            options.append(
                AgentModelOption(
                    rawValue: rawID,
                    displayName: displayName,
                    description: description,
                    isPlaceholderDefault: false,
                    isProviderDefault: false,
                    supportedReasoningEfforts: supportedEfforts,
                    defaultReasoningEffort: defaultEffort
                )
            )

            for effort in supportedEfforts {
                let compound = "\(rawID)-\(effort.rawValue)"
                let collidesWithBase = available.contains {
                    guard let otherID = ($0["modelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                    return otherID.caseInsensitiveCompare(compound) == .orderedSame
                }
                if collidesWithBase { continue }
                variants.append(
                    AgentModelOption(
                        rawValue: compound,
                        displayName: "\(displayName) \(effort.displayName)",
                        description: description,
                        isPlaceholderDefault: false,
                        isProviderDefault: false,
                        effortVariant: AgentModelEffortVariant(baseModelRaw: rawID, reasoningEffort: effort)
                    )
                )
            }
        }
        // currentModelId is provider authority: match it against advertised BASE options
        // only, never the client-synthesized variants appended below.
        let currentRaw: String? = if let current = (models["currentModelId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !current.isEmpty
        {
            options.first(where: { $0.rawValue.caseInsensitiveCompare(current) == .orderedSame })?.rawValue
        } else {
            nil
        }
        options.append(contentsOf: variants)
        guard !options.isEmpty else {
            return .malformed(reason: "Grok `models.availableModels` contains no usable models.")
        }
        // The session's ACTIVE effort comes from the session config's selected mode entry
        // (`_meta["x.ai/sessionConfig"].options`, category "mode") — never from a model's
        // advertised default, which would silently promote defaults to confirmed state.
        // Cardinality is fail-closed: exactly one mode entry may be selected (a malformed
        // selected entry still counts), its id must be present, and it must resolve to
        // exactly one effort through the CURRENT model's advertised id→value pairs (an id
        // colliding with another pair's value is ambiguous → unknown).
        let sessionConfig = (sessionResponse["_meta"] as? [String: Any])?["x.ai/sessionConfig"] as? [String: Any]
        let sessionOptions = sessionConfig?["options"] as? [[String: Any]] ?? []
        let selectedModeEntries = sessionOptions.filter {
            ($0["category"] as? String) == "mode" && ($0["selected"] as? Bool) == true
        }
        let currentEffortRaw: String? = {
            guard selectedModeEntries.count == 1,
                  let selectedID = (selectedModeEntries[0]["id"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
                  !selectedID.isEmpty,
                  let currentRaw,
                  let pairs = effortPairsByModelRaw[currentRaw]
            else { return nil }
            let matches = pairs.filter {
                $0.id.caseInsensitiveCompare(selectedID) == .orderedSame
                    || $0.effort.rawValue.caseInsensitiveCompare(selectedID) == .orderedSame
            }
            let distinctEfforts = Set(matches.map { $0.effort.rawValue.lowercased() })
            guard distinctEfforts.count == 1 else { return nil }
            return matches.first?.effort.rawValue
        }()

        return .valid(ACPDiscoveredSessionModels(
            options: options,
            currentModelRaw: currentRaw,
            currentEffortRaw: currentEffortRaw
        ))
    }

    func makeDirectModelSelectionRequest(
        sessionID: String,
        baseModelRaw: String,
        reasoningEffortRaw: String?
    ) -> ACPDirectModelSelectionRequest {
        // Verified against grok 1.0.4: session/set_model takes {sessionId, modelId} plus an
        // optional camelCase `_meta.reasoningEffort`, and responds with
        // {"_meta": {"model": {"Ok": "<modelId>"}}} — the Ok echoes the BASE model id only.
        var params: [String: Any] = ["sessionId": sessionID, "modelId": baseModelRaw]
        if let effort = CodexReasoningEffort.parse(reasoningEffortRaw) {
            params["_meta"] = ["reasoningEffort": effort.rawValue]
        }
        return ACPDirectModelSelectionRequest(
            method: "session/set_model",
            params: params,
            expectedConfirmationModelRaw: baseModelRaw
        )
    }
}
