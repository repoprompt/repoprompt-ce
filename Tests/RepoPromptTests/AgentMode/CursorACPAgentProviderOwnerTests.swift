import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class CursorACPAgentProviderOwnerTests: XCTestCase {
    func testCursorClassifierRecognizesNarrowGenericAndMissingCategoryParameters() {
        let provider = makeProvider()
        let choices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Thought-Level",
            category: "model_parameter",
            displayName: "Effort",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "thought_level",
            category: nil,
            displayName: "Anything",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_config",
            displayName: "Anything",
            choices: choices
        )), .speed)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Fast-Mode",
            category: nil,
            displayName: "Anything",
            choices: choices
        )), .speed)
    }

    func testCursorClassifierRecognizesObservedFastSelectorShape() {
        let provider = makeProvider()

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "fast",
            category: "model_config",
            displayName: "Fast Mode",
            choices: [
                .init(rawValue: "false", displayName: "Off"),
                .init(rawValue: "true", displayName: "Fast")
            ]
        )), .speed)
    }

    func testCursorClassifierUsesMultiLevelEffortAndReasoningButIgnoresBooleanThinking() {
        let provider = makeProvider()
        let effortChoices = [
            ACPModelParameterChoice(rawValue: "low", displayName: "Low"),
            ACPModelParameterChoice(rawValue: "high", displayName: "High")
        ]

        for configID in ["effort", "reasoning"] {
            XCTAssertEqual(provider.modelParameterKind(for: .init(
                configID: configID,
                category: "thought_level",
                displayName: configID.capitalized,
                choices: effortChoices
            )), .thinking, configID)
        }

        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "thinking",
            category: "thought_level",
            displayName: "Thinking",
            choices: [
                .init(rawValue: "false", displayName: "Off"),
                .init(rawValue: "true", displayName: "On")
            ]
        )))
    }

    func testCursorClassifierRejectsModelModeAndAmbiguousParameters() {
        let provider = makeProvider()
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        for category in ["model", "mode"] {
            XCTAssertNil(provider.modelParameterKind(for: .init(
                configID: "Cursor.Fast-Mode",
                category: category,
                displayName: "Speed",
                choices: speedChoices
            )))
        }
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: nil,
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_parameter",
            displayName: "Anything",
            choices: [.init(rawValue: "true", displayName: "Fast")]
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "permission",
            displayName: "Speed",
            choices: speedChoices
        )))
    }

    func testCursorClassifierRejectsSemanticModelAndModeIDsBeforeParameterHeuristics() {
        let provider = makeProvider()
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: nil,
            displayName: "Effort",
            choices: []
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: "model_parameter",
            displayName: "Speed",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: "model_config",
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: nil,
            displayName: "Cursor.Fast-Mode",
            choices: speedChoices
        )))
    }

    func testResumeControlsPromptAndSessionWithStoredMCPConfiguration() throws {
        let provider = makeProvider()
        let message = AgentMessage(systemPrompt: " SYS ", userMessage: " USER ")
        for resume in [nil, " session-id "] as [String?] {
            let request = ACPRunRequest(agentKind: .cursor, modelString: nil, workspacePath: "/workspace", resumeSessionID: resume, attachments: [], taskLabelKind: nil)
            let blocks = try provider.buildPromptBlocks(for: message, request: request)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?["text"] as? String, resume == nil ? "SYS\n\nUSER" : "USER")
            let session = try provider.makeSessionConfiguration(for: request, mcpServer: RepoPromptMCPServerConfiguration(command: "/ignored/mcp"))
            XCTAssertEqual(session.mode, resume == nil ? .new : .load(existingSessionID: "session-id"))
            XCTAssertEqual(session.mcpServers, [RepoPromptMCPServerConfiguration(command: "/fixture/mcp")])
        }
    }

    func testAuthSelectionKeepsWireIDAndDefersToNonemptyEnvironmentToken() {
        let provider = makeProvider()
        XCTAssertEqual(provider.preferredAuthMethodID(context: .init(authMethodIDs: ["other", "CuRsOr_LoGiN"], environment: [:])), "CuRsOr_LoGiN")
        XCTAssertEqual(provider.preferredAuthMethodID(context: .init(authMethodIDs: ["cursor_login"], environment: ["CURSOR_API_KEY": "  "])), "cursor_login")
        for key in ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"] {
            XCTAssertNil(provider.preferredAuthMethodID(context: .init(authMethodIDs: ["cursor_login"], environment: [key: "fixture-token"])))
        }
        XCTAssertNil(provider.preferredAuthMethodID(context: .init(authMethodIDs: ["other"], environment: [:])))
    }

    func testRequiredToolNameResolutionReachesCursorEvents() {
        let events = makeProvider().normalizeSessionUpdate([
            "sessionUpdate": "tool_call", "toolCallId": "call", "title": "alias (trusted)", "rawInput": ["path": "File.swift"]
        ], sessionID: "session")
        guard case let .stream(result) = events.first else { return XCTFail("Missing tool call") }
        XCTAssertEqual(result.toolName, "mcp__RepoPromptCE__read_file")
    }

    func testPlaceholderSuccessIsSuppressedButFailureRemainsDurable() throws {
        let provider = makeProvider()
        let placeholder: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": "call", "title": "other", "status": "completed", "rawOutput": ["success": true]]
        XCTAssertTrue(provider.normalizeSessionUpdate(placeholder, sessionID: "session").isEmpty)
        var failure = placeholder
        failure["rawOutput"] = ["success": false, "error": "failed", "chat_id": "root-id"] as [String: Any]
        let events = provider.normalizeSessionUpdate(failure, sessionID: "session")
        guard case let .stream(result) = events.first else { return XCTFail("Lost failed placeholder") }
        XCTAssertEqual(result.toolIsError, true)
        let json = try XCTUnwrap(result.toolResultJSON)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["status"] as? String, "failed")
        XCTAssertEqual(payload["acp_status"] as? String, "completed")
        XCTAssertEqual(payload["chat_id"] as? String, "root-id")
    }

    private func makeProvider() -> CursorACPAgentProvider {
        let resolver = CursorACPLaunchResolver(
            launchEnvironmentProvider: { _ in ACPLaunchEnvironment(environment: [:], shellEnvironmentSource: nil) },
            supplementalPathProvider: { $0 },
            probeRunner: { _, _, _, _ in throw NSError(domain: "UnexpectedCursorProbe", code: 1) },
            failureRecorder: { _, _ in XCTFail("Unexpected Cursor discovery") },
            nowProvider: { ProcessInfo.processInfo.systemUptime },
            deadlineWaiter: { deadline in await CursorACPLaunchResolver.defaultDeadlineWaiter(deadline) },
            aggregateProbeTimeout: 10
        )
        return CursorACPAgentProvider(
            config: CursorAgentConfig(),
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: "/fixture/mcp"),
            launchResolver: resolver,
            toolNames: ACPToolNameResolution(
                isRepoPromptServerIdentifier: { $0 == "trusted" },
                canonicalRepoPromptToolName: { $0 == "alias" ? "read_file" : nil },
                isRepoPromptToolNameWithServerPrefix: { _ in false }
            ),
            projectMCPApproval: UnusedCursorApproval()
        )
    }
}

private struct UnusedCursorApproval: CursorACPProjectMCPApproval {
    var cleanupArtifactKind: String {
        "unused-test-approval"
    }

    func cursorDataDirectoryURL(workingDirectory: String, environment: [String: String]) -> URL {
        XCTFail("Pure provider operation unexpectedly resolved an approval directory")
        return URL(fileURLWithPath: "/unexpected")
    }

    func prepareProjectMCPApproval(workingDirectory: String, cursorDataDirectory: URL, repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration, cleanupAfterRun: Bool) throws -> ACPLaunchCleanupArtifact? {
        throw NSError(domain: "UnexpectedCursorApproval", code: 1)
    }

    func cleanupProjectMCPApproval(leaseID: UUID) {
        XCTFail("Pure provider operation unexpectedly cleaned an approval")
    }
}
