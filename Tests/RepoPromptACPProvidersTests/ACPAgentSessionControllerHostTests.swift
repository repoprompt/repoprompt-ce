import Darwin
import Foundation
import RepoPromptACPProviders
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
        let host = RecordingHost()
        host.setSnapshot("old")
        let provider = FixtureProvider(providerID: .grokBuild, script: script.path, observations: observations.path)
        let request = ACPRunRequest(agentKind: .grokBuild, modelString: nil, workspacePath: directory.path, resumeSessionID: nil, attachments: [], taskLabelKind: nil)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, host: host, allowsProviderProcessLaunchForTesting: true)
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
            await controller.shutdown()
            XCTAssertTrue(host.events().contains("clear"))
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

private struct FixtureProvider: ACPAgentProvider, ACPDirectSessionModelProvider {
    let providerID: ACPProviderID
    let script: String
    let observations: String

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(providerID: providerID, command: "/usr/bin/python3", arguments: ["-u", script], environment: ["OBS_FILE": observations], workingDirectory: nil, additionalPathHints: [], enableDebugLogging: false)
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

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
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
        record("clear")
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

        func recordRunRoutingEvent(runID _: UUID, event _: String, fields _: [String: String]) async {
            XCTFail("Unexpected diagnostics")
        }
    #endif
}
