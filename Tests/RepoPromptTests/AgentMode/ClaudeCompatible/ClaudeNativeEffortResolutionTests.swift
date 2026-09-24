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
        XCTAssertEqual(ClaudeAgentModeCoordinator.resolvedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: nil,
            isMCPOriginated: true,
            stored: .high
        ), .high)
        XCTAssertEqual(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5:low",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: true
        ), .low)
        XCTAssertNil(ClaudeAgentModeCoordinator.validatedMCPPinnedEffort(
            modelRaw: "claude-opus-5-5",
            agentKind: .claudeCode,
            pinnedEffortRaw: "low",
            isMCPOriginated: false
        ))
    }

    @MainActor
    func testMCPConfigurationPreservesClaudePinAndClearsItForUnpinnedModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-claude-effort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        defer {
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        }
        let workspace = window.workspaceManager.createWorkspace(
            name: "Claude MCP effort pin",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "claudeEffortPinTests")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.isMCPOriginated = true

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5:low",
            reasoningEffortRaw: "low"
        )
        XCTAssertEqual(session.selectedReasoningEffortRaw, "low")
        XCTAssertEqual(viewModel.claudeCoordinator.currentClaudeEffortLevel(for: session), .low)

        try await viewModel.mcpConfigureSession(
            tabID: tabID,
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: "claude-opus-5-5",
            reasoningEffortRaw: nil
        )
        XCTAssertNil(session.selectedReasoningEffortRaw)
    }
}
