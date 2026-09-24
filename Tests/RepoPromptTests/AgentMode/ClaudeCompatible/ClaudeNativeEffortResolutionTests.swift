import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeEffortResolutionTests: XCTestCase {
    private actor FixedModelResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel _: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(
                effectiveModel: "claude-opus-5-5",
                environmentOverrides: [:],
                backend: .defaultClaude
            )
        }
    }

    func testTurnScopedEffortOverridesEncodedModelEffortInFlagSettings() async throws {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: FixedModelResolver()
        )

        let overridden = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: .low
        )
        XCTAssertEqual((overridden?["settings"] as? [String: Any])?["effortLevel"] as? String, "low")

        let baseline = try await controller.test_resolveApplyFlagSettingsRequest(
            model: "claude-opus-5-5:high",
            effortLevel: nil
        )
        XCTAssertEqual((baseline?["settings"] as? [String: Any])?["effortLevel"] as? String, "high")
    }

    @MainActor
    func testMCPExplicitClaudeEffortPinWinsOverStoredPreference() {
        let extracted = AgentExternalMCPRunStarter.extractReasoningEffort(from: "claude-opus-5-5:low")
        XCTAssertEqual(extracted.model, "claude-opus-5-5:low")
        XCTAssertEqual(extracted.effort, "low")
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: true,
            stored: .high
        ), .low)
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: extracted.effort,
            isMCPOriginated: false,
            stored: .high
        ), .high)
    }
}
