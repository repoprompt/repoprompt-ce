import Foundation

package enum ACPProviderID: String, Codable, Hashable {
    case openCode
    case cursor
    case grokBuild
    case antigravity
    case devin
}

package enum ACPModelParameterKind: String, Codable, Hashable, CaseIterable {
    case thinking
    case speed

    package var sortOrder: Int {
        switch self {
        case .thinking: 0
        case .speed: 1
        }
    }
}

package struct ACPModelParameterChoice: Codable, Hashable {
    package let rawValue: String
    package let displayName: String
    package let description: String?

    package init(rawValue: String, displayName: String, description: String? = nil) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
    }
}

package struct ACPModelParameterDefinition: Codable, Hashable {
    package let kind: ACPModelParameterKind
    package let configID: String
    package let displayName: String
    package let choices: [ACPModelParameterChoice]
    package let currentValueRaw: String

    package func choice(matching requestedValue: String) -> ACPModelParameterChoice? {
        if let exact = choices.first(where: { $0.rawValue == requestedValue }) {
            return exact
        }
        let matches = choices.filter {
            $0.rawValue.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    package init(
        kind: ACPModelParameterKind,
        configID: String,
        displayName: String,
        choices: [ACPModelParameterChoice],
        currentValueRaw: String
    ) {
        self.kind = kind
        self.configID = configID
        self.displayName = displayName
        self.choices = choices
        self.currentValueRaw = currentValueRaw
    }
}

package struct ACPModelParameterSet: Codable, Hashable {
    package let baseModelRaw: String
    package let parameters: [ACPModelParameterDefinition]

    package func definition(configID: String) -> ACPModelParameterDefinition? {
        parameters.first { $0.configID == configID }
    }

    package func definition(kind: ACPModelParameterKind) -> ACPModelParameterDefinition? {
        let matches = parameters.filter { $0.kind == kind }
        return matches.count == 1 ? matches[0] : nil
    }

    package init(
        baseModelRaw: String,
        parameters: [ACPModelParameterDefinition]
    ) {
        self.baseModelRaw = baseModelRaw
        self.parameters = parameters
    }
}

package struct ACPModelParameterSelection: Codable, Hashable {
    package let providerID: ACPProviderID
    package let baseModelRaw: String
    package let kind: ACPModelParameterKind
    package let configID: String
    package let valueRaw: String

    package var identity: ACPModelParameterIdentity {
        ACPModelParameterIdentity(
            providerID: providerID,
            baseModelRaw: baseModelRaw,
            kind: kind
        )
    }

    /// Build the single `.thinking` pin for an OpenCode-style effort chip selection. `configID`
    /// comes from the live advertised definition (never assumed to be `"effort"`); `valueRaw == nil`
    /// clears. Returns nil when there is nothing to store.
    package static func thinkingPin(
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

    package static func normalized(_ selections: [Self]) -> [Self] {
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

    package static func selections(
        for providerID: ACPProviderID,
        activeBaseModelRaw: String,
        from selections: [Self]
    ) -> [Self] {
        // Devin effort is encoded in the model ID; a stored pin must never override it.
        guard providerID != .devin else { return [] }
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

    package init(
        providerID: ACPProviderID,
        baseModelRaw: String,
        kind: ACPModelParameterKind,
        configID: String,
        valueRaw: String
    ) {
        self.providerID = providerID
        self.baseModelRaw = baseModelRaw
        self.kind = kind
        self.configID = configID
        self.valueRaw = valueRaw
    }
}

package struct ACPModelParameterIdentity: Hashable {
    package let providerID: ACPProviderID
    package let canonicalBaseModelRaw: String
    package let kind: ACPModelParameterKind

    package init(
        providerID: ACPProviderID,
        baseModelRaw: String,
        kind: ACPModelParameterKind
    ) {
        self.providerID = providerID
        canonicalBaseModelRaw = Self.canonicalBaseModelRaw(baseModelRaw, providerID: providerID)
        self.kind = kind
    }

    package static func canonicalBaseModelRaw(_ raw: String, providerID: ACPProviderID) -> String {
        if providerID == .cursor {
            return SettingsModelIdentityPolicy.canonicalCursorModelRaw(raw)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

package struct ACPResolvedModelParameter: Equatable {
    package let baseModelRaw: String
    package let definition: ACPModelParameterDefinition
    package let selectedChoice: ACPModelParameterChoice

    package init(
        baseModelRaw: String,
        definition: ACPModelParameterDefinition,
        selectedChoice: ACPModelParameterChoice
    ) {
        self.baseModelRaw = baseModelRaw
        self.definition = definition
        self.selectedChoice = selectedChoice
    }
}
