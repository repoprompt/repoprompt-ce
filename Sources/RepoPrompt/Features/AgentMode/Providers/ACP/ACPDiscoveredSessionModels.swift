import Foundation
import RepoPromptAIContracts

struct ACPDiscoveredSessionModels: Equatable {
    let options: [AgentModelOption]
    let currentModelRaw: String?
    /// The session's active reasoning effort (e.g. Grok's `_meta.reasoningEffort`), when the
    /// provider advertises one. Lets the controller skip redundant effort mutations.
    var currentEffortRaw: String?
    /// Ephemeral provenance copied from the controller's existing inbound sequence for an
    /// applicable direct effort report (including an unresolvable report). Bootstrap/warmed
    /// effort has no report provenance and cannot confirm a subsequent mutation.
    var currentEffortInboundSequence: UInt64?
    var modelParameterSets: [ACPModelParameterSet]
    /// False only for persisted model-only records written before parameter discovery.
    var hasModelParameterMetadata: Bool

    init(
        options: [AgentModelOption],
        currentModelRaw: String?,
        currentEffortRaw: String? = nil,
        modelParameterSets: [ACPModelParameterSet] = [],
        hasModelParameterMetadata: Bool = true
    ) {
        self.options = options
        self.currentModelRaw = currentModelRaw
        self.currentEffortRaw = currentEffortRaw
        self.modelParameterSets = modelParameterSets
        self.hasModelParameterMetadata = hasModelParameterMetadata
    }

    var preferredModelRaw: String? {
        if let current = option(matching: currentModelRaw) {
            // A confirmed non-default active effort resolves to its provenanced variant
            // (`grok-4.6` at low → `grok-4.6-low`); a default effort stays the bare base
            // alias, and nil/unresolvable effort falls back to the base.
            if let effortRaw = currentEffortRaw,
               let effort = CodexReasoningEffort.parse(effortRaw),
               effort != current.defaultReasoningEffort,
               let variant = options.first(where: {
                   $0.effortVariant?.reasoningEffort == effort
                       && $0.effortVariant?.baseModelRaw.caseInsensitiveCompare(current.rawValue) == .orderedSame
               })
            {
                return variant.rawValue
            }
            return current.rawValue
        }
        return Self.normalizedRawModel(currentModelRaw)
            ?? options.first(where: \.isProviderDefault)?.rawValue
            ?? options.first?.rawValue
    }

    func option(matching raw: String?) -> AgentModelOption? {
        guard let normalized = Self.normalizedRawModel(raw) else { return nil }
        return options.first {
            Self.normalizedRawModel($0.rawValue) == normalized
        }
    }

    func contains(rawModel: String?) -> Bool {
        option(matching: rawModel) != nil
    }

    private static func normalizedRawModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed.lowercased()
    }
}
