import Foundation

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

struct ACPModelParameterSelection: Codable, Hashable {
    let providerID: ACPProviderID
    let baseModelRaw: String
    let kind: ACPModelParameterKind
    let configID: String
    let valueRaw: String

    var identity: ACPModelParameterIdentity {
        ACPModelParameterIdentity(
            providerID: providerID,
            baseModelRaw: baseModelRaw,
            kind: kind
        )
    }

    /// Build the single `.thinking` pin for an OpenCode-style effort chip selection. `configID`
    /// comes from the live advertised definition (never assumed to be `"effort"`); `valueRaw == nil`
    /// clears. Returns nil when there is nothing to store.
    static func thinkingPin(
        configID: String,
        valueRaw: String?,
        providerID: ACPProviderID,
        modelRaw: String
    ) -> [Self]? {
        let trimmedConfigID = configID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let valueRaw, !trimmedConfigID.isEmpty else { return nil }
        return [
            ACPModelParameterSelection(
                providerID: providerID,
                baseModelRaw: modelRaw,
                kind: .thinking,
                configID: trimmedConfigID,
                valueRaw: valueRaw
            )
        ]
    }

    static func normalized(_ selections: [Self]) -> [Self] {
        var valueByIdentity: [ACPModelParameterIdentity: Self] = [:]
        var orderedIdentities: [ACPModelParameterIdentity] = []
        for selection in selections {
            let identity = selection.identity
            if valueByIdentity[identity] == nil {
                orderedIdentities.append(identity)
            }
            valueByIdentity[identity] = selection
        }
        return orderedIdentities.compactMap { valueByIdentity[$0] }
    }

    static func selections(
        for providerID: ACPProviderID,
        activeBaseModelRaw: String,
        from selections: [Self]
    ) -> [Self] {
        let activeIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            activeBaseModelRaw,
            providerID: providerID
        )
        return normalized(selections).filter {
            $0.providerID == providerID
                && ACPModelParameterIdentity.canonicalBaseModelRaw(
                    $0.baseModelRaw,
                    providerID: providerID
                ) == activeIdentity
        }
    }
}

struct ACPModelParameterIdentity: Hashable {
    let providerID: ACPProviderID
    let canonicalBaseModelRaw: String
    let kind: ACPModelParameterKind

    init(
        providerID: ACPProviderID,
        baseModelRaw: String,
        kind: ACPModelParameterKind
    ) {
        self.providerID = providerID
        canonicalBaseModelRaw = Self.canonicalBaseModelRaw(baseModelRaw, providerID: providerID)
        self.kind = kind
    }

    static func canonicalBaseModelRaw(_ raw: String, providerID: ACPProviderID) -> String {
        if providerID == .cursor {
            // Pure identity: a saved parameter pin must resolve to the same identity before and
            // after Cursor's discovery snapshot warms, so this never consults membership.
            return CursorAIModelCatalog.canonicalIdentity(raw)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ACPResolvedModelParameter: Equatable {
    let baseModelRaw: String
    let definition: ACPModelParameterDefinition
    let selectedChoice: ACPModelParameterChoice
}

enum ACPModelParameterResolver {
    static func resolve(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection],
        workspacePath: String? = nil,
        openCodeParameters: OpenCodeACPModelParameterSnapshot? = nil
    ) -> [ACPResolvedModelParameter] {
        guard let parameterSet = parameterSet(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            workspacePath: workspacePath,
            openCodeParameters: openCodeParameters
        ) else { return [] }
        return resolve(
            parameterSet: parameterSet,
            providerID: providerID,
            persistedSelections: persistedSelections
        )
    }

    private static func resolve(
        parameterSet: ACPModelParameterSet,
        providerID: ACPProviderID,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPResolvedModelParameter] {
        parameterSet.parameters.sorted { $0.kind.sortOrder < $1.kind.sortOrder }.compactMap { definition in
            let definitionIdentity = ACPModelParameterIdentity(
                providerID: providerID,
                baseModelRaw: parameterSet.baseModelRaw,
                kind: definition.kind
            )
            let saved = persistedSelections.last { selection in
                selection.identity == definitionIdentity
            }
            // OpenCode must show unsupported saved intent, not a default that the next run
            // will never use. Cursor deliberately retains its existing display fallback.
            let savedChoice = saved.flatMap { selection in
                definition.choice(matching: selection.valueRaw)
                    ?? (
                        providerID == .openCode
                            ? ACPModelParameterChoice(rawValue: selection.valueRaw, displayName: selection.valueRaw)
                            : nil
                    )
            }
            guard let selectedChoice = savedChoice ?? definition.choice(matching: definition.currentValueRaw)
            else { return nil }
            return .init(
                baseModelRaw: parameterSet.baseModelRaw,
                definition: definition,
                selectedChoice: selectedChoice
            )
        }
    }

    static func parameterSet(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        workspacePath: String? = nil,
        openCodeParameters: OpenCodeACPModelParameterSnapshot? = nil
    ) -> ACPModelParameterSet? {
        switch providerID {
        case .cursor:
            CursorAIModelCatalog.parameterSet(for: selectedModelRaw)
        case .openCode:
            openCodeParameterSet(
                selectedModelRaw: selectedModelRaw,
                workspacePath: workspacePath,
                observation: openCodeParameters
            )
        default:
            nil
        }
    }

    /// Accept OpenCode metadata only when the observation is `.available`, its key matches the
    /// requested normalized workspace+model exactly, and the advertised set matches that model
    /// unambiguously. Missing or mismatched context yields no parameter set — never a fall back
    /// to the provider-global registry, whose per-provider snapshot cannot represent the
    /// demand-scoped `(workspace, model)` authority.
    private static func openCodeParameterSet(
        selectedModelRaw: String,
        workspacePath: String?,
        observation: OpenCodeACPModelParameterSnapshot?
    ) -> ACPModelParameterSet? {
        guard let observation,
              case let .available(parameterSet) = observation.state
        else { return nil }
        let targetIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            selectedModelRaw,
            providerID: .openCode
        )
        // Compare the constructed expected key directly; `observation.key`'s fields are already
        // canonical at construction, so re-canonicalizing them would be a no-op. Key equality
        // covers both the canonical model identity and the normalized workspace.
        let expectedKey = OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: selectedModelRaw)
        guard observation.key == expectedKey else { return nil }
        guard ACPModelParameterIdentity.canonicalBaseModelRaw(
            parameterSet.baseModelRaw,
            providerID: .openCode
        ) == targetIdentity else { return nil }
        return parameterSet
    }

    static func effectiveSelections(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: selectedModelRaw,
            from: persistedSelections
        )
    }
}
