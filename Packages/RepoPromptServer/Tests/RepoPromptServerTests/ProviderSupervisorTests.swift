import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

#if os(Linux)
    import Glibc
#endif

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
private struct ImmediateClock: RuntimeClock {
    func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for duration: Duration) async throws {}
}

private actor FakeProcessPort: ProcessSupervisionPort {
    private let leader: ProcessIdentity
    private let inspectedLeader: ProcessIdentity
    private let children: [ProcessIdentity]
    private let lateChildren: [ProcessIdentity]
    private var observedSignals: [Int32] = []
    private var observedProcessGroups: [Int32] = []
    private var reapedPIDs: [Int32] = []
    private var reconstructed: [(ProcessIdentity, String)] = []
    private var descendantScans = 0

    init(leader: ProcessIdentity, children: [ProcessIdentity], lateChildren: [ProcessIdentity] = [], inspectedLeader: ProcessIdentity? = nil) {
        self.leader = leader
        self.inspectedLeader = inspectedLeader ?? leader
        self.children = children
        self.lateChildren = lateChildren
    }

    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        leader
    }

    func inspect(pid: Int32) async throws -> ProcessIdentity? {
        ([inspectedLeader] + children).first { $0.pid == pid }
    }

    func descendants(of pid: Int32) async throws -> [ProcessIdentity] {
        descendantScans += 1
        guard pid == leader.pid else { return [] }
        return descendantScans >= 3 ? children + lateChildren : children
    }

    func signal(_ signal: Int32, processGroupID: Int32, verifiedMembers: [ProcessIdentity]) async throws {
        observedSignals.append(signal)
        observedProcessGroups.append(processGroupID)
    }

    func reap(pid: Int32) async throws {
        reapedPIDs.append(pid)
    }

    func containmentMode(for _: ProcessIdentity) async throws -> String {
        "cgroup-v2"
    }

    func reconstruct(leader: ProcessIdentity, containmentMode: String) async throws {
        reconstructed.append((leader, containmentMode))
    }

    func result() -> (signals: [Int32], processGroups: [Int32], reaped: [Int32], reconstructed: [(ProcessIdentity, String)]) {
        (observedSignals, observedProcessGroups, reapedPIDs, reconstructed)
    }
}

final class ProviderSupervisorTests: XCTestCase {
    func testCodexJSONLPublishesDurableIdentityAndUsesNativeResumeCommand() async throws {
        let runner = RecordingProviderRunner()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let first = try await adapter.execute(kind: .codex, model: "gpt-test", prompt: "first", workingDirectory: "/tmp")
        XCTAssertEqual(first.providerSessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(first.output, "done")
        _ = try await adapter.execute(kind: .codex, model: nil, prompt: "continue", workingDirectory: "/tmp", resumeProviderSessionID: first.providerSessionID)
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Array(calls[1].prefix(4)), ["exec", "resume", "--json", "--skip-git-repo-check"])
        XCTAssertTrue(calls[1].contains("11111111-1111-1111-1111-111111111111"))
        let capabilities = await adapter.capabilities()
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.supportsSteering, true)
    }

    func testCataloguedDisabledProviderReportsUnavailableAndRejectsExecutionLocally() async throws {
        let runner = RecordingProviderRunner()
        let adapter = ProviderCLIAdapter(
            configurations: [
                .init(kind: .codex, executable: "/usr/bin/true", expectedVersion: "1.0", protocolVersion: "app-server-v2")
            ],
            enabledProviders: [],
            runner: runner
        )

        let capabilities = await adapter.capabilities()
        let capability = try XCTUnwrap(capabilities.first { $0.kind == .codex })
        XCTAssertFalse(capability.enabled)
        XCTAssertEqual(capability.executable, "/usr/bin/true")
        XCTAssertEqual(capability.version, "1.0")
        XCTAssertEqual(capability.protocolVersion, "app-server-v2")
        XCTAssertEqual(capability.reasonUnavailable, "administratively disabled")

        do {
            _ = try await adapter.execute(kind: .codex, model: nil, prompt: "must not run", workingDirectory: "/tmp")
            XCTFail("disabled provider unexpectedly executed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .providerUnavailable)
        }
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testProviderPublishesNativeIdentityBeforeProcessCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.fakeCodexAppServerScript(finalTextShell: "done", delayBeforeCompletion: true).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = try PortableProcessSupervisionPort()
        let observer = ProviderIdentityObserver()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: executable.path)], processPort: port, outputDirectory: directory.appendingPathComponent("output").path, ephemeralHomeRoot: directory.appendingPathComponent("homes").path)

        let task = Task {
            try await adapter.execute(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path) { identity in
                await observer.record(identity)
            }
        }
        for _ in 0 ..< 30 {
            if await observer.value() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let observedIdentity = await observer.value()
        XCTAssertEqual(observedIdentity, "22222222-2222-2222-2222-222222222222")
        let result = try await task.value
        XCTAssertEqual(result.output, "done")
    }

    func testProviderVersionProbesUseWritableIsolatedHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          case "$HOME" in
            */repoprompt-provider-probes/openCodeACP) ;;
            *) exit 65 ;;
          esac
          mkdir -p "$HOME/.local/share" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
          printf 'probe' > "$XDG_DATA_HOME/version-probe"
          echo 'fixture 1.0'
          exit 0
        fi
        if [ "$*" != "acp" ]; then exit 64; fi
        while IFS= read -r line; do
          sleep 30
        done
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent("repoprompt-provider-probes/openCodeACP", isDirectory: true)
            )
        }
        let configuration = ProviderCLIConfiguration(kind: .openCodeACP, executable: executable.path, protocolVersion: "acp-v1")
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let adapter = ProviderCLIAdapter(
            configurations: [configuration],
            enabledProviders: [.openCodeACP],
            processPort: try PortableProcessSupervisionPort(),
            processStore: store,
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let settings = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.openCodeACP])

        let clock = ContinuousClock()
        let started = clock.now
        try await settings.bootstrap()
        let catalog = try await settings.catalog(refreshCLI: true, refreshRuntime: false)
        let provider = try XCTUnwrap(catalog.providers.first { $0.providerID == .openCodeACP })
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
        XCTAssertTrue(provider.cli?.healthy == true)
        XCTAssertEqual(provider.cli?.version, "fixture 1.0")
        XCTAssertFalse(provider.preflight.ready)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("repoprompt-provider-probes/openCodeACP/.local/share/version-probe")
                    .path
            )
        )
        try await store.close()
    }

    func testPackagedProviderAuthorityDoesNotLaunchVersionProbe() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = RecordingProviderRunner()
        let configuration = ProviderCLIConfiguration(
            kind: .openCodeACP,
            executable: "/usr/bin/true",
            expectedVersion: "1.2.3",
            protocolVersion: "acp-v1"
        )
        let adapter = ProviderCLIAdapter(
            configurations: [configuration],
            enabledProviders: [.openCodeACP],
            runner: runner
        )
        let settings = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [.openCodeACP],
            runner: runner
        )

        try await settings.bootstrap()
        let initial = try await settings.catalog()
        let initialProvider = try XCTUnwrap(initial.providers.first { $0.providerID == .openCodeACP })
        XCTAssertEqual(initialProvider.cli?.version, "1.2.3")
        XCTAssertTrue(initialProvider.cli?.healthy == true)
        XCTAssertTrue(initialProvider.runtimePreflightVerified)

        let refreshed = try await settings.catalog(refreshCLI: true, refreshRuntime: false)
        let refreshedProvider = try XCTUnwrap(refreshed.providers.first { $0.providerID == .openCodeACP })
        XCTAssertEqual(refreshedProvider.cli?.version, "1.2.3")
        XCTAssertTrue(refreshedProvider.cli?.healthy == true)
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
        try await store.close()
    }

    func testProviderUsesAuthorityRunIDAndRemovesEphemeralCredentialHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        let homes = directory.appendingPathComponent("homes", isDirectory: true)
        let credentials = directory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: credentials.appendingPathComponent("auth.json"))
        try Data(Self.fakeCodexAppServerScript(finalTextShell: "$HOME", version: "provider 1.0").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let port = try PortableProcessSupervisionPort()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: executable.path, expectedVersion: "1.0", credentialSourceDirectory: credentials.path)], processPort: port, processStore: store, outputDirectory: directory.appendingPathComponent("output").path, ephemeralHomeRoot: homes.path)
        let capabilities = await adapter.preflight()
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.enabled, true)
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.version, "1.0")
        let runID = UUID()

        let output = try await adapter.complete(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path, runID: runID)

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), homes.appendingPathComponent(runID.uuidString).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homes.appendingPathComponent(runID.uuidString).path))
        let processFamilyState = try await store.processFamilyState(runID: runID)
        XCTAssertEqual(processFamilyState, "exited")
        let resources = try await store.ownedResources(states: nil)
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerHome })
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerCredentialCopy })
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerOutput })
        XCTAssertTrue(resources.filter { $0.runID == runID }.allSatisfy { $0.lifecycleState == .deleted })
        try await store.close()
    }

    func testManagedCodexAuthIsCopiedIntoIsolatedPerRunHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        let managed = directory.appendingPathComponent("managed-codex", isDirectory: true)
        let processHome = managed.appendingPathComponent("process-home", isDirectory: true)
        let configHome = managed.appendingPathComponent("config", isDirectory: true)
        let cacheHome = managed.appendingPathComponent("cache", isDirectory: true)
        let codexHome = managed.appendingPathComponent("home", isDirectory: true)
        let sqliteHome = managed.appendingPathComponent("sqlite", isDirectory: true)
        let ephemeralHomes = directory.appendingPathComponent("ephemeral-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in [processHome, configHome, cacheHome, codexHome, sqliteHome] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data("keep".utf8).write(to: codexHome.appendingPathComponent("conversation-state"))
        try Data(Self.fakeCodexAppServerScript(finalTextShell: "$CODEX_HOME", version: "provider 1.0").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runID = UUID()
        let source = PersistentProviderRuntimeSource(
            environment: [
                "HOME": processHome.path,
                "XDG_CONFIG_HOME": configHome.path,
                "XDG_CACHE_HOME": cacheHome.path,
                "CODEX_HOME": codexHome.path,
                "CODEX_SQLITE_HOME": sqliteHome.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            sourceDirectory: codexHome.path
        )
        let adapter = ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: executable.path, expectedVersion: "1.0")],
            processPort: try PortableProcessSupervisionPort(),
            processStore: store,
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: ephemeralHomes.path,
            credentialSource: source
        )

        let result = try await adapter.complete(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path, runID: runID)

        let isolatedCodexHome = ephemeralHomes.appendingPathComponent(runID.uuidString).appendingPathComponent(".codex")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), isolatedCodexHome.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("conversation-state").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedCodexHome.path))
        let resources = try await store.ownedResources(states: nil)
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerHome })
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerCredentialCopy })
        try await store.close()
    }

    func testMissingCodexRolloutStartsReplacementThreadWithRepoPromptHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.missingRolloutCodexScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: executable.path)],
            processPort: try PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let fallback = "User:\nfirst question\n\nAssistant:\nfirst answer\n\nUser:\nfollow-up"
        let result = try await adapter.executeStreaming(.init(
            kind: .codex,
            model: nil,
            prompt: "follow-up",
            workingDirectory: directory.path,
            runID: UUID(),
            resumeProviderSessionID: "missing-thread",
            resumeFallbackPrompt: fallback
        )) { _ in }

        XCTAssertEqual(result.providerSessionID, "replacement-thread")
        let log = try Data(contentsOf: directory.appendingPathComponent("fallback-turn.json"))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: log) as? [String: Any])
        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, fallback)
    }

    func testNativePortableProviderMatrixExecutesProtocolContracts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(ProviderKind, String)] = [
            (.claudeCompatible, Self.fakeClaudeScript()),
            (.openCodeACP, Self.fakeACPScript(requiredArguments: "acp")),
            (.cursorACP, Self.fakeACPScript(requiredArguments: "--approve-mcps acp")),
            (.grokBuildACP, Self.fakeACPScript(requiredArguments: "agent --no-leader stdio")),
            (.headlessAdapter, Self.fakeHeadlessAdapterScript()),
            (.mcp, Self.fakeMCPServerScript())
        ]
        let port = try PortableProcessSupervisionPort()
        var configurations: [ProviderCLIConfiguration] = []
        for (kind, script) in fixtures {
            let executable = directory.appendingPathComponent(kind.rawValue)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            configurations.append(.init(kind: kind, executable: executable.path, expectedVersion: "fixture 1.0"))
        }
        let adapter = ProviderCLIAdapter(
            configurations: configurations,
            processPort: port,
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let preflight = await adapter.preflight().filter(\.enabled)
        XCTAssertEqual(Set(preflight.map(\.kind)), Set(fixtures.map(\.0)))

        let expected: [(ProviderKind, String, String?)] = [
            (.claudeCompatible, "claude done", "claude-session"),
            (.openCodeACP, "acp done", "acp-session"),
            (.cursorACP, "acp done", "acp-session"),
            (.grokBuildACP, "acp done", "acp-session"),
            (.headlessAdapter, "headless done", "headless-session"),
            (.mcp, "file_search\nread_file", nil)
        ]
        for (kind, output, identity) in expected {
            let events = ProviderEventRecorder()
            let result = try await adapter.executeStreaming(.init(kind: kind, model: nil, prompt: "contract prompt", workingDirectory: directory.path, runID: UUID())) { event in
                await events.record(event)
            }
            XCTAssertEqual(result.output, output, kind.rawValue)
            XCTAssertEqual(result.providerSessionID, identity, kind.rawValue)
            let observed = await events.values()
            XCTAssertTrue(observed.contains { if case .assistantFinal = $0 { true } else { false } } || observed.contains { if case .assistantDelta = $0 { true } else { false } }, kind.rawValue)
            XCTAssertTrue(observed.contains { if case .completed = $0 { true } else { false } }, kind.rawValue)
        }
    }

    func testGrokBuildFullAccessInsertsAlwaysApproveAfterAgentLikeDesktop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        try Data(Self.fakeACPScript(requiredArguments: "agent --always-approve --no-leader stdio").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .grokBuildACP, executable: executable.path, expectedVersion: "fixture 1.0")],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let result = try await adapter.executeStreaming(.init(
            kind: .grokBuildACP,
            model: nil,
            prompt: "contract prompt",
            workingDirectory: directory.path,
            runID: UUID(),
            policy: .init(mode: .fullAccess)
        )) { _ in }
        XCTAssertEqual(result.providerSessionID, "acp-session")
    }

    func testGrokBuildSelectsModelsThroughSessionSetModelNotConfigOptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        try Data(Self.grokBuildModelScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .grokBuildACP, executable: executable.path, expectedVersion: "fixture 1.0")],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let result = try await adapter.executeStreaming(.init(
            kind: .grokBuildACP,
            model: "grok-code",
            prompt: "contract prompt",
            workingDirectory: directory.path,
            runID: UUID(),
            policy: .init(providerSettings: ["provider.reasoningEffort": "high"])
        )) { _ in }
        XCTAssertEqual(result.providerSessionID, "grok-session")
        let log = try String(contentsOf: directory.appendingPathComponent("grok.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("set_model"), log)
        XCTAssertTrue(log.contains("grok-code"), log)
        XCTAssertTrue(log.contains("reasoningEffort"), log)
        XCTAssertTrue(log.contains("high"), log)
        XCTAssertFalse(log.contains("set_config_option"), log)
    }

    func testPortablePortCapturesAndReapsProviderOutput() async throws {
        let executable = ["/bin/echo", "/usr/bin/echo"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let echo = try XCTUnwrap(executable)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let port = try PortableProcessSupervisionPort()
        let captured = try await port.launchCaptured(executable: echo, arguments: ["provider-output"], environment: [:], workingDirectory: FileManager.default.temporaryDirectory.path, helperToken: UUID().uuidString, outputDirectory: output.path)
        let result = try await port.waitForCapturedProcess(captured, maximumBytes: 1024)
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "provider-output")
        let reaped = try await port.inspect(pid: captured.identity.pid)
        XCTAssertNil(reaped)
    }

    #if os(Linux)
        func testReapWaitsForDelayedAdoptedChild() async throws {
            let port = try PortableProcessSupervisionPort()
            var descriptors = [Int32](repeating: -1, count: 2)
            let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Glibc.pipe(buffer.baseAddress!)
            }
            XCTAssertEqual(pipeResult, 0)
            guard pipeResult == 0 else { return }

            let wrapperPID = fork()
            if wrapperPID == 0 {
                _ = Glibc.close(descriptors[0])
                let childPID = fork()
                if childPID == 0 {
                    usleep(150_000)
                    _exit(0)
                }
                var reportedPID = childPID
                withUnsafeBytes(of: &reportedPID) { bytes in
                    _ = Glibc.write(descriptors[1], bytes.baseAddress, bytes.count)
                }
                _ = Glibc.close(descriptors[1])
                _exit(childPID > 0 ? 0 : 1)
            }
            _ = Glibc.close(descriptors[1])
            guard wrapperPID > 0 else {
                _ = Glibc.close(descriptors[0])
                XCTFail("fork failed")
                return
            }

            var adoptedPID: Int32 = 0
            let readCount = withUnsafeMutableBytes(of: &adoptedPID) { bytes in
                Glibc.read(descriptors[0], bytes.baseAddress, bytes.count)
            }
            _ = Glibc.close(descriptors[0])
            var wrapperStatus: Int32 = 0
            while waitpid(wrapperPID, &wrapperStatus, 0) < 0, errno == EINTR {}
            XCTAssertEqual(readCount, MemoryLayout<Int32>.size)
            guard readCount == MemoryLayout<Int32>.size, adoptedPID > 1 else { return }

            try await port.reap(pid: adoptedPID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: "/proc/\(adoptedPID)"))
        }

        func testReapingTrackedProviderDoesNotConsumeUnrelatedChildStatus() async throws {
            let unrelatedPID = fork()
            if unrelatedPID == 0 {
                _exit(0)
            }
            guard unrelatedPID > 0 else {
                XCTFail("fork failed")
                return
            }
            defer {
                var status: Int32 = 0
                _ = waitpid(unrelatedPID, &status, WNOHANG)
            }

            for _ in 0 ..< 100 {
                guard let stat = try? String(contentsOfFile: "/proc/\(unrelatedPID)/stat", encoding: .utf8) else { break }
                if stat.contains(") Z ") { break }
                try await Task.sleep(for: .milliseconds(10))
            }

            let sleep = try XCTUnwrap(["/bin/sleep", "/usr/bin/sleep"].first { FileManager.default.isExecutableFile(atPath: $0) })
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: output) }
            let port = try PortableProcessSupervisionPort()
            let captured = try await port.launchCaptured(
                executable: sleep,
                arguments: ["0.05"],
                environment: [:],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                helperToken: UUID().uuidString,
                outputDirectory: output.path
            )
            _ = try await port.waitForCapturedProcess(captured, maximumBytes: 1024)

            var unrelatedStatus: Int32 = 0
            XCTAssertEqual(waitpid(unrelatedPID, &unrelatedStatus, WNOHANG), unrelatedPID)
        }

        func testPortableLaunchRecordsPostSetsidProviderIdentity() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let executable = directory.appendingPathComponent("provider")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try """
            #!/bin/sh
            sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let port = try PortableProcessSupervisionPort()
            let identity = try await port.launch(
                executable: executable.path,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectory: directory.path,
                helperToken: UUID().uuidString
            )
            let supervisor = ProviderProcessSupervisor(processPort: port)
            let runID = UUID()
            try await supervisor.register(runID: runID, leader: identity)
            XCTAssertEqual(identity.processGroupID, identity.pid)
            XCTAssertEqual(identity.sessionID, identity.pid)
            XCTAssertNotEqual(URL(fileURLWithPath: identity.executablePath).lastPathComponent, "setsid")

            var providerMembers: [ProcessIdentity] = []
            for _ in 0 ..< 20 where providerMembers.isEmpty {
                providerMembers = try await port.descendants(of: identity.pid)
                if providerMembers.isEmpty {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            XCTAssertFalse(providerMembers.isEmpty)
            XCTAssertTrue(providerMembers.allSatisfy { $0.processGroupID == identity.processGroupID })

            try await supervisor.cancel(runID: runID, graceScans: 1)
            let reaped = try await port.inspect(pid: identity.pid)
            XCTAssertNil(reaped)
            for member in providerMembers {
                let memberInspection = try await port.inspect(pid: member.pid)
                XCTAssertNil(memberInspection)
            }
        }
    #endif

    func testPortableProcessLaunchValidationRejectsBeforeProviderSpawn() async throws {
        let executable = try XCTUnwrap(["/usr/bin/touch", "/bin/touch"].first { FileManager.default.isExecutableFile(atPath: $0) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = directory.appendingPathComponent("provider-started")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = try PortableProcessSupervisionPort()
        do {
            _ = try await port.launchInteractiveCaptured(
                executable: executable,
                arguments: [marker.path],
                environment: [:],
                workingDirectory: directory.path,
                helperToken: UUID().uuidString,
                outputDirectory: directory.appendingPathComponent("output").path,
                launchValidation: {
                    throw ServiceAPIError(code: .rootUnauthorized, message: "launch path changed")
                }
            )
            XCTFail("expected launch validation rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNativeProviderProtocolsReceiveReadOnlyExecutionPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(ProviderKind, String)] = [
            (.codex, Self.policyCodexScript()),
            (.claudeCompatible, Self.policyClaudeScript()),
            (.openCodeACP, Self.policyACPScript()),
            (.headlessAdapter, Self.policyHeadlessScript())
        ]
        var configurations: [ProviderCLIConfiguration] = []
        for (kind, script) in fixtures {
            let executable = directory.appendingPathComponent(kind.rawValue)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            configurations.append(.init(kind: kind, executable: executable.path))
        }
        let adapter = try ProviderCLIAdapter(
            configurations: configurations,
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        for (kind, _) in fixtures {
            _ = try await adapter.executeStreaming(.init(
                kind: kind,
                model: nil,
                prompt: "inspect",
                workingDirectory: directory.path,
                runID: UUID(),
                policy: .init(mode: .readOnly)
            )) { _ in }
        }
        let codex = try String(contentsOf: directory.appendingPathComponent("codex.log"), encoding: .utf8)
        XCTAssertTrue(codex.contains(#""sandbox":"read-only""#))
        XCTAssertTrue(codex.contains(#""type":"readOnly""#))
        let claude = try String(contentsOf: directory.appendingPathComponent("claude.log"), encoding: .utf8)
        XCTAssertTrue(claude.contains("--permission-mode plan"))
        XCTAssertTrue(claude.contains("--disallowedTools Bash,Write,Edit,NotebookEdit"))
        let acp = try String(contentsOf: directory.appendingPathComponent("acp.log"), encoding: .utf8)
        XCTAssertTrue(acp.contains("set_config_option"), acp)
        XCTAssertTrue(acp.contains(#""value":"plan""#), acp)
        let headless = try String(contentsOf: directory.appendingPathComponent("headless.log"), encoding: .utf8)
        XCTAssertTrue(headless.contains(#""mode":"readOnly""#))
        XCTAssertTrue(headless.contains(#""writableRoots":[]"#))
    }

    func testNativeCodexResumeSteerAndApprovalUseOneLiveTransportReader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data(Self.controlCodexScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: executable.path)],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let runID = UUID()
        let events = ProviderEventRecorder()
        let task = Task {
            try await adapter.executeStreaming(.init(
                kind: .codex,
                model: nil,
                prompt: "continue",
                workingDirectory: directory.path,
                runID: runID,
                resumeProviderSessionID: "existing-thread"
            )) { event in
                await events.record(event)
            }
        }
        var interactionObserved = false
        for _ in 0 ..< 100 {
            if await events.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) {
                interactionObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard interactionObserved else {
            _ = try await task.value
            return XCTFail("ACP provider completed without requesting permission")
        }
        let observedInteraction = await events.values().contains(where: {
            if case .interactionRequested = $0 { true } else { false }
        })
        XCTAssertTrue(observedInteraction)
        try await adapter.deliverInteraction(runID: runID, providerRequestID: "99", answer: Data(#"{"decision":"accept"}"#.utf8))
        try await adapter.steer(runID: runID, text: "steer now", targetTurnEpoch: 1)
        let result = try await task.value

        XCTAssertEqual(result.providerSessionID, "existing-thread")
        XCTAssertEqual(result.output, "steered done")
        let log = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#"thread\/resume"#), log)
        XCTAssertTrue(log.contains(#"turn\/steer"#), log)
        XCTAssertTrue(log.contains(#""id":99"#), log)
        XCTAssertTrue(log.contains(#""decision":"accept""#), log)

        let interruptedRunID = UUID()
        let interruptedEvents = ProviderEventRecorder()
        let interrupted = Task {
            try await adapter.executeStreaming(.init(
                kind: .codex,
                model: nil,
                prompt: "interrupt",
                workingDirectory: directory.path,
                runID: interruptedRunID,
                resumeProviderSessionID: "existing-thread"
            )) { event in
                await interruptedEvents.record(event)
            }
        }
        for _ in 0 ..< 100 {
            if await interruptedEvents.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await adapter.cancel(runID: interruptedRunID)
        do {
            _ = try await interrupted.value
            XCTFail("Interrupted native Codex run unexpectedly completed")
        } catch {}
        let interruptedLog = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(interruptedLog.contains(#"turn\/interrupt"#), interruptedLog)
    }

    func testNativeCodexProjectsDesktopToolNamesWebActionsAndHonestTerminalStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data(Self.toolLifecycleCodexScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: executable.path)],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let events = ProviderEventRecorder()

        let result = try await adapter.executeStreaming(.init(
            kind: .codex,
            model: nil,
            prompt: "show tool activity",
            workingDirectory: directory.path,
            runID: UUID()
        )) { event in
            await events.record(event)
        }

        XCTAssertEqual(result.output, "done")
        let observed = await events.values()
        var commandStarted = false
        var commandFailed = false
        var uncertainCommandWarned = false
        var webStarted = false
        var webCompleted = false
        for event in observed {
            switch event {
            case let .toolStarted(providerToolID, name, arguments) where providerToolID == "command-startup":
                commandStarted = name == "bash" && String(decoding: arguments ?? Data(), as: UTF8.self).contains(#""command":"pwd""#)
            case let .toolCompleted(providerToolID, name, output, status) where providerToolID == "command-startup":
                commandFailed = name == "bash" && status == .failed && output?.contains(#""status":"failed""#) == true
            case let .toolCompleted(providerToolID, name, _, status) where providerToolID == "command-unknown":
                uncertainCommandWarned = name == "bash" && status == .warning
            case let .toolStarted(providerToolID, name, arguments) where providerToolID == "web-open":
                let payload = arguments.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                webStarted = name == "search" && payload?["action"] == "open_page" && payload?["url"] == "https://example.com"
            case let .toolCompleted(providerToolID, name, output, status) where providerToolID == "web-open":
                let payload = output.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
                webCompleted = name == "search" && status == .success && payload?["action"] == "open_page"
            default:
                break
            }
        }
        XCTAssertTrue(commandStarted)
        XCTAssertTrue(commandFailed)
        XCTAssertTrue(uncertainCommandWarned)
        XCTAssertTrue(webStarted)
        XCTAssertTrue(webCompleted)
    }

    func testNativeACPResumeSteerAndApprovalFenceTheLatestPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        try Data(Self.controlACPScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .openCodeACP, executable: executable.path)],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let runID = UUID()
        let events = ProviderEventRecorder()
        let task = Task {
            try await adapter.executeStreaming(.init(
                kind: .openCodeACP,
                model: nil,
                prompt: "continue",
                workingDirectory: directory.path,
                runID: runID,
                resumeProviderSessionID: "existing-acp"
            )) { event in
                await events.record(event)
            }
        }
        var interactionObserved = false
        for _ in 0 ..< 100 {
            if await events.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) {
                interactionObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard interactionObserved else {
            _ = try await task.value
            return XCTFail("ACP provider completed without requesting permission")
        }
        try await adapter.deliverInteraction(runID: runID, providerRequestID: "50", answer: Data(#"{"optionId":"allow"}"#.utf8))
        try await adapter.steer(runID: runID, text: "replacement", targetTurnEpoch: 2)
        let result = try await task.value

        XCTAssertEqual(result.providerSessionID, "existing-acp")
        XCTAssertEqual(result.output, "replacement done")
        let log = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#"session\/load"#), log)
        XCTAssertTrue(log.contains(#"session\/cancel"#), log)
        XCTAssertTrue(log.contains(#""id":50"#), log)
        XCTAssertTrue(log.contains(#""optionId":"allow""#), log)
    }

    func testProcStatParserHandlesSpacesAndParenthesesInCommand() {
        let fields = ["S", "1", "42", "42"] + Array(repeating: "0", count: 15) + ["987654"]
        let line = "123 (provider worker (sandbox)) " + fields.joined(separator: " ")
        let stat = ProcStatParser.parse(line)
        XCTAssertEqual(stat?.pid, 123)
        XCTAssertEqual(stat?.parentPID, 1)
        XCTAssertEqual(stat?.processGroupID, 42)
        XCTAssertEqual(stat?.sessionID, 42)
        XCTAssertEqual(stat?.startTimeTicks, 987_654)
    }

    func testCancellationUsesTermThenVerifiedKillAndReap() async throws {
        let leader = ProcessIdentity(pid: 100, parentPID: 1, processGroupID: 100, sessionID: 100, startTimeTicks: 10, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let child = ProcessIdentity(pid: 101, parentPID: 100, processGroupID: 100, sessionID: 100, startTimeTicks: 11, bootID: "boot", executablePath: "/helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [child])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped.sorted(), [100, 101])
    }

    func testCancellationFindsLateForkDuringGraceWindow() async throws {
        let leader = ProcessIdentity(pid: 200, parentPID: 1, processGroupID: 200, sessionID: 200, startTimeTicks: 20, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let late = ProcessIdentity(pid: 201, parentPID: 200, processGroupID: 200, sessionID: 200, startTimeTicks: 21, bootID: "boot", executablePath: "/late-helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [], lateChildren: [late])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped.sorted(), [200, 201])
    }

    func testCancellationAcceptsReparentedOrExecedSameProcessInstance() async throws {
        let leader = ProcessIdentity(pid: 205, parentPID: 1, processGroupID: 205, sessionID: 205, startTimeTicks: 20, bootID: "boot", executablePath: "/bin/sh", helperTokenDigest: "token")
        let observed = ProcessIdentity(pid: 205, parentPID: 99, processGroupID: 205, sessionID: 205, startTimeTicks: 20, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [], inspectedLeader: observed)
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped, [205])
    }

    func testCancellationSignalsVerifiedDescendantThatEscapedLeaderProcessGroup() async throws {
        let leader = ProcessIdentity(pid: 210, parentPID: 1, processGroupID: 210, sessionID: 210, startTimeTicks: 20, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let escaped = ProcessIdentity(pid: 211, parentPID: 210, processGroupID: 211, sessionID: 211, startTimeTicks: 21, bootID: "boot", executablePath: "/escaped-helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [escaped])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.processGroups.sorted(), [210, 210, 211, 211])
        XCTAssertEqual(result.reaped.sorted(), [210, 211])
    }

    func testPersistedFamilyIsReconciledAfterSupervisorRestart() async throws {
        let leader = ProcessIdentity(pid: 300, parentPID: 1, processGroupID: 300, sessionID: 300, startTimeTicks: 30, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let child = ProcessIdentity(pid: 301, parentPID: 300, processGroupID: 300, sessionID: 300, startTimeTicks: 31, bootID: "boot", executablePath: "/helper", helperTokenDigest: "token")
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let port = FakeProcessPort(leader: leader, children: [child])
        let initial = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock(), store: store)
        let runID = UUID()
        try await initial.register(runID: runID, leader: leader, connectionGeneration: 7)
        let activeBeforeRecovery = try await store.activeProcessFamilies()
        XCTAssertEqual(activeBeforeRecovery.map(\.runID), [runID])
        XCTAssertEqual(activeBeforeRecovery.first?.containmentMode, "cgroup-v2")

        let recovered = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock(), store: store)
        try await recovered.recoverPersistedFamilies()

        let activeAfterRecovery = try await store.activeProcessFamilies()
        XCTAssertTrue(activeAfterRecovery.isEmpty)
        let result = await port.result()
        XCTAssertEqual(result.reaped.sorted(), [300, 301])
        XCTAssertEqual(result.reconstructed.count, 1)
        XCTAssertEqual(result.reconstructed.first?.0, leader)
        XCTAssertEqual(result.reconstructed.first?.1, "cgroup-v2")
        try await store.close()
    }

    private static func fakeCodexAppServerScript(finalTextShell: String, version: String = "provider 1.0", delayBeforeCompletion: Bool = false) -> String {
        let delay = delayBeforeCompletion ? "sleep 1" : ":"
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '\(version)'; exit 0; fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*start*|*method*thread*resume*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"22222222-2222-2222-2222-222222222222"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}'
              \(delay)
              printf '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"%s"}}}\n' "\(finalTextShell)"
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1"}}}'
              ;;
          esac
        done
        """
    }

    private static func toolLifecycleCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*start*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"tool-thread"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"tool-turn"}}}'
              echo '{"jsonrpc":"2.0","method":"item/started","params":{"item":{"id":"command-startup","type":"commandExecution","command":"pwd","status":"inProgress","source":"unifiedExecStartup"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"command-startup","type":"commandExecution","command":"pwd","status":"inProgress","source":"unifiedExecStartup","aggregatedOutput":"bwrap: No permissions to create a new namespace"}}}'
              echo '{"jsonrpc":"2.0","method":"item/started","params":{"item":{"id":"command-unknown","type":"commandExecution","command":"printf ok","status":"inProgress","source":"agent"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"command-unknown","type":"commandExecution","command":"printf ok","status":"inProgress","source":"agent","aggregatedOutput":"ok"}}}'
              echo '{"jsonrpc":"2.0","method":"item/started","params":{"item":{"id":"web-open","type":"webSearch","action":{"type":"openPage","url":"https://example.com"}}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"web-open","type":"webSearch","status":"completed","action":{"type":"openPage","url":"https://example.com"},"title":"Example Domain"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"tool-turn"}}}' ;;
          esac
        done
        """
    }

    private static func missingRolloutCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*resume*) echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"no rollout found for thread id missing-thread"}}' ;;
            *method*thread*start*) echo '{"jsonrpc":"2.0","id":3,"result":{"thread":{"id":"replacement-thread"}}}' ;;
            *method*turn*start*)
              printf '%s' "$line" > "$PWD/fallback-turn.json"
              echo '{"jsonrpc":"2.0","id":4,"result":{"turn":{"id":"replacement-turn"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"replacement-turn"}}}'
              ;;
          esac
        done
        """
    }

    private static func fakeClaudeScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        while IFS= read -r line; do
          echo '{"type":"assistant","session_id":"claude-session","message":{"content":[{"type":"thinking","thinking":"reason"},{"type":"text","text":"claude done"}]}}'
          echo '{"type":"result","session_id":"claude-session","result":"claude done"}'
          break
        done
        """
    }

    private static func fakeACPScript(requiredArguments: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$*" != "\(requiredArguments)" ]; then exit 64; fi
        while IFS= read -r line; do
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*new*) echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-session"}}' ;;
            *session*prompt*)
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"reason"}}}}'
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"acp done"}}}}'
              echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
              ;;
          esac
        done
        """
    }

    private static func grokBuildModelScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$*" != "agent --no-leader stdio" ]; then exit 64; fi
        while IFS= read -r line; do
          echo "$line" >> "$PWD/grok.log"
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*new*) echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"grok-session","models":{"currentModelId":"grok-default","availableModels":[{"modelId":"grok-code","name":"Grok Code"}]},"configOptions":[{"id":"model","category":"model","currentValue":"wrong","options":[{"value":"wrong"}]}]}}' ;;
            *session*set_model*) echo '{"jsonrpc":"2.0","id":3,"result":{"_meta":{"model":{"Ok":"grok-code"}}}}' ;;
            *session*set_config_option*) echo '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"model","category":"model","currentValue":"wrong","options":[{"value":"wrong"}]}]}}' ;;
            *session*prompt*)
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"grok done"}}}}'
              echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}' ;;
          esac
        done
        """
    }

    private static func fakeHeadlessAdapterScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$1" != "--headless-provider-json" ]; then exit 64; fi
        while IFS= read -r line; do
          echo '{"type":"reasoning","content":"reason"}'
          echo '{"type":"toolCall","id":"tool-1","name":"read_file","args":{"path":"A.swift"}}'
          echo '{"type":"toolResult","id":"tool-1","name":"read_file","result":"ok","failed":false}'
          echo '{"type":"finalMessage","content":"headless done"}'
          echo '{"type":"completion","providerSessionID":"headless-session"}'
          break
        done
        """
    }

    private static func fakeMCPServerScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$#" -ne 0 ]; then exit 64; fi
        while IFS= read -r line; do
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}' ;;
            *tools*list*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file"},{"name":"file_search"}]}}' ;;
          esac
        done
        """
    }

    private static func policyCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/codex.log"
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*start*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"policy-thread"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1"}}}' ;;
          esac
        done
        """
    }

    private static func policyClaudeScript() -> String {
        """
        #!/bin/sh
        echo "$*" > "$PWD/claude.log"
        while IFS= read -r line; do
          echo '{"type":"result","session_id":"claude-policy","result":"done"}'
          break
        done
        """
    }

    private static func policyACPScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/acp.log"
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*new*) echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-policy","configOptions":[{"id":"mode","category":"mode","currentValue":"build","options":[{"value":"plan"},{"value":"build"}]}]}}' ;;
            *session*set_config_option*) echo '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"mode","category":"mode","currentValue":"plan","options":[{"value":"plan"},{"value":"build"}]}]}}' ;;
            *session*prompt*)
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"done"}}}}'
              echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}' ;;
          esac
        done
        """
    }

    private static func policyHeadlessScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" > "$PWD/headless.log"
          echo '{"type":"finalMessage","content":"done"}'
          echo '{"type":"completion","providerSessionID":"headless-policy"}'
          break
        done
        """
    }

    private static func controlCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/control.log"
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*resume*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"existing-thread"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-control"}}}'
              echo '{"jsonrpc":"2.0","id":99,"method":"item/commandExecution/requestApproval","params":{"reason":"approve control"}}' ;;
            *method*turn*steer*)
              echo '{"jsonrpc":"2.0","id":4,"result":{}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-control","type":"agentMessage","text":"steered done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-control"}}}' ;;
          esac
        done
        """
    }

    private static func controlACPScript() -> String {
        """
        #!/bin/sh
        prompts=0
        while IFS= read -r line; do
          echo "$line" >> "$PWD/control.log"
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*load*) echo '{"jsonrpc":"2.0","id":2,"result":{}}' ;;
            *session*prompt*)
              prompts=$((prompts + 1))
              if [ "$prompts" -eq 1 ]; then
                echo '{"jsonrpc":"2.0","id":50,"method":"session/request_permission","params":{"toolCall":{"title":"approve acp"},"options":[{"optionId":"allow"},{"optionId":"deny"}]}}'
              else
                echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"replacement done"}}}}'
                echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
              fi ;;
          esac
        done
        """
    }
}

private actor RecordingProviderRunner: WorkspaceCommandRunning {
    private var arguments: [[String]] = []

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        self.arguments.append(arguments)
        return """
        {"type":"thread.started","thread_id":"11111111-1111-1111-1111-111111111111"}
        {"type":"item.completed","item":{"type":"agent_message","text":"done"}}
        """
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        maximumBytes: Int,
        launchValidation: @escaping @Sendable () throws -> Void,
        launchAcknowledgement: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try launchValidation()
        try await launchAcknowledgement()
        return try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maximumBytes: maximumBytes
        )
    }

    func calls() -> [[String]] {
        arguments
    }
}

private actor ProviderIdentityObserver {
    private var identity: String?

    func record(_ value: String) {
        identity = value
    }

    func value() -> String? {
        identity
    }
}

private actor ProviderEventRecorder {
    private var events: [ProviderRuntimeEvent] = []

    func record(_ event: ProviderRuntimeEvent) {
        events.append(event)
    }

    func values() -> [ProviderRuntimeEvent] {
        events
    }
}

private struct PersistentProviderRuntimeSource: ProviderCredentialSourceProviding {
    let environment: [String: String]
    let sourceDirectory: String?

    init(environment: [String: String], sourceDirectory: String? = nil) {
        self.environment = environment
        self.sourceDirectory = sourceDirectory
    }

    func sourceDirectory(for _: ProviderKind) async throws -> String? { sourceDirectory }

    func persistentRuntimeEnvironment(for kind: ProviderKind) async throws -> [String: String]? {
        kind == .codex ? environment : nil
    }
}
