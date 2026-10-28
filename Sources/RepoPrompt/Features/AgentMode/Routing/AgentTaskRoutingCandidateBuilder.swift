import Foundation

/// Builds router-owned choices from one provider-authoritative metadata snapshot.
/// Profile prose is advisory and never admits a model or effort.
@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let utilityTier: String
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
        let snapshotScope: RoutingExecutionMetadataSnapshot.Scope?
        let profileIdentity: String?
        var usagePeerClass: String?
        var usageModelAliases: Set<String> = []

        init(
            opaqueKey: String,
            utilityTier: String,
            target: AgentRoutingExecutableTarget,
            descriptor: AgentTaskRoutingCandidateDescriptor,
            snapshotScope: RoutingExecutionMetadataSnapshot.Scope? = nil,
            profileIdentity: String? = nil,
            usagePeerClass: String? = nil,
            usageModelAliases: Set<String> = []
        ) {
            self.opaqueKey = opaqueKey
            self.utilityTier = utilityTier
            self.target = target
            self.descriptor = descriptor
            self.snapshotScope = snapshotScope
            self.profileIdentity = profileIdentity
            self.usagePeerClass = usagePeerClass
            self.usageModelAliases = usageModelAliases
        }
    }

    enum BuildError: Error, Equatable {
        case noAvailableTargets
        case insufficientCapacity
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

    struct ModelFamilyAvailability: Equatable {
        let id: String
        let displayName: String
        let provider: AgentProviderKind
        let model: RoutingExecutionModelMetadata?
        let unavailableReason: String?

        var isAvailable: Bool {
            model != nil
        }
    }

    struct RoleDefaultReference: Equatable {
        let roleLabel: String
        let provider: AgentProviderKind
        let modelRaw: String
        let isUserOverride: Bool
    }

    let opaqueKey: () -> String
    private let metadata: RoutingExecutionMetadataAdapter
    private let profiles: RoutingModelProfileResolver
    private let profileSnapshot: RoutingModelProfileSnapshot

    init(
        opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() },
        profileResolver: RoutingModelProfileResolver? = nil,
        profileSnapshot: RoutingModelProfileSnapshot? = nil,
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) {
        self.opaqueKey = opaqueKey
        metadata = RoutingExecutionMetadataAdapter(modelOptions: modelOptions)
        let snapshot = profileSnapshot ?? RoutingModelProfileSnapshot.bundled
        self.profileSnapshot = snapshot
        profiles = profileResolver ?? snapshot.resolver
    }

    func capture(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> RoutingExecutionMetadataSnapshot {
        metadata.capture(allowedProviders: allowedProviders, availability: availability, surface: surface)
    }

    func build(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        roleDefaults: [RoleDefaultReference] = [],
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        try build(
            snapshot: capture(allowedProviders: allowedProviders, availability: availability, surface: surface),
            roleDefaults: roleDefaults,
            maximumChoices: maximumChoices
        )
    }

    func build(
        snapshot: RoutingExecutionMetadataSnapshot,
        roleDefaults: [RoleDefaultReference] = [],
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices,
        usagePeerClasses: Set<String>? = nil
    ) throws -> [Candidate] {
        // Class filtering happens before capacity truncation so excluded tiers never consume slots.
        let allSelected = Self.executableModels(in: snapshot).filter { definition, _ in
            usagePeerClasses.map { classes in definition.usagePeerClass.map(classes.contains) == true } ?? true
        }
        guard !allSelected.isEmpty else { throw BuildError.noAvailableTargets }
        let capacity = min(maximumChoices, FiniteChoiceDecisionValidator.maximumChoices)
        guard capacity > 0, allSelected.count == 1 || capacity >= 2 else {
            throw BuildError.insufficientCapacity
        }
        let selected = Array(allSelected.prefix(capacity))
        return selected.map { definition, model in
            let target = model.baseTarget
            let profile = profiles.resolve(model, catalogRevision: snapshot.scope.catalogRevision)
            let key = opaqueKey()
            let tier = definition.preferredCodexFamily == nil ? definition.modelClass : model.baseModelRaw
            let references = roleDefaults.filter { reference in
                reference.provider == model.provider
                    && model.advertisedOptionRawValues.contains {
                        $0 == reference.modelRaw
                    }
            }
            return Candidate(
                opaqueKey: key,
                utilityTier: tier,
                target: target,
                descriptor: .init(
                    opaqueKey: key,
                    roleLabels: [tier],
                    targetDescription: Self.modelDescription(model, profile: profile, snapshotDate: profiles.snapshotDate, roleDefaults: references),
                    rubricVersion: profiles.rubricVersion,
                    rubric: definition.rubric
                ),
                snapshotScope: snapshot.scope,
                profileIdentity: profileSnapshot.identity,
                usagePeerClass: definition.usagePeerClass,
                usageModelAliases: Set([model.baseModelRaw] + (model.provider == .claudeCode ? definition.baseModelAliases.filter { ["opus", "sonnet", "haiku", "fable"].contains($0) } : []))
            )
        }
    }

    func buildEfforts(
        for model: Candidate,
        availability: AgentModelCatalog.AvailabilityContext,
        allowPaidFast: Bool = false,
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        guard let scope = model.snapshotScope else { throw BuildError.noAvailableTargets }
        return try buildEfforts(
            for: model,
            snapshot: capture(
                allowedProviders: scope.allowedProviders,
                availability: availability,
                surface: scope.surface
            ),
            allowPaidFast: allowPaidFast,
            maximumChoices: maximumChoices
        )
    }

    func buildEfforts(
        for model: Candidate,
        snapshot: RoutingExecutionMetadataSnapshot,
        allowPaidFast: Bool = false,
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        guard model.snapshotScope == snapshot.scope,
              model.profileIdentity == profileSnapshot.identity,
              let selected = snapshot.model(for: model.target)
        else { throw BuildError.noAvailableTargets }
        // A Fast tier remains an exact provider-advertised target. Never synthesize it from
        // a model name, and expose it only after the explicit paid-tier opt-in.
        let fastVariants = allowPaidFast && selected.provider == .codexExec
            ? snapshot.models.filter {
                $0.provider == .codexExec && Self.isPaidFast($0.baseTarget)
                    && CodexModelSpecifier(raw: $0.baseModelRaw).baseModel == selected.baseModelRaw
            } : []
        let baseTargets = [selected.baseTarget] + selected.efforts.compactMap(\.executableTarget)
        var seen: Set<AgentRoutingExecutableTarget> = []
        let ordinaryTargets = baseTargets.filter { !Self.isPaidFast($0) && seen.insert($0).inserted }
        let capacity = min(maximumChoices, FiniteChoiceDecisionValidator.maximumChoices)
        guard capacity > 0, ordinaryTargets.count <= capacity else { throw BuildError.insufficientCapacity }
        let optionalFastTargets = allowPaidFast
            ? baseTargets.filter(Self.isPaidFast)
            + fastVariants.flatMap { [$0.baseTarget] + $0.efforts.compactMap(\.executableTarget) }
            : []
        let fastTargets = optionalFastTargets.filter { seen.insert($0).inserted }
        let targets = ordinaryTargets + (ordinaryTargets.count + fastTargets.count <= capacity ? fastTargets : [])
        let candidates = targets.map { target -> Candidate in
            let key = opaqueKey()
            let effort = target.reasoningEffortRaw
                ?? selected.efforts.first(where: { $0.executableTarget == target })?.id.rawValue
                ?? "provider-default"
            return Candidate(
                opaqueKey: key,
                utilityTier: effort,
                target: target,
                descriptor: .init(
                    opaqueKey: key,
                    roleLabels: ["effort:\(effort)"],
                    targetDescription: "Already selected model: \(selected.displayName). \(profiles.effortDescription(raw: effort == "provider-default" ? nil : effort).value)",
                    rubricVersion: profiles.rubricVersion,
                    rubric: "Choose this effort only if it supplies the reasoning depth the task needs. Prefer the lowest effort with a clear reliability margin; raise effort when ambiguity, review depth, risk, or long-horizon reasoning warrants it."
                ),
                snapshotScope: snapshot.scope,
                profileIdentity: profileSnapshot.identity
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

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
            snapshotScope: models.first?.snapshotScope,
            profileIdentity: profileSnapshot.identity,
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
                snapshotScope: match.snapshotScope,
                profileIdentity: match.profileIdentity,
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

    /// Capability floor for user-created primary sessions. Light and balanced classes (Luna, Haiku,
    /// Terra, Sonnet) are never offered to the primary-session Model Router.
    static let primarySessionUsagePeerClasses: Set<String> = ["strong", "frontier"]

    private static func effortRaw(_ target: AgentRoutingExecutableTarget, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: target.reasoningEffortRaw ?? CodexModelSpecifier(raw: target.modelRaw).reasoningEffort?.rawValue
        case .claudeCode: target.reasoningEffortRaw ?? ClaudeModelSpecifier(raw: target.modelRaw).effortLevel?.rawValue
        default: nil
        }
    }

    func hasAvailableTarget(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Bool {
        for provider in Self.curatedProviders where allowedProviders.contains(provider)
            && surface.allows(provider)
            && AgentModelCatalog.isAgentAvailable(provider, availability: availability)
        {
            let snapshot = capture(allowedProviders: [provider], availability: availability, surface: surface)
            if !Self.executableModels(in: snapshot).isEmpty { return true }
        }
        return false
    }

    /// Saved scope intent narrows the executable frontier only while that provider is available.
    static func providers(
        for scope: AgentTaskRoutingScope,
        configuration: AgentTaskRouterConfiguration,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Set<AgentProviderKind> {
        let available = availableProviders(availability: availability, surface: surface)
        let preferred = scope == .primarySession ? configuration.primaryProvider : configuration.subagentProvider
        if let preferred, available.contains(preferred) { return [preferred] }
        return available
    }

    static func availableProviders(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) -> Set<AgentProviderKind> {
        Set(curatedProviders.filter { provider in
            guard surface.allows(provider), AgentModelCatalog.isAgentAvailable(provider, availability: availability) else {
                return false
            }
            return !modelOptions(provider, availability).filter { !$0.isPlaceholderDefault }.isEmpty
        })
    }

    func modelFamilyAvailability(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> [ModelFamilyAvailability] {
        let snapshot = capture(
            allowedProviders: Set(Self.curatedProviders),
            availability: availability,
            surface: surface
        )
        return Self.familyDisplayOrderedDefinitions.map { definition in
            let displayName = Self.familyDisplayName(for: definition)
            let providerAvailable = surface.allows(definition.provider)
                && AgentModelCatalog.isAgentAvailable(definition.provider, availability: availability)
            let model = providerAvailable
                ? Self.resolveModel(definition, from: snapshot.models.filter { $0.provider == definition.provider })
                : nil
            let reason: String? = if model != nil {
                nil
            } else if !providerAvailable {
                "\(definition.provider.displayName) not connected."
            } else {
                "\(definition.provider.displayName) does not advertise a supported \(displayName) model."
            }
            return .init(
                id: "\(definition.provider.rawValue):\(definition.modelClass)",
                displayName: displayName,
                provider: definition.provider,
                model: model,
                unavailableReason: reason
            )
        }
    }

    /// Strongest-first within each provider so that position bias in a finite-choice judge and
    /// any capacity truncation favor capable models. Main-session flagships (Sol, Opus) lead.
    private static let modelDefinitions: [ModelDefinition] = [
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6"],
            modelClass: "gpt-sol",
            preferredCodexFamily: "sol",
            rubric: "Sol is OpenAI's current flagship for complex coding and agentic work. Strong default for substantive primary work; its base capability avoids missed findings and retries."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-astra"],
            modelClass: "gpt-6-astra",
            rubric: "Astra is OpenAI's most capable premium tier. Choose it for the hardest, highest-risk, or longest-horizon work where its extra capability justifies premium price."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-terra"],
            modelClass: "gpt-5.6-terra",
            rubric: "Terra is a previous-generation balanced tier, weaker than current flagships. Choose it only for clearly bounded, routine work; it is not cheaper than Sol."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-luna", "gpt-5.6-luna"],
            modelClass: "gpt-luna",
            preferredCodexFamily: "luna",
            rubric: "Luna is a light, high-volume tier meant for exploration and simple lookups. Not suitable for implementation, review, debugging, or multi-step agentic work. A short prompt does not make a task simple."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-opus-5-5", "opus", "claude-opus-5"],
            modelClass: "claude-opus",
            rubric: "Opus is Anthropic's recommended flagship for long-running agentic coding and knowledge work. Strong default for substantive primary work; its base capability avoids missed findings and retries."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-fable-5-1", "fable"],
            modelClass: "claude-fable",
            rubric: "Fable is Anthropic's most capable premium tier. Choose it for the hardest, highest-risk, or longest-horizon work where its extra capability justifies premium price."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-sonnet-5-5", "claude-sonnet-5", "sonnet"],
            modelClass: "claude-sonnet",
            rubric: "Sonnet is a balanced tier below the flagships. Choose it only for clearly bounded, routine work with a clear reliability margin."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "haiku"],
            modelClass: "claude-haiku",
            rubric: "Haiku is a light, fast tier meant for exploration and simple lookups. Not suitable for implementation, review, debugging, or multi-step agentic work. A short prompt does not make a task simple."
        )
    ]

    /// Settings list families lightest-first; router candidate order is independent of this.
    private static let familyDisplayOrder = [
        "gpt-luna", "gpt-5.6-terra", "gpt-sol", "gpt-6-astra",
        "claude-haiku", "claude-sonnet", "claude-opus", "claude-fable"
    ]

    private static var familyDisplayOrderedDefinitions: [ModelDefinition] {
        modelDefinitions.sorted {
            (familyDisplayOrder.firstIndex(of: $0.modelClass) ?? .max) < (familyDisplayOrder.firstIndex(of: $1.modelClass) ?? .max)
        }
    }

    private static let curatedProviders: [AgentProviderKind] = [.codexExec, .claudeCode]

    private static func familyDisplayName(for definition: ModelDefinition) -> String {
        definition.modelClass.split(separator: "-").last.map(String.init)?.capitalized
            ?? definition.modelClass.capitalized
    }

    private static func executableModels(
        in snapshot: RoutingExecutionMetadataSnapshot
    ) -> [(ModelDefinition, RoutingExecutionModelMetadata)] {
        modelDefinitions.compactMap { definition in
            let provider = definition.provider
            guard snapshot.scope.allowedProviders.contains(provider),
                  snapshot.scope.surface.allows(provider),
                  AgentModelCatalog.isAgentAvailable(provider, availability: snapshot.scope.availability),
                  let model = resolveModel(
                      definition,
                      from: snapshot.models.filter { $0.provider == provider }
                  )
            else { return nil }
            return (definition, model)
        }
    }

    private static func resolveModel(
        _ definition: ModelDefinition,
        from models: [RoutingExecutionModelMetadata]
    ) -> RoutingExecutionModelMetadata? {
        let providerModels = models.filter { model in
            guard model.provider == definition.provider else { return false }
            return baseModelRaw(model.baseModelRaw, provider: definition.provider) == model.baseModelRaw
        }
        if let family = definition.preferredCodexFamily {
            let options = providerModels.map { model in
                AgentModelOption(
                    rawValue: model.baseModelRaw,
                    displayName: model.displayName,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: model.isProviderDefault
                )
            }
            if let preferred = AgentModelCatalog.preferredCodexFamilyOption(family, from: options),
               let model = providerModels.first(where: { $0.baseModelRaw == preferred.rawValue })
            { return model }
        }
        return definition.baseModelAliases.lazy.compactMap { alias in
            providerModels.first { model in
                model.baseModelRaw.caseInsensitiveCompare(alias) == .orderedSame
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

    private static func modelDescription(
        _ model: RoutingExecutionModelMetadata,
        profile: ResolvedRoutingProfile,
        snapshotDate: String,
        roleDefaults: [RoleDefaultReference]
    ) -> String {
        let references = if roleDefaults.isEmpty {
            ""
        } else {
            " Agent Models references: \(roleDefaultLabels(roleDefaults)). These are context about the user's established setup, not constraints or automatic choices."
        }
        return "Provider: \(model.provider.displayName); base model: \(model.displayName). \(profile.description(snapshotDate: snapshotDate))\(references)"
    }

    private static func roleDefaultLabels(_ references: [RoleDefaultReference]) -> String {
        references.map { reference in
            let source = reference.isUserOverride ? "user-set" : "recommended"
            return "\(reference.roleLabel) (\(source))"
        }.joined(separator: ", ")
    }
}
