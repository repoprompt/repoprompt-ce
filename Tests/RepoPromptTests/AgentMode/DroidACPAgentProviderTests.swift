import Foundation
@testable import RepoPrompt
import XCTest

final class DroidACPAgentProviderTests: XCTestCase {
    // MARK: - Launch Configuration

    func testLaunchConfigurationSetsProviderIDAndDroidArguments() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertEqual(launch.providerID, .droid)
        XCTAssertEqual(launch.arguments, ["exec", "--output-format", "acp"])
        XCTAssertEqual(launch.command, try canonicalExecutablePath(executable))
    }

    func testLaunchConfigurationPassesEmptyEnvironment() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: directory.path))

        XCTAssertTrue(launch.environment.isEmpty)
    }

    func testLaunchConfigurationUsesStandardizedWorkingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let launch = try provider.makeLaunchConfiguration(
            for: makeRunRequest(workspacePath: directory.path + "/./subdir/..")
        )

        XCTAssertEqual(launch.workingDirectory, directory.standardizedFileURL.path)
    }

    func testLaunchConfigurationFallsBackToTmpWhenWorkspacePathIsNil() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let launch = try provider.makeLaunchConfiguration(for: makeRunRequest(workspacePath: nil))

        XCTAssertFalse(launch.workingDirectory.isEmpty)
    }

    // MARK: - Session Configuration

    func testSessionConfigurationIncludesMCPServerWhenEnabled() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let mcpConfig = RepoPromptMCPServerConfiguration(
            command: "/tmp/repoprompt-mcp-fixture",
            args: ["--fixture"],
            env: [.init(name: "RP_FIXTURE", value: "1")]
        )
        let provider = DroidACPAgentProvider(
            config: DroidAgentConfig(
                commandName: executable.path,
                additionalPathHints: [],
                includeRepoPromptMCPServer: true
            ),
            repoPromptMCPConfiguration: mcpConfig,
            launchResolver: DroidACPLaunchResolver()
        )

        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: directory.path),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(session.mcpServers, [mcpConfig])
    }

    func testSessionConfigurationExcludesMCPServerWhenDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: directory.path),
            mcpServer: .repoPrompt
        )

        XCTAssertTrue(session.mcpServers.isEmpty)
    }

    func testSessionConfigurationUsesNewModeForFreshRun() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: directory.path, resumeSessionID: nil),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(session.mode, .new)
    }

    func testSessionConfigurationUsesLoadModeForResumedSession() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)
        let sessionID = "test-session-\(UUID().uuidString)"

        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: directory.path, resumeSessionID: sessionID),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(session.mode, .load(existingSessionID: sessionID))
    }

    func testSessionConfigurationTreatsEmptyResumeIDAsNew() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)

        let session = try provider.makeSessionConfiguration(
            for: makeRunRequest(workspacePath: directory.path, resumeSessionID: "  "),
            mcpServer: .repoPrompt
        )

        XCTAssertEqual(session.mode, .new)
    }

    // MARK: - Prompt Block Building

    func testBuildPromptBlocksCombinesSystemAndUserForFreshRun() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)
        let message = AgentMessage(systemPrompt: "System instructions", userMessage: "User task")

        let blocks = try provider.buildPromptBlocks(
            for: message,
            request: makeRunRequest(workspacePath: directory.path)
        )

        let text = blocks.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("System instructions"))
        XCTAssertTrue(text.contains("User task"))
    }

    func testBuildPromptBlocksOmitsSystemForFollowUp() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)
        let message = AgentMessage(systemPrompt: "System instructions", userMessage: "Follow-up question")

        let blocks = try provider.buildPromptBlocks(
            for: message,
            request: makeRunRequest(workspacePath: directory.path, resumeSessionID: "existing-session")
        )

        let text = blocks.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(text.contains("System instructions"))
        XCTAssertTrue(text.contains("Follow-up question"))
    }

    func testBuildPromptBlocksHandlesEmptySystemPrompt() throws {
        let directory = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: directory)
        let provider = makeProvider(commandName: executable.path, includeRepoPromptMCPServer: false)
        let message = AgentMessage(systemPrompt: "", userMessage: "User task only")

        let blocks = try provider.buildPromptBlocks(
            for: message,
            request: makeRunRequest(workspacePath: directory.path)
        )

        let text = blocks.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(text.contains("User task only"))
    }

    // MARK: - Error Normalization

    func testNormalizeErrorWrapsCommandNotFoundAsInvalidConfiguration() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let rawError = CLIProcessRunnerError.commandNotFound("droid")

        let normalized = provider.normalizeError(rawError)

        guard case let AIProviderError.invalidConfiguration(detail) = normalized else {
            return XCTFail("Expected invalidConfiguration, got: \(normalized)")
        }
        XCTAssertTrue(detail.contains("Droid CLI not found"))
    }

    func testNormalizeErrorWrapsLaunchResolutionAsInvalidConfiguration() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let rawError = DroidACPLaunchResolutionError.exactPathNotFound("droid")

        let normalized = provider.normalizeError(rawError)

        guard case AIProviderError.invalidConfiguration = normalized else {
            return XCTFail("Expected invalidConfiguration, got: \(normalized)")
        }
    }

    func testNormalizeErrorPreservesExistingAIProviderError() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let originalError = AIProviderError.invalidConfiguration(detail: "Already classified")

        let normalized = provider.normalizeError(originalError)

        guard case let AIProviderError.invalidConfiguration(detail) = normalized else {
            return XCTFail("Expected invalidConfiguration, got: \(normalized)")
        }
        XCTAssertEqual(detail, "Already classified")
    }

    func testNormalizeErrorWrapsUnclassifiedErrorAsAPIError() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let rawError = NSError(
            domain: "DroidACP.Test",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "unclassified detail"]
        )

        let normalized = provider.normalizeError(rawError)

        guard case let AIProviderError.apiError(source) = normalized else {
            return XCTFail("Expected apiError, got: \(normalized)")
        }
        let sourceError = source as NSError?
        XCTAssertEqual(sourceError?.domain, rawError.domain)
        XCTAssertEqual(sourceError?.code, rawError.code)
    }

    // MARK: - Auth Method

    func testPreferredAuthMethodSelectsFactoryAPIKey() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let context = ACPAuthenticationContext(
            authMethodIDs: ["oauth", "factory_api_key", "browser"],
            environment: [:]
        )

        let preferred = provider.preferredAuthMethodID(context: context)

        XCTAssertEqual(preferred, "factory_api_key")
    }

    func testPreferredAuthMethodReturnsNilWhenEnvironmentTokenPresent() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        let context = ACPAuthenticationContext(
            authMethodIDs: ["factory_api_key"],
            environment: ["FACTORY_API_KEY": "sk-test-key"]
        )

        let preferred = provider.preferredAuthMethodID(context: context)

        XCTAssertNil(preferred)
    }

    // MARK: - Provider ID

    func testProviderIDIsDroid() {
        let provider = makeProvider(commandName: "droid", includeRepoPromptMCPServer: false)
        XCTAssertEqual(provider.providerID, .droid)
    }

    // MARK: - Helpers

    private func makeProvider(commandName: String, includeRepoPromptMCPServer: Bool) -> DroidACPAgentProvider {
        DroidACPAgentProvider(
            config: DroidAgentConfig(
                commandName: commandName,
                additionalPathHints: [],
                includeRepoPromptMCPServer: includeRepoPromptMCPServer
            ),
            launchResolver: DroidACPLaunchResolver()
        )
    }

    private func makeRunRequest(
        workspacePath: String?,
        resumeSessionID: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .droid,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func canonicalExecutablePath(_ url: URL) throws -> String {
        try XCTUnwrap(FileSystemService.realpathString(url.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidACPAgentProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func makeExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("droid")
        let lines = [
            "#!/bin/sh",
            "printf '%s\\n' 'Droid ACP support'",
            "exit 0"
        ]
        try lines.joined(separator: "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}
