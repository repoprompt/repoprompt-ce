import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class DevinACPAgentProviderOwnerTests: XCTestCase {
    func testDevinClassifiesOnlyThoughtLevel() throws {
        let (provider, _) = try makeProvider()
        XCTAssertTrue(provider.supportsParameterizedModelPicker)
        let cases: [(configID: String, category: String?, kind: ACPModelParameterKind?)] = [
            ("arbitrary_effort_id", " ThOuGhT_LeVeL ", .thinking),
            ("thought_level", "model_config", nil),
            ("speed", "model_config", nil),
            ("speed", "speed", nil)
        ]
        for (configID, category, expectedKind) in cases {
            XCTAssertEqual(provider.modelParameterKind(for: .init(
                configID: configID, category: category, displayName: configID, choices: []
            )), expectedKind)
        }
    }

    func testRoutineInfoStderrIsHiddenWhileActionableOutputRemainsVisible() throws {
        let (provider, _) = try makeProvider()

        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20.134260Z  INFO chisel: elapsed_since_main_ms=4 logging initialized"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20Z INFO chisel: logging initialized"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z ERROR chisel: startup failed"))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-15T11:10:05.047288Z  WARN message_forest: MessageChain tree duplication: system prefix changed"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:10:27.520189Z  WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error sending request for url (https://unleash.codeium.com/api/client/features): operation timed out"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:11:36Z WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error decoding response body"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z  WARN chisel: retrying"))
        XCTAssertTrue(provider.shouldEmitStderrLine("permission denied while reading config"))
    }

    func testInjectedLaunchPoliciesPreserveOrderingProjectionAndCleanupArtifact() async throws {
        for includeMCP in [true, false] {
            let events = Events()
            let artifact = ACPLaunchCleanupArtifact(providerID: .devin, id: UUID(), kind: "fixture-overlay")
            let overlay = ["COLLISION": "overlay", "XDG_CONFIG_HOME": "/fixture-projection", "ONLY_OVERLAY": "yes"]
            let (provider, directory) = try makeProvider(
                includeMCP: includeMCP,
                isolateForeignMCPImports: true,
                environment: ["COLLISION": "source", "UNCHANGED": "source"],
                permissionArguments: { mode in
                    XCTAssertEqual(mode, "fixture-carrier")
                    events.add("permission")
                    return ["--permission-mode", "fixture-mode"]
                },
                prepareIntegration: { cwd, policy, source, isolate in
                    XCTAssertEqual(events.snapshot(), ["permission"])
                    events.add("prepare:\(cwd)")
                    switch policy {
                    case let .mergeRepoPrompt(configuration):
                        XCTAssertTrue(includeMCP)
                        XCTAssertEqual(configuration.name, "owner-fixture")
                        XCTAssertEqual(configuration.command, "/usr/bin/true")
                    case .disableAll:
                        XCTAssertFalse(includeMCP)
                    }
                    XCTAssertTrue(isolate)
                    XCTAssertEqual(source["COLLISION"], "source")
                    XCTAssertEqual(source["UNCHANGED"], "source")
                    return .init(environment: overlay, cleanupArtifact: artifact)
                },
                cleanupIntegration: { received in
                    XCTAssertEqual(received, artifact)
                    events.add("cleanup")
                }
            )
            let request = makeRequest(path: directory.path + "/child/..", permissionMode: "fixture-carrier")
            let support = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) { try await provider.support(for: request) }
            XCTAssertEqual(support, .supported)
            XCTAssertEqual(events.snapshot(), [])
            let launch = try provider.makeLaunchConfiguration(for: request)
            XCTAssertEqual(events.snapshot(), ["permission", "prepare:\(directory.standardizedFileURL.path)"])
            XCTAssertEqual(launch.arguments, ["--permission-mode", "fixture-mode", "acp"])
            XCTAssertEqual(launch.environment["COLLISION"], "overlay")
            XCTAssertEqual(launch.environment["UNCHANGED"], "source")
            XCTAssertEqual(launch.environment["XDG_CONFIG_HOME"], "/fixture-projection")
            XCTAssertEqual(launch.explicitEnvironmentKeys, Set(overlay.keys))
            XCTAssertEqual(launch.cleanupArtifact, artifact)
            XCTAssertEqual(launch.expectedExecutableIdentity?.canonicalPath, launch.command)
            XCTAssertEqual(launch.workingDirectory, directory.standardizedFileURL.path)
            XCTAssertTrue(launch.enableDebugLogging)
            let noArtifact = ACPLaunchConfiguration(providerID: .devin, command: launch.command, arguments: [], environment: [:], workingDirectory: directory.path, additionalPathHints: [], enableDebugLogging: false)
            await provider.cleanupLaunchArtifacts(for: noArtifact)
            XCTAssertEqual(events.snapshot().count, 2)
            await provider.cleanupLaunchArtifacts(for: launch)
            XCTAssertEqual(events.snapshot(), ["permission", "prepare:\(directory.standardizedFileURL.path)", "cleanup"])
        }
    }

    func testResolverFailurePrecedesPermissionAndPermissionFailurePrecedesOverlay() throws {
        let events = Events()
        let directory = try makeDirectory()
        let missing = directory.appendingPathComponent("missing/devin").path
        let (unresolved, _) = try makeProvider(commandName: missing, permissionArguments: { _ in
            events.add("permission")
            throw FixtureError.rejected
        })
        XCTAssertThrowsError(try unresolved.makeLaunchConfiguration(for: makeRequest(path: directory.path))) { error in
            XCTAssertEqual(error as? DevinACPLaunchResolutionError, .exactPathNotFound(missing))
        }
        XCTAssertEqual(events.snapshot(), [])
        let (rejected, _) = try makeProvider(permissionArguments: { _ in
            events.add("permission")
            throw FixtureError.rejected
        }, prepareIntegration: { _, _, _, _ in
            events.add("prepare")
            throw FixtureError.unexpected
        })
        XCTAssertThrowsError(try rejected.makeLaunchConfiguration(for: makeRequest(path: directory.path))) { error in
            XCTAssertEqual(error as? FixtureError, .rejected)
        }
        XCTAssertEqual(events.snapshot(), ["permission"])
    }

    func testMetadataPrecedenceAndInjectedToolNameResolutionKeepGenericDispatcherUnresolved() throws {
        let names = ACPToolNameResolution(
            isRepoPromptServerIdentifier: { _ in false },
            canonicalRepoPromptToolName: { $0 == "mcp__trusted__alias" ? "read_file" : nil },
            isRepoPromptToolNameWithServerPrefix: { $0 == "mcp__trusted__alias" }
        )
        let (provider, _) = try makeProvider(toolNames: names)
        let cases: [([String: String], String)] = [
            (["cognition.ai/toolName": "preferred", "cognition.ai/inferenceToolName": "mcp_call_tool"], "preferred"),
            (["cognition.ai/inferenceToolName": "fallback"], "fallback"),
            (["cognition.ai/toolName": "mcp_call_tool", "cognition.ai/inferenceToolName": "fallback"], "tool"),
            (["cognition.ai/inferenceToolName": "mcp_call_tool"], "tool"),
            (["cognition.ai/toolName": "mcp__trusted__alias"], "mcp__\(RepoPromptMCPServerConfiguration.defaultServerName)__read_file")
        ]
        for (metadata, expected) in cases {
            let result = provider.normalizeSessionUpdate(["sessionUpdate": "tool_call", "toolCallId": "fixture-call", "_meta": metadata], sessionID: "fixture-session")
            guard case let .stream(event) = result.first else { return XCTFail("Missing tool event") }
            XCTAssertEqual(event.toolName, expected)
        }
    }

    func testNewAndLoadedSessionsKeepNativeMCPInjectionDisabled() throws {
        let (provider, directory) = try makeProvider()
        let cases: [(String?, ACPSessionConfiguration.Mode)] = [(nil, .new), ("  ", .new), (" session-id ", .load(existingSessionID: "session-id"))]
        for (resumeID, expectedMode) in cases {
            let request = makeRequest(path: directory.path, resumeID: resumeID)
            let session = try provider.makeSessionConfiguration(for: request, mcpServer: RepoPromptMCPServerConfiguration(command: "/usr/bin/true"))
            XCTAssertEqual(session.mode, expectedMode)
            XCTAssertEqual(session.workingDirectory, directory.standardizedFileURL.path)
            XCTAssertTrue(session.mcpServers.isEmpty)
        }
    }

    private enum FixtureError: Error, Equatable { case unexpected, rejected }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) {
            lock.withLock { values.append(value) }
        }

        func snapshot() -> [String] {
            lock.withLock { values }
        }
    }

    private func makeProvider(
        commandName: String? = nil,
        includeMCP: Bool = true,
        isolateForeignMCPImports: Bool = false,
        environment: [String: String] = [:],
        toolNames: ACPToolNameResolution? = nil,
        permissionArguments: @escaping DevinACPAgentProvider.PermissionArguments = { _ in throw FixtureError.unexpected },
        prepareIntegration: @escaping DevinACPAgentProvider.IntegrationPreparer = { _, _, _, _ in throw FixtureError.unexpected },
        cleanupIntegration: @escaping DevinACPAgentProvider.IntegrationCleanup = { _ in XCTFail("Unexpected cleanup") }
    ) throws -> (DevinACPAgentProvider, URL) {
        let directory = try makeDirectory()
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nprintf 'Run as an ACP server over stdio\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let source = ["PATH": directory.path, "SHELL": "/bin/false"].merging(environment) { _, supplied in supplied }
        let resolver = DevinACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: source) },
            supplementalPathProvider: { $0 },
            environmentFilter: { value, _ in value },
            failureRecorder: { _, _ in }
        )
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(commandName: commandName ?? executable.path, additionalPathHints: [], enableDebugLogging: true, includeRepoPromptMCPServer: includeMCP),
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(name: "owner-fixture", command: "/usr/bin/true"),
            launchResolver: resolver,
            isolateForeignMCPImports: isolateForeignMCPImports,
            toolNames: toolNames ?? ACPToolNameResolution(isRepoPromptServerIdentifier: { _ in false }, canonicalRepoPromptToolName: { _ in nil }, isRepoPromptToolNameWithServerPrefix: { _ in false }),
            permissionArguments: permissionArguments,
            prepareIntegration: prepareIntegration,
            cleanupIntegration: cleanupIntegration
        )
        return (provider, directory)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DevinProviderOwner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeRequest(path: String, permissionMode: String? = nil, resumeID: String? = nil) -> ACPRunRequest {
        ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: path, resumeSessionID: resumeID, attachments: [], taskLabelKind: nil, launchPermissionMode: permissionMode)
    }
}
