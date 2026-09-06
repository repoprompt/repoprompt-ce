import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class ACPIntegratedAgentModeRunnerModelSelectionTests: XCTestCase {
    func testOMPSelectedModelReachesControllerBeforeInitialAndRetainedPrompts() async throws {
        try await verifySelections(agentKind: .omp)
    }

    func testDevinSelectedModelReachesControllerBeforeInitialAndRetainedPrompts() async throws {
        try await verifySelections(agentKind: .devin)
    }

    private func verifySelections(agentKind: AgentProviderKind) async throws {
        let providerID: ACPProviderID = agentKind == .omp ? .omp : .devin
        defer { AgentACPModelRegistry.shared.test_reset(providerID: providerID) }
        let directory = try makeTestDirectory(name: "ACPIntegratedRunnerModels")
        let provider = try ACPModelSelectionFixtureProvider(directory: directory, providerID: providerID)
        func request(_ model: String, resume: String? = nil) -> ACPRunRequest {
            ACPRunRequest(
                agentKind: agentKind,
                modelString: model,
                workspacePath: directory.path,
                resumeSessionID: resume,
                attachments: [],
                taskLabelKind: nil
            )
        }
        // Bootstrap with the provider default so bootstrap's own model application cannot
        // mask a skipped runner call. Both production runner paths call this same method.
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request("default"))
        do {
            _ = try await controller.bootstrap()
            let initial = request("model-b")
            try await ACPIntegratedAgentModeRunner.applyExplicitSelectedModelIfNeeded(initial, controller: controller, runID: UUID())
            try await controller.prompt(AgentMessage(userMessage: "initial"), request: initial)
            let continuation = request("model-c", resume: "fixture-session")
            try await ACPIntegratedAgentModeRunner.applyExplicitSelectedModelIfNeeded(continuation, controller: controller, runID: UUID())
            let reusable = await controller.prepareForNextTurn()
            XCTAssertTrue(reusable)
            try await controller.prompt(AgentMessage(userMessage: "follow-up"), request: continuation)
            // Rejection must propagate from the controller, not silently use the old model.
            do {
                try await ACPIntegratedAgentModeRunner.applyExplicitSelectedModelIfNeeded(request("rejected"), controller: controller, runID: UUID())
                XCTFail("Expected model-selection rejection")
            } catch {
                XCTAssertTrue(String(describing: error).contains("fixture rejection"), "\(error)")
            }
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
        let records = try provider.records()
        XCTAssertEqual(records.compactMap { $0["selected"] as? String }, ["model-b", "model-c", "rejected"])
        let prompts = records.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.compactMap { $0["model"] as? String }, ["model-b", "model-c"])
        XCTAssertEqual(prompts.compactMap { $0["mode"] as? String }, ["ask", "ask"])
        XCTAssertEqual(records.count(where: { $0["method"] as? String == "session/new" }), 1)
        XCTAssertFalse(records.contains { $0["method"] as? String == "session/load" })
    }
}

/// Disposable wire fixture, not evidence about an installed provider's protocol behavior.
struct ACPModelSelectionFixtureProvider: ACPAgentProvider {
    let directory: URL
    let providerID: ACPProviderID

    init(directory: URL, providerID: ACPProviderID) throws {
        self.directory = directory
        self.providerID = providerID
        let script = #"""
        #!/usr/bin/env python3
        import json, sys
        from pathlib import Path
        root = Path(__file__).parent
        model, mode = 'model-a', 'ask'
        def options():
            return [
                {'id':'model','name':'Model','category':'model','type':'select','currentValue':model,
                 'options':[{'value':v,'name':v} for v in ['model-a','model-b','model-c','rejected']]},
                {'id':'mode','name':'Mode','category':'mode','type':'select','currentValue':mode,
                 'options':[{'value':v,'name':v} for v in ['ask','code']]}]
        def reply(i, result):
            print(json.dumps({'jsonrpc':'2.0','id':i,'result':result}),flush=True)
        for line in sys.stdin:
            m=json.loads(line); method=m.get('method'); params=m.get('params',{}); i=m.get('id')
            record={'method':method,'model':model,'mode':mode}
            if method=='session/set_config_option': record['selected']=params['value']
            with (root/'requests.jsonl').open('a') as f: f.write(json.dumps(record)+'\n')
            if method=='initialize':
                reply(i,{'protocolVersion':1,'agentCapabilities':{'loadSession':True},'authMethods':[]})
            elif method in ['session/new','session/load']:
                reply(i,{'sessionId':'fixture-session','configOptions':options()})
            elif method=='session/set_config_option':
                if params['value']=='rejected':
                    print(json.dumps({'jsonrpc':'2.0','id':i,'error':{'code':-32602,'message':'fixture rejection'}}),flush=True)
                else:
                    if params['configId']=='model': model=params['value']
                    else: mode=params['value']
                    reply(i,{'configOptions':options()})
            elif method=='session/prompt':
                stderr=root/'stderr.txt'
                if stderr.exists(): print(stderr.read_text(),file=sys.stderr,flush=True)
                print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'fixture-session',
                    'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'answer'}}}}),flush=True)
                reply(i,{'stopReason':'end_turn'})
            elif i is not None: reply(i,{})
        """# + "\n"
        let executable = directory.appendingPathComponent("acp-fixture")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func records() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: directory.appendingPathComponent("acp-fixture").path,
            arguments: [],
            environment: [:],
            workingDirectory: directory.path,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(for _: ACPRunRequest, mcpServer _: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(mode: .new, workingDirectory: directory.path, mcpServers: [])
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID)
    }

    func shouldEmitStderrLine(_ line: String) -> Bool {
        if providerID == .devin {
            return DevinACPAgentProvider(config: DevinAgentConfig(includeRepoPromptMCPServer: false)).shouldEmitStderrLine(line)
        }
        return true
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
