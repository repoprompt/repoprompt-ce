import Foundation
import RepoPromptAIContracts

enum AgentTranscriptQualityRepair {
    enum Context: Equatable {
        case coldRestore(agentKindRaw: String?)
        case liveTerminal(agentKind: AgentProviderKind)
    }

    static func shouldFinalizeExplicitRepoPromptTools(context: Context) -> Bool {
        switch context {
        case .coldRestore:
            // A persisted terminal session cannot have a legitimately still-running
            // RepoPrompt MCP call. Repair every explicit tool family on cold restore.
            true
        case let .liveTerminal(agentKind):
            // ACP runtimes and Claude-native runs both surface explicit RepoPrompt MCP
            // calls through the shared transcript finalizer. Codex native keeps its
            // specialized command/tool finalization path.
            agentKind.acpProviderID != nil || agentKind.usesClaudeNativeRuntime
        }
    }

    @discardableResult
    static func finalizePendingTerminalTools(
        in items: inout [AgentChatItem],
        terminalState: AgentSessionRunState,
        context: Context,
        maxSequenceIndexExclusive: Int? = nil,
        nonToolBoundary: Int
    ) -> Int {
        guard terminalState != .idle, !terminalState.isActive else { return 0 }
        return AgentTranscriptIO.finalizePendingToolCalls(
            in: &items,
            terminalState: terminalState,
            includeExplicitRepoPromptToolCalls: shouldFinalizeExplicitRepoPromptTools(context: context),
            maxSequenceIndexExclusive: maxSequenceIndexExclusive,
            nonToolBoundary: nonToolBoundary
        )
    }

    static func terminalMetadataRepairNeeded(in transcript: AgentTranscript) -> Bool {
        transcript.turns.contains { terminalMetadataRepairNeeded(in: $0) }
    }

    private static func terminalMetadataRepairNeeded(in turn: AgentTranscriptTurn) -> Bool {
        let activities = turn.allActivities
        let expectedConclusionID = recomputedConclusionActivity(in: turn)?.id
        if turn.conclusionActivityID != expectedConclusionID {
            return true
        }
        guard let conclusionActivityID = turn.conclusionActivityID else {
            return false
        }
        guard let conclusion = activities.first(where: { $0.id == conclusionActivityID }) else {
            return true
        }
        guard conclusion.itemKind == .assistant || conclusion.itemKind == .assistantInline else {
            return expectedConclusionID != nil
        }
        return !AgentDisplayableText.hasDisplayableBody(conclusion.text)
    }

    private static func recomputedConclusionActivity(in turn: AgentTranscriptTurn) -> AgentTranscriptActivity? {
        let activities = turn.allActivities
        let assistantActivities = activities.filter {
            ($0.itemKind == .assistant || $0.itemKind == .assistantInline)
                && AgentDisplayableText.hasDisplayableBody($0.text)
        }
        let lastMiddleSequenceIndex = activities.last(where: {
            $0.itemKind != .assistant && $0.itemKind != .assistantInline
        })?.sequenceIndex ?? Int.min
        let trailingAssistantActivities = assistantActivities.filter { $0.sequenceIndex > lastMiddleSequenceIndex }
        return trailingAssistantActivities.reversed().first { activity in
            AgentTranscriptActivity(from: activity.toItem()).isSubstantiveAssistant
        } ?? trailingAssistantActivities.last
    }
}
