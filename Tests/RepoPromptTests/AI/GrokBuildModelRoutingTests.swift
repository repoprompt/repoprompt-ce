import Darwin
import Foundation
import RepoPromptSecureStorage
import RepoPromptShared
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildModelRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
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

        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
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

    func testOneShotLaunchIsolatesImportedMCPServersAndPreservesAPIKey() {
        for apiKey in [nil, "xai-test-key-123"] as [String?] {
            let environment = GrokBuildOneShotHeadlessAgentProvider.launchEnvironment(apiKey: apiKey)
            XCTAssertEqual(environment["GROK_CLAUDE_MCPS_ENABLED"], "0")
            XCTAssertEqual(environment["GROK_CURSOR_MCPS_ENABLED"], "0")
            XCTAssertEqual(environment["XAI_API_KEY"], apiKey)
            XCTAssertNil(environment["HOME"])
            XCTAssertNil(environment["GROK_HOME"])
        }
    }

    func testOneShotCleanupUsesEffectiveHomeAndRemovesEntireOwnedFolder() async throws {
        for homeSelection in ["default", "empty override", "absolute override", "relative override"] {
            let root = try makeOneShotFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let promptDirectory = root.appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
            try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let defaultGrokHome = home.appendingPathComponent(".grok", isDirectory: true)
            var environment = ["HOME": home.path]
            let grokHome: URL
            switch homeSelection {
            case "empty override":
                environment["GROK_HOME"] = ""
                grokHome = defaultGrokHome
            case "absolute override":
                grokHome = root.appendingPathComponent("custom-grok", isDirectory: true)
                environment["GROK_HOME"] = grokHome.path
            case "relative override":
                environment["GROK_HOME"] = "relative-grok"
                grokHome = promptDirectory.appendingPathComponent("relative-grok", isDirectory: true)
            default:
                grokHome = defaultGrokHome
            }
            let encodedCWD = try encodedOneShotCWD(resolvedOneShotCWD(promptDirectory))
            let owned = grokHome.appendingPathComponent("sessions/\(encodedCWD)", isDirectory: true)
            try makeStoredOneShotSession(at: owned)
            let neighborDirectory = grokHome.appendingPathComponent("sessions/rp-grok-oneshot-request-fedcba9876543210")
            let neighbor = neighborDirectory.appendingPathComponent("prompt_history.jsonl")
            let configFile = grokHome.appendingPathComponent("config.toml")
            try writeOneShotFixture("existing config", to: configFile)
            let unselectedSession = defaultGrokHome.appendingPathComponent("sessions/\(encodedCWD)")
            if homeSelection == "absolute override" {
                try makeStoredOneShotSession(at: unselectedSession)
            }

            try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
                promptDirectory: promptDirectory,
                environment: environment
            ) {
                // A newly appeared, similarly named folder with incomplete metadata
                // is not owned by this request, even when it shares the cwd basename.
                try writeOneShotFixture("neighbor prompt", to: neighbor)
                try writeOneShotFixture("/incomplete", to: neighborDirectory.appendingPathComponent(".cwd"))
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path), homeSelection)
            XCTAssertFalse(FileManager.default.fileExists(atPath: promptDirectory.path), homeSelection)
            // A relative Grok home lives inside the request cwd and is request-owned too.
            if homeSelection != "relative override" {
                XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "neighbor prompt", homeSelection)
                XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), "existing config", homeSelection)
            }
            if homeSelection == "absolute override" {
                XCTAssertTrue(FileManager.default.fileExists(atPath: unselectedSession.path))
            }
        }
    }

    func testOneShotCleanupUsesResolvedWorkingDirectoryIdentity() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalParent = root.appendingPathComponent("physical", isDirectory: true)
        let physicalCWD = physicalParent.appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalCWD, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physicalParent)
        let promptDirectory = alias.appendingPathComponent(physicalCWD.lastPathComponent, isDirectory: true)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        let owned = try grokHome.appendingPathComponent(
            "sessions/\(encodedOneShotCWD(resolvedOneShotCWD(promptDirectory)))"
        )
        let logicalPathSession = grokHome.appendingPathComponent(
            "sessions/\(encodedOneShotCWD(promptDirectory.path))"
        )
        XCTAssertNotEqual(owned, logicalPathSession)
        try makeStoredOneShotSession(at: owned)
        try makeStoredOneShotSession(at: logicalPathSession)

        try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
            promptDirectory: promptDirectory,
            environment: ["GROK_HOME": grokHome.path]
        ) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalCWD.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logicalPathSession.path))
    }

    func testOneShotCleanupPreservesSymlinkThenParentHomePaths() async throws {
        for key in ["GROK_HOME", "HOME"] {
            for absolute in [false, true] {
                let label = "\(key), \(absolute ? "absolute" : "relative")"
                let root = try makeOneShotFixtureRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let requests = root.appendingPathComponent("requests", isDirectory: true)
                let promptDirectory = requests.appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
                let actual = root.appendingPathComponent("actual", isDirectory: true)
                try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: actual.appendingPathComponent("child"), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    atPath: requests.appendingPathComponent("grok-link").path,
                    withDestinationPath: "../actual/child"
                )
                let physicalCWD = try resolvedOneShotCWD(promptDirectory)
                let relativeHome = "../grok-link/../grok-home"
                let homePath = absolute ? try resolvedOneShotCWD(requests) + "/grok-link/../grok-home" : relativeHome
                let suffix = key == "HOME" ? "grok-home/.grok/sessions" : "grok-home/sessions"
                let encoded = encodedOneShotCWD(physicalCWD)
                // The symlink points into actual/child: the following .. reaches
                // actual, not requests. Expected storage is outside the private cwd.
                let owned = actual.appendingPathComponent("\(suffix)/\(encoded)")
                let decoy = requests.appendingPathComponent("\(suffix)/\(encoded)")
                try makeStoredOneShotSession(at: decoy)

                try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
                    promptDirectory: promptDirectory,
                    environment: [key: homePath]
                ) {
                    // Home does not exist when cleanup addressing is captured.
                    try makeStoredOneShotSession(at: owned)
                    let filesystemHome = try XCTUnwrap(realpath(physicalCWD + "/" + relativeHome, nil))
                    defer { free(filesystemHome) }
                    XCTAssertEqual(String(cString: filesystemHome), try resolvedOneShotCWD(actual.appendingPathComponent("grok-home")), label)
                }

                XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path), label)
                XCTAssertEqual(try? String(contentsOf: decoy.appendingPathComponent("prompt_history.jsonl"), encoding: .utf8), "fixture prompt", label)
                XCTAssertFalse(FileManager.default.fileExists(atPath: promptDirectory.path), label)
            }
        }
    }

    func testOneShotRefusesOverLongPhysicalCWDBeforeLaunchWithoutDeletingSessions() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptDirectory = root
            .appendingPathComponent(String(repeating: "中", count: 30), isDirectory: true)
            .appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
        try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
        let resolvedCWD = try resolvedOneShotCWD(promptDirectory)
        XCTAssertGreaterThan(encodedOneShotCWD(resolvedCWD).utf8.count, 255)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        let neighbor = grokHome.appendingPathComponent("sessions/rp-grok-oneshot-request-fedcba9876543210")
        try makeStoredOneShotSession(at: neighbor)
        var operationInvoked = false
        var removedItems: [URL] = []

        do {
            try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
                promptDirectory: promptDirectory,
                environment: ["GROK_HOME": grokHome.path],
                removeItem: { url in
                    removedItems.append(url)
                    try FileManager.default.removeItem(at: url)
                }
            ) {
                operationInvoked = true
            }
            XCTFail("Expected pre-launch refusal for a hashed cwd")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("255 bytes"))
            XCTAssertTrue(detail.contains("shorter temporary directory"))
        } catch {
            XCTFail("Expected actionable pre-launch refusal, got \(error)")
        }

        XCTAssertFalse(operationInvoked, "The request operation must not reach process launch")
        XCTAssertEqual(removedItems, [promptDirectory], "Only the unused request cwd may be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: promptDirectory.path))
        XCTAssertEqual(try String(contentsOf: neighbor.appendingPathComponent("prompt_history.jsonl"), encoding: .utf8), "fixture prompt")
    }

    func testOneShotCleanupWithoutStoredSessionDoesNotCreateGrokHome() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptDirectory = root.appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
        try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
        let grokHome = root.appendingPathComponent("absent-grok-home", isDirectory: true)

        try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
            promptDirectory: promptDirectory,
            environment: ["GROK_HOME": grokHome.path]
        ) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: promptDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: grokHome.path))
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

    func testOneShotCleanupFailureReportsBoundedDiagnosticWithoutReplacingOutcome() async throws {
        for outcome in ["completed", "failed", "timed out", "cancelled"] {
            let root = try makeOneShotFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let promptDirectory = root.appendingPathComponent("rp-grok-oneshot-request", isDirectory: true)
            try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
            let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
            let owned = try grokHome.appendingPathComponent("sessions/\(encodedOneShotCWD(resolvedOneShotCWD(promptDirectory)))")
            try makeStoredOneShotSession(at: owned)
            let deletionError = NSError(
                domain: "private-prompt-domain",
                code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: String(repeating: "SECRET_PROMPT_CONTENT", count: 100)]
            )
            let requestError = NSError(domain: "GrokBuildCLI", code: 7, userInfo: [NSLocalizedDescriptionKey: outcome])
            var diagnostics: [String] = []

            do {
                let response = try await GrokBuildOneShotHeadlessAgentProvider.withRequestCleanup(
                    promptDirectory: promptDirectory,
                    environment: ["GROK_HOME": grokHome.path],
                    removeItem: { url in
                        if url.standardizedFileURL.path == owned.standardizedFileURL.path { throw deletionError }
                        try FileManager.default.removeItem(at: url)
                    },
                    reportFailure: { diagnostics.append($0) }
                ) {
                    if outcome == "completed" { return "fixture response" }
                    if outcome == "cancelled" { throw CancellationError() }
                    throw requestError
                }
                XCTAssertEqual(outcome, "completed")
                XCTAssertEqual(response, "fixture response")
            } catch {
                if outcome == "cancelled" {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertNotEqual(outcome, "completed")
                    XCTAssertTrue(error as NSError === requestError, "Original request error must remain primary")
                }
            }

            XCTAssertEqual(diagnostics.count, 1, outcome)
            let diagnostic = try XCTUnwrap(diagnostics.first)
            XCTAssertTrue(diagnostic.contains("cleanup failed"))
            XCTAssertTrue(diagnostic.contains("\(NSFileWriteNoPermissionError)"))
            XCTAssertLessThanOrEqual(diagnostic.utf8.count, 160)
            XCTAssertFalse(diagnostic.contains("SECRET_PROMPT_CONTENT"))
            XCTAssertFalse(diagnostic.contains(deletionError.domain))
            XCTAssertFalse(diagnostic.contains(owned.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path), outcome)
            XCTAssertFalse(FileManager.default.fileExists(atPath: promptDirectory.path), outcome)
        }
    }

    func testOneShotSuccessParsesCompletionAndRemovesEntireSession() async throws {
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
        let ownedPath = try String(contentsOf: root.appendingPathComponent("session-path"), encoding: .utf8)
        let requestCWD = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPath), "Remove all artifacts, including opaque attachments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestCWD))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "neighbor prompt")
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
        requestTimeout: TimeInterval = 30
    ) throws -> GrokBuildOneShotHeadlessAgentProvider {
        let executable = root.appendingPathComponent("grok")
        let script = #"""
        #!/bin/sh
        if [ "$1" = agent ] && [ "$2" = --help ]; then
            printf 'stdio\n'
            exit 0
        fi
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
        session="$GROK_HOME/sessions/$encoded"
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
        if [ "$RPCE_FIXTURE_MODE" = cancel ]; then
            printf 'ready\n' > "$RPCE_FIXTURE_ROOT/ready.fifo"
        fi
        /bin/sleep 60 &
        wait $!
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": root.appendingPathComponent("home", isDirectory: true).path,
            "GROK_HOME": root.appendingPathComponent("grok-home", isDirectory: true).path,
            "RPCE_FIXTURE_ROOT": root.path,
            "RPCE_FIXTURE_MODE": mode
        ]
        return GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildAgentConfig(commandName: executable.path, includeRepoPromptMCPServer: false),
            launchResolver: GrokBuildACPLaunchResolver(environmentProvider: { _ in environment }),
            requestTimeout: requestTimeout,
            apiKeyProvider: { nil }
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
        let provider = GrokBuildOneShotHeadlessAgentProvider(
            config: GrokBuildCLIProvider.test_makeHeadlessConfig(modelName: nil)
        )
        let message = AgentMessage(
            systemPrompt: "system",
            userMessage: "inspect",
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Secret Diagram")
            ]
        )

        do {
            _ = try await provider.streamAgentMessage(message)
            XCTFail("Expected Grok Build image rejection")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("image attachments"))
            XCTAssertFalse(detail.contains("AQID"))
            XCTAssertFalse(detail.contains("Secret Diagram"))
        } catch {
            XCTFail("Expected actionable provider configuration error, got \(error)")
        }
    }

    func testNonAgentAdapterMapsNonSuccessfulStopsToIncomplete() {
        let incompleteStopReasons = [
            "max_tokens",
            "max_turn_requests",
            "cancelled",
            "refusal",
            "future_reason"
        ]
        for stopReason in incompleteStopReasons {
            let normalized = GrokBuildCLIProvider.test_normalizedTerminalResult(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    promptTokens: 11,
                    completionTokens: 7,
                    providerSessionID: "session-1",
                    stopReason: stopReason,
                    contextUsedTokens: 13
                )
            )

            XCTAssertEqual(normalized.type, AIStreamResult.incompleteType, stopReason)
            XCTAssertEqual(normalized.stopReason, stopReason, stopReason)
            XCTAssertEqual(normalized.promptTokens, 11, stopReason)
            XCTAssertEqual(normalized.completionTokens, 7, stopReason)
            XCTAssertEqual(normalized.providerSessionID, "session-1", stopReason)
            XCTAssertEqual(normalized.contextUsedTokens, 13, stopReason)
        }
    }

    func testNonAgentAdapterKeepsSuccessfulStopsCompleted() {
        let successfulStopReasons = [
            "end_turn",
            "stop",
            "stop_sequence",
            "completed",
            "complete"
        ]
        for stopReason in successfulStopReasons {
            let normalized = GrokBuildCLIProvider.test_normalizedTerminalResult(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    stopReason: stopReason
                )
            )

            XCTAssertEqual(normalized.type, "message_stop", stopReason)
            XCTAssertEqual(normalized.stopReason, stopReason, stopReason)
        }

        let missingReason = GrokBuildCLIProvider.test_normalizedTerminalResult(
            AIStreamResult(type: "message_stop", text: nil)
        )
        XCTAssertEqual(missingReason.type, "message_stop")
    }

    func testNonAgentCompletionPrefersAuthoritativeFinalContent() {
        XCTAssertEqual(
            GrokBuildCLIProvider.test_resolvedCompletionText(
                streamedParts: ["draft ", "answer"],
                finalContent: "final answer"
            ),
            "final answer"
        )
        XCTAssertEqual(
            GrokBuildCLIProvider.test_resolvedCompletionText(
                streamedParts: ["streamed ", "answer"],
                finalContent: nil
            ),
            "streamed answer"
        )
    }

    @MainActor
    func testDropdownDisplaysGrokBuildCatalogName() {
        let model = AIModel.grokBuildCustom(name: "grok-4.6")
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
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
}
