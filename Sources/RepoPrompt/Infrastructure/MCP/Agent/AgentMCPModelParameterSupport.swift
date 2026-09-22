import Foundation
import MCP

enum AgentMCPModelParameterSupport {
    /// Source of one-shot demand-scoped OpenCode model-parameter observations. Tests inject a
    /// per-call provider instead of mutating a global, so overlapping tests cannot race a shared
    /// override slot.
    typealias OneShotObservationProvider = (String?, String, Bool) async throws -> OpenCodeACPModelParameterSnapshot

    /// The live provider resolves through the shared demand-scoped polling service.
    static let liveOneShotObservationProvider: OneShotObservationProvider = { workspacePath, modelRaw, forceRefresh in
        try await OpenCodeACPModelPollingService.shared.discoverModelParametersOnce(
            workspacePath: workspacePath,
            modelRaw: modelRaw,
            forceRefresh: forceRefresh
        )
    }

    struct Request: Equatable {
        let configID: String
        let valueRaw: String
    }

    /// Cursor-only synchronous definitions (static catalogue). OpenCode parameter metadata is
    /// demand-scoped and asynchronous — use `definitions(agent:modelRaw:workspacePath:) async`,
    /// which acquires a one-shot observation for the resolved workspace/model first.
    static func definitions(agent: AgentProviderKind, modelRaw: String) -> [ACPModelParameterDefinition] {
        guard agent.acpProviderID == .cursor,
              let parameterSet = ACPModelParameterResolver.parameterSet(
                  providerID: .cursor,
                  selectedModelRaw: modelRaw
              )
        else { return [] }
        return sortedDefinitions(from: parameterSet)
    }

    /// Acquire parameter definitions for the resolved workspace/model, or an empty list when
    /// metadata is unavailable. Cancellation rethrows so the caller observes a cancelled read;
    /// an ordinary discovery failure or missing/unusable metadata is a best-effort empty
    /// list — never a fall back to the provider-global registry.
    static func definitions(
        agent: AgentProviderKind,
        modelRaw: String,
        workspacePath: String?,
        oneShot provider: OneShotObservationProvider = liveOneShotObservationProvider
    ) async throws -> [ACPModelParameterDefinition] {
        guard let providerID = agent.acpProviderID else { return [] }
        switch providerID {
        case .cursor:
            return definitions(agent: agent, modelRaw: modelRaw)
        case .openCode:
            do {
                guard let parameterSet = try await openCodeParameterSet(
                    modelRaw: modelRaw,
                    workspacePath: workspacePath,
                    // Best-effort read path: a retained terminal observation answers without a
                    // fresh probe.
                    forceRefresh: false,
                    oneShot: provider
                ) else { return [] }
                return sortedDefinitions(from: parameterSet)
            } catch {
                // Cancellation is honoured so a cancelled acquisition is not reported as empty
                // metadata; an ordinary discovery failure is a non-error empty list.
                if error is CancellationError {
                    throw error
                }
                return []
            }
        default:
            return []
        }
    }

    static func definitionValues(agent: AgentProviderKind, modelRaw: String) -> [Value] {
        definitionValues(definitions(agent: agent, modelRaw: modelRaw))
    }

    static func definitionValues(
        agent: AgentProviderKind,
        modelRaw: String,
        workspacePath: String?,
        oneShot provider: OneShotObservationProvider = liveOneShotObservationProvider
    ) async throws -> [Value] {
        let definitions = try await definitions(
            agent: agent,
            modelRaw: modelRaw,
            workspacePath: workspacePath,
            oneShot: provider
        )
        return definitionValues(definitions)
    }

    private static func definitionValues(_ definitions: [ACPModelParameterDefinition]) -> [Value] {
        definitions.map { definition in
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

    /// Synchronously resolve explicit parameter selections against the static Cursor catalogue.
    /// OpenCode requests must use the throwing async overload, which forces a fresh targeted
    /// observation before validating the raw value.
    static func resolve(
        value: Value?,
        agent: AgentProviderKind?,
        modelRaw: String?
    ) throws -> [ACPModelParameterSelection] {
        guard let value else { return [] }
        let requests = try parseRequests(value)
        guard !requests.isEmpty else { return [] }
        guard let agent,
              agent.acpProviderID != nil
        else {
            throw MCPError.invalidParams("model_parameters are supported only for ACP models.")
        }
        guard agent == .cursor else {
            throw MCPError.invalidParams(
                "Model parameter metadata is unavailable for the selected model."
            )
        }
        return try resolve(requests: requests, providerID: .cursor, modelRaw: modelRaw)
    }

    /// Asynchronous resolver that accepts an explicit OpenCode parameter request only after a
    /// fresh targeted observation validates the raw value. The explicit-request resolver owns
    /// the freshness policy: an explicit new request is validated against a forced one-shot
    /// observation, which bypasses a retained completed observation but joins an existing
    /// identical acquisition (callers do not pass a freshness flag). Missing metadata, discovery
    /// failure, or an unsupported value surface as the existing argument errors — never an empty
    /// successful list. Cancellation propagates.
    static func resolve(
        value: Value?,
        agent: AgentProviderKind?,
        modelRaw: String?,
        workspacePath: String?,
        oneShot provider: OneShotObservationProvider = liveOneShotObservationProvider
    ) async throws -> [ACPModelParameterSelection] {
        guard let value else { return [] }
        let requests = try parseRequests(value)
        guard !requests.isEmpty else { return [] }
        guard let agent,
              let providerID = agent.acpProviderID
        else {
            throw MCPError.invalidParams("model_parameters are supported only for ACP models.")
        }
        switch providerID {
        case .cursor:
            return try resolve(requests: requests, providerID: .cursor, modelRaw: modelRaw)
        case .openCode:
            guard let modelRaw else {
                throw MCPError.invalidParams(
                    "Model parameter metadata is unavailable for the selected model."
                )
            }
            let parameterSet: ACPModelParameterSet
            do {
                guard let resolved = try await openCodeParameterSet(
                    modelRaw: modelRaw,
                    workspacePath: workspacePath,
                    // Freshness policy lives here: explicit requests always re-probe.
                    forceRefresh: true,
                    oneShot: provider
                ) else {
                    throw MCPError.invalidParams(
                        "Model parameter metadata is unavailable for the selected model."
                    )
                }
                parameterSet = resolved
            } catch let error as MCPError {
                throw error
            } catch {
                if error is CancellationError {
                    // Cancellation must not be converted into "metadata unavailable".
                    throw error
                }
                // A discovery transport failure is reported as the existing "metadata
                // unavailable" argument error — never an empty successful list.
                throw MCPError.invalidParams(
                    "Model parameter metadata is unavailable for the selected model."
                )
            }
            return try requests.map { request in
                try selection(request: request, parameterSet: parameterSet, providerID: .openCode, modelRaw: modelRaw)
            }
        default:
            throw MCPError.invalidParams("model_parameters are supported only for ACP models.")
        }
    }

    private static func resolve(
        requests: [Request],
        providerID: ACPProviderID,
        modelRaw: String?
    ) throws -> [ACPModelParameterSelection] {
        guard let modelRaw,
              let parameterSet = ACPModelParameterResolver.parameterSet(
                  providerID: providerID,
                  selectedModelRaw: modelRaw
              )
        else {
            throw MCPError.invalidParams(
                "Model parameter metadata is unavailable for the selected model."
            )
        }
        return try requests.map { request in
            try selection(request: request, parameterSet: parameterSet, providerID: providerID, modelRaw: modelRaw)
        }
    }

    private static func selection(
        request: Request,
        parameterSet: ACPModelParameterSet,
        providerID: ACPProviderID,
        modelRaw: String
    ) throws -> ACPModelParameterSelection {
        guard let definition = parameterSet.definition(configID: request.configID) else {
            throw MCPError.invalidParams(
                "Unknown model parameter config_id '\(request.configID)' for model '\(modelRaw)'."
            )
        }
        guard let choice = definition.choice(matching: request.valueRaw) else {
            let allowed = definition.choices.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams(
                "Unknown value '\(request.valueRaw)' for model parameter '\(request.configID)'. Allowed values: \(allowed)."
            )
        }
        return ACPModelParameterSelection(
            providerID: providerID,
            baseModelRaw: parameterSet.baseModelRaw,
            kind: definition.kind,
            configID: definition.configID,
            valueRaw: choice.rawValue
        )
    }

    /// A one-shot OpenCode parameter observation reduced to its usable parameter set. Only a
    /// terminal `.available` observation whose key matches the requested (workspace, model)
    /// yields metadata; every other outcome is nil. Cancellation propagates (never converted to
    /// "missing metadata"); other provider errors also propagate so callers can distinguish
    /// "no metadata" from "discovery failed".
    private static func openCodeParameterSet(
        modelRaw: String,
        workspacePath: String?,
        forceRefresh: Bool,
        oneShot provider: OneShotObservationProvider
    ) async throws -> ACPModelParameterSet? {
        let snapshot = try await provider(workspacePath, modelRaw, forceRefresh)
        return ACPModelParameterResolver.parameterSet(
            providerID: .openCode,
            selectedModelRaw: modelRaw,
            workspacePath: workspacePath,
            openCodeParameters: snapshot
        )
    }

    /// Merge an inherited (role-pin) baseline with explicit request parameters. `normalized`
    /// de-duplicates per identity with last-wins, so an explicit request parameter overrides an
    /// inherited one for free.
    static func merged(
        inherited: [ACPModelParameterSelection],
        explicit: [ACPModelParameterSelection]
    ) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.normalized(inherited + explicit)
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
        guard let agentRaw,
              let agent = AgentProviderKind(rawValue: agentRaw),
              let providerID = agent.acpProviderID,
              let modelRaw
        else { return [] }
        return ACPModelParameterResolver.effectiveSelections(
            providerID: providerID,
            selectedModelRaw: modelRaw,
            persistedSelections: selections
        )
    }

    private static func sortedDefinitions(from parameterSet: ACPModelParameterSet) -> [ACPModelParameterDefinition] {
        parameterSet.parameters.sorted {
            if $0.kind.sortOrder != $1.kind.sortOrder {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.configID < $1.configID
        }
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
