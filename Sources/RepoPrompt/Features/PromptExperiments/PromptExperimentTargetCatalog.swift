#if DEBUG
    import Foundation

    /// Prompt Experiment view over the existing Agent Mode target resolver and discovery catalog.
    /// Roles may follow the effective Agent Models profile; explicit compound IDs never mutate it.
    /// Only providers with an enforced tool-free completion profile are offered.
    @MainActor
    enum PromptExperimentTargetCatalog {
        private static let supportedAgents: Set<AgentProviderKind> = [
            .claudeCode,
            .claudeCodeGLM,
            .kimiCode,
            .customClaudeCompatible
        ]

        static func availableTargets(
            availability: AgentModelCatalog.AvailabilityContext = .current
        ) -> [PromptExperimentResolvedTarget] {
            let exactTargets = exactTargets(availability: availability)
            let roleTargets = AgentModelCatalog.taskLabels.compactMap { label -> PromptExperimentResolvedTarget? in
                try? resolve(
                    label.label,
                    availability: availability,
                    exactTargets: exactTargets
                )
            }
            return roleTargets + exactTargets
        }

        static func resolve(
            _ rawSelector: String,
            availability: AgentModelCatalog.AvailabilityContext = .current
        ) throws -> PromptExperimentResolvedTarget {
            try resolve(
                rawSelector,
                availability: availability,
                exactTargets: exactTargets(availability: availability)
            )
        }

        static func resolve(
            _ rawSelector: String,
            availability: AgentModelCatalog.AvailabilityContext,
            exactTargets: [PromptExperimentResolvedTarget]
        ) throws -> PromptExperimentResolvedTarget {
            let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty else {
                throw PromptExperimentAuthorityError.targetUnavailable("Choose a catalog task role or exact agent:model target.")
            }

            if selector.contains(":") {
                guard let exact = exactTargets.first(where: {
                    $0.selector.caseInsensitiveCompare(selector) == .orderedSame
                }) else {
                    throw PromptExperimentAuthorityError.targetUnavailable(
                        "Target ‘\(selector)’ is not an available canonical Prompt Experiment target. Refresh capabilities or choose a target shown in the native picker."
                    )
                }
                return exact
            }

            do {
                let resolved = try AgentMCPSelectionResolver.resolve(
                    modelID: selector,
                    availability: availability,
                    surface: .headless
                )
                guard let agentRaw = resolved.agentRaw,
                      let modelRaw = resolved.modelRaw,
                      let agent = AgentProviderKind(rawValue: agentRaw),
                      supportedAgents.contains(agent),
                      let exact = exactTargets.first(where: {
                          guard $0.agentRaw == agentRaw else { return false }
                          return $0.modelRaw.caseInsensitiveCompare(modelRaw) == .orderedSame
                              || AgentModelCatalog.modelOptionIsSelected(
                                  optionRaw: $0.modelRaw,
                                  selectedRaw: modelRaw,
                                  agentKind: agent
                              )
                      })
                else {
                    throw PromptExperimentAuthorityError.targetUnavailable(
                        "No currently available, isolated Prompt Experiment target resolves for role ‘\(selector)’; ACP and unsupported provider families are excluded."
                    )
                }
                return PromptExperimentResolvedTarget(
                    role: selector.lowercased(),
                    agentRaw: exact.agentRaw,
                    modelRaw: exact.modelRaw,
                    displayName: exact.displayName
                )
            } catch let error as PromptExperimentAuthorityError {
                throw error
            } catch {
                throw PromptExperimentAuthorityError.targetUnavailable(error.localizedDescription)
            }
        }

        private static func exactTargets(
            availability: AgentModelCatalog.AvailabilityContext
        ) -> [PromptExperimentResolvedTarget] {
            var seen: Set<String> = []
            var targets: [PromptExperimentResolvedTarget] = []
            for agent in AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless)
                where agent.available && supportedAgents.contains(agent.agent)
            {
                for model in agent.models where model.available {
                    for target in model.startTargets where target.available {
                        guard target.modelRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else {
                            continue
                        }
                        let selector = target.selectionID.rawValue
                        let key = selector.lowercased()
                        guard seen.insert(key).inserted else { continue }
                        targets.append(PromptExperimentResolvedTarget(
                            role: selector,
                            agentRaw: target.selectionID.agentRaw,
                            modelRaw: target.modelRaw,
                            displayName: target.name
                        ))
                    }
                }
            }
            return targets.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }
#endif
