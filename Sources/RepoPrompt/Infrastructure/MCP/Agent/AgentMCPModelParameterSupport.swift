import Foundation
import MCP

enum AgentMCPModelParameterSupport {
    struct Request: Equatable {
        let configID: String
        let valueRaw: String
    }

    static func definitions(modelRaw: String) -> [ACPModelParameterDefinition] {
        guard let parameterSet = CursorAIModelCatalog.parameterSet(for: modelRaw)
        else { return [] }
        return parameterSet.parameters.sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.configID < $1.configID
        }
    }

    static func definitionValues(modelRaw: String) -> [Value] {
        definitions(modelRaw: modelRaw).map { definition in
            let object: [String: Value] = [
                "kind": .string(definition.kind.rawValue),
                "config_id": .string(definition.configID),
                "name": .string(definition.displayName),
                "current_value": .string(definition.currentValueRaw),
                "choices": .array(definition.choices.map { choice in
                    var choiceObject: [String: Value] = [
                        "value": .string(choice.rawValue),
                        "name": .string(choice.displayName)
                    ]
                    if let description = choice.description {
                        choiceObject["description"] = .string(description)
                    }
                    return .object(choiceObject)
                })
            ]
            return .object(object)
        }
    }

    static func resolve(
        value: Value?,
        agent: AgentProviderKind?,
        modelRaw: String?
    ) throws -> [ACPModelParameterSelection] {
        guard let value else { return [] }
        let requests = try parseRequests(value)
        guard !requests.isEmpty else { return [] }
        guard agent == .cursor else {
            throw MCPError.invalidParams("model_parameters are supported only for Cursor models.")
        }
        guard let modelRaw,
              let parameterSet = CursorAIModelCatalog.parameterSet(for: modelRaw)
        else {
            throw MCPError.invalidParams(
                "Cursor model parameter metadata is unavailable for the selected model. Use a model advertised by this RepoPrompt release."
            )
        }

        return try requests.map { request in
            guard let definition = parameterSet.definition(configID: request.configID) else {
                throw MCPError.invalidParams(
                    "Unknown Cursor model parameter config_id '\(request.configID)' for model '\(modelRaw)'."
                )
            }
            guard let choice = definition.choice(matching: request.valueRaw) else {
                let allowed = definition.choices.map(\.rawValue).joined(separator: ", ")
                throw MCPError.invalidParams(
                    "Unknown value '\(request.valueRaw)' for Cursor model parameter '\(request.configID)'. Allowed values: \(allowed)."
                )
            }
            return ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: parameterSet.baseModelRaw,
                kind: definition.kind,
                configID: definition.configID,
                valueRaw: choice.rawValue
            )
        }
    }

    static func selectionValues(_ selections: [ACPModelParameterSelection]) -> [Value] {
        ACPModelParameterSelection.normalized(selections).map { selection in
            .object([
                "provider_id": .string(selection.providerID.rawValue),
                "base_model": .string(selection.baseModelRaw),
                "kind": .string(selection.kind.rawValue),
                "config_id": .string(selection.configID),
                "value": .string(selection.valueRaw)
            ])
        }
    }

    static func effectiveSelections(
        _ selections: [ACPModelParameterSelection],
        agentRaw: String?,
        modelRaw: String?
    ) -> [ACPModelParameterSelection] {
        guard agentRaw == AgentProviderKind.cursor.rawValue,
              let modelRaw
        else { return [] }
        return ACPModelParameterResolver.effectiveSelections(
            providerID: .cursor,
            selectedModelRaw: modelRaw,
            persistedSelections: selections
        )
    }

    private static func parseRequests(_ value: Value) throws -> [Request] {
        guard let values = value.arrayValue else {
            throw MCPError.invalidParams("model_parameters must be an array of {config_id, value} objects.")
        }
        var seenConfigIDs = Set<String>()
        return try values.enumerated().map { index, value in
            guard let object = value.objectValue else {
                throw MCPError.invalidParams("model_parameters[\(index)] must be an object.")
            }
            let configID = try requiredString(object["config_id"], name: "model_parameters[\(index)].config_id")
            let valueRaw = try requiredString(object["value"], name: "model_parameters[\(index)].value")
            guard seenConfigIDs.insert(configID).inserted else {
                throw MCPError.invalidParams("model_parameters contains duplicate config_id '\(configID)'.")
            }
            return Request(configID: configID, valueRaw: valueRaw)
        }
    }

    private static func requiredString(_ value: Value?, name: String) throws -> String {
        guard let string = value?.stringValue,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPError.invalidParams("\(name) must be a non-empty string.")
        }
        return string
    }
}
