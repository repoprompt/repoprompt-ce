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
        let directory = try makeTestDirectory(name: "DevinACPAgentProviderTests")
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("devin")
        try "#!/bin/sh\ncase \"$*\" in *--help*) echo 'Run as an ACP server over stdio';; *) printf '%s' \"$HOME\";; esac\n"
            .write(to: executable, atomically: true, encoding: .utf8)
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
            ),
            launchResolver: DevinACPLaunchResolver(environmentProvider: { _ in
                ["PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": directory.path, "HOME": directory.path]
            })
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

    func testFixtureLaunchUsesResolvedDevinACPWithIsolatedRepoPromptMCPConfig() async throws {
        let (provider, directory) = try makeProvider()
        let sourceDevin = directory.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"Fixture":{"transport":"stdio","command":"/bin/echo","args":["fixture"]}}}"#.utf8)
            .write(to: sourceDevin.appendingPathComponent("mcp_config.json"))
        let request = makeRequest(workspacePath: directory.path)
        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)
        addTeardownBlock { await provider.cleanupLaunchArtifacts(for: launch) }
        XCTAssertEqual(launch.providerID, .devin)
        XCTAssertEqual(launch.arguments, ["acp"])
        let configRoot = try XCTUnwrap(launch.environment["XDG_CONFIG_HOME"])
        let configURL = URL(fileURLWithPath: configRoot)
            .appendingPathComponent("devin/mcp_config.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["Fixture", RepoPromptMCPServerConfiguration.defaultServerName])
        XCTAssertEqual(launch.environment["HOME"], directory.path)
        let fixture = try XCTUnwrap(servers["Fixture"] as? [String: Any])
        XCTAssertEqual((fixture["env"] as? [String: String])?["XDG_CONFIG_HOME"], directory.path)
        XCTAssertNotNil(launch.cleanupArtifact)
        XCTAssertNotNil(launch.expectedExecutableIdentity)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: launch.command)
        child.arguments = launch.arguments
        child.environment = launch.environment
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let childData = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(String(decoding: childData, as: UTF8.self), directory.path)
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

    func testModelDiscoveryLaunchDoesNotInjectRepoPromptMCP() async throws {
        let (provider, directory) = try makeProvider(includeRepoPromptMCPServer: false)
        let request = makeRequest(workspacePath: directory.path)
        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)

        XCTAssertEqual(launch.environment["XDG_CONFIG_HOME"], directory.path)
        XCTAssertNil(launch.cleanupArtifact)
    }

    func testIsolatedMCPConfigPreservesExistingDevinConfigAndMergesServers() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinSourceConfig")
        let sourceDevin = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDevin, withIntermediateDirectories: true)

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
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
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

    func testPromptPrependsSystemTextOnlyOnInitialTurn() throws {
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

    func testDiscoveryIncludesDevinCurrentModelAndAdvertisedAlternatives() throws {
        let availability = AgentModelCatalog.AvailabilityContext(devinAvailable: true)
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "gpt-5-6-sol-medium",
                        displayName: "GPT-5.6 Sol Medium Thinking",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    ),
                    AgentModelOption(
                        rawValue: "claude-opus-5-medium",
                        displayName: "Claude Opus 5 Medium",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: "gpt-5-6-sol-medium"
            ),
            for: .devin
        )

        let devin = try XCTUnwrap(
            AgentModelCatalog.discoveryAgents(availability: availability)
                .first(where: { $0.agent == .devin })
        )
        XCTAssertTrue(devin.available)
        XCTAssertEqual(devin.defaults.modelRaw, "gpt-5-6-sol-medium")
        XCTAssertEqual(
            devin.models.map(\.name),
            ["Claude Opus 5 Medium", "GPT-5.6 Sol Medium Thinking"]
        )
    }

    @MainActor
    func testNativeFamilyMetadataAnnotatesOnlyACPModelsAndSurvivesStorage() async throws {
        let directory = try makeTestDirectory(name: "DevinModelFamilies")
        _ = try ACPModelSelectionFixtureProvider(directory: directory, providerID: .devin)
        let catalog = #"{"families":[{"family_uid":"fixture","family_label":"Fixture Family","variants":[{"model_uid":"model-a"},{"model_uid":"model-b"},{"model_uid":"not-advertised-by-acp"}]}]}"#
        try catalog.write(to: directory.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("devin")
        let script = """
        #!/bin/sh
        if [ "$1" = "models" ]; then cat '\(directory.path)/catalog.json'; exit 0; fi
        if [ "$2" = "--help" ]; then echo 'Run as an ACP server over stdio'; exit 0; fi
        exec '\(directory.path)/acp-fixture'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = DevinACPAgentProvider(config: DevinAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false))
        let request = makeRequest(workspacePath: directory.path)
        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = try XCTUnwrap(AgentACPModelRegistry.shared.currentSnapshot(for: .devin))
            XCTAssertFalse(snapshot.options.contains { $0.rawValue == "not-advertised-by-acp" })
            let family = try XCTUnwrap(snapshot.options.first { $0.rawValue == "model-a" }?.modelFamily)
            XCTAssertEqual(family.displayName, "Fixture Family")
            let groups = AgentModelCatalog.devinModelGroups(for: snapshot.options)
            XCTAssertEqual(groups.map(\.id), ["", "fixture"])
            XCTAssertEqual(Set(groups[1].options.map(\.rawValue)), ["model-a", "model-b"])
            let items = AgentModelStableMenuItems.modelItems(
                agentKind: .devin,
                options: snapshot.options,
                selectedAgent: .devin,
                selectedModelRaw: "model-a"
            ) { _, _ in }
            XCTAssertEqual(items.last?.title, "Fixture Family")
            let record = try XCTUnwrap(ACPDynamicModelStore.canonicalProviderRecord(from: snapshot, providerID: .devin))
            let decoded = try JSONDecoder().decode(ACPDynamicProviderRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(ACPDynamicModelStore.snapshot(from: decoded)?.options.first { $0.rawValue == "model-a" }?.modelFamily, family)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    func testFamilyCatalogRejectsConflictingModelAssignments() throws {
        let invalid = #"{"families":[{"family_uid":"one","family_label":"One","variants":[{"model_uid":"same"}]},{"family_uid":"two","family_label":"Two","variants":[{"model_uid":"same"}]}]}"#
        XCTAssertThrowsError(try DevinModelFamilyCatalog.parse(Data(invalid.utf8)))
        XCTAssertThrowsError(try DevinModelFamilyCatalog.parse(Data(#"{"families":[{"family_uid":"","family_label":"Missing ID","variants":[]}]}"#.utf8)))
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

    func testDevinMCPClientRoutingPolicyPinsRmcpHint() {
        XCTAssertEqual(AgentProviderKind.devin.mcpClientNameHint, "rmcp")
        XCTAssertTrue(MCPClientIdentity.matches("rmcp", AgentProviderKind.devin.mcpClientNameHint))
        XCTAssertTrue(AgentProviderKind.devin.requiresPrePromptAgentModeMCPRouting)
    }
}
