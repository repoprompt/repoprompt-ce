import Foundation
@testable import RepoPromptApp
import XCTest

final class OMPACPAgentProviderTests: XCTestCase {
    private func makeProvider(
        includeRepoPromptMCPServer: Bool = true
    ) throws -> (OMPACPAgentProvider, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMPACPAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("omp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = OMPACPAgentProvider(
            config: OMPAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: includeRepoPromptMCPServer
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

    func testConnectionProbeConfigurationCanDisableMCPInjection() throws {
        let (provider, directory) = try makeProvider(includeRepoPromptMCPServer: false)
        let session = try provider.makeSessionConfiguration(
            for: makeRequest(workspacePath: directory.path),
            mcpServer: .repoPrompt
        )
        XCTAssertTrue(session.mcpServers.isEmpty)
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
        let ompProvider = provider as? OMPACPHeadlessAgentProvider
        XCTAssertNotNil(ompProvider)
        XCTAssertEqual(ompProvider?.test_config.commandName, "omp")
    }

    func testCatalogExposesOnlyProviderManagedDefaultModel() {
        let availability = AgentModelCatalog.AvailabilityContext(ompAvailable: true)
        let options = AgentModelCatalog.options(for: .omp, availability: availability)
        XCTAssertEqual(options.map(\.rawValue), [AgentModel.defaultModel.rawValue])
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

    func testObservedOMPMCPClientIdentityMatchesRoutingHint() {
        XCTAssertEqual(AgentProviderKind.omp.mcpClientNameHint, "omp-coding-agent")
        XCTAssertTrue(MCPClientIdentity.matches("omp-coding-agent", AgentProviderKind.omp.mcpClientNameHint))
        XCTAssertTrue(AgentProviderKind.omp.requiresPrePromptAgentModeMCPRouting)
    }
}
