import Foundation

private struct GrokBuildAdvertisedEffortEntry {
    let idRaw: String?
    let valueRaw: String?
    let reasoningEffort: CodexReasoningEffort?
    let isDefault: Bool
}

private struct GrokBuildAdvertisedEffortState {
    let entries: [GrokBuildAdvertisedEffortEntry]
    let wireValueByEffort: [CodexReasoningEffort: String]
}

// MARK: - ACPDirectSessionModelProvider

extension GrokBuildACPAgentProvider: ACPDirectSessionModelProvider {
    /// Parses Grok's top-level `models` (`SessionModelState`) from a `session/new` or
    /// `session/load` response. Verified against grok 1.0.4: the response carries
    /// `{sessionId, models: {currentModelId, availableModels: [{modelId, name, description?,
    /// _meta?}]}, _meta}` and no modern `configOptions`.
    func parseDirectSessionModelSnapshot(
        from sessionResponse: [String: Any]
    ) -> ACPProviderModelSnapshotResult {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { return nil }
            return trimmed
        }

        let sessionID = nonEmpty(sessionResponse["sessionId"] as? String)
        guard let modelsValue = sessionResponse["models"] else {
            directEffortWireState.markUnavailable(sessionID: sessionID)
            return .absent
        }
        guard let models = modelsValue as? [String: Any] else {
            directEffortWireState.markUnavailable(sessionID: sessionID)
            return .malformed(reason: "Grok `models` metadata is not an object.")
        }
        guard let available = models["availableModels"] as? [[String: Any]] else {
            directEffortWireState.markUnavailable(sessionID: sessionID)
            return .malformed(reason: "Grok `models.availableModels` is missing or not an array.")
        }

        var options: [AgentModelOption] = []
        var variants: [AgentModelOption] = []
        var seen = Set<String>()
        var effortStateByModelRaw: [String: GrokBuildAdvertisedEffortState] = [:]
        var wireValuesByModelRaw: [String: [CodexReasoningEffort: String]] = [:]
        for entry in available {
            guard let rawID = nonEmpty(entry["modelId"] as? String) else { continue }
            guard seen.insert(rawID).inserted else { continue }
            let displayName = nonEmpty(entry["name"] as? String) ?? rawID
            let description = nonEmpty(entry["description"] as? String)

            let meta = entry["_meta"] as? [String: Any]
            let supportsEffort = (meta?["supportsReasoningEffort"] as? Bool) == true
            let effortEntries = supportsEffort ? (meta?["reasoningEfforts"] as? [[String: Any]] ?? []) : []
            let advertisedEfforts = effortEntries.map { effortEntry in
                let valueRaw = nonEmpty(effortEntry["value"] as? String)
                return GrokBuildAdvertisedEffortEntry(
                    idRaw: nonEmpty(effortEntry["id"] as? String),
                    valueRaw: valueRaw,
                    reasoningEffort: CodexReasoningEffort.parse(valueRaw),
                    isDefault: (effortEntry["default"] as? Bool) == true
                )
            }

            // A semantic effort is selectable only when every advertised spelling collapses
            // to one exact wire value. Aliases such as `maximum` remain intact; competing
            // spellings (`max` and `maximum`) are ambiguous and therefore unavailable.
            var wireValuesByEffort: [CodexReasoningEffort: Set<String>] = [:]
            for advertised in advertisedEfforts {
                guard let effort = advertised.reasoningEffort,
                      let valueRaw = advertised.valueRaw
                else { continue }
                wireValuesByEffort[effort, default: []].insert(valueRaw)
            }
            let selectableEfforts: [(effort: CodexReasoningEffort, wireValueRaw: String)] =
                CodexReasoningEffort.displayOrder.compactMap { effort in
                    guard let values = wireValuesByEffort[effort],
                          values.count == 1,
                          let wireValueRaw = values.first
                    else { return nil }
                    return (effort, wireValueRaw)
                }
            let wireValueByEffort = Dictionary(
                uniqueKeysWithValues: selectableEfforts.map { ($0.effort, $0.wireValueRaw) }
            )
            effortStateByModelRaw[rawID.lowercased()] = GrokBuildAdvertisedEffortState(
                entries: advertisedEfforts,
                wireValueByEffort: wireValueByEffort
            )
            wireValuesByModelRaw[rawID.lowercased()] = wireValueByEffort

            let declaredDefault = supportsEffort
                ? CodexReasoningEffort.parse(meta?["reasoningEffort"] as? String)
                : nil
            // Count every list-default entry before parsing/filtering. Any unknown,
            // incomplete, or competing default keeps the fallback non-authoritative.
            let listDefault: CodexReasoningEffort? = {
                let defaults = advertisedEfforts.filter(\.isDefault)
                guard !defaults.isEmpty,
                      defaults.allSatisfy({ $0.reasoningEffort != nil })
                else { return nil }
                let distinct = Set(defaults.compactMap(\.reasoningEffort))
                guard distinct.count == 1,
                      let effort = distinct.first,
                      wireValueByEffort[effort] != nil
                else { return nil }
                return effort
            }()
            let defaultEffort = [declaredDefault, listDefault]
                .compactMap(\.self)
                .first(where: { wireValueByEffort[$0] != nil })
            let supportedEfforts = selectableEfforts.map(\.effort)

            options.append(
                AgentModelOption(
                    rawValue: rawID,
                    displayName: displayName,
                    description: description,
                    isPlaceholderDefault: false,
                    isProviderDefault: false,
                    supportedReasoningEfforts: supportedEfforts,
                    defaultReasoningEffort: defaultEffort
                )
            )

            for selection in selectableEfforts {
                let compound = "\(rawID)-\(selection.effort.rawValue)"
                let collidesWithBase = available.contains {
                    guard let otherID = nonEmpty($0["modelId"] as? String) else { return false }
                    return otherID.caseInsensitiveCompare(compound) == .orderedSame
                }
                if collidesWithBase { continue }
                variants.append(
                    AgentModelOption(
                        rawValue: compound,
                        displayName: "\(displayName) \(selection.effort.displayName)",
                        description: description,
                        isPlaceholderDefault: false,
                        isProviderDefault: false,
                        effortVariant: AgentModelEffortVariant(
                            baseModelRaw: rawID,
                            reasoningEffort: selection.effort
                        )
                    )
                )
            }
        }
        let currentRaw: String? = if let current = nonEmpty(models["currentModelId"] as? String) {
            options.first(where: { $0.rawValue.caseInsensitiveCompare(current) == .orderedSame })?.rawValue
        } else {
            nil
        }
        options.append(contentsOf: variants)
        guard !options.isEmpty else {
            directEffortWireState.markUnavailable(sessionID: sessionID)
            return .malformed(reason: "Grok `models.availableModels` contains no usable models.")
        }

        let sessionConfig = (sessionResponse["_meta"] as? [String: Any])?["x.ai/sessionConfig"] as? [String: Any]
        let sessionOptions = sessionConfig?["options"] as? [[String: Any]] ?? []
        let selectedModeEntries = sessionOptions.filter {
            ($0["category"] as? String) == "mode" && ($0["selected"] as? Bool) == true
        }
        let currentEffortRaw: String? = {
            guard selectedModeEntries.count == 1,
                  let selectedID = nonEmpty(selectedModeEntries[0]["id"] as? String),
                  let currentRaw,
                  let state = effortStateByModelRaw[currentRaw.lowercased()]
            else { return nil }
            let matches = state.entries.filter { entry in
                let idMatches = entry.idRaw.map {
                    $0.caseInsensitiveCompare(selectedID) == .orderedSame
                } ?? false
                let valueMatches = entry.valueRaw.map {
                    $0.caseInsensitiveCompare(selectedID) == .orderedSame
                } ?? false
                return idMatches || valueMatches
            }
            guard !matches.isEmpty,
                  matches.allSatisfy({ entry in
                      guard let effort = entry.reasoningEffort else { return false }
                      return state.wireValueByEffort[effort] != nil
                  })
            else { return nil }
            let distinctEfforts = Set(matches.compactMap(\.reasoningEffort))
            guard distinctEfforts.count == 1 else { return nil }
            return distinctEfforts.first?.rawValue
        }()

        directEffortWireState.replace(
            sessionID: sessionID,
            valuesByModelRaw: wireValuesByModelRaw
        )
        return .valid(ACPDiscoveredSessionModels(
            options: options,
            currentModelRaw: currentRaw,
            currentEffortRaw: currentEffortRaw
        ))
    }

    func makeDirectModelSelectionRequest(
        sessionID: String,
        baseModelRaw: String,
        reasoningEffortRaw: String?
    ) -> ACPDirectModelSelectionRequest {
        var params: [String: Any] = ["sessionId": sessionID, "modelId": baseModelRaw]
        var expectedConfirmationModelRaw = baseModelRaw
        if let trimmed = reasoningEffortRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           let effort = CodexReasoningEffort.parse(trimmed)
        {
            switch directEffortWireState.lookup(
                sessionID: sessionID,
                baseModelRaw: baseModelRaw,
                effort: effort
            ) {
            case let .exact(wireValueRaw):
                params["_meta"] = ["reasoningEffort": wireValueRaw]
            case .uninitialized:
                // Direct request-shape callers that have not parsed a session snapshot retain
                // the exact supplied value. Runtime selections always install live state first.
                params["_meta"] = ["reasoningEffort": trimmed]
            case .unavailable:
                // The request builder cannot throw. Make any base-only acknowledgement fail
                // closed so the controller invalidates authority and never proceeds as though
                // an ambiguous/missing effort value was applied.
                expectedConfirmationModelRaw = "\u{0}grok-effort-wire-value-unavailable"
            }
        }
        return ACPDirectModelSelectionRequest(
            method: "session/set_model",
            params: params,
            expectedConfirmationModelRaw: expectedConfirmationModelRaw
        )
    }
}
