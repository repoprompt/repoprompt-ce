import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// The decision and feedback belong to the admitted session, not its status-pill presenter.
@MainActor
struct AgentAutoEffortTurnPolicy {
    let modelRouterSettingsStore: GlobalSettingsStore
    let modelRouterRuntime: AgentTaskRouterRuntime?
    let codexCoordinator: CodexAgentModeCoordinator
    let claudeCoordinator: ClaudeAgentModeCoordinator
    let ownsSession: (AgentTabSession) -> Bool
    var didChange: (AgentTabSession) -> Void = { _ in }

    /// Shared pre-turn judgment. MCP calls this only before an inactive run starts, never to
    /// change effort in the middle of an active provider turn or override an initial routed start.
    func chooseAutoEffortForUserTurn(
        text: String,
        session: AgentTabSession,
        workflow: AgentWorkflowDefinition?,
        requestID: UUID = UUID(),
        isSpeculative: Bool = false,
        isRepromptReplacement: Bool = false,
        isCurrent: @MainActor () -> Bool
    ) async -> (selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature) {
        var admitted = true
        func admit() -> Bool {
            admitted = admitted && isCurrent()
            return admitted
        }
        guard admit() else { return ineligibleAutoEffortChoice() }
        let autoEffortConfiguration = modelRouterSettingsStore.autoEffortConfiguration()
        guard autoEffortConfiguration.enabled else {
            return (nil, .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled))
        }
        guard !session.runState.isActive,
              AutoEffortModelPolicy.shouldJudgeWorkflow(workflow),
              isRepromptReplacement || !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
              let maskedExcerpt = AutoEffortTaskSummary.make(from: text)
        else {
            return (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
        }
        guard let runtime = modelRouterRuntime,
              let backendID = autoEffortConfiguration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable))
        }

        let provider = session.selectedAgent
        let modelRaw = session.selectedModelRaw
        let selectedWorkflow = session.selectedWorkflow
        let workflowMutationGeneration = session.userWorkflowSelectionMutationGeneration
        let modelID: String
        let efforts: [String]
        let manualEffortRaw: String?
        switch provider {
        case .codexExec:
            guard let base = CodexModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            let option = codexCoordinator.modelOptions(for: .codexExec).first {
                CodexModelSpecifier(raw: $0.rawValue).baseModel?.caseInsensitiveCompare(base) == .orderedSame
            }
            modelID = base
            efforts = AutoEffortModelPolicy.codexEfforts(
                modelRaw: modelRaw,
                advertised: option?.supportedReasoningEfforts ?? []
            )
            manualEffortRaw = codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode:
            guard let base = ClaudeModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            modelID = base
            efforts = AutoEffortModelPolicy.claudeEfforts(
                modelRaw: modelRaw,
                advertised: AgentModelCatalog.supportedClaudeEfforts(
                    forSelectedModelRaw: modelRaw,
                    agentKind: provider
                )
            )
            manualEffortRaw = claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default:
            return ineligibleAutoEffortChoice()
        }
        guard admit(), efforts.count >= 2 else { return ineligibleAutoEffortChoice() }
        let judgmentID = requestID
        if !isSpeculative {
            session.autoEffortJudgmentID = judgmentID
        }
        if !isSpeculative { didChange(session) }
        defer {
            // Release only this operation's marker, even after claim loss. Leaving it would
            // block successor MCP turns; a different judgment UUID is never cleared.
            if !isSpeculative, session.autoEffortJudgmentID == judgmentID {
                session.autoEffortJudgmentID = nil
                didChange(session)
            }
        }
        guard let registration = await runtime.registry.registration(for: backendID),
              admit(),
              let prepared = try? AutoEffortDecisionPolicy().build(
                  requestID: judgmentID,
                  maskedTaskExcerpt: maskedExcerpt,
                  selectedModelID: modelID,
                  builtInWorkflow: workflow?.builtInWorkflow,
                  efforts: efforts,
                  capabilities: registration.capabilities
              )
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: false, decision: .fallback, fallbackApplied: true))
        }
        let outcome = await runtime.coordinator.decide(
            serviceID: backendID, request: prepared.request, consumerRevision: autoEffortConfiguration.revision
        )
        let chosen = prepared.effort(for: outcome)
        let currentAutoEffortConfiguration = modelRouterSettingsStore.autoEffortConfiguration()
        guard admit(), currentAutoEffortConfiguration.enabled,
              currentAutoEffortConfiguration.revision == autoEffortConfiguration.revision,
              currentAutoEffortConfiguration.selectedBackendRawValue == autoEffortConfiguration.selectedBackendRawValue,
              currentAutoEffortConfiguration.selectedBackendID == backendID,
              ownsSession(session),
              isSpeculative || session.autoEffortJudgmentID == judgmentID,
              session.selectedWorkflow == selectedWorkflow,
              session.userWorkflowSelectionMutationGeneration == workflowMutationGeneration,
              session.selectedAgent == provider,
              session.selectedModelRaw == modelRaw,
              !session.runState.isActive,
              let chosen, efforts.contains(chosen)
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        let currentManualEffortRaw: String? = switch provider {
        case .codexExec: codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode: claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default: nil
        }
        guard admit(), currentManualEffortRaw == manualEffortRaw else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        return (
            AutoEffortTurnSelection(
                provider: provider,
                selectedModelRaw: modelRaw,
                manualEffortRaw: manualEffortRaw,
                effortRaw: chosen,
                backendID: backendID,
                autoEffortRevision: autoEffortConfiguration.revision
            ),
            .init(
                configured: true, eligible: true, judgmentRequested: true, decision: .selected,
                chosenModelRaw: modelRaw, chosenEffortRaw: chosen
            )
        )
    }

    private func ineligibleAutoEffortChoice() -> (
        selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature
    ) {
        (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
    }

    func auditForSubmittedTurn(
        _ item: AgentChatItem, session: AgentTabSession, autoEffort: AgentAutomationTurnAudit.Feature
    ) -> AgentAutomationTurnAudit {
        let routerEnabled = modelRouterSettingsStore.modelRouterConfiguration().enabled
        return .init(
            turnID: item.id, createdAt: item.timestamp,
            router: .init(configured: routerEnabled, eligible: false, judgmentRequested: false, decision: routerEnabled ? .ineligible : .disabled),
            autoEffort: autoEffort, acceptedProviderRaw: session.selectedAgent.rawValue,
            acceptedModelRaw: session.selectedModelRaw, acceptedEffortRaw: session.selectedReasoningEffortRaw, reprompt: nil
        )
    }

    func recordSubmittedAutoEffort(_ selection: AutoEffortTurnSelection, for session: AgentTabSession) {
        guard ownsSession(session) else { return }
        session.autoEffortFeedback = AutoEffortTurnFeedback(
            selection: selection,
            previous: session.autoEffortFeedback
        )
        didChange(session)
    }
}
