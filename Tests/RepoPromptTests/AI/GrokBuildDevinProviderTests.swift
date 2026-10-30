import Darwin
import Foundation
import os
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import XCTest

final class GrokBuildDevinProviderTests: XCTestCase {
    func testOneShotLaunchIsolatesImportsAndSessionStorageAndPreservesAPIKey() {
        for apiKey in [nil, "xai-test-key-123"] as [String?] {
            let environment = GrokBuildOneShotHeadlessAgentProvider.launchEnvironment(apiKey: apiKey)
            XCTAssertEqual(environment["GROK_CLAUDE_MCPS_ENABLED"], "0")
            XCTAssertEqual(environment["GROK_CURSOR_MCPS_ENABLED"], "0")
            XCTAssertEqual(environment["GROK_CLAUDE_HOOKS_ENABLED"], "0")
            XCTAssertEqual(environment["GROK_CURSOR_HOOKS_ENABLED"], "0")
            XCTAssertEqual(environment["GROK_SESSION_SEARCH"], "0")
            XCTAssertEqual(environment["GROK_STORAGE_MODE"], "local")
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

    func testOracleOneShotArgumentsUseSelectedModelAndPromptFile() {
        XCTAssertEqual(
            DevinCLIProvider.test_arguments(
                modelName: "claude-opus-4-6",
                promptFilePath: "/tmp/prompt.md",
                isDefaultModel: { $0.caseInsensitiveCompare("default") == .orderedSame }
            ),
            [
                "--model", "claude-opus-4-6",
                "--respect-workspace-trust", "false",
                "--permission-mode", "auto",
                "--prompt-file", "/tmp/prompt.md",
                "-p"
            ]
        )
    }

    func testOracleOneShotPromptRequestsOnePlainAnswerWithoutTools() {
        let prompt = DevinCLIProvider.test_promptText(from: AIMessage(
            systemPrompt: "Return Markdown.",
            userMessage: "Summarize this."
        ))

        XCTAssertTrue(prompt.contains("Return Markdown."))
        XCTAssertTrue(prompt.contains("Summarize this."))
        XCTAssertTrue(prompt.contains("Do not use any tools"))
    }

    func testOracleAttachmentsCarryThroughToolLessACPMessage() {
        let image = OracleAttachment(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
        let message = DevinCLIProvider.test_makeImageAgentMessage(from: AIMessage(
            systemPrompt: "Return Markdown.",
            conversationMessages: [.init(role: .user, content: "Describe the image.")],
            attachments: [image],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: []
        ))

        XCTAssertEqual(message.attachments, [image])
        XCTAssertTrue(message.systemPrompt.contains("Return Markdown."))
        XCTAssertTrue(message.systemPrompt.contains("Do not use any tools"))
        XCTAssertTrue(message.userMessage.contains("Describe the image."))
        XCTAssertFalse(message.userMessage.contains("Do not use any tools"))
        XCTAssertNil(message.resumeSessionID)

        let config = DevinCLIProvider(host: FixtureDevinCLIHost(), config: DevinAgentConfig(commandName: "custom-devin", additionalPathHints: ["/custom/bin"]), launchResolver: makeDevinResolver(environment: [:]), headlessProviderFactory: { _, _ in preconditionFailure("No request is executed by the config witness") }).test_makeImageHeadlessConfig(modelName: "claude-opus-4-6")
        XCTAssertEqual(config.commandName, "custom-devin")
        XCTAssertEqual(config.additionalPathHints, ["/custom/bin"])
        XCTAssertEqual(config.modelString, "claude-opus-4-6")
        XCTAssertFalse(config.includeRepoPromptMCPServer)
    }
}

extension GrokBuildDevinProviderTests {
    func testGrokSelectionFailurePrecedesLaunchProbeAndKeyRead() async throws {
        let events = FixtureEvents()
        let host = FixtureGrokOneShotHost(events: events, rejectSelection: true)
        let provider = GrokBuildOneShotHeadlessAgentProvider(
            host: host,
            config: GrokBuildAgentConfig(commandName: "/never-launch/grok", additionalPathHints: [], modelString: "rejected"),
            launchResolver: GrokBuildACPLaunchResolver(
                launchEnvironmentProvider: { _ in events.append("unexpected-probe")
                    return .init(environment: [:])
                },
                supplementalPathProvider: { $0 },
                environmentFilter: { environment, _ in environment },
                failureRecorder: { _, _ in events.append("unexpected-resolution-failure") }
            ),
            apiKeyProvider: { events.append("unexpected-key")
                return "unused"
            }
        )
        do {
            let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "prompt"))
            for try await _ in stream {}
            XCTFail("Expected selection refusal")
        } catch {
            XCTAssertEqual(error as? FixtureProviderError, .selection)
        }
        await provider.dispose()
        XCTAssertEqual(events.values, ["selection:rejected"])
    }

    func testGrokKeyReadFollowsProbeAndFilterUsesItsExactResult() async throws {
        for configuredKey in [nil, "  configured-key  "] as [String?] {
            let root = try makeOneShotFixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("grok")
            let supportFile = root.appendingPathComponent("support-probed")
            let script = """
            #!/bin/sh
            if [ "$1" = agent ] && [ "$2" = --help ]; then
                printf 'probed' > '\(supportFile.path)'
                printf 'stdio\\n'
                exit 0
            fi
            printf '%s' "$PWD" > '\(root.appendingPathComponent("request-cwd").path)'
            printf '%s\\n' '{"text":"'"$XAI_API_KEY"'","stopReason":"end_turn"}'
            """
            try installFixtureScript(script, at: executable)
            let events = FixtureEvents()
            let host = FixtureGrokOneShotHost(events: events, rejectSelection: false)
            let provider = GrokBuildOneShotHeadlessAgentProvider(
                host: host,
                config: GrokBuildAgentConfig(commandName: executable.path, additionalPathHints: [], modelString: "opaque-selection", apiKey: configuredKey),
                launchResolver: makeGrokResolver(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GROK_HOME": root.appendingPathComponent("grok-home").path]),
                apiKeyProvider: {
                    XCTAssertEqual(try String(contentsOf: supportFile, encoding: .utf8), "probed")
                    events.append("key")
                    return "fresh-key"
                }
            )
            var content: [String] = []
            var terminal = 0
            try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
                let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "prompt"))
                for try await value in stream {
                    if value.type == "content", let text = value.text { content.append(text) }
                    if value.type == "message_stop" { terminal += 1 }
                }
            }
            await provider.dispose()
            XCTAssertEqual(content, [configuredKey == nil ? "fresh-key" : "configured-key"])
            XCTAssertEqual(terminal, 1)
            XCTAssertEqual(
                events.values,
                configuredKey == nil
                    ? ["selection:opaque-selection", "key", "filter:fresh-key"]
                    : ["selection:opaque-selection", "filter:configured-key"]
            )
            let cwd = try String(contentsOf: root.appendingPathComponent("request-cwd"), encoding: .utf8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "Request artifacts must be removed after physical completion")
        }
    }

    func testDevinTextExecutionUsesRequiredIntegrationAndCleanupWithoutACP() async throws {
        let root = try makeOneShotFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("devin")
        try installFixtureScript("""
        #!/bin/sh
        if [ "$1" = acp ] && [ "$2" = --help ]; then
            printf 'Run as an ACP server over stdio\\n'
            exit 0
        fi
        printf '%s\\n' "$@" > '\(root.appendingPathComponent("arguments").path)'
        printf '%s' "$RPCE_INTEGRATION_SENTINEL"
        """, at: executable)
        let host = FixtureDevinCLIHost()
        let provider = DevinCLIProvider(
            host: host,
            config: DevinAgentConfig(commandName: executable.path, additionalPathHints: [], includeRepoPromptMCPServer: false),
            launchResolver: makeDevinResolver(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path]),
            headlessProviderFactory: { _, _ in preconditionFailure("Text requests must not construct ACP") }
        )
        let completion = try await ProviderProcessLaunchPolicy.$allowsLaunchForTesting.withValue(true) {
            try await provider.completeMessage(AIMessage(systemPrompt: "", userMessage: "prompt"), model: .devinCustom(name: "raw-model"))
        }
        await provider.dispose()
        XCTAssertEqual(completion.text, "prepared")
        XCTAssertEqual(host.events.values, ["model", "prepare", "filter-factory", "default:fixture-model", "filter-run", "cleanup"])
        let directory = try XCTUnwrap(host.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8).components(separatedBy: .newlines)
        XCTAssertEqual(Array(arguments.prefix(4)), ["--model", "fixture-model", "--respect-workspace-trust", "false"])
        XCTAssertTrue(arguments.contains("auto"))
        XCTAssertTrue(arguments.contains(directory + "/prompt.md"))
    }

    func testDevinImageFailureUsesACPAndRemovesPrivateDirectoryWithoutTextIntegration() async throws {
        let host = FixtureDevinCLIHost()
        let factoryEvents = FixtureEvents()
        let provider = DevinCLIProvider(
            host: host,
            config: DevinAgentConfig(commandName: "fixture-devin", additionalPathHints: ["/fixture/bin"], includeRepoPromptMCPServer: true),
            launchResolver: makeDevinResolver(environment: [:]),
            headlessProviderFactory: { config, workspacePath in
                XCTAssertEqual(config.commandName, "fixture-devin")
                XCTAssertEqual(config.additionalPathHints, ["/fixture/bin"])
                XCTAssertEqual(config.modelString, "fixture-model")
                XCTAssertFalse(config.includeRepoPromptMCPServer)
                let directory = workspacePath ?? ""
                factoryEvents.append(directory)
                XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions]) as? Int, 0o700)
                return DevinACPHeadlessAgentProvider(
                    isDefaultModel: { $0 == "default" },
                    config: config,
                    workspacePath: workspacePath,
                    providerFactory: { _ in RejectingImageACPProvider() },
                    controllerFactory: { _, _, _ in throw FixtureProviderError.unexpectedController }
                )
            }
        )
        let attachment = OracleAttachment(payload: .image(.png, Data([1, 2, 3])), fileName: "fixture.png", title: "image")
        do {
            _ = try await provider.completeMessage(AIMessage(systemPrompt: "", conversationMessages: [.init(role: .user, content: "describe")], attachments: [attachment], temperature: nil, promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder, disabledPromptSections: []), model: .devinCustom(name: "raw-model"))
            XCTFail("Expected ACP support refusal")
        } catch {
            XCTAssertEqual(error as? FixtureProviderError, .image)
        }
        await provider.dispose()
        XCTAssertEqual(host.events.values, ["model"], "Image requests must not prepare text integration or launch a text process")
        XCTAssertEqual(factoryEvents.values.count, 1)
        let directory = try XCTUnwrap(factoryEvents.values.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }
}

private enum FixtureProviderError: Error, Equatable {
    case selection, image, unexpectedController
}

private final class FixtureEvents: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ value: String) {
        state.withLock { $0.append(value) }
    }

    var values: [String] {
        state.withLock { $0 }
    }
}

private struct FixtureGrokOneShotHost: GrokBuildOneShotHost {
    let events: FixtureEvents
    let rejectSelection: Bool

    func resolveModelSelection(modelString: String?) async throws -> (model: String?, effort: String?) {
        events.append("selection:" + (modelString ?? "nil"))
        if rejectSelection { throw FixtureProviderError.selection }
        return (modelString, nil)
    }

    func filterEnvironment(_ environment: [String: String], explicitOverrides: [String: String], removedNamesProvider: ProviderRemovedEnvironmentNames?) async -> [String: String] {
        events.append("filter:" + (explicitOverrides["XAI_API_KEY"] ?? "nil"))
        return environment.merging(explicitOverrides) { _, explicit in explicit }
    }
}

private final class FixtureDevinCLIHost: DevinCLIHost {
    let events = FixtureEvents()
    private let state = OSAllocatedUnfairLock(initialState: String?.none)
    private let artifact = ACPLaunchCleanupArtifact(providerID: .devin, id: UUID(), kind: "fixture-integration")
    var directory: String? {
        state.withLock { $0 }
    }

    func modelName(for _: AIModel) -> String? {
        events.append("model")
        return "fixture-model"
    }

    func isDefaultModel(_ modelName: String) -> Bool {
        events.append("default:" + modelName)
        return modelName.caseInsensitiveCompare("default") == .orderedSame
    }

    func prepareIsolatedIntegration(workingDirectory: String, sourceEnvironment _: [String: String]) throws -> (environment: [String: String], cleanupArtifact: ACPLaunchCleanupArtifact) {
        events.append("prepare")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingDirectory))
        state.withLock { $0 = workingDirectory }
        return (["RPCE_INTEGRATION_SENTINEL": "prepared"], artifact)
    }

    func cleanupIntegration(artifact: ACPLaunchCleanupArtifact) {
        events.append("cleanup")
        XCTAssertEqual(artifact, self.artifact)
        XCTAssertTrue(directory.map { FileManager.default.fileExists(atPath: $0) } == true, "Integration cleanup precedes request-directory removal")
    }

    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter {
        events.append("filter-factory")
        return { [events] environment, overrides in
            events.append("filter-run")
            return environment.merging(explicitOverrides) { _, explicit in explicit }.merging(overrides) { _, runtime in runtime }
        }
    }
}

private struct RejectingImageACPProvider: ACPAgentProvider {
    var providerID: ACPProviderID {
        .devin
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        throw FixtureProviderError.image
    }

    func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
        throw FixtureProviderError.unexpectedController
    }

    func makeSessionConfiguration(for _: ACPRunRequest, mcpServer _: RepoPromptMCPServerConfiguration) throws -> ACPSessionConfiguration {
        throw FixtureProviderError.unexpectedController
    }

    func buildPromptBlocks(for _: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        throw FixtureProviderError.unexpectedController
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

private func makeGrokResolver(environment: [String: String]) -> GrokBuildACPLaunchResolver {
    GrokBuildACPLaunchResolver(
        launchEnvironmentProvider: { _ in .init(environment: environment) },
        supplementalPathProvider: { $0 },
        environmentFilter: { environment, overrides in environment.merging(overrides) { _, runtime in runtime } },
        failureRecorder: { _, _ in XCTFail("Synthetic Grok resolution should succeed") }
    )
}

private func makeDevinResolver(environment: [String: String]) -> DevinACPLaunchResolver {
    DevinACPLaunchResolver(
        launchEnvironmentProvider: { _ in .init(environment: environment) },
        supplementalPathProvider: { $0 },
        environmentFilter: { environment, overrides in environment.merging(overrides) { _, runtime in runtime } },
        failureRecorder: { _, _ in XCTFail("Synthetic Devin resolution should succeed") }
    )
}

private func installFixtureScript(_ script: String, at executable: URL) throws {
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
}
