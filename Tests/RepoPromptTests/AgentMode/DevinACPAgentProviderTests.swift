import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class DevinACPAgentProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        super.tearDown()
    }

    private func makeProvider(
        includeRepoPromptMCPServer: Bool = true
    ) throws -> (DevinACPAgentProvider, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevinACPAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: includeRepoPromptMCPServer
            ),
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: "/bin/echo",
                args: ["--backend", "app"]
            )
        )
        return (provider, directory)
    }

    private func makeRequest(
        workspacePath: String,
        resumeSessionID: String? = nil,
        attachments: [AgentImageAttachment] = []
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: AgentModel.defaultModel.rawValue,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: attachments,
            taskLabelKind: nil
        )
    }

    func testLaunchUsesInstalledDevinACPWithIsolatedRepoPromptMCPConfig() async throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.providerID, .devin)
        XCTAssertEqual(launch.arguments, ["acp"])
        let configRoot = try XCTUnwrap(launch.environment["XDG_CONFIG_HOME"])
        let configURL = URL(fileURLWithPath: configRoot)
            .appendingPathComponent("devin/mcp_config.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers[RepoPromptMCPServerConfiguration.defaultServerName])
        XCTAssertNotNil(launch.cleanupArtifact)
        XCTAssertNotNil(launch.expectedExecutableIdentity)
        await provider.cleanupLaunchArtifacts(for: launch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot))
    }

    func testSessionConfigurationUsesIsolatedMCPConfigAndLoadsTrimmedResumeID() throws {
        let (provider, directory) = try makeProvider()
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path, resumeSessionID: "  devin-session  "),
            mcpServer: .repoPrompt
        )
        guard case let .load(existingSessionID) = session.mode else {
            return XCTFail("expected session/load")
        }
        XCTAssertEqual(existingSessionID, "devin-session")
        XCTAssertTrue(session.mcpServers.isEmpty)
    }

    func testModelDiscoveryLaunchDoesNotInjectRepoPromptMCP() throws {
        let (provider, directory) = try makeProvider(includeRepoPromptMCPServer: false)
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))

        XCTAssertTrue(launch.environment.isEmpty)
        XCTAssertNil(launch.cleanupArtifact)
    }

    func testIsolatedMCPConfigPreservesExistingDevinConfigAndMergesServers() throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevinSourceConfig-\(UUID().uuidString)", isDirectory: true)
        let sourceDevin = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let settingsURL = sourceDevin.appendingPathComponent("config.json")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: settingsURL)
        let existingMCPURL = sourceDevin.appendingPathComponent("mcp_config.json")
        try Data("""
        {"mcpServers":{"Existing":{"transport":"stdio","command":"/bin/echo","args":["existing"]}}}
        """.utf8).write(to: existingMCPURL)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: "/bin/echo",
                args: ["repo-prompt"]
            ),
            sourceConfigurationRoot: sourceRoot
        )
        defer { DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact) }

        let isolatedRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"])
        let isolatedDevin = URL(fileURLWithPath: isolatedRoot).appendingPathComponent("devin")
        let linkedSettings = isolatedDevin.appendingPathComponent("config.json")
        let values = try linkedSettings.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: linkedSettings), try Data(contentsOf: settingsURL))

        let isolatedMCP = isolatedDevin.appendingPathComponent("mcp_config.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: isolatedMCP)) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["Existing"])
        XCTAssertNotNil(servers[RepoPromptMCPServerConfiguration.defaultServerName])
        let attributes = try FileManager.default.attributesOfItem(atPath: isolatedMCP.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testPromptUsesStandardACPTextAndImageBlocks() throws {
        let (provider, directory) = try makeProvider()
        let first = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "SYS", userMessage: "USER"),
            request: makeRequest(workspacePath: directory.path)
        )
        XCTAssertEqual(first.first?["text"] as? String, "SYS\n\nUSER")

        let followUp = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "SYS", userMessage: "NEXT"),
            request: makeRequest(workspacePath: directory.path, resumeSessionID: "session")
        )
        XCTAssertEqual(followUp.first?["text"] as? String, "NEXT")
    }

    func testStandardAgentMessageUpdateUsesDefaultNormalizer() throws {
        let (provider, _) = try makeProvider()
        let events = provider.normalizeSessionUpdate(
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hello"]],
            sessionID: "session"
        )
        guard case let .stream(result) = events.first else {
            return XCTFail("expected stream event")
        }
        XCTAssertEqual(result.text, "hello")
    }

    func testAuthenticationRemainsDevinManaged() throws {
        let (provider, _) = try makeProvider()
        XCTAssertNil(provider.preferredAuthMethodID(context: ACPAuthenticationContext(
            authMethodIDs: ["agent"],
            environment: [:]
        )))
    }

    func testInteractiveFactoryReturnsDevinProviderWithoutModelConfiguration() async throws {
        let provider = try await ACPAgentProviderFactory.makeProvider(for: .devin, modelString: "ignored-model")
        XCTAssertNotNil(provider as? DevinACPAgentProvider)
    }

    func testHeadlessFactoryFailsClosed() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .devin,
            modelString: "ignored-model"
        )
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
    }

    func testCatalogUsesModelsAdvertisedByDevinACP() {
        let availability = AgentModelCatalog.AvailabilityContext(devinAvailable: true)
        XCTAssertEqual(
            AgentModelCatalog.options(for: .devin, availability: availability).map(\.rawValue),
            [AgentModel.defaultModel.rawValue]
        )

        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "gpt-5.6",
                        displayName: "GPT-5.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    ),
                    AgentModelOption(
                        rawValue: "claude-opus-4.6",
                        displayName: "Claude Opus 4.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: "gpt-5.6"
            ),
            for: .devin
        )

        let options = AgentModelCatalog.options(for: .devin, availability: availability)
        XCTAssertEqual(Set(options.map(\.rawValue)), ["gpt-5.6", "claude-opus-4.6"])
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .devin, availability: availability), "gpt-5.6")
        XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4.6", for: .devin, availability: availability))
        XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.devin, availability: availability))
    }

    func testTaskLabelsDoNotSelectProviderManagedDevinImplicitly() {
        let onlyDevin = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.devin)
        for label in AgentModelCatalog.taskLabels {
            XCTAssertNil(AgentModelCatalog.resolveTaskLabelKind(label.kind, availability: onlyDevin))
        }
    }

    @MainActor
    func testContextBuilderFallbackDoesNotSelectDevinImplicitly() {
        let onlyDevin = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.devin)
        XCTAssertNil(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: onlyDevin
        ))
    }

    func testPermissionBindingIsInformationalAndProviderManaged() {
        XCTAssertEqual(AgentProviderPermissionLevelID.options(for: .devin), [.devin])
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .devin), .devin)
        XCTAssertEqual(AgentProviderPermissionLevelID.devin.subagentRawValue, "providerManaged")
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-once", for: .devin))
    }

    func testObservedDevinMCPClientIdentityMatchesRoutingHint() {
        XCTAssertEqual(AgentProviderKind.devin.mcpClientNameHint, "rmcp")
        XCTAssertTrue(MCPClientIdentity.matches("rmcp", AgentProviderKind.devin.mcpClientNameHint))
        XCTAssertTrue(AgentProviderKind.devin.requiresPrePromptAgentModeMCPRouting)
    }
}
