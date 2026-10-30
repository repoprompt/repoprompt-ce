import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class ClaudeHeadlessExecutionTests: XCTestCase {
    func testReadinessFailureDoesNotPrepareLeaseOrResolveEnvironment() async throws {
        let journal = HeadlessJournal()
        let service = HeadlessConfigService(journal: journal, url: URL(fileURLWithPath: "/unused"))
        let host = HeadlessRecordingHost(journal: journal)
        let provider = makeProvider(service: service, host: host, journal: journal, serverReadiness: { false })
        do {
            _ = try await provider.prepare()
            XCTFail("Expected readiness failure")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, "Could not start MCP server. Check MCP settings and try again.")
        }
        let entries = await journal.entries
        XCTAssertTrue(entries.isEmpty)
        let preparationCount = await service.preparationCount
        XCTAssertEqual(preparationCount, 0)
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testTerminalStreamSamplesPolicyAtExecutionAndStopsTrackingBeforeLeaseCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude-fixture")
        try "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"result\",\"result\":\"done\",\"session_id\":\"session\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let journal = HeadlessJournal()
        let leaseURL = root.appendingPathComponent("launch.json")
        let service = HeadlessConfigService(journal: journal, url: leaseURL)
        let host = HeadlessRecordingHost(journal: journal)
        let provider = makeProvider(service: service, host: host, journal: journal, command: executable.path)
        XCTAssertTrue(host.calls.isEmpty)
        host.policyMarker = "latest"
        let stream = try await provider.streamAgentMessage(AgentMessage(systemPrompt: "instructions", userMessage: "request"), runID: UUID())
        var events: [RepoPromptDomainRuntime.AIStreamResult] = []
        for try await event in stream {
            events.append(event)
        }
        await provider.dispose()
        XCTAssertEqual(host.calls, ["prompt:latest", "user:latest", "override:latest", "arguments:latest", "client", "tracking:claude-code"])
        XCTAssertEqual(events.map(\.type), ["system", "final_content", "message_stop"])
        XCTAssertEqual(events.last?.providerSessionID, "session")
        XCTAssertEqual(events.last?.promptTokens, 2)
        XCTAssertEqual(events.last?.completionTokens, 3)
        let entries = await journal.entries
        XCTAssertEqual(entries.first, "resolve")
        let preparationCount = await service.preparationCount
        XCTAssertEqual(preparationCount, 1)
        XCTAssertLessThan(try XCTUnwrap(entries.firstIndex(of: "register")), try XCTUnwrap(entries.firstIndex(of: "processStarted")))
        XCTAssertLessThan(try XCTUnwrap(entries.firstIndex(of: "stop")), try XCTUnwrap(entries.firstIndex(of: "cleanup")))
        XCTAssertTrue(entries.contains("clear"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL.path))
    }

    func testParserPreservesFinalMessageThenCompletionAndStopReason() throws {
        let journal = HeadlessJournal()
        let provider = makeProvider(
            service: HeadlessConfigService(journal: journal, url: URL(fileURLWithPath: "/unused")),
            host: HeadlessRecordingHost(journal: journal), journal: journal
        )
        let events = try provider.parseStreamEvents(Data("{\"type\":\"result\",\"result\":\"done\",\"stop_reason\":\"max_turns\",\"sessionId\":\"resume\",\"usage\":{\"inputTokens\":\"4\",\"outputTokens\":5}}".utf8))
        XCTAssertEqual(events.count, 3)
        guard case let .system(message) = events[0], case let .finalMessage(content) = events[1],
              case let .completion(usage, cost, session) = events[2]
        else { return XCTFail("Expected stop reason, final message, completion") }
        XCTAssertEqual(message, "Claude stop reason: max_turns")
        XCTAssertEqual(content, "done")
        XCTAssertEqual(usage?.inputTokens, 4)
        XCTAssertEqual(usage?.outputTokens, 5)
        XCTAssertNil(cost)
        XCTAssertEqual(session, "resume")
    }

    private func makeProvider(
        service: HeadlessConfigService,
        host: HeadlessRecordingHost,
        journal: HeadlessJournal,
        command: String = "/unused",
        serverReadiness: @escaping @Sendable () async -> Bool = { true }
    ) -> ClaudeCodeAgentProvider {
        let config = ClaudeCodeAgentConfig(
            commandName: command, additionalPathHints: [], modelString: "sonnet", runtimeVariant: .standard,
            enableDebugLogging: false, sdkConnectTimeoutSeconds: 30, sdkRelaunchMaxAttempts: 0,
            permissionMode: "bypassPermissions", allowNativeBashTool: false, toolContext: .discoverRun,
            disallowedBuiltInTools: [], mcpStrictMode: true, toolSearchEnabled: false, effortLevel: nil
        )
        return ClaudeCodeAgentProvider(
            composedRunner: CLIProcessRunner(config: CLIProcessConfiguration(
                command: command, allowsProviderProcessLaunchForTesting: true,
                environment: ProcessInfo.processInfo.environment, additionalPaths: [], shellLookupMode: .disabled
            )),
            config: config, environmentResolver: HeadlessResolver(journal: journal, leaseURL: service.url), configService: service,
            host: host, serverReadiness: serverReadiness,
            processStarted: { _ in await journal.record("processStarted") },
            cleanupStarted: { await journal.record("cleanup") }
        )
    }
}

private actor HeadlessJournal {
    private(set) var entries: [String] = []
    func record(_ entry: String) {
        entries.append(entry)
    }
}

private struct HeadlessLease: LaunchConfigLease {
    let url: URL
    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor HeadlessConfigService: ClaudeHeadlessConfigPreparing {
    let journal: HeadlessJournal
    let url: URL
    private(set) var preparationCount = 0
    init(journal: HeadlessJournal, url: URL) {
        self.journal = journal
        self.url = url
    }

    func prepareClaudeHeadlessLaunchConfig() throws -> any LaunchConfigLease {
        preparationCount += 1
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        return HeadlessLease(url: url)
    }
}

private struct HeadlessResolver: ClaudeCodeLaunchEnvironmentResolving {
    let journal: HeadlessJournal
    let leaseURL: URL
    func resolve(variant: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
        guard FileManager.default.fileExists(atPath: leaseURL.path) else { throw CocoaError(.fileNoSuchFile) }
        await journal.record("resolve")
        return ClaudeCompatiblePluginLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backendID: nil)
    }
}

private final class HeadlessRecordingHost: ClaudeHeadlessHosting {
    let journal: HeadlessJournal
    var calls: [String] = []
    var policyMarker = "initial"
    init(journal: HeadlessJournal) {
        self.journal = journal
    }

    func currentPromptDelivery() -> ClaudeHeadlessPromptDelivery {
        let marker = policyMarker
        calls.append("prompt:\(marker)")
        return ClaudeHeadlessPromptDelivery(userMessage: { [self] user, _ in
            calls.append("user:\(marker)")
            return user
        }, nativeSystemPromptOverride: { [self] _ in
            calls.append("override:\(marker)")
            return nil
        })
    }

    func buildArguments(config: ClaudeCodeAgentConfig, context: ClaudeHeadlessAgentContext, resumeSessionID: String?, systemPromptOverride: String?) -> [String] {
        calls.append("arguments:\(policyMarker)")
        return []
    }

    func isReasoningExtractionEnabled() -> Bool {
        false
    }

    func expectedClientName(for variant: ClaudeCodeRuntimeVariant) -> String? {
        calls.append("client")
        return "fixture-client"
    }

    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await journal.record("register")
    }

    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await journal.record("clear")
    }

    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Continuation) {
        calls.append("tracking:\(clientNameHint)")
        continuation.yield(.init(type: "system", text: "tracking started"))
    }

    @MainActor func stopTracking() async {
        await journal.record("stop")
    }
}
