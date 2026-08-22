import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderGlobalBehaviorSettingsTests: XCTestCase {
    func testUIBudgetUsesContextBudgetWhenFollowUpAnalysisDisabled() {
        var settings = ContextBuilderDefaults.behaviorSettings
        settings.contextTokenBudget = 43210
        settings.analysisTokenBudget = 54321
        settings.followUpAnalysisEnabled = false

        XCTAssertEqual(ContextBuilderBudgetResolver.resolveUIBudget(behaviorSettings: settings), 43210)
    }

    func testUIBudgetUsesAnalysisBudgetWhenFollowUpAnalysisEnabled() {
        var settings = ContextBuilderDefaults.behaviorSettings
        settings.contextTokenBudget = 43210
        settings.analysisTokenBudget = 54321
        settings.followUpAnalysisEnabled = true

        XCTAssertEqual(ContextBuilderBudgetResolver.resolveUIBudget(behaviorSettings: settings), 54321)
    }

    func testMCPBudgetUsesContextBudgetForOmittedAndClarify() {
        var settings = ContextBuilderDefaults.behaviorSettings
        settings.contextTokenBudget = 43210
        settings.analysisTokenBudget = 54321

        for wantsResponse in [false, ContextBuilderResponseType.clarify.wantsResponse] {
            XCTAssertEqual(
                ContextBuilderBudgetResolver.resolveMCPBudget(
                    wantsResponse: wantsResponse,
                    behaviorSettings: settings
                ),
                43210
            )
        }
    }

    func testMCPBudgetUsesAnalysisBudgetForPlanQuestionAndReviewRegardlessOfFollowUpAnalysis() {
        for followUpAnalysisEnabled in [false, true] {
            var settings = ContextBuilderDefaults.behaviorSettings
            settings.contextTokenBudget = 43210
            settings.analysisTokenBudget = 54321
            settings.followUpAnalysisEnabled = followUpAnalysisEnabled

            for responseType in [
                ContextBuilderResponseType.plan,
                .question,
                .review
            ] {
                XCTAssertEqual(
                    ContextBuilderBudgetResolver.resolveMCPBudget(
                        wantsResponse: responseType.wantsResponse,
                        behaviorSettings: settings
                    ),
                    54321,
                    responseType.rawValue
                )
            }
        }
    }

    func testUIRunKeepsBehaviorCapturedAtLaunch() {
        let settings = ContextBuilderBehaviorSettings(
            contextTokenBudget: 43210,
            analysisTokenBudget: 54321,
            enhancementMode: .augment,
            questionTimeoutSeconds: 91,
            allowUIClarifyingQuestions: false,
            allowMCPClarifyingQuestions: true,
            followUpAnalysisEnabled: true
        )

        let captured = ContextBuilderRunBehavior.ui(settings: settings, selectedFollowUp: .review)

        XCTAssertEqual(captured.tokenBudget, 54321)
        XCTAssertEqual(captured.enhancementMode, .augment)
        XCTAssertEqual(captured.questionTimeoutSeconds, 91)
        XCTAssertFalse(captured.allowClarifyingQuestions)
        XCTAssertEqual(captured.automaticFollowUp, .review)
    }

    func testMCPRunBehaviorAppliesInactiveTargetSafety() {
        var settings = ContextBuilderDefaults.behaviorSettings
        settings.contextTokenBudget = 43210
        settings.analysisTokenBudget = 54321
        settings.allowMCPClarifyingQuestions = true
        settings.followUpAnalysisEnabled = true

        let active = ContextBuilderRunBehavior.mcp(
            settings: settings,
            wantsResponse: true,
            targetIsActive: true
        )
        let inactive = ContextBuilderRunBehavior.mcp(
            settings: settings,
            wantsResponse: false,
            targetIsActive: false
        )

        XCTAssertEqual(active.tokenBudget, 54321)
        XCTAssertTrue(active.allowClarifyingQuestions)
        XCTAssertNil(active.automaticFollowUp)
        XCTAssertEqual(inactive.tokenBudget, 43210)
        XCTAssertFalse(inactive.allowClarifyingQuestions)
        XCTAssertNil(inactive.automaticFollowUp)
    }

    func testFollowUpAnalysisRemainsGlobalAcrossTabSwitches() async throws {
        let settingsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderGlobalTabSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settingsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: settingsRoot) }
        let suiteName = "ContextBuilderGlobalTabSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = try GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: settingsRoot.appendingPathComponent("Settings/globalSettings.json")
            )
        )
        var globalBehavior = store.contextBuilderBehaviorSettings()
        globalBehavior.followUpAnalysisEnabled = true
        store.setContextBuilderBehaviorSettings(globalBehavior, commit: false)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let composition = WindowStateCompositionFactory.make(
            windowID: -602,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService(),
            settingsStore: store
        )
        await composition.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderGlobalTabSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = composition.workspaceManager.createWorkspace(
            name: "Context Builder global tab settings",
            repoPaths: [root.path],
            ephemeral: true
        )
        await composition.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: #function
        )

        let firstPromptID = UUID()
        let secondPromptID = UUID()
        let firstTab = ComposeTabState(
            name: "First",
            contextBuilder: ContextBuilderTabConfig(
                instructions: "First instructions",
                followUpTypeRaw: ContextBuilderFollowUpType.plan.rawValue,
                selectedContextBuilderPromptIDs: [firstPromptID]
            )
        )
        let secondTab = ComposeTabState(
            name: "Second",
            contextBuilder: ContextBuilderTabConfig(
                instructions: "Second instructions",
                followUpTypeRaw: ContextBuilderFollowUpType.review.rawValue,
                selectedContextBuilderPromptIDs: [secondPromptID]
            )
        )
        let workspaceIndex = try XCTUnwrap(
            composition.workspaceManager.workspaces.firstIndex { $0.id == workspace.id }
        )
        composition.workspaceManager.workspaces[workspaceIndex].composeTabs = [firstTab, secondTab]
        composition.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = firstTab.id
        composition.promptManager.loadComposeTabsFromWorkspace(
            composition.workspaceManager.workspaces[workspaceIndex],
            syncPromptText: true
        )

        var storeEmissions = 0
        let cancellable = store.objectWillChange.sink { storeEmissions += 1 }
        defer { cancellable.cancel() }

        await composition.promptManager.switchComposeTab(firstTab.id)
        let viewModel = composition.contextBuilderAgentViewModel
        XCTAssertEqual(viewModel.contextBuilderInstructions, "First instructions")
        XCTAssertEqual(viewModel.selectedContextBuilderPromptIDs, [firstPromptID])
        XCTAssertEqual(viewModel.selectedFollowUpType, .plan)
        XCTAssertTrue(viewModel.followUpAnalysisEnabled)

        await composition.promptManager.switchComposeTab(secondTab.id)
        XCTAssertEqual(viewModel.contextBuilderInstructions, "Second instructions")
        XCTAssertEqual(viewModel.selectedContextBuilderPromptIDs, [secondPromptID])
        XCTAssertEqual(viewModel.selectedFollowUpType, .review)
        XCTAssertTrue(viewModel.followUpAnalysisEnabled)
        XCTAssertEqual(storeEmissions, 0)
    }
}
