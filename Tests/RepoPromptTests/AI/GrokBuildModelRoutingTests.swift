import Darwin
import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptSecureStorage
import RepoPromptShared
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

private actor OneShotFilteringPolicyWitness {
    private(set) var queryCount = 0

    func removedNames() -> Set<String> {
        queryCount += 1
        // A second policy lookup would allow the custom root again.
        return queryCount == 1 ? ["GROK_HOME", "GROK_STORAGE_MODE"] : []
    }
}

final class GrokBuildModelRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentModelCatalogRuntime.shared.acpRegistry.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentModelCatalogRuntime.shared.acpRegistry.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testModelIdentityRoundTripsToGrokBuildProvider() {
        let model = AIModel.grokBuildCustom(name: "grok-4.6-high")

        XCTAssertEqual(model.rawValue, "grokbuild_custom_grok-4.6-high")
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
        XCTAssertEqual(model.modelName, "grok-4.6-high")
        XCTAssertEqual(model.providerType, .grokBuild)
        XCTAssertEqual(AIProviderType.displayName(for: model.providerType), "Grok Build")
        XCTAssertEqual(ObjectIdentifier(model.provider), ObjectIdentifier(GrokBuildCLIProvider.self))
    }

    func testCatalogUsesDefaultAndDiscoveredGrokBuildModels() {
        XCTAssertEqual(
            AIModel.modelsForProvider(.grokBuild),
            [.grokBuildCustom(name: AgentModel.defaultModel.rawValue)]
        )

        _ = AgentModelCatalogRuntime.shared.acpRegistry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "grok-4.6",
                        displayName: "Grok 4.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: "grok-4.6"
            ),
            for: .grokBuild
        )

        let models = AIModel.modelsForProvider(.grokBuild)
        XCTAssertEqual(Set(models), [
            .grokBuildCustom(name: AgentModel.defaultModel.rawValue),
            .grokBuildCustom(name: "grok-4.6")
        ])
        XCTAssertEqual(
            models.first { $0.modelName == "grok-4.6" }?.displayName,
            "Grok 4.6"
        )
    }

    func testFactoryCreatesGrokBuildProviderWithoutStoredAPIKey() async throws {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )

        let provider = try await AIProviderFactory.createProvider(
            for: .grokBuild,
            keyManager: keyManager
        )
        XCTAssertTrue(provider is GrokBuildCLIProvider)
        await provider.dispose()
    }

    func testNonAgentAdapterDisablesRepoPromptToolsAndPreservesModel() {
        let config = GrokBuildCLIProvider.test_makeHeadlessConfig(modelName: "grok-4.6")
        let message = GrokBuildCLIProvider.test_makeAgentMessage(
            from: AIMessage(systemPrompt: "", userMessage: "Hello")
        )

        XCTAssertEqual(config.modelString, "grok-4.6")
        XCTAssertFalse(config.includeRepoPromptMCPServer)
        XCTAssertFalse(config.alwaysApproveTools)
        XCTAssertTrue(message.systemPrompt.contains("Do not use any tools"))
    }

    func testOneShotCancellationRemovesSessionAfterChildStopsWriting() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        let neighbor = grokHome.appendingPathComponent("sessions/neighbor/prompt_history.jsonl")
        try writeOneShotFixture("neighbor prompt", to: neighbor)
        let provider = try makeSyntheticOneShotProvider(root: root)
        let readyFIFO = root.appendingPathComponent("ready.fifo")
        XCTAssertEqual(mkfifo(readyFIFO.path, 0o600), 0)
        let readyHandle = try FileHandle(forUpdating: readyFIFO)
        defer {
            readyHandle.readabilityHandler = nil
            try? readyHandle.close()
        }
        let ready = expectation(description: "Synthetic Grok has written the request session")
        readyHandle.readabilityHandler = { handle in
            _ = handle.availableData
            handle.readabilityHandler = nil
            ready.fulfill()
        }
        // The provider task inherits this fixture-only opt-in for both its support probe and request.
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let stream = try await provider.streamAgentMessage(
                AgentMessage(systemPrompt: "fixture system", userMessage: "fixture prompt")
            )
            let consumer = Task {
                for try await _ in stream {}
            }
            await fulfillment(of: [ready], timeout: 10)
            await provider.dispose()
            switch await consumer.result {
            case .success:
                XCTFail("Expected request cancellation")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "Cancellation must remain the primary error: \(error)")
            }
        }

        let ownedPath = try String(contentsOf: root.appendingPathComponent("session-path"), encoding: .utf8)
        let requestCWD = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("child-stopped"), encoding: .utf8), "stopped")
        let expectedName = encodedOneShotCWD(requestCWD)
        XCTAssertLessThanOrEqual(expectedName.utf8.count, 255)
        XCTAssertEqual(URL(fileURLWithPath: ownedPath).lastPathComponent, expectedName, "Fixture must use Grok's cwd encoding")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPath), "The whole request-owned session must be removed after the child's final write; stored=\(ownedPath), cwd=\(requestCWD)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestCWD))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "neighbor prompt")
    }

    func testOneShotSuccessAppliesIsolationPolicyParsesCompletionAndRemovesEntireSession() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let neighbor = root.appendingPathComponent("grok-home/sessions/neighbor/prompt_history.jsonl")
        try writeOneShotFixture("neighbor prompt", to: neighbor)
        let provider = try makeSyntheticOneShotProvider(root: root, mode: "success")
        var results: [AIStreamResult] = []

        // The same fixture-only opt-in covers both the probe and the actual request.
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let stream = try await provider.streamAgentMessage(
                AgentMessage(systemPrompt: "fixture system", userMessage: "fixture prompt")
            )
            for try await result in stream {
                results.append(result)
            }
        }
        await provider.dispose()

        XCTAssertEqual(results.map(\.type), ["reasoning", "content", "message_stop"])
        XCTAssertEqual(results.first?.reasoning, "fixture reasoning")
        XCTAssertEqual(results.dropFirst().first?.text, "fixture completion")
        let terminal = try XCTUnwrap(results.last)
        XCTAssertEqual(terminal.stopReason, "end_turn")
        XCTAssertEqual(terminal.providerSessionID, "fixture-session")
        XCTAssertEqual(terminal.promptTokens, 11)
        XCTAssertEqual(terminal.completionTokens, 7)
        XCTAssertEqual(terminal.cost, 0.25)
        let launchPolicy = try String(contentsOf: root.appendingPathComponent("launch-policy"), encoding: .utf8)
        XCTAssertEqual(launchPolicy, [
            "GROK_CLAUDE_MCPS_ENABLED=0",
            "GROK_CURSOR_MCPS_ENABLED=0",
            "GROK_CLAUDE_HOOKS_ENABLED=0",
            "GROK_CURSOR_HOOKS_ENABLED=0",
            "GROK_SESSION_SEARCH=0",
            "GROK_STORAGE_MODE=local"
        ].joined(separator: "\n") + "\n", "The request child must receive one-shot overrides, not inherited isolation policy")
        let ownedPath = try String(contentsOf: root.appendingPathComponent("session-path"), encoding: .utf8)
        let requestCWD = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPath), "Remove all artifacts, including opaque attachments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestCWD))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "neighbor prompt")
    }

    func testOneShotWithheldGrokHomeUsesOneSnapshotForChildAndCleanup() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultHome = root.appendingPathComponent("home/.grok", isDirectory: true)
        let neighbor = defaultHome.appendingPathComponent("sessions/neighbor/prompt_history.jsonl")
        let customNeighbor = root.appendingPathComponent("grok-home/sessions/neighbor/prompt_history.jsonl")
        try writeOneShotFixture("default neighbor", to: neighbor)
        try writeOneShotFixture("custom neighbor", to: customNeighbor)
        let policy = OneShotFilteringPolicyWitness()
        let provider = try makeSyntheticOneShotProvider(
            root: root,
            mode: "success",
            removedNamesProvider: { provider in
                XCTAssertEqual(provider, AgentProviderKind.grokBuild.rawValue)
                return await policy.removedNames()
            }
        )
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let stream = try await provider.streamAgentMessage(
                AgentMessage(systemPrompt: "fixture system", userMessage: "fixture prompt")
            )
            for try await _ in stream {}
        }
        await provider.dispose()

        let ownedPath = try String(contentsOf: root.appendingPathComponent("session-path"), encoding: .utf8)
        let requestCWD = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
        let expectedOwned = defaultHome.appendingPathComponent("sessions/\(encodedOneShotCWD(requestCWD))")
        XCTAssertEqual(ownedPath, expectedOwned.path, "The child must not recover copied ambient GROK_HOME")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPath), "Cleanup must select the child's filtered storage root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestCWD))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "default neighbor")
        XCTAssertEqual(try String(contentsOf: customNeighbor, encoding: .utf8), "custom neighbor")
        let queryCount = await policy.queryCount
        XCTAssertEqual(queryCount, 1, "Do not re-read a changed policy between cleanup capture and child launch")
        let launchPolicy = try String(contentsOf: root.appendingPathComponent("launch-policy"), encoding: .utf8)
        XCTAssertTrue(launchPolicy.contains("GROK_STORAGE_MODE=local\n"), "Explicit isolation overrides survive ambient withholding")
    }

    func testOneShotProcessFailureAndTimeoutCleanUpWithoutReplacingError() async throws {
        for mode in ["failure", "timeout"] {
            let root = try makeOneShotFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let neighbor = root.appendingPathComponent("grok-home/sessions/neighbor/prompt_history.jsonl")
            try writeOneShotFixture("neighbor prompt", to: neighbor)
            let provider = try makeSyntheticOneShotProvider(root: root, mode: mode, requestTimeout: 1)

            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                do {
                    let stream = try await provider.streamAgentMessage(
                        AgentMessage(systemPrompt: "fixture system", userMessage: "fixture prompt")
                    )
                    for try await _ in stream {}
                    XCTFail("Expected \(mode) error")
                } catch let AIProviderError.apiError(source) {
                    let error = try XCTUnwrap(source) as NSError
                    XCTAssertEqual(error.domain, "GrokBuildCLI", mode)
                    if mode == "failure" {
                        XCTAssertEqual(error.code, 7)
                        XCTAssertEqual(error.localizedDescription, "fixture primary failure")
                    } else {
                        XCTAssertEqual(error.localizedDescription, "Grok Build timed out after 1s.")
                    }
                } catch {
                    XCTFail("Original \(mode) error must remain primary, got \(error)")
                }
            }
            await provider.dispose()

            let ownedPath = try String(contentsOf: root.appendingPathComponent("session-path"), encoding: .utf8)
            let requestCWD = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPath), mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: requestCWD), mode)
            XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "neighbor prompt", mode)
            if mode == "timeout" {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("child-stopped"), encoding: .utf8), "stopped")
            }
        }
    }

    private func makeSyntheticOneShotProvider(
        root: URL,
        mode: String = "cancel",
        requestTimeout: TimeInterval = 30,
        modelString: String? = nil,
        removedNamesProvider: ProviderEnvironmentFiltering.RemovedNamesProvider? = nil
    ) throws -> GrokBuildOneShotHeadlessAgentProvider {
        let executable = root.appendingPathComponent("grok")
        let script = #"""
        #!/bin/sh
        if [ "$1" = agent ] && [ "$2" = --help ]; then
            printf 'stdio\n'
            exit 0
        fi
        printf '%s\n' "$@" > "$RPCE_FIXTURE_ROOT/args"
        printf '%s\n' \
            "GROK_CLAUDE_MCPS_ENABLED=$GROK_CLAUDE_MCPS_ENABLED" \
            "GROK_CURSOR_MCPS_ENABLED=$GROK_CURSOR_MCPS_ENABLED" \
            "GROK_CLAUDE_HOOKS_ENABLED=$GROK_CLAUDE_HOOKS_ENABLED" \
            "GROK_CURSOR_HOOKS_ENABLED=$GROK_CURSOR_HOOKS_ENABLED" \
            "GROK_SESSION_SEARCH=$GROK_SESSION_SEARCH" \
            "GROK_STORAGE_MODE=$GROK_STORAGE_MODE" > "$RPCE_FIXTURE_ROOT/launch-policy"
        cwd=$(/bin/pwd -P)
        encoded=$(printf '%s' "$cwd" | /usr/bin/od -An -v -t x1 | /usr/bin/awk '
            {
                for (i = 1; i <= NF; i++) {
                    hex = "0123456789abcdef"
                    byte = (index(hex, substr($i, 1, 1)) - 1) * 16 + index(hex, substr($i, 2, 1)) - 1
                    if ((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                        (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95 || byte == 126)
                        printf "%c", byte
                    else
                        printf "%%%s", toupper($i)
                }
            }')
        grok_home=${GROK_HOME:-$HOME/.grok}
        session="$grok_home/sessions/$encoded"
        /bin/mkdir -p "$session/session-id/attachments"
        printf '%s' "$cwd" > "$session/.cwd"
        /bin/cat prompt.txt > "$session/prompt_history.jsonl"
        /bin/cat prompt.txt > "$session/session-id/system_prompt.txt"
        printf 'opaque artifact' > "$session/session-id/attachments/opaque.txt"
        printf '%s' "$cwd" > "$RPCE_FIXTURE_ROOT/request-cwd"
        printf '%s' "$session" > "$RPCE_FIXTURE_ROOT/session-path"
        if [ "$RPCE_FIXTURE_MODE" = success ]; then
            printf '%s\n' '{"text":"fixture completion","thought":"fixture reasoning","stopReason":"end_turn","sessionId":"fixture-session","usage":{"input_tokens":11,"output_tokens":7},"total_cost_usd":0.25}'
            exit 0
        fi
        if [ "$RPCE_FIXTURE_MODE" = failure ]; then
            printf '%s\n' '{"type":"error","message":"fixture primary failure"}'
            printf 'secondary stderr diagnostic\n' >&2
            exit 7
        fi
        trap 'printf "last write" > "$session/session-id/final-write" && printf "stopped" > "$RPCE_FIXTURE_ROOT/child-stopped"; exit 0' TERM
        exec 3<> "$RPCE_FIXTURE_ROOT/hold.fifo"
        if [ "$RPCE_FIXTURE_MODE" = cancel ]; then
            printf 'ready\n' > "$RPCE_FIXTURE_ROOT/ready.fifo"
        fi
        while :; do
            read -r release <&3
        done
        """#
        let holdFIFO = root.appendingPathComponent("hold.fifo")
        guard mkfifo(holdFIFO.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "GROK_HOME": root.appendingPathComponent("grok-home", isDirectory: true).path,
            "GROK_CLAUDE_MCPS_ENABLED": "1",
            "GROK_CURSOR_MCPS_ENABLED": "1",
            "GROK_CLAUDE_HOOKS_ENABLED": "1",
            "GROK_CURSOR_HOOKS_ENABLED": "1",
            "GROK_SESSION_SEARCH": "1",
            "GROK_STORAGE_MODE": "writeback",
            "RPCE_FIXTURE_ROOT": root.path,
            "RPCE_FIXTURE_MODE": mode
        ]
        return GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildAgentConfig(
                commandName: executable.path,
                modelString: modelString,
                includeRepoPromptMCPServer: false
            ),
            launchResolver: GrokBuildACPLaunchResolver(environmentProvider: { _ in environment }),
            requestTimeout: requestTimeout,
            apiKeyProvider: { nil },
            removedNamesProvider: removedNamesProvider
        )
    }

    private func makeOneShotFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokOneShotCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func resolvedOneShotCWD(_ directory: URL) throws -> String {
        guard let path = realpath(directory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return String(cString: path)
    }

    private func encodedOneShotCWD(_ cwd: String) -> String {
        cwd.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    private func makeStoredOneShotSession(at directory: URL) throws {
        try writeOneShotFixture("fixture prompt", to: directory.appendingPathComponent("prompt_history.jsonl"))
        try writeOneShotFixture("fixture system", to: directory.appendingPathComponent("session-id/system_prompt.txt"))
        try writeOneShotFixture("opaque artifact", to: directory.appendingPathComponent("session-id/attachments/opaque.txt"))
    }

    private func writeOneShotFixture(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testOneShotRejectsImagesBeforeLaunchWithoutLeakingPayload() async {
        let launchAttempts = LaunchAttemptCounter()
        let provider = GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildCLIProvider.test_makeHeadlessConfig(modelName: nil),
            launchResolver: GrokBuildACPLaunchResolver(environmentProvider: { _ in
                launchAttempts.record()
                return [:]
            }),
            apiKeyProvider: {
                launchAttempts.record()
                return nil
            }
        )
        let message = AgentMessage(
            systemPrompt: "system",
            userMessage: "inspect",
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Secret Diagram")
            ]
        )

        do {
            _ = try await provider.streamAgentMessage(message)
            XCTFail("Expected Grok Build image rejection")
        } catch let error as AttachmentAdmissionError {
            let detail = error.localizedDescription
            XCTAssertTrue(detail.contains("image.png"), detail)
            XCTAssertTrue(detail.contains("Grok Build cannot carry an image attachment"), detail)
            XCTAssertFalse(detail.contains("AQID"), detail)
            XCTAssertFalse(detail.contains("Secret Diagram"), detail)
        } catch {
            XCTFail("Expected AttachmentAdmissionError, got \(error)")
        }
        XCTAssertEqual(launchAttempts.count, 0, "Refusal must precede launch resolution and credential lookup")
    }

    private final class LaunchAttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0

        var count: Int {
            lock.withLock { attempts }
        }

        func record() {
            lock.withLock { attempts += 1 }
        }
    }

    @MainActor
    func testDropdownDisplaysGrokBuildCatalogName() {
        let model = AIModel.grokBuildCustom(name: "grok-4.6")
        _ = AgentModelCatalogRuntime.shared.acpRegistry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: model.modelName,
                        displayName: "Grok 4.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: model.modelName
            ),
            for: .grokBuild
        )

        XCTAssertEqual(
            AIModelDropdown.displayName(
                forRawValue: model.rawValue,
                destinationID: "planningModel",
                availableModels: [model],
                customOpenRouterModels: []
            ),
            "Grok 4.6"
        )
    }

    /// A cold registry admits a saved effort variant and sends its recorded base and effort.
    func testOneShotAdmitsSavedCatalogModelBeforeRegistryWarms() async throws {
        let base = AgentModelOption(
            rawValue: "grok-4.7-build-fast",
            displayName: "Grok 4.7 Build Fast",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: [.high, .xhigh],
            defaultReasoningEffort: .high
        )
        let variant = AgentModelOption(
            rawValue: "grok-4.7-build-fast-xhigh",
            displayName: "Grok 4.7 Build Fast Extra High",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(baseModelRaw: base.rawValue, reasoningEffort: .xhigh)
        )
        let registry = AgentModelCatalogRuntime.shared.acpRegistry
        XCTAssertTrue(registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: [base, variant], currentModelRaw: base.rawValue),
            for: .grokBuild
        ))
        registry.test_clearMemoryPreservingStore(providerID: .grokBuild)
        XCTAssertNil(registry.resolvedSnapshot(for: .grokBuild), "Precondition: the registry is cold")

        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try makeSyntheticOneShotProvider(root: root, mode: "success", modelString: variant.rawValue)
        var results: [AIStreamResult] = []
        try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            let stream = try await provider.streamAgentMessage(
                AgentMessage(systemPrompt: "fixture system", userMessage: "fixture prompt")
            )
            for try await result in stream {
                results.append(result)
            }
        }
        await provider.dispose()

        XCTAssertEqual(results.last?.type, "message_stop", "The saved-catalog request completes")
        let arguments = try String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for (flag, value) in [("-m", base.rawValue), ("--reasoning-effort", "xhigh")] {
            XCTAssertTrue(
                zip(arguments, arguments.dropFirst()).contains { $0.0 == flag && $0.1 == value },
                "Expected adjacent \(flag) \(value) arguments"
            )
        }
    }

    /// An Oracle lane for a catalog-recorded Grok effort variant reports that variant's effort,
    /// the value the one-shot sends as `--reasoning-effort`.
    func testOracleExecutionProfileReportsCatalogRecordedGrokEffort() throws {
        let base = AgentModelOption(
            rawValue: "grok-4.7-build-fast",
            displayName: "Grok 4.7 Build Fast",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: [.high, .xhigh],
            defaultReasoningEffort: .high
        )
        let variant = AgentModelOption(
            rawValue: "grok-4.7-build-fast-xhigh",
            displayName: "Grok 4.7 Build Fast Extra High",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            effortVariant: AgentModelEffortVariant(baseModelRaw: base.rawValue, reasoningEffort: .xhigh)
        )
        let suffixBase = AgentModelOption(
            rawValue: "grok-4.7-build-fast-high",
            displayName: "Grok Base Ending in High",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false
        )
        let cases: [(name: String, options: [AgentModelOption]?, modelID: String, cold: Bool, expectedEffort: String?)] = [
            ("warm variant", [base, variant], variant.rawValue, false, "xhigh"),
            ("cold saved variant", [base, variant], variant.rawValue, true, "xhigh"),
            ("bare base with advertised default", [base, variant], base.rawValue, false, nil),
            ("effort-suffixed base without variant record", [base, suffixBase], suffixBase.rawValue, false, nil),
            ("no catalog", nil, variant.rawValue, false, nil)
        ]
        let registry = AgentModelCatalogRuntime.shared.acpRegistry
        for row in cases {
            registry.test_reset(providerID: .grokBuild)
            if let options = row.options {
                XCTAssertTrue(registry.updateDiscoveredModels(
                    ACPDiscoveredSessionModels(options: options, currentModelRaw: options.first?.rawValue),
                    for: .grokBuild
                ), row.name)
            }
            if row.cold {
                registry.test_clearMemoryPreservingStore(providerID: .grokBuild)
                XCTAssertNil(registry.resolvedSnapshot(for: .grokBuild), row.name)
            }
            let profile = try XCTUnwrap(
                AppOracleGroupRouting.executionProfile(for: .grokBuildCustom(name: row.modelID)),
                row.name
            )
            XCTAssertEqual(profile.modelID, row.modelID, row.name)
            XCTAssertEqual(profile.effectiveReasoningEffort, row.expectedEffort, row.name)
            if row.cold {
                XCTAssertNil(registry.resolvedSnapshot(for: .grokBuild), "Profile capture must not warm memory")
            }
        }
    }
}
