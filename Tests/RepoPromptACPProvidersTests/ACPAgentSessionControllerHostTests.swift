import Darwin
import Foundation
@testable import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class ACPAgentSessionControllerHostTests: XCTestCase {
    func testACPBootstrapRefusesDevinNewAndColdResumeWithoutFixtureOptIn() async throws {
        for resumeID in [nil, "persisted-devin-session"] as [String?] {
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ACPRefusal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let recordURL = workspace.appendingPathComponent("requests.jsonl")
            let script = workspace.appendingPathComponent("server.py")
            try "import os\nopen(os.environ['OBS_FILE'], 'w').write('launched')\n".write(to: script, atomically: true, encoding: .utf8)
            let provider = FixtureProvider(providerID: .devin, script: script.path, observations: recordURL.path)
            let request = ACPRunRequest(agentKind: .devin, modelString: nil, workspacePath: workspace.path, resumeSessionID: resumeID, attachments: [], taskLabelKind: nil)
            let host = RecordingHost()
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, host: host)
            let expectedMode: ACPSessionConfiguration.Mode = resumeID.map { .load(existingSessionID: $0) } ?? .new
            XCTAssertEqual(host.initialSessionConfiguration()?.mode, expectedMode)
            XCTAssertEqual(host.initialSessionConfiguration()?.workingDirectory, workspace.path)
            do {
                _ = try await controller.bootstrap()
                XCTFail("Discovery and cold resume must fail closed without an explicit fixture permit")
            } catch {
                XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
            }
            let identity = await controller.currentProviderSessionIdentity()
            XCTAssertNil(identity.runtimeSessionID)
            XCTAssertEqual(identity.loadSessionID, resumeID)
            await controller.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "Refusal must precede ACP initialization")
        }
    }

    func testRequiredHostRoutesLaunchAndReadsRegistryAtSelectionTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPHost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py")
        let observations = directory.appendingPathComponent("observations")
        try #"""
        import json, os, sys
        with open(os.environ['OBS_FILE'], 'w') as output:
            output.write(os.environ.get('FIXTURE_ROUTE', 'missing'))
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if 'id' not in request: continue
            if method == 'initialize':
                result = {'agentCapabilities': {}}
            elif method == 'session/new':
                result = {'sessionId': 'session-one'}
            elif method == 'session/set_model':
                result = {'_meta': {'model': {'Ok': request['params']['modelId']}}}
            else:
                result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let clearing = expectation(description: "original shutdown entered host cleanup")
        let joined = expectation(description: "second shutdown joined original producer")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let host = RecordingHost(beforeClear: {
            clearing.fulfill()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        host.setSnapshot("old")
        let provider = FixtureProvider(providerID: .grokBuild, script: script.path, observations: observations.path)
        let request = ACPRunRequest(agentKind: .grokBuild, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(
            provider: provider, runRequest: request, host: host,
            diagnosticSink: { event in
                if case .info("Joining ACP controller shutdown") = event { joined.fulfill() }
            },
            allowsProviderProcessLaunchForTesting: true
        )
        XCTAssertEqual(host.events(), ["configuration", "preflight-init"])
        do {
            _ = try await controller.bootstrap()
            XCTAssertEqual(try String(contentsOf: observations, encoding: .utf8), "carrier")
            XCTAssertEqual(Array(host.events().prefix(6)), ["configuration", "preflight-init", "filter", "carrier", "preflight-launch", "register"])
            do {
                try await controller.setSessionModel("new")
                XCTFail("A model absent from the current registry must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("not in the discovered model set"))
            }
            host.setSnapshot("new")
            try await controller.setSessionModel("new")
            XCTAssertGreaterThanOrEqual(host.events().count(where: { $0 == "registry" }), 2)
            let original = Task { await controller.shutdown() }
            await fulfillment(of: [clearing], timeout: 10)
            let repeated = Task { await controller.shutdown() }
            repeated.cancel()
            await fulfillment(of: [joined], timeout: 10)
            XCTAssertFalse(host.events().contains("clear"), "The original host cleanup is still suspended")
            release.continuation.yield(())
            await repeated.value
            XCTAssertTrue(host.events().contains("clear"), "A cancelled waiter must still join actual shutdown completion")
            await original.value
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 1)
        } catch {
            release.continuation.finish()
            await controller.shutdown()
            throw error
        }
    }
}

private struct FixtureProvider: ACPAgentProvider, ACPDirectSessionModelProvider {
    let providerID: ACPProviderID
    let script: String
    let observations: String
    var emitsFixtureText = false
    var responseText: String?

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        var environment = ["OBS_FILE": observations]
        if let responseText {
            environment["FIXTURE_RESPONSE"] = responseText
        }
        return ACPLaunchConfiguration(providerID: providerID, command: "/usr/bin/python3", arguments: ["-u", script], environment: environment, workingDirectory: nil, additionalPathHints: [], enableDebugLogging: false)
    }

    func makeSessionConfiguration(for request: ACPRunRequest, mcpServer: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
        XCTAssertEqual(mcpServer.name, "fixture-host")
        let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
    }

    func buildPromptBlocks(for _: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        []
    }

    func normalizeSessionUpdate(_ update: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        guard emitsFixtureText, let text = update["fixtureText"] as? String else { return [] }
        return [.stream(AIStreamResult(type: "content", text: text))]
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }

    func parseDirectSessionModelSnapshot(from _: [String: Any]) -> ACPProviderModelSnapshotResult {
        .absent
    }

    func parseDirectSessionEffortReport(from _: [[String: Any]], sessionID _: String, options _: [AgentModelOption]) -> ACPDirectSessionEffortReport? {
        nil
    }

    func makeDirectModelSelectionRequest(sessionID: String, baseModelRaw: String, reasoningEffortRaw _: String?) -> ACPDirectModelSelectionRequest {
        ACPDirectModelSelectionRequest(method: "session/set_model", params: ["sessionId": sessionID, "modelId": baseModelRaw], expectedConfirmationModelRaw: baseModelRaw)
    }
}

private final class RecordingHost: ACPAgentSessionHost, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var snapshot: ACPDiscoveredSessionModels?
    private var initialConfiguration: ACPSessionConfiguration?
    private let clearedExpectation: XCTestExpectation?
    private let allowsDiagnostics: Bool
    private let beforeClear: (@Sendable () async -> Void)?

    init(clearedExpectation: XCTestExpectation? = nil, allowsDiagnostics: Bool = false, beforeClear: (@Sendable () async -> Void)? = nil) {
        self.clearedExpectation = clearedExpectation
        self.allowsDiagnostics = allowsDiagnostics
        self.beforeClear = beforeClear
    }

    private func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    func events() -> [String] {
        lock.withLock { recorded }
    }

    func initialSessionConfiguration() -> ACPSessionConfiguration? {
        lock.withLock { initialConfiguration }
    }

    func setSnapshot(_ raw: String) {
        let option = AgentModelOption(rawValue: raw, displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        lock.withLock { snapshot = ACPDiscoveredSessionModels(options: [option], currentModelRaw: nil) }
    }

    var applicationVersion: String {
        "fixture"
    }

    var repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration {
        record("configuration")
        return RepoPromptMCPServerConfiguration(name: "fixture-host", command: "/usr/bin/true")
    }

    var cursorAutoModelRaw: String {
        "auto"
    }

    func preflightInjectedMCPServers(in configuration: ACPSessionConfiguration) throws {
        lock.withLock {
            initialConfiguration = configuration
            recorded.append("preflight-init")
        }
    }

    func preflightInjectedMCPServers(in _: ACPSessionConfiguration, environment: [String: String]) throws {
        XCTAssertEqual(environment["FIXTURE_ROUTE"], "carrier")
        record("preflight-launch")
    }

    func mcpClientNameHint(for _: AgentProviderKind) -> String? {
        "fixture-client"
    }

    func displayName(for _: AgentProviderKind) -> String {
        "Fixture"
    }

    func normalizedModelParameterSelections(_ selections: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        selections
    }

    func canonicalParameterModelRaw(_ raw: String, providerID _: ACPProviderID) -> String {
        raw
    }

    func parameterIdentityMatches(_: ACPModelParameterSelection, providerID _: ACPProviderID, baseModelRaw _: String, kind _: ACPModelParameterKind) -> Bool {
        XCTFail("Unexpected identity lookup")
        return false
    }

    func recognizedDevinPermissionMode(_: String?) -> Bool {
        XCTFail("Unexpected Devin policy")
        return false
    }

    func normalizedDevinPermissionMode(_ mode: String?) -> String? {
        mode
    }

    func devinThinkingSelection(for _: String) -> ACPDevinThinkingSelection? {
        XCTFail("Unexpected Devin lookup")
        return nil
    }

    func grokDecomposition(raw: String, options: [AgentModelOption]) -> ACPGrokModelDecomposition? {
        options.first(where: { $0.rawValue == raw }).map { ACPGrokModelDecomposition(base: $0, explicitEffort: nil) }
    }

    func grokCompoundRaw(base: String, effort _: CodexReasoningEffort?) -> String {
        base
    }

    func resolvedModelSnapshot(for _: ACPProviderID) -> ACPDiscoveredSessionModels? {
        record("registry")
        return lock.withLock { snapshot }
    }

    func publishDiscoveredModels(_: ACPDiscoveredSessionModels, for _: ACPProviderID) {
        record("publish")
    }

    func filterEnvironment(_ environment: [String: String], launchConfiguration _: ACPLaunchConfiguration, kind _: AgentProviderKind) async -> [String: String] {
        record("filter")
        var result = environment
        result["FIXTURE_ROUTE"] = "filtered"
        return result
    }

    func mergingCurrentCarrier(into environment: [String: String]) -> [String: String] {
        record("carrier")
        var result = environment
        result["FIXTURE_ROUTE"] = "carrier"
        return result
    }

    func registerExpectedAgentPID(_: pid_t, clientName: String, runID _: UUID?) async {
        XCTAssertEqual(clientName, "fixture-client")
        record("register")
    }

    func clearExpectedAgentPID(_: pid_t, clientName: String, runID _: UUID?) async {
        XCTAssertEqual(clientName, "fixture-client")
        await beforeClear?()
        record("clear")
        clearedExpectation?.fulfill()
    }

    func permissionIsAutoSelectable(optionID _: String?, providerID _: ACPProviderID) -> Bool {
        XCTFail("Unexpected permission policy")
        return false
    }

    func permissionOneTimeAllow(options _: [(optionID: String, kind: String)], providerID _: ACPProviderID) -> String? {
        XCTFail("Unexpected permission policy")
        return nil
    }

    func permissionOneTimeReject(options _: [(optionID: String, kind: String)]) -> String? {
        XCTFail("Unexpected permission policy")
        return nil
    }

    #if DEBUG
        func diagnosticErrorKind(_: Error) -> String {
            "fixture"
        }

        func recordRunRoutingEvent(runID _: UUID, event: String, fields _: [String: String]) async {
            if allowsDiagnostics {
                record("routing:\(event)")
            } else {
                XCTFail("Unexpected diagnostics")
            }
        }
    #endif
}

final class ACPCLIProviderExecutionTests: XCTestCase {
    func testInjectedConfigurationIsResolvedPerRequestAndTerminalStreamsReleaseEachProcess() async throws {
        for consumer in Consumer.allCases {
            let fixture = try makeFixture(consumer: consumer, holdPrompt: false)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cleared = expectation(description: "\(consumer) terminal processes released")
            cleared.expectedFulfillmentCount = 2
            let host = RecordingHost(clearedExpectation: cleared, allowsDiagnostics: true)
            var configuredModels: [AIModel] = []
            let cli = makeCLI(consumer: consumer, fixture: fixture.provider, host: host) { model in
                configuredModels.append(model)
                return model == consumer.model("second") ? "second" : "first"
            }
            XCTAssertTrue(configuredModels.isEmpty, "Construction must not eagerly snapshot request policy")
            for name in ["first", "second"] {
                let result = try await cli.completeMessage(AIMessage(systemPrompt: "", userMessage: "Execute"), model: consumer.model(name), maxTokens: nil)
                XCTAssertEqual(result.text, name, "Injected config must reach the actual provider process for this request")
            }
            await fulfillment(of: [cleared], timeout: 10)
            await cli.dispose()
            await cli.dispose()
            XCTAssertEqual(configuredModels, [consumer.model("first"), consumer.model("second")])
            XCTAssertEqual(host.events().count(where: { $0 == "register" }), 2)
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 2)
            let methods = try recordedMethods(at: fixture.observations)
            XCTAssertEqual(methods.count(where: { $0 == "session/new" }), 2)
            XCTAssertEqual(methods.count(where: { $0 == "session/prompt" }), 2)
            XCTAssertFalse(methods.contains("session/load"), "CLI requests must not resume an earlier conversation")
        }
    }

    func testCancellingCLIConsumptionDisposesTheExistingHeadlessController() async throws {
        for consumer in Consumer.allCases {
            let fixture = try makeFixture(consumer: consumer, holdPrompt: true)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let cleared = expectation(description: "\(consumer) cancelled process released")
            let content = expectation(description: "\(consumer) partial content received")
            let host = RecordingHost(clearedExpectation: cleared, allowsDiagnostics: true)
            let cli = makeCLI(consumer: consumer, fixture: fixture.provider, host: host) { _ in "partial" }
            let stream = try await cli.streamMessage(AIMessage(systemPrompt: "", userMessage: "Wait for cancellation"), model: consumer.model("partial"), maxTokens: nil)
            let execution = Task {
                do {
                    for try await result in stream {
                        if result.type == "content", result.text == "partial" {
                            content.fulfill()
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        XCTFail("Unexpected stream failure: \(error)")
                    }
                }
            }
            await fulfillment(of: [content], timeout: 10)
            execution.cancel()
            _ = await execution.result
            await fulfillment(of: [cleared], timeout: 10)
            await cli.dispose()
            await cli.dispose()
            XCTAssertEqual(host.events().count(where: { $0 == "register" }), 1)
            XCTAssertEqual(host.events().count(where: { $0 == "clear" }), 1)
        }
    }

    func testOpenCodeStaleTerminationCannotRemoveTheReplacementProvider() {
        final class Provider {}
        let first = Provider()
        let second = Provider()
        let third = Provider()
        let store = ActiveOpenCodeCLIProviderStore<Provider>()
        XCTAssertNil(store.replace(first))
        XCTAssertTrue(store.replace(second) === first)
        XCTAssertTrue(store.remove(first))
        XCTAssertTrue(store.contains(second))
        XCTAssertTrue(store.replace(third) === second)
        XCTAssertTrue(store.remove(second))
        XCTAssertTrue(store.contains(third))
        let remaining = store.removeAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.first === third)
        XCTAssertFalse(store.contains(third))
        XCTAssertNil(store.replace(first), "Draining must retire the current-provider identity too")
    }

    private enum Consumer: CaseIterable {
        case cursor
        case openCode

        var providerID: ACPProviderID {
            switch self {
            case .cursor: .cursor
            case .openCode: .openCode
            }
        }

        var sessionMode: String {
            switch self {
            case .cursor: CursorAgentConfig.promptOnlySessionModeID
            case .openCode: OpenCodeAgentConfig.managedNoToolsSessionModeID
            }
        }

        func model(_ name: String) -> AIModel {
            switch self {
            case .cursor: .cursorCustom(name: name)
            case .openCode: .openCodeCustom(name: name)
            }
        }
    }

    private func makeCLI(
        consumer: Consumer,
        fixture: FixtureProvider,
        host: RecordingHost,
        resolveConfiguration: @escaping (AIModel) -> String
    ) -> any AIProvider {
        switch consumer {
        case .cursor:
            CursorCLIProvider(
                configurationFactory: { model in
                    let name = resolveConfiguration(model)
                    return CursorAgentConfig(enableDebugLogging: name == "second", modelString: name, includeRepoPromptMCPServer: false, sessionModeID: CursorAgentConfig.promptOnlySessionModeID)
                },
                headlessProviderFactory: { config, workspacePath in
                    XCTAssertNil(workspacePath)
                    var configured = fixture
                    configured.responseText = config.modelString
                    let provider = configured
                    return CursorACPHeadlessAgentProvider(
                        config: config, workspacePath: workspacePath, baseModel: nil,
                        providerFactory: { _ in provider },
                        controllerFactory: { provider, request, diagnosticSink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, host: host, diagnosticSink: diagnosticSink, allowsProviderProcessLaunchForTesting: true)
                        },
                        applySelectedModel: { _, _ in }
                    )
                }
            )
        case .openCode:
            OpenCodeCLIProvider(
                configurationFactory: { model in
                    let name = resolveConfiguration(model)
                    return OpenCodeAgentConfig(modelString: name, enableDebugLogging: name == "second", includeRepoPromptMCPServer: false, toolProfile: .noTools)
                },
                headlessProviderFactory: { config, workspacePath in
                    XCTAssertNil(workspacePath)
                    var configured = fixture
                    configured.responseText = config.modelString
                    let provider = configured
                    return OpenCodeACPHeadlessAgentProvider(
                        config: config, workspacePath: workspacePath,
                        providerFactory: { _ in provider },
                        controllerFactory: { provider, request, diagnosticSink in
                            try ACPAgentSessionController(provider: provider, runRequest: request, host: host, diagnosticSink: diagnosticSink, allowsProviderProcessLaunchForTesting: true)
                        },
                        selectedModel: { _ in nil }
                    )
                }
            )
        }
    }

    private func makeFixture(consumer: Consumer, holdPrompt: Bool) throws -> (directory: URL, observations: URL, provider: FixtureProvider) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ACPCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let observations = directory.appendingPathComponent(holdPrompt ? "hold.jsonl" : "terminal.jsonl")
        let script = directory.appendingPathComponent("server.py")
        try #"""
        import json, os, sys
        for line in sys.stdin:
            request = json.loads(line)
            with open(os.environ['OBS_FILE'], 'a') as output:
                output.write(json.dumps(request) + '\n')
            if 'id' not in request: continue
            method = request.get('method')
            if method == 'initialize':
                result = {'agentCapabilities': {}}
            elif method == 'session/new':
                result = {'sessionId': 'fixture-session', 'configOptions': [{'id': 'mode', 'name': 'Mode', 'category': 'mode', 'type': 'select', 'currentValue': '\#(consumer.sessionMode)', 'options': [{'value': '\#(consumer.sessionMode)', 'name': 'Fixture'}]}]}
            elif method == 'session/prompt':
                print(json.dumps({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': 'fixture-session', 'update': {'sessionUpdate': 'agent_message_chunk', 'fixtureText': os.environ['FIXTURE_RESPONSE']}}}), flush=True)
                if os.environ['OBS_FILE'].endswith('hold.jsonl'): continue
                result = {'stopReason': 'end_turn'}
            else:
                result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        return (directory, observations, FixtureProvider(providerID: consumer.providerID, script: script.path, observations: observations.path, emitsFixtureText: true))
    }

    private func recordedMethods(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return request?["method"] as? String
        }
    }
}
