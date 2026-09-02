import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class OMPACPAgentProviderTests: XCTestCase {
    private func makeProvider() throws -> (OMPACPAgentProvider, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPACPAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("omp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = OMPACPAgentProvider(
            config: OMPAgentConfig(
                commandName: executable.path,
                additionalPathHints: []
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
            agentKind: .omp,
            modelString: AgentModel.defaultModel.rawValue,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: attachments,
            taskLabelKind: nil
        )
    }

    func testLaunchUsesInstalledOMPACPWithoutRepoPromptOwnedOverrides() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(for: makeRequest(workspacePath: directory.path))
        XCTAssertEqual(launch.providerID, .omp)
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertTrue(launch.environment.isEmpty)
        XCTAssertNil(launch.cleanupArtifact)
        XCTAssertNotNil(launch.expectedExecutableIdentity)
    }

    func testSessionConfigurationInjectsRepoPromptMCPAndLoadsTrimmedResumeID() throws {
        let (provider, directory) = try makeProvider()
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path, resumeSessionID: "  omp-session  "),
            mcpServer: .repoPrompt
        )
        guard case let .load(existingSessionID) = session.mode else {
            return XCTFail("expected session/load")
        }
        XCTAssertEqual(existingSessionID, "omp-session")
        XCTAssertEqual(session.mcpServers, [.repoPrompt])
    }

    func testPromptUsesStandardACPTextAndImageBlocks() throws {
        let (provider, directory) = try makeProvider()
        let imageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let imageURL = directory.appendingPathComponent("pixel.png")
        try imageData.write(to: imageURL)
        let first = try provider.buildPromptBlocks(
            for: AgentMessage(systemPrompt: "SYS", userMessage: "USER"),
            request: makeRequest(
                workspacePath: directory.path,
                attachments: [AgentImageAttachment(source: .localFile(path: imageURL.path), title: "pixel.png")]
            )
        )
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]["type"] as? String, "text")
        XCTAssertEqual(first[0]["text"] as? String, "SYS\n\nUSER")
        XCTAssertEqual(first[1]["type"] as? String, "image")
        XCTAssertEqual(first[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(first[1]["data"] as? String, imageData.base64EncodedString())
        XCTAssertEqual(first[1]["uri"] as? String, imageURL.absoluteString)

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

    func testAuthenticationRemainsOMPManaged() throws {
        let (provider, _) = try makeProvider()
        XCTAssertNil(provider.preferredAuthMethodID(context: ACPAuthenticationContext(
            authMethodIDs: ["agent"],
            environment: [:]
        )))
    }

    func testInteractiveFactoryReturnsOMPProviderWithoutModelConfiguration() async throws {
        let provider = try await ACPAgentProviderFactory.makeProvider(for: .omp, modelString: "ignored-model")
        XCTAssertNotNil(provider as? OMPACPAgentProvider)
    }

    func testHeadlessFactoryReturnsOMPProviderWithoutModelConfiguration() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .omp,
            modelString: "ignored-model"
        )
        XCTAssertNotNil(provider as? OMPACPHeadlessAgentProvider)
    }

    func testCatalogExposesOnlyProviderManagedDefaultModel() {
        AgentACPModelRegistry.shared.test_reset(providerID: .omp)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .omp) }

        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "discovered-omp-model",
                        displayName: "Discovered OMP Model",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "discovered-omp-model"
            ),
            for: .omp
        ))
        let availability = AgentModelCatalog.AvailabilityContext(ompAvailable: true)
        let options = AgentModelCatalog.options(for: .omp, availability: availability)

        XCTAssertEqual(options.map(\.rawValue), [AgentModel.defaultModel.rawValue])
        XCTAssertEqual(
            AgentModelCatalog.defaultModelRaw(for: .omp, availability: availability),
            AgentModel.defaultModel.rawValue
        )
        XCTAssertFalse(
            AgentModelCatalog.isValid(
                rawModel: "discovered-omp-model",
                for: .omp,
                availability: availability
            )
        )
        XCTAssertTrue(
            AgentModelCatalog.isValid(
                rawModel: AgentModel.defaultModel.rawValue,
                for: .omp,
                availability: availability
            )
        )
        XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.omp, availability: availability))
    }

    func testTaskLabelsDoNotSelectProviderManagedOMPImplicitly() {
        let onlyOMP = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.omp)
        for label in AgentModelCatalog.taskLabels {
            XCTAssertNil(AgentModelCatalog.resolveTaskLabelKind(label.kind, availability: onlyOMP))
        }
    }

    func testPermissionBindingIsInformationalAndProviderManaged() {
        XCTAssertEqual(AgentProviderPermissionLevelID.options(for: .omp), [.omp])
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .omp), .omp)
        XCTAssertEqual(AgentProviderPermissionLevelID.omp.subagentRawValue, "providerManaged")
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-once", for: .omp))
    }

    @MainActor
    func testMCPSafeDefaultsLeaveOMPRuntimePermissionsProviderManaged() {
        let runtimePermission = AgentProviderPreferenceSnapshotStore()
            .runtimePermission(for: .omp, profile: .mcpSafeDefaults)

        XCTAssertEqual(runtimePermission, AgentProviderRuntimePermissionBinding())
    }

    func testObservedOMPMCPClientIdentityMatchesRoutingHint() {
        XCTAssertEqual(AgentProviderKind.omp.mcpClientNameHint, "omp-coding-agent")
        XCTAssertTrue(MCPClientIdentity.matches("omp-coding-agent", AgentProviderKind.omp.mcpClientNameHint))
        XCTAssertTrue(AgentProviderKind.omp.requiresPrePromptAgentModeMCPRouting)
    }
}
