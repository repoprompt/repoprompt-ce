import Foundation

/// Builds router-owned model and effort choices from live provider catalogs.
///
/// Agent Models assignments are included as reference signals. They never restrict the candidates
/// or preselect a target because Router mode owns the final model-and-effort decision.
@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let utilityTier: String
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
        var usagePeerClass: String?
        var usageModelAliases: Set<String> = []
    }

    enum BuildError: Error, Equatable { case noAvailableTargets }

    struct RoleDefaultReference: Equatable {
        let roleLabel: String
        let provider: AgentProviderKind
        let modelRaw: String
        let isUserOverride: Bool
    }

    private struct ModelDefinition {
        let provider: AgentProviderKind
        let baseModelAliases: [String]
        let modelClass: String
        let preferredCodexFamily: String?
        let rubric: String

        /// Explicit substitution constraints, not a claim of identical model capabilities.
        var usagePeerClass: String? {
            switch modelClass {
            case "gpt-luna", "claude-haiku": "light"
            case "gpt-5.6-terra", "claude-sonnet": "balanced"
            case "gpt-sol", "claude-opus": "strong"
            case "gpt-6-astra", "claude-fable": "frontier"
            default: nil
            }
        }

        init(
            provider: AgentProviderKind,
            baseModelAliases: [String],
            modelClass: String,
            preferredCodexFamily: String? = nil,
            rubric: String
        ) {
            self.provider = provider
            self.baseModelAliases = baseModelAliases
            self.modelClass = modelClass
            self.preferredCodexFamily = preferredCodexFamily
            self.rubric = rubric
        }
    }

    let opaqueKey: () -> String
    private let modelOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption]

    init(
        opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() },
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) {
        self.opaqueKey = opaqueKey
        self.modelOptions = modelOptions
    }

    func build(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        roleDefaults: [RoleDefaultReference] = []
    ) throws -> [Candidate] {
        let definitions = eligibleDefinitions(
            allowedProviders: allowedProviders,
            availability: availability,
            surface: surface
        )
        var seenTargets: Set<AgentRoutingExecutableTarget> = []
        let candidates = definitions.compactMap { definition -> Candidate? in
            guard let baseModelRaw = resolvedBaseModelRaw(definition, availability: availability) else {
                return nil
            }
            let target = AgentRoutingExecutableTarget(
                agentRaw: definition.provider.rawValue,
                modelRaw: baseModelRaw,
                reasoningEffortRaw: nil,
                modelParameters: []
            )
            guard seenTargets.insert(target).inserted else { return nil }
            let key = opaqueKey()
            let utilityTier = definition.preferredCodexFamily == nil ? definition.modelClass : baseModelRaw
            let matchingRoleDefaults = roleDefaults.filter {
                $0.provider == definition.provider
                    && Self.baseModelRaw($0.modelRaw, provider: $0.provider)?
                    .caseInsensitiveCompare(baseModelRaw) == .orderedSame
            }
            return Candidate(
                opaqueKey: key,
                utilityTier: utilityTier,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: [utilityTier],
                    targetDescription: Self.modelDescription(
                        target,
                        displayName: AgentModelCatalog.displayName(
                            for: baseModelRaw,
                            agentKind: definition.provider,
                            availability: availability
                        ),
                        roleDefaults: matchingRoleDefaults
                    ),
                    rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                    rubric: definition.rubric
                ),
                usagePeerClass: definition.usagePeerClass,
                usageModelAliases: Set([baseModelRaw] + (definition.provider == .claudeCode ? definition.baseModelAliases.filter { ["opus", "sonnet", "haiku", "fable"].contains($0) } : []))
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    /// Whether `build` would return at least one candidate for the same inputs, without building any.
    ///
    /// Exactly equivalent to `(try? build(...)) != nil`: `build` is non-empty iff some eligible
    /// definition resolves a base model, because the first such definition's target is always new to
    /// its empty `seenTargets` set. This stops at that first definition and never mints opaque keys,
    /// resolves display names, or renders descriptions, so availability checks on hot presentation
    /// paths (the Model Router status pill) stay cheap.
    func hasAvailableTarget(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Bool {
        eligibleDefinitions(
            allowedProviders: allowedProviders,
            availability: availability,
            surface: surface
        ).contains { definition in
            resolvedBaseModelRaw(definition, availability: availability) != nil
        }
    }

    func buildEfforts(
        for model: Candidate,
        availability: AgentModelCatalog.AvailabilityContext,
        allowPaidFast: Bool = false
    ) throws -> [Candidate] {
        guard let provider = AgentProviderKind(rawValue: model.target.agentRaw) else {
            throw BuildError.noAvailableTargets
        }
        let selectedBase = Self.baseModelRaw(model.target.modelRaw, provider: provider)?.lowercased()
        guard let selectedBase else { throw BuildError.noAvailableTargets }

        let options = modelOptions(provider, availability)
        var targets: [(AgentRoutingExecutableTarget, String)] = []
        for option in options where !option.isPlaceholderDefault {
            guard allowPaidFast || provider != .codexExec || CodexModelSpecifier(raw: option.rawValue).serviceTier == nil else { continue }
            guard Self.baseModelRaw(option.rawValue, provider: provider)?.lowercased() == selectedBase else { continue }
            let target = Self.executableTarget(option.rawValue, provider: provider)
            targets.append((target, option.displayName))
            if provider == .codexExec,
               target.reasoningEffortRaw == nil,
               !option.supportedReasoningEfforts.isEmpty
            {
                for effort in option.supportedReasoningEfforts {
                    let raw = "\(model.target.modelRaw)-\(effort.rawValue)"
                    targets.append((Self.executableTarget(raw, provider: provider), "\(option.displayName) \(effort.displayName)"))
                }
            }
        }

        var seen: Set<AgentRoutingExecutableTarget> = []
        let candidates = targets.compactMap { target, displayName -> Candidate? in
            guard seen.insert(target).inserted else { return nil }
            let key = opaqueKey()
            let effort = Self.effortRaw(target, provider: provider) ?? "provider-default"
            return Candidate(
                opaqueKey: key,
                utilityTier: effort,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: ["effort:\(effort)"],
                    targetDescription: "Already selected model: \(displayName). \(AgentTaskRoutingModelProfileCatalog.effortDescription(for: target))",
                    rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                    rubric: "Choose this effort only if it supplies the reasoning depth the task needs. Prefer the lowest effort with a clear reliability margin; raise effort when ambiguity, review depth, risk, or long-horizon reasoning warrants it."
                )
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    /// Same catalog-owned peer classes for local composer/role starts and Jev recommendations.
    /// The selected target is retained exactly; unsupported/default identities are not guessed.
    func usageCandidates(
        basedOn target: AgentRoutingExecutableTarget,
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> (selected: Candidate, candidates: [Candidate])? {
        guard target.modelParameters.isEmpty, !Self.isPaidFast(target),
              let provider = AgentProviderKind(rawValue: target.agentRaw),
              let base = Self.baseModelRaw(target.modelRaw, provider: provider),
              let models = try? build(allowedProviders: allowedProviders, availability: availability, surface: surface),
              let definition = Self.modelDefinitions.first(where: { definition in
                  definition.provider == provider && (definition.baseModelAliases.contains(base) || models.contains {
                      $0.target.agentRaw == provider.rawValue && $0.target.modelRaw == base && $0.usagePeerClass == definition.usagePeerClass
                  })
              }), let peerClass = definition.usagePeerClass else { return nil }
        let selectedKey = opaqueKey()
        let selected = Candidate(
            opaqueKey: selectedKey,
            utilityTier: definition.modelClass,
            target: target,
            descriptor: .init(opaqueKey: selectedKey, roleLabels: [], targetDescription: "Local starting choice", rubricVersion: "local", rubric: ""),
            usagePeerClass: peerClass,
            usageModelAliases: Set([base] + definition.baseModelAliases.filter { ["opus", "sonnet", "haiku", "fable"].contains($0) })
        )
        let effort = Self.effortRaw(target, provider: provider)
        let peers = models.filter { $0.usagePeerClass == peerClass && $0.target.agentRaw != provider.rawValue }.compactMap { model -> Candidate? in
            guard let effort else { return model }
            guard let efforts = try? buildEfforts(for: model, availability: availability),
                  let peerProvider = AgentProviderKind(rawValue: model.target.agentRaw),
                  let match = efforts.first(where: { Self.effortRaw($0.target, provider: peerProvider) == effort }) else { return nil }
            return Candidate(
                opaqueKey: model.opaqueKey,
                utilityTier: model.utilityTier,
                target: match.target,
                descriptor: model.descriptor,
                usagePeerClass: model.usagePeerClass,
                usageModelAliases: model.usageModelAliases
            )
        }
        return (selected, [selected] + peers)
    }

    static func isPaidFast(_ target: AgentRoutingExecutableTarget) -> Bool {
        (target.agentRaw == AgentProviderKind.codexExec.rawValue && CodexModelSpecifier(raw: target.modelRaw).serviceTier != nil)
            || target.modelParameters.contains { $0.configID == "fast" && $0.valueRaw == "true" }
    }

    static func availableProviders(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Set<AgentProviderKind> {
        Set([AgentProviderKind.codexExec, .claudeCode].filter {
            surface.allows($0) && AgentModelCatalog.isAgentAvailable($0, availability: availability)
        })
    }

    /// A saved provider choice is a live preference rather than an availability gate. Use it
    /// exclusively while authenticated; otherwise keep routing with the remaining verified
    /// providers and automatically resume the preference when it becomes available again.
    static func providers(
        preferring preferredProvider: AgentProviderKind?,
        from availableProviders: Set<AgentProviderKind>
    ) -> Set<AgentProviderKind> {
        guard let preferredProvider,
              availableProviders.contains(preferredProvider)
        else { return availableProviders }
        return [preferredProvider]
    }

    private static let modelDefinitions: [ModelDefinition] = [
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-luna", "gpt-5.6-luna"],
            modelClass: "gpt-luna",
            preferredCodexFamily: "luna",
            rubric: "Judge Luna as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-terra"],
            modelClass: "gpt-5.6-terra",
            rubric: "Judge Terra as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6"],
            modelClass: "gpt-sol",
            preferredCodexFamily: "sol",
            rubric: "Judge Sol as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-astra"],
            modelClass: "gpt-6-astra",
            rubric: "Judge Astra as a base model using its capability, expected completion reliability, and premium price."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "haiku"],
            modelClass: "claude-haiku",
            rubric: "Judge Haiku as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-sonnet-5-5", "claude-sonnet-5", "sonnet"],
            modelClass: "claude-sonnet",
            rubric: "Judge Sonnet as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-opus-5-5", "opus", "claude-opus-5"],
            modelClass: "claude-opus",
            rubric: "Judge Opus as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-fable-5-1", "fable"],
            modelClass: "claude-fable",
            rubric: "Judge Fable as a base model using its capability, expected completion reliability, and premium price."
        )
    ]

    private func eligibleDefinitions(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> [ModelDefinition] {
        Self.modelDefinitions.filter {
            allowedProviders.contains($0.provider)
                && surface.allows($0.provider)
                && AgentModelCatalog.isAgentAvailable($0.provider, availability: availability)
        }
    }

    /// The base model `build` would target for this definition, or `nil` when it contributes none.
    private func resolvedBaseModelRaw(
        _ definition: ModelDefinition,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> String? {
        guard let option = resolveModelOption(definition, availability: availability) else { return nil }
        return Self.baseModelRaw(option.rawValue, provider: definition.provider)
    }

    private func resolveModelOption(
        _ definition: ModelDefinition,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelOption? {
        let options = modelOptions(definition.provider, availability).filter {
            definition.provider != .codexExec || CodexModelSpecifier(raw: $0.rawValue).serviceTier == nil
        }
        if let family = definition.preferredCodexFamily,
           let option = AgentModelCatalog.preferredCodexFamilyOption(family, from: options)
        {
            return option
        }
        return definition.baseModelAliases.lazy.compactMap { alias in
            options.first { option in
                Self.baseModelRaw(option.rawValue, provider: definition.provider)?
                    .caseInsensitiveCompare(alias) == .orderedSame
            }
        }.first
    }

    private static func baseModelRaw(_ raw: String, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: CodexModelSpecifier(raw: raw).baseModel
        case .claudeCode: ClaudeModelSpecifier(raw: raw).baseModel
        default: nil
        }
    }

    private static func effortRaw(_ target: AgentRoutingExecutableTarget, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: target.reasoningEffortRaw ?? CodexModelSpecifier(raw: target.modelRaw).reasoningEffort?.rawValue
        case .claudeCode: target.reasoningEffortRaw ?? ClaudeModelSpecifier(raw: target.modelRaw).effortLevel?.rawValue
        default: nil
        }
    }

    private static func executableTarget(
        _ modelRaw: String,
        provider: AgentProviderKind
    ) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: provider.rawValue,
            modelRaw: modelRaw,
            reasoningEffortRaw: provider == .codexExec
                ? CodexModelSpecifier(raw: modelRaw).reasoningEffort?.rawValue
                : nil,
            modelParameters: []
        )
    }

    private static func modelDescription(
        _ target: AgentRoutingExecutableTarget,
        displayName: String,
        roleDefaults: [RoleDefaultReference]
    ) -> String {
        let provider = AgentProviderKind(rawValue: target.agentRaw)?.displayName ?? target.agentRaw
        let references = if roleDefaults.isEmpty {
            ""
        } else {
            " Agent Models references: \(roleDefaultLabels(roleDefaults)). These are context about the user's established setup, not constraints or automatic choices."
        }
        return "Provider: \(provider); base model: \(displayName). \(AgentTaskRoutingModelProfileCatalog.modelDescription(for: target))\(references)"
    }

    private static func roleDefaultLabels(_ references: [RoleDefaultReference]) -> String {
        references.map { reference in
            let source = reference.isUserOverride ? "user-set" : "recommended"
            return "\(reference.roleLabel) (\(source))"
        }.joined(separator: ", ")
    }
}
