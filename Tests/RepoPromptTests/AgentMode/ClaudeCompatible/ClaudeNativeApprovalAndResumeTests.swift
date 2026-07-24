import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeApprovalAndResumeTests: XCTestCase {
    enum ResolverError: Error {
        case unsupportedModel
    }

    actor RecordingLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        private(set) var requestedModels: [String?] = []
        private(set) var requestedEfforts: [String?] = []

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?,
            requestedEffort: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            requestedModels.append(requestedModel)
            requestedEfforts.append(requestedEffort)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        }
    }

    func testNativeFlagResolutionPassesEncodedGLMModelToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.test_resolveApplyFlagSettingsRequest(model: "glm-5-turbo:xhigh")
            XCTFail("Expected encoded unsupported GLM XHigh model to be rejected by the resolver")
        } catch ResolverError.unsupportedModel {
            // Expected.
        }

        let requestedModels = await resolver.requestedModels
        let requestedEfforts = await resolver.requestedEfforts
        XCTAssertEqual(requestedModels, ["glm-5-turbo:xhigh"])
        XCTAssertEqual(requestedEfforts, ["xhigh"])
    }

    func testNativeFlagResolutionPassesSeparateEffortToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            environmentResolver: resolver
        )

        _ = try await controller.test_resolveApplyFlagSettingsRequest(model: "sonnet", effortLevel: .max)

        let requestedModels = await resolver.requestedModels
        let requestedEfforts = await resolver.requestedEfforts
        XCTAssertEqual(requestedModels, ["sonnet"])
        XCTAssertEqual(requestedEfforts, ["max"])
    }

    func testNativeLaunchEnvironmentIncludesEffortEnvironment() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(
                commandName: "/usr/bin/false",
                runtimeVariant: .standard,
                effortLevel: .max
            )
        )

        let environment = await controller.test_effectiveLaunchEnvironment(
            base: [:],
            resolverOverrides: [
                "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]"
            ],
            effortLevel: .max
        )

        XCTAssertEqual(environment["ANTHROPIC_MODEL"], "deepseek-v4-pro[1m]")
        XCTAssertEqual(environment["CLAUDE_CODE_EFFORT_LEVEL"], "max")
    }

    func testNativeLaunchEnvironmentUsesPerLaunchEffortEnvironment() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(
                commandName: "/usr/bin/false",
                runtimeVariant: .standard,
                effortLevel: .max
            )
        )

        let environment = await controller.test_effectiveLaunchEnvironment(
            base: ["CLAUDE_CODE_EFFORT_LEVEL": "max"],
            effortLevel: .low
        )

        XCTAssertEqual(environment["CLAUDE_CODE_EFFORT_LEVEL"], "low")
    }

    func testNativeLaunchEnvironmentOmitsEffortEnvironmentWhenSuppressed() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm,
                effortLevel: .max
            )
        )

        let environment = await controller.test_effectiveLaunchEnvironment(
            base: ["CLAUDE_CODE_EFFORT_LEVEL": "low"],
            resolverOverrides: [
                "ANTHROPIC_MODEL": "glm-4.7"
            ],
            suppressesEffortSettings: true
        )

        XCTAssertEqual(environment["ANTHROPIC_MODEL"], "glm-4.7")
        XCTAssertNil(environment["CLAUDE_CODE_EFFORT_LEVEL"])
    }

    func testNativeLiveModelSwitchRequiresRestartWhenLaunchEnvironmentChanges() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
        let directGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5-turbo",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo",
                "ANTHROPIC_MODEL": "glm-5-turbo"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let slotGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-4.7",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7",
                "ANTHROPIC_MODEL": "glm-4.7"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        var selectedModelOnlyEnvironment = directGLM.environmentOverrides
        selectedModelOnlyEnvironment["ANTHROPIC_MODEL"] = "glm-4.7"
        let sameEnvironmentDifferentFlagModel = ClaudeCodeLaunchEnvironment(
            effectiveModel: "opus",
            environmentOverrides: selectedModelOnlyEnvironment,
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )

        let directToSlotRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: slotGLM
        )
        let sameEnvironmentRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: sameEnvironmentDifferentFlagModel
        )

        XCTAssertTrue(directToSlotRequiresRestart)
        XCTAssertFalse(sameEnvironmentRequiresRestart)
    }

    func testRepoPromptPermissionAutoApprovalAndAllowPayloadPreserveToolUseID() throws {
        let repoPromptPayload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": ["path": "Sources/App.swift"],
            "permission_suggestions": [["type": "tool", "name": "mcp__RepoPromptCE__read_file"]]
        ]

        let match = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, .topLevelToolName)
        XCTAssertEqual(match.normalizedToolName, "read_file")

        let allowOnce = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: false
        )
        XCTAssertEqual(allowOnce["behavior"] as? String, "allow")
        XCTAssertEqual(allowOnce["toolUseID"] as? String, "toolu_read_1")
        XCTAssertNil(allowOnce["updatedPermissions"])
        XCTAssertEqual((allowOnce["updatedInput"] as? [String: Any])?["path"] as? String, "Sources/App.swift")

        let allowForSession = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: true
        )
        XCTAssertEqual((allowForSession["updatedPermissions"] as? [[String: Any]])?.first?["name"] as? String, "mcp__RepoPromptCE__read_file")

        let nestedMatch = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: [
                "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]
            ]
        ))
        XCTAssertEqual(nestedMatch.source, .nestedToolName)
        XCTAssertEqual(nestedMatch.normalizedToolName, "read_file")

        XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: ["input": ["command": "rm -rf /tmp/example"]]
        ))
    }

    func testSystemAPIRetryPayloadMapsToTaskProgressWithAttemptAndDelay() throws {
        let progress = ClaudeNativeProcessSessionController.test_parseAPIRetryProgressResult(from: [
            "type": "system",
            "subtype": "api_retry",
            "attempt": 2,
            "max_retries": 5,
            "error_status": "429",
            "error": "rate_limit",
            "retry_delay_ms": 1500
        ])

        XCTAssertEqual(progress?.type, "task_progress")
        let text = try XCTUnwrap(progress?.text)
        XCTAssertTrue(text.contains("Provider API retry 2/5"), text)
        XCTAssertTrue(text.contains("429"), text)
        XCTAssertTrue(text.contains("rate_limit"), text)
        XCTAssertTrue(text.contains("Retrying in 2s"), text)
    }

    func testNonAPIRetrySystemPayloadDoesNotMapToTaskProgress() {
        XCTAssertNil(
            ClaudeNativeProcessSessionController.test_parseAPIRetryProgressResult(from: [
                "type": "system",
                "subtype": "init"
            ])
        )
        XCTAssertNil(
            ClaudeNativeProcessSessionController.test_parseAPIRetryProgressResult(from: [
                "type": "assistant",
                "subtype": "api_retry"
            ])
        )
    }

    func testAgentModeConfigClampsSDKConnectTimeoutSeconds() {
        let short = ClaudeCodeAgentConfig.agentMode(
            commandName: "/usr/bin/false",
            sdkConnectTimeoutSeconds: 0.25
        )
        XCTAssertEqual(short.sdkConnectTimeoutSeconds, 1)

        let custom = ClaudeCodeAgentConfig.agentMode(
            commandName: "/usr/bin/false",
            sdkConnectTimeoutSeconds: 42
        )
        XCTAssertEqual(custom.sdkConnectTimeoutSeconds, 42)

        let discovery = ClaudeCodeAgentConfig.discovery(commandName: "/usr/bin/false")
        XCTAssertEqual(discovery.sdkConnectTimeoutSeconds, 10)
    }
}
