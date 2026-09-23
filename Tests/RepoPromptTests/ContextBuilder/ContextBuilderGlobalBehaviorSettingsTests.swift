import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ContextBuilderGlobalBehaviorSettingsTests: XCTestCase {
    func testAnalysisTokenBudgetNormalizationPreservesBoundsAndClampsOutsideValues() {
        let range = ContextBuilderDefaults.analysisTokenBudgetRange

        XCTAssertEqual(ContextBuilderDefaults.normalizedAnalysisTokenBudget(range.lowerBound - 1), range.lowerBound)
        XCTAssertEqual(ContextBuilderDefaults.normalizedAnalysisTokenBudget(range.lowerBound), range.lowerBound)
        XCTAssertEqual(ContextBuilderDefaults.normalizedAnalysisTokenBudget(range.upperBound), range.upperBound)
        XCTAssertEqual(ContextBuilderDefaults.normalizedAnalysisTokenBudget(range.upperBound + 1), range.upperBound)
    }

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

    // MARK: - Presentation projection (#810)

    /// Desired settings that disagree with every captured decision below, so any live read
    /// in an active readout would produce a different label.
    private static let conflictingDesiredSettings = ContextBuilderBehaviorSettings(
        contextTokenBudget: 70000,
        analysisTokenBudget: 90000,
        enhancementMode: .fullRewrite,
        questionTimeoutSeconds: 300,
        allowUIClarifyingQuestions: true,
        allowMCPClarifyingQuestions: true,
        followUpAnalysisEnabled: true
    )

    func testIdlePresentationFollowsDesiredSettingsImmediately() {
        var desired = Self.conflictingDesiredSettings
        desired.followUpAnalysisEnabled = false

        let before = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .plan
        )
        XCTAssertFalse(before.isActive)
        XCTAssertFalse(before.isUnavailable)
        XCTAssertEqual(before.tokenBudgetLabel, "70k")
        XCTAssertEqual(before.headerTitle, "Task Description")
        XCTAssertTrue(before.instructionsPlaceholder.hasPrefix("Describe your task here..."))
        XCTAssertEqual(before.modeLabel, "Rewrite")
        XCTAssertEqual(before.allowsClarifyingQuestions, true)
        XCTAssertEqual(before.questionIndicatorSymbolName, "questionmark.circle.fill")
        XCTAssertNil(before.automaticFollowUp)
        XCTAssertFalse(before.isAutomaticFollowUpEnabled)
        XCTAssertEqual(before.automaticFollowUpPresentation, .off)
        XCTAssertEqual(before.automaticFollowUpIndicatorSymbolName, "bolt")
        XCTAssertEqual(
            before.summaryLines,
            [
                "Context Builder Settings",
                "Token budget: 70k",
                "Prompt mode: Rewrite",
                "Clarifying questions: On",
                "Question timeout: 5 min"
            ]
        )

        desired.followUpAnalysisEnabled = true
        desired.enhancementMode = .preserve
        desired.allowUIClarifyingQuestions = false
        let after = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .review
        )
        XCTAssertEqual(after.tokenBudgetLabel, "90k")
        XCTAssertEqual(after.headerTitle, "Build Context")
        XCTAssertEqual(after.instructionsPlaceholder, "Describe what files to look for (your instructions won't be modified)")
        XCTAssertEqual(after.modeLabel, "Preserve")
        XCTAssertEqual(after.automaticFollowUp, .review)
        XCTAssertEqual(after.automaticFollowUpPresentation, .enabled(.review))
        XCTAssertEqual(after.automaticFollowUpIndicatorSymbolName, "bolt.fill")
        XCTAssertEqual(after.allowsClarifyingQuestions, false)
        XCTAssertEqual(after.questionIndicatorSymbolName, "questionmark.circle")
        XCTAssertEqual(
            after.summaryLines,
            [
                "Context Builder Settings",
                "Token budget: 90k",
                "Prompt mode: Preserve",
                "Clarifying questions: Off"
            ]
        )
    }

    func testActiveUIPresentationUsesCapturedBehaviorDespiteConflictingDesiredSettings() {
        let captured = ContextBuilderRunBehavior(
            tokenBudget: 43000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 91,
            allowClarifyingQuestions: false,
            automaticFollowUp: nil
        )

        let presentation = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: captured,
            desiredSettings: Self.conflictingDesiredSettings,
            selectedFollowUp: .plan
        )

        XCTAssertEqual(presentation, .active(captured))
        XCTAssertTrue(presentation.isActive)
        XCTAssertFalse(presentation.isUnavailable)
        XCTAssertEqual(presentation.tokenBudgetLabel, "43k")
        XCTAssertEqual(presentation.headerTitle, "Additional Context (Optional)")
        XCTAssertEqual(presentation.instructionsPlaceholder, "Add extra details to help the agent find relevant files and enhance your prompt")
        XCTAssertEqual(presentation.modeLabel, "Augment")
        XCTAssertEqual(presentation.questionTimeoutSeconds, 91)
        XCTAssertEqual(presentation.allowsClarifyingQuestions, false)
        XCTAssertEqual(presentation.questionIndicatorSymbolName, "questionmark.circle")
        // Valid nil capture is Off for this run, not unavailable, even though the desired
        // follow-up preference is enabled.
        XCTAssertNil(presentation.automaticFollowUp)
        XCTAssertFalse(presentation.isAutomaticFollowUpEnabled)
        XCTAssertEqual(presentation.automaticFollowUpPresentation, .off)
        XCTAssertEqual(presentation.automaticFollowUpIndicatorSymbolName, "bolt")
        XCTAssertEqual(
            presentation.summaryLines,
            [
                "Current run settings",
                "Token budget: 43k",
                "Prompt mode: Augment",
                "Clarifying questions: Off"
            ]
        )
    }

    func testActiveMCPPresentationUsesCapturedPermissionWhileDesiredPermissionsAllowQuestions() {
        var settings = Self.conflictingDesiredSettings
        settings.questionTimeoutSeconds = 120
        // Inactive workspace target suppresses MCP questions even though both desired toggles are on.
        let captured = ContextBuilderRunBehavior.mcp(
            settings: settings,
            wantsResponse: true,
            targetIsActive: false
        )

        let presentation = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: captured,
            desiredSettings: Self.conflictingDesiredSettings,
            selectedFollowUp: .plan
        )

        XCTAssertEqual(presentation.allowsClarifyingQuestions, false)
        XCTAssertEqual(presentation.questionIndicatorSymbolName, "questionmark.circle")
        XCTAssertEqual(presentation.tokenBudgetLabel, "90k")
        XCTAssertEqual(
            presentation.summaryLines,
            [
                "Current run settings",
                "Token budget: 90k",
                "Prompt mode: Rewrite",
                "Clarifying questions: Off"
            ]
        )
        // MCP response intent is separate authority; the projection carries no UI follow-up
        // for MCP runs and must not be read as "no response".
        XCTAssertNil(presentation.automaticFollowUp)
        XCTAssertFalse(presentation.isUnavailable)

        let activeTarget = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: ContextBuilderRunBehavior.mcp(
                settings: settings,
                wantsResponse: false,
                targetIsActive: true
            ),
            desiredSettings: Self.conflictingDesiredSettings,
            selectedFollowUp: .plan
        )
        XCTAssertEqual(activeTarget.allowsClarifyingQuestions, true)
        XCTAssertEqual(activeTarget.tokenBudgetLabel, "70k")
        XCTAssertTrue(activeTarget.summaryLines.contains("Clarifying questions: On"))
        XCTAssertTrue(activeTarget.summaryLines.contains("Question timeout: 2 min"))
    }

    func testActiveWithoutCaptureIsUnavailableRatherThanLiveOrOff() {
        let presentation = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: nil,
            desiredSettings: Self.conflictingDesiredSettings,
            selectedFollowUp: .plan
        )

        XCTAssertEqual(presentation, .unavailable)
        XCTAssertTrue(presentation.isActive)
        XCTAssertTrue(presentation.isUnavailable)
        XCTAssertNil(presentation.behavior)
        XCTAssertNil(presentation.enhancementMode)
        XCTAssertNil(presentation.allowsClarifyingQuestions)
        XCTAssertNil(presentation.questionTimeoutSeconds)
        XCTAssertEqual(presentation.tokenBudgetLabel, "Unavailable")
        XCTAssertEqual(presentation.modeLabel, "Unavailable")
        XCTAssertEqual(presentation.headerTitle, "Context Builder")
        XCTAssertEqual(presentation.headerTooltip, "Current run settings unavailable")
        XCTAssertEqual(presentation.instructionsPlaceholder, "Current run settings unavailable")
        XCTAssertEqual(presentation.questionIndicatorSymbolName, "questionmark.circle.dashed")
        XCTAssertEqual(presentation.summaryLines, ["Current run settings unavailable"])
        // Unknown follow-up is neither Off nor enabled.
        XCTAssertNil(presentation.automaticFollowUp)
        XCTAssertFalse(presentation.isAutomaticFollowUpEnabled)
        XCTAssertEqual(presentation.automaticFollowUpPresentation, .unavailable)
        XCTAssertEqual(presentation.automaticFollowUpIndicatorSymbolName, "bolt.trianglebadge.exclamationmark")
    }

    func testIdlePresentationNormalizesDesiredAnalysisBudgetWhileCapturedBudgetStaysVerbatim() {
        let range = ContextBuilderDefaults.analysisTokenBudgetRange
        var desired = Self.conflictingDesiredSettings
        desired.followUpAnalysisEnabled = true

        desired.analysisTokenBudget = range.lowerBound - 10000
        let low = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .plan
        )
        XCTAssertEqual(low.behavior?.tokenBudget, range.lowerBound)

        desired.analysisTokenBudget = range.upperBound + 50000
        let high = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .plan
        )
        XCTAssertEqual(high.behavior?.tokenBudget, range.upperBound)

        // A captured effective budget outside the preference range is displayed as captured.
        let captured = ContextBuilderRunBehavior(
            tokenBudget: range.lowerBound - 10000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 60,
            allowClarifyingQuestions: true,
            automaticFollowUp: .plan
        )
        let active = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: captured,
            desiredSettings: desired,
            selectedFollowUp: .plan
        )
        XCTAssertEqual(active.behavior?.tokenBudget, range.lowerBound - 10000)
        XCTAssertEqual(active.tokenBudgetLabel, "\((range.lowerBound - 10000) / 1000)k")
    }

    func testSettledRunReturnsToIdleAuthorityEvenIfStaleCaptureIsOffered() {
        let stale = ContextBuilderRunBehavior(
            tokenBudget: 43000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 91,
            allowClarifyingQuestions: false,
            automaticFollowUp: nil
        )

        let presentation = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: stale,
            desiredSettings: Self.conflictingDesiredSettings,
            selectedFollowUp: .question
        )

        XCTAssertEqual(
            presentation,
            .idle(ContextBuilderRunBehavior.ui(settings: Self.conflictingDesiredSettings, selectedFollowUp: .question))
        )
        XCTAssertEqual(presentation.tokenBudgetLabel, "90k")
        XCTAssertEqual(presentation.modeLabel, "Rewrite")
        XCTAssertEqual(presentation.automaticFollowUp, .question)
        XCTAssertEqual(presentation.allowsClarifyingQuestions, true)
    }

    func testAutomaticFollowUpTooltipDescribesDesiredOrCapturedIntent() {
        var desired = Self.conflictingDesiredSettings
        desired.followUpAnalysisEnabled = false
        let idleOff = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .review
        )
        XCTAssertEqual(
            idleOff.automaticFollowUpTooltip(planModelName: "Model A"),
            "Automatic follow-up: Off\n\nTurn on to run the selected analysis after Context Builder"
        )

        desired.followUpAnalysisEnabled = true
        desired.analysisTokenBudget = ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound - 10000
        let idleOn = ContextBuilderBehaviorPresentation.resolve(
            isRunning: false,
            activeRunBehavior: nil,
            desiredSettings: desired,
            selectedFollowUp: .question
        )
        let normalizedBudget = ContextBuilderDefaults.analysisTokenBudgetRange.lowerBound / 1000
        XCTAssertEqual(
            idleOn.automaticFollowUpTooltip(planModelName: "Model A"),
            "Auto-run answer after Context Builder\n\nUses Model A with \(normalizedBudget)k tokens"
        )

        let capturedOff = ContextBuilderRunBehavior(
            tokenBudget: 43000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 91,
            allowClarifyingQuestions: false,
            automaticFollowUp: nil
        )
        let activeOff = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: capturedOff,
            desiredSettings: desired,
            selectedFollowUp: .question
        )
        XCTAssertEqual(activeOff.automaticFollowUpTooltip(planModelName: "Model A"), "Automatic follow-up: Off for this run")

        let capturedOn = ContextBuilderRunBehavior(
            tokenBudget: 43000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 91,
            allowClarifyingQuestions: false,
            automaticFollowUp: .plan
        )
        let activeOn = ContextBuilderBehaviorPresentation.resolve(
            isRunning: true,
            activeRunBehavior: capturedOn,
            desiredSettings: desired,
            selectedFollowUp: .question
        )
        XCTAssertEqual(
            activeOn.automaticFollowUpTooltip(planModelName: "Model A"),
            "Auto-run plan after Context Builder\n\nUses Model A with 43k tokens"
        )

        XCTAssertEqual(
            ContextBuilderBehaviorPresentation.unavailable.automaticFollowUpTooltip(planModelName: "Model A"),
            "Current run settings unavailable"
        )
    }

    func testQuestionTimeoutLabelUsesWholeMinutesOnlyWhenExact() {
        XCTAssertEqual(ContextBuilderBehaviorPresentation.questionTimeoutLabel(30), "30 sec")
        XCTAssertEqual(ContextBuilderBehaviorPresentation.questionTimeoutLabel(60), "1 min")
        XCTAssertEqual(ContextBuilderBehaviorPresentation.questionTimeoutLabel(91), "91 sec")
        XCTAssertEqual(ContextBuilderBehaviorPresentation.questionTimeoutLabel(300), "5 min")
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
