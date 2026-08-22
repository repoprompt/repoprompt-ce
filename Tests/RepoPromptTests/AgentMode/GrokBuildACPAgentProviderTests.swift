import Foundation
@testable import RepoPromptApp
import XCTest

final class GrokBuildACPAgentProviderTests: XCTestCase {
    private func makeProvider(
        config: GrokBuildAgentConfig,
        resolver: GrokBuildACPLaunchResolver? = nil
    ) throws -> (GrokBuildACPAgentProvider, URL) {
        let directory = try makeTestDirectory(name: "GrokBuildACPAgentProviderTests")
        let executable = directory.appendingPathComponent("grok")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolvedConfig = GrokBuildAgentConfig(
            commandName: executable.path,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            modelString: config.modelString,
            includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
            alwaysApproveTools: config.alwaysApproveTools,
            apiKey: config.apiKey
        )
        let provider = GrokBuildACPAgentProvider(
            config: resolvedConfig,
            launchResolver: resolver ?? GrokBuildACPLaunchResolver()
        )
        return (provider, directory)
    }

    private func makeRequest(
        workspacePath: String,
        resumeSessionID: String? = nil,
        attachments: [AgentImageAttachment] = [],
        autoApprove: Bool = false
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: attachments,
            taskLabelKind: nil,
            autoApproveAllToolPermissions: autoApprove
        )
    }

    func testLaunchUsesGrokAgentStdio() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.arguments, ["agent", "--no-leader", "stdio"])
        XCTAssertNil(launch.cleanupArtifact)
    }

    func testManagedModeDoesNotAppendAlwaysApprove() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(alwaysApproveTools: false))
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertFalse(launch.arguments.contains("--always-approve"))
    }

    func testRequestFullAccessAppendsAlwaysApproveAfterAgent() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(alwaysApproveTools: false))
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, autoApprove: true)
        )
        XCTAssertEqual(launch.arguments, ["agent", "--always-approve", "--no-leader", "stdio"])
    }

    func testConfigFullAccessAppendsAlwaysApproveForHeadless() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(alwaysApproveTools: true))
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.arguments, ["agent", "--always-approve", "--no-leader", "stdio"])
    }

    func testAlwaysApproveIsNotDuplicatedWhenBothSourcesSet() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(alwaysApproveTools: true))
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path, autoApprove: true)
        )
        XCTAssertEqual(launch.arguments.count(where: { $0 == "--always-approve" }), 1)
    }

    func testStoredGrokAPIKeyIsInjectedAsXAIAPIKey() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(apiKey: "xai-test-key-123"))
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.environment["XAI_API_KEY"], "xai-test-key-123")
    }

    func testMissingStoredKeyOmitsXAIAPIKey() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(apiKey: nil))
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertNil(launch.environment["XAI_API_KEY"])
    }

    func testEmptyStoredKeyIsOmitted() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(apiKey: "   "))
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertNil(launch.environment["XAI_API_KEY"])
    }

    func testNewSessionInjectsRepoPromptMCP() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path),
            mcpServer: .repoPrompt
        )
        guard case .new = session.mode else {
            return XCTFail("expected new session, got \(session.mode)")
        }
        XCTAssertEqual(session.mcpServers.count, 1)
        XCTAssertEqual(session.mcpServers.first, .repoPrompt)
    }

    func testSessionConfigCanDisableMCPInjection() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig(includeRepoPromptMCPServer: false))
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path),
            mcpServer: .repoPrompt
        )
        XCTAssertTrue(session.mcpServers.isEmpty)
    }

    func testResumeUsesSessionLoad() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path, resumeSessionID: "  sess-123  "),
            mcpServer: .repoPrompt
        )
        guard case let .load(existingSessionID) = session.mode else {
            return XCTFail("expected load, got \(session.mode)")
        }
        XCTAssertEqual(existingSessionID, "sess-123")
    }

    func testFirstPromptCombinesSystemAndUserText() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let blocks = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "SYS", userMessage: "USER"),
            request: makeRequest(workspacePath: directory.path)
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?["text"] as? String, "SYS\n\nUSER")
    }

    func testFollowUpPromptOmitsSystemReplay() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let blocks = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "SYS", userMessage: "USER"),
            request: makeRequest(workspacePath: directory.path, resumeSessionID: "sess-1")
        )
        XCTAssertEqual(blocks.first?["text"] as? String, "USER")
    }

    func testUnsupportedAttachmentIsRejected() throws {
        let (provider, directory) = try makeProvider(config: GrokBuildAgentConfig())
        let attachment = AgentImageAttachment(source: .url("https://example.com/image.png"))
        XCTAssertThrowsError(
            try provider.buildPromptBlocks(
                for: AgentMessage(systemPrompt: "", userMessage: "hi"),
                request: makeRequest(workspacePath: directory.path, attachments: [attachment])
            )
        ) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(detail.contains("does not advertise image support"))
        }
    }

    func testPreferredAuthMethodIsNil() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let context = ACPAuthenticationContext(
            authMethodIDs: ["cached_token", "xai.api_key"],
            environment: ["XAI_API_KEY": "x"]
        )
        XCTAssertNil(provider.preferredAuthMethodID(context: context))
    }

    func testCommandNotFoundUsesGrokInstallGuidance() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let error = provider.normalizeError(CLIProcessRunnerError.commandNotFound("grok"))
        guard case let AIProviderError.invalidConfiguration(detail) = error else {
            return XCTFail("expected invalidConfiguration, got \(error)")
        }
        XCTAssertTrue(detail.contains("@xai-official/grok"))
    }

    func testAuthErrorUsesLoginOrEnvironmentGuidance() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let synthetic = NSError(domain: "GrokBuild", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Run `grok login` first, or set XAI_API_KEY."
        ])
        let error = provider.normalizeError(synthetic)
        guard case let AIProviderError.invalidConfiguration(detail) = error else {
            return XCTFail("expected invalidConfiguration, got \(error)")
        }
        XCTAssertTrue(detail.contains("grok login"))
        XCTAssertTrue(detail.contains("XAI_API_KEY"))
    }

    // MARK: - ACPDirectSessionModelProvider

    func testSessionModelStateParsesIntoDiscoveredModels() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let response: [String: Any] = [
            "sessionId": "s1",
            "models": [
                "currentModelId": "grok-4.6",
                "availableModels": [
                    ["modelId": "grok-4.6", "name": "Grok 4.6", "description": "Frontier"],
                    ["modelId": "grok-4.5", "name": "Grok 4.5"]
                ]
            ]
        ]
        guard case let .valid(models) = provider.parseDirectSessionModelSnapshot(from: response) else {
            return XCTFail("expected valid snapshot")
        }
        XCTAssertEqual(models.options.map(\.rawValue), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(models.options.first?.displayName, "Grok 4.6")
        XCTAssertEqual(models.currentModelRaw, "grok-4.6")
    }

    func testSessionModelStateMissingModelsIsAbsent() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        guard case .absent = provider.parseDirectSessionModelSnapshot(from: ["sessionId": "s1"]) else {
            return XCTFail("expected absent")
        }
    }

    func testSessionModelStateMalformedShapes() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        guard case .malformed = provider.parseDirectSessionModelSnapshot(from: ["models": "nope"]) else {
            return XCTFail("expected malformed for non-object models")
        }
        guard case .malformed = provider.parseDirectSessionModelSnapshot(from: ["models": ["availableModels": "nope"]]) else {
            return XCTFail("expected malformed for non-array availableModels")
        }
        guard case .malformed = provider.parseDirectSessionModelSnapshot(from: ["models": ["availableModels": []]]) else {
            return XCTFail("expected malformed for empty availableModels")
        }
    }

    func testSessionModelStateResolvesCurrentModelCaseInsensitively() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let response: [String: Any] = [
            "models": [
                "currentModelId": "GROK-4.5",
                "availableModels": [["modelId": "grok-4.5"]]
            ]
        ]
        guard case let .valid(models) = provider.parseDirectSessionModelSnapshot(from: response) else {
            return XCTFail("expected valid snapshot")
        }
        XCTAssertEqual(models.currentModelRaw, "grok-4.5")
        // name falls back to modelId
        XCTAssertEqual(models.options.first?.displayName, "grok-4.5")
    }

    func testDirectModelSelectionRequestShape() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let request = provider.makeDirectModelSelectionRequest(
            sessionID: "s1",
            baseModelRaw: "grok-4.5",
            reasoningEffortRaw: nil
        )
        XCTAssertEqual(request.method, "session/set_model")
        XCTAssertEqual(request.params["sessionId"] as? String, "s1")
        XCTAssertEqual(request.params["modelId"] as? String, "grok-4.5")
        XCTAssertNil(request.params["_meta"])
        XCTAssertEqual(request.expectedConfirmationModelRaw, "grok-4.5")
    }

    func testDirectModelSelectionRequestCarriesEffortMeta() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        let request = provider.makeDirectModelSelectionRequest(
            sessionID: "s1",
            baseModelRaw: "grok-4.5",
            reasoningEffortRaw: "low"
        )
        XCTAssertEqual(request.params["modelId"] as? String, "grok-4.5")
        XCTAssertEqual(
            (request.params["_meta"] as? [String: Any])?["reasoningEffort"] as? String,
            "low"
        )
        // The wire confirms the base model id, never the effort.
        XCTAssertEqual(request.expectedConfirmationModelRaw, "grok-4.5")
    }
}

extension GrokBuildACPAgentProviderTests {
    /// The interactive factory must not OR the global Full Access preference into the
    /// launch config: the per-run permission binding (which honors .mcpSafeDefaults and
    /// custom profiles) is authoritative. Regression coverage for the Safe Managed bypass.
    func testInteractiveFactoryLeavesAlwaysApproveToRunRequest() async throws {
        let provider = try await ACPAgentProviderFactory.makeProvider(
            for: .grokBuild,
            modelString: nil,
            grokAPIKeyProvider: { nil }
        )
        let grokProvider = try XCTUnwrap(provider as? GrokBuildACPAgentProvider)
        XCTAssertFalse(grokProvider.test_config.alwaysApproveTools)
    }
}

extension GrokBuildACPAgentProviderTests {
    func testBackgroundWorkerStderrNoiseIsSuppressed() throws {
        let (provider, _) = try makeProvider(config: GrokBuildAgentConfig())
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-08-14T13:48:59Z ERROR worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("ERROR something genuinely useful failed"))
        XCTAssertTrue(provider.shouldEmitStderrLine("warning: low disk space"))
    }
}
