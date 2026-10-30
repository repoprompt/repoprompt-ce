import Foundation
import RepoPromptApp
import RepoPromptShared
import XCTest

final class CodexAppServerTransportOwnerTests: XCTestCase {
    private let budget = 64 * 1024 * 1024

    func testOverBudgetSplitAndSameChunkFailAllRequestsWithoutSuffixOrTimerLeak() async throws {
        for split in [true, false] {
            let sent = AsyncStream<Data>.makeStream()
            let client = CodexAppServerClient(launchHost: FixtureCodexLaunchHost(root: FileManager.default.temporaryDirectory, executable: URL(fileURLWithPath: "/unused")), writeFrameHandler: { _, frame in sent.continuation.yield(frame) }, expectedAgentPIDRegistrar: .init(register: { _, _, _ in XCTFail("unexpected PID registration") }, clear: { _, _, _ in XCTFail("unexpected PID clearance") }))
            await client.debugInstallTestTransport()
            let generation = await client.debugTransportGeneration()
            var writes = sent.stream.makeAsyncIterator()
            let first = beginRequest(client, method: "thread/resume")
            _ = await writes.next()
            let second = beginRequest(client, method: "fixture/ping")
            _ = await writes.next()
            let suffix = Data("\n{\"id\":1,\"result\":{\"recovered\":true}}\n".utf8)
            if split {
                let chunk = Data(repeating: 0x78, count: 1024 * 1024)
                for _ in 0 ..< 64 {
                    await client.debugIngestStdoutChunk(chunk, generation: generation)
                }
                await client.debugIngestStdoutChunk(Data([0x78]), generation: generation)
                // Failure must settle before the delimiter or any recoverable suffix arrives.
            } else {
                var chunk = Data(repeating: 0x78, count: budget + 1)
                chunk.append(suffix)
                await client.debugIngestStdoutChunk(chunk, generation: generation)
            }
            for request in [first, second] {
                do {
                    _ = try await request.value
                    XCTFail("Oversized transport must fail every pending request")
                } catch let error as CodexAppServerClient.ClientError {
                    guard case let .stdoutFrameBudgetExceeded(limitBytes) = error else {
                        XCTFail("Unexpected failure: \(error)")
                        continue
                    }
                    XCTAssertEqual(limitBytes, budget)
                }
            }
            await client.debugIngestStdoutChunk(suffix, generation: generation)
            let pending = await client.debugPendingRequestCount()
            let timers = await client.debugTimeoutTaskCount()
            let running = await client.debugIsProcessRunning()
            let reason = await client.debugLastTransportTerminationReason()
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(timers, 0)
            XCTAssertFalse(running)
            XCTAssertEqual(reason, .stdoutFrameBudgetExceeded(limitBytes: budget))
            let recoveryAttempts = await client.debugDecodeRecoveryAttempts()
            XCTAssertEqual(recoveryAttempts, 0)

            await client.debugInstallTestTransport()
            let successor = await client.debugTransportGeneration()
            let next = beginRequest(client, method: "fixture/ping")
            let written = await writes.next()
            let write = try XCTUnwrap(written)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: write) as? [String: Any])
            await client.debugIngestStdoutChunk(Data(repeating: 0x78, count: budget + 1), generation: generation)
            let successorRunning = await client.debugIsProcessRunning()
            let successorReason = await client.debugLastTransportTerminationReason()
            XCTAssertTrue(successorRunning)
            XCTAssertNil(successorReason)
            let id = try XCTUnwrap(payload["id"] as? Int)
            await client.debugIngestStdoutChunk(Data("{\"id\":\(id),\"result\":{\"ok\":true}}\n".utf8), generation: successor)
            let reply = try await next.value
            XCTAssertEqual(reply["ok"] as? Bool, true)
            await client.stop()
            sent.continuation.finish()
        }
    }

    func testPhysicalLaunchKeepsCapturedRuntimeAndTwoConfigurationEvaluationPoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture.py")
        let observations = root.appendingPathComponent("observed.json")
        let fresh = root.appendingPathComponent("fresh.txt")
        try "before".write(to: fresh, atomically: true, encoding: .utf8)
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            msg = json.loads(line)
            if msg.get('method') == 'initialize':
                with open(os.environ['OBSERVATIONS'], 'w') as f:
                    json.dump({'args':sys.argv[1:], 'home':os.environ.get('CODEX_HOME'), 'request':msg}, f)
            if 'id' in msg:
                print(json.dumps({'id':msg['id'], 'result':{}}), flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        let host = FixtureCodexLaunchHost(root: root, executable: executable)
        let registered = root.appendingPathComponent("registered")
        let cleared = root.appendingPathComponent("cleared")
        let runID = UUID()
        let client = CodexAppServerClient(
            launchHost: host,
            processSpawnPreparation: {
                entered.continuation.yield(())
                for await _ in released.stream {
                    break
                }
            },
            expectedAgentPIDRegistrar: .init(
                register: { pid, name, run in
                    try? "\(pid):\(name):\(run)".write(to: registered, atomically: true, encoding: .utf8)
                },
                clear: { pid, name, run in
                    try? "\(pid):\(name):\(run)".write(to: cleared, atomically: true, encoding: .utf8)
                }
            )
        )
        await client.setExpectedAgentPIDRegistration(.init(clientName: "fixture", runID: runID))
        // A cached runtime must still prepare its state on every call.
        _ = try await client.prepareRuntimeForLaunch()
        _ = try await client.prepareRuntimeForLaunch()
        let prepareCount = try String(contentsOf: root.appendingPathComponent("prepares"), encoding: .utf8)
        XCTAssertEqual(prepareCount, "xx")
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let start = Task { try await client.startIfNeeded() }
            var entry = entered.stream.makeAsyncIterator()
            _ = await entry.next()
            try "after".write(to: fresh, atomically: true, encoding: .utf8)
            await client.updateProcessFeaturePolicy(.resolved(goalsEnabled: false, memoriesEnabled: false, computerUseEnabled: true))
            released.continuation.yield(())
            do {
                try await start.value
            } catch {
                await client.stop()
                throw error
            }
            await client.stop()
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: observations)) as? [String: Any])
        XCTAssertEqual(object["args"] as? [String], ["base-computer-use=false", "fresh=after", "app-server"])
        XCTAssertEqual(object["home"] as? String, root.appendingPathComponent("owned").path)
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let info = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, "fixture-app-version")
        let registration = try String(contentsOf: registered, encoding: .utf8)
        XCTAssertTrue(registration.hasSuffix(":fixture:\(runID)"))
        XCTAssertEqual(registration, try String(contentsOf: cleared, encoding: .utf8))
        let resolved = try String(contentsOf: root.appendingPathComponent("resolutions"), encoding: .utf8)
        XCTAssertEqual(resolved, "x", "cached launch must not resolve a second runtime")
        entered.continuation.finish()
        released.continuation.finish()
    }

    private func beginRequest(_ client: CodexAppServerClient, method: String) -> Task<[String: Any], Error> {
        Task { try await client.request(method: method, params: nil, timeout: 120, useDefaultTimeout: false) }
    }
}

private struct FixtureCodexLaunchHost: CodexAppServerLaunchHost {
    let root: URL
    let executable: URL
    var applicationVersion: String {
        "fixture-app-version"
    }

    func resolveRuntime(commandName: String, additionalPathHints: [String], enableDebugLogging: Bool) async -> CodexAppServerRuntimeResolution {
        let resolutionLog = root.appendingPathComponent("resolutions")
        let old = (try? String(contentsOf: resolutionLog, encoding: .utf8)) ?? ""
        try? (old + "x").write(to: resolutionLog, atomically: true, encoding: .utf8)
        let runtime = CodexProviderRuntime.Runtime(
            executableURL: executable,
            version: .init(major: 0, minor: 164, patch: 0),
            source: .externalOverride,
            statePaths: .init(codexHome: root.appendingPathComponent("owned"), sqliteHome: root.appendingPathComponent("sqlite"))
        )
        return .init(
            environment: ["PATH": "/usr/bin:/bin", "OBSERVATIONS": root.appendingPathComponent("observed.json").path, "CODEX_HOME": "untrusted-home"],
            resolution: .init(commandName: commandName, resolvedCommand: executable.path, status: .available, runtime: runtime, userMessage: "", debugMessage: "")
        )
    }

    func prepareState(for runtime: CodexProviderRuntime.Runtime) throws {
        try FileManager.default.createDirectory(at: runtime.statePaths.codexHome, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("prepares")
        let old = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        try (old + "x").write(to: path, atomically: true, encoding: .utf8)
    }

    func filterEnvironment(_ environment: [String: String], explicitOverrides: [String: String]) async -> [String: String] {
        XCTAssertEqual(environment["CODEX_HOME"], explicitOverrides["CODEX_HOME"])
        return environment
    }

    func baseProcessArguments(runtime: CodexProviderRuntime.Runtime, provisionsRepoPromptMCP: Bool, featurePolicy: CodexProcessConfiguration.FeaturePolicy, reasoningSummary: CodexProcessConfiguration.ReasoningSummary?) throws -> [String] {
        XCTAssertEqual(runtime.executableURL, executable)
        return ["base-computer-use=\(featurePolicy.computerUseEnabled)"]
    }

    func computerUseProcessArguments(runtime: CodexProviderRuntime.Runtime) throws -> [String] {
        XCTAssertEqual(runtime.executableURL, executable)
        return try ["fresh=" + String(contentsOf: root.appendingPathComponent("fresh.txt"), encoding: .utf8)]
    }
}
