import Foundation

enum ACPProviderID: String, Codable, Hashable {
    case openCode
    case cursor
    case grokBuild
    case antigravity
    case devin
}

struct ACPDiscoveredSessionModels: Equatable {
    let options: [AgentModelOption]
    let currentModelRaw: String?
    /// The session's active reasoning effort (e.g. Grok's `_meta.reasoningEffort`), when the
    /// provider advertises one. Lets the controller skip redundant effort mutations.
    var currentEffortRaw: String?
    var modelParameterSets: [ACPModelParameterSet]

    init(
        options: [AgentModelOption],
        currentModelRaw: String?,
        currentEffortRaw: String? = nil,
        modelParameterSets: [ACPModelParameterSet] = []
    ) {
        self.options = options
        self.currentModelRaw = currentModelRaw
        self.currentEffortRaw = currentEffortRaw
        self.modelParameterSets = modelParameterSets
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

enum ACPModelParameterKind: String, Codable, Hashable, CaseIterable {
    case thinking
    case speed

    var sortOrder: Int {
        switch self {
        case .thinking: 0
        case .speed: 1
        }
    }
}

struct ACPModelParameterChoice: Codable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?

    init(rawValue: String, displayName: String, description: String? = nil) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
    }
}

struct ACPModelParameterDefinition: Codable, Hashable {
    let kind: ACPModelParameterKind
    let configID: String
    let displayName: String
    let choices: [ACPModelParameterChoice]
    let currentValueRaw: String

    func choice(matching requestedValue: String) -> ACPModelParameterChoice? {
        if let exact = choices.first(where: { $0.rawValue == requestedValue }) {
            return exact
        }
        let matches = choices.filter {
            $0.rawValue.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ACPModelParameterSet: Codable, Hashable {
    let baseModelRaw: String
    let parameters: [ACPModelParameterDefinition]

    func definition(configID: String) -> ACPModelParameterDefinition? {
        parameters.first { $0.configID == configID }
    }

    func definition(kind: ACPModelParameterKind) -> ACPModelParameterDefinition? {
        let matches = parameters.filter { $0.kind == kind }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Provenance for a synthesized reasoning-effort variant option: the base model raw and the
/// effort it encodes. Present only on variant options — bases and plain models leave it nil,
/// so no layer ever re-parses compound raw strings to recover the decomposition.
struct AgentModelEffortVariant: Hashable, Codable {
    let baseModelRaw: String
    let reasoningEffort: CodexReasoningEffort
}

struct AgentModelOption: Identifiable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?
    let isPlaceholderDefault: Bool
    let isProviderDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let defaultReasoningEffort: CodexReasoningEffort?
    let effortVariant: AgentModelEffortVariant?

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        effortVariant: AgentModelEffortVariant? = nil
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.effortVariant = effortVariant
    }

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        effortVariant: AgentModelEffortVariant? = nil
    ) {
        let isPlaceholder =
            rawValue.caseInsensitiveCompare("default") == .orderedSame
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        isPlaceholderDefault = isPlaceholder && isDefault
        isProviderDefault = !isPlaceholder && isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.effortVariant = effortVariant
    }

    var isDefault: Bool {
        isPlaceholderDefault || isProviderDefault
    }

    var id: String {
        rawValue
    }
}
