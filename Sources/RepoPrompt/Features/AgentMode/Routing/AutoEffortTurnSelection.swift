import Foundation

/// Ephemeral choice for one composer-created user turn. Never written to the model picker or settings.
struct AutoEffortTurnSelection: Equatable {
    let provider: AgentProviderKind
    let selectedModelRaw: String
    let manualEffortRaw: String?
    let effortRaw: String

    func isCurrent(
        provider currentProvider: AgentProviderKind,
        selectedModelRaw currentModelRaw: String,
        manualEffortRaw currentManualEffortRaw: String?,
        enabled: Bool
    ) -> Bool {
        enabled
            && provider == currentProvider
            && selectedModelRaw == currentModelRaw
            && manualEffortRaw == currentManualEffortRaw
    }
}

/// UI-only record of a Jev choice for a submitted user turn. It is not persisted and does not
/// claim that the provider cached or completed the turn.
struct AutoEffortTurnFeedback: Equatable {
    enum Direction: Equatable {
        case up, down, unchanged, unknown
    }

    let provider: AgentProviderKind
    let selectedModelRaw: String
    let effortRaw: String
    let direction: Direction

    init(selection: AutoEffortTurnSelection, previous: AutoEffortTurnFeedback?) {
        provider = selection.provider
        selectedModelRaw = selection.selectedModelRaw
        effortRaw = selection.effortRaw
        let previousEffort = previous.flatMap {
            $0.provider == selection.provider && $0.selectedModelRaw == selection.selectedModelRaw
                ? $0.effortRaw : nil
        } ?? selection.manualEffortRaw
        let order = ["low", "medium", "high", "xhigh", "max"]
        if let before = previousEffort.flatMap({ order.firstIndex(of: $0) }),
           let after = order.firstIndex(of: selection.effortRaw)
        {
            direction = after > before ? .up : (after < before ? .down : .unchanged)
        } else {
            direction = .unknown
        }
    }
}

/// Conservative exact-model admission. The provider's live effort catalog supplies the choices;
/// a model name alone never authorizes an effort that the active runtime does not advertise.
enum AutoEffortModelPolicy {
    private static let codexModels: Set<String> = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
    private static let claudeModels: Set<String> = [
        "claude-opus-5", "claude-opus-5-5", "claude-fable-5-1", "claude-mythos-5-1"
    ]

    /// Custom workflow templates are user-authored and may contain private content. The
    /// built-in category is fixed application metadata; never send the template itself.
    static func shouldJudgeWorkflow(_ workflow: AgentWorkflowDefinition?) -> Bool {
        workflow == nil || workflow?.builtInWorkflow != nil
    }

    static func shouldJudgeMCPUserTurn(
        isEnabled: Bool,
        startsNewRun: Bool,
        hasPriorUserTurn: Bool,
        isNativePreparedTurn: Bool
    ) -> Bool {
        isEnabled && startsNewRun && hasPriorUserTurn && !isNativePreparedTurn
    }

    static func codexEfforts(modelRaw: String, advertised: [CodexReasoningEffort]) -> [String] {
        guard let base = CodexModelSpecifier(raw: modelRaw).baseModel?.lowercased(),
              codexModels.contains(base)
        else { return [] }
        let permitted: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
        return permitted.filter { advertised.contains($0) }.map(\.rawValue)
    }

    static func claudeEfforts(modelRaw: String, advertised: [ClaudeCodeEffortLevel]) -> [String] {
        guard let base = ClaudeModelSpecifier(raw: modelRaw).baseModel?.lowercased(),
              claudeModels.contains(base)
        else { return [] }
        let permitted: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .xhigh, .max]
        return permitted.filter { advertised.contains($0) }.map(\.rawValue)
    }
}
