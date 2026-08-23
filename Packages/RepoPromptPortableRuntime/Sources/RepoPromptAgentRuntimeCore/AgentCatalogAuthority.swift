import Foundation
import RepoPromptRuntimeModel

public enum AgentCatalogModelSourceKind: String, Codable, Hashable, Sendable {
    case live
    case persisted
    case providerFallback
}

/// Explicit provider model metadata. `modelID` and `variantEffortID` are supplied by
/// the provider/desktop adapter; the authority never derives either from `rawValue`.
public struct AgentCatalogModelCandidate: Codable, Hashable, Sendable {
    public let modelID: String
    public let rawValue: String
    public let displayName: String
    public let description: String?
    public let variantEffortID: String?
    public let supportedEffortIDs: [String]
    public let defaultEffortID: String?
    public let serviceTier: String?
    public let isProviderDefault: Bool
    public let capabilities: ProviderModelCapabilities

    public init(
        modelID: String,
        rawValue: String,
        displayName: String,
        description: String? = nil,
        variantEffortID: String? = nil,
        supportedEffortIDs: [String] = [],
        defaultEffortID: String? = nil,
        serviceTier: String? = nil,
        isProviderDefault: Bool = false,
        capabilities: ProviderModelCapabilities = .init()
    ) {
        self.modelID = modelID
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.variantEffortID = variantEffortID
        self.supportedEffortIDs = supportedEffortIDs
        self.defaultEffortID = defaultEffortID
        self.serviceTier = serviceTier
        self.isProviderDefault = isProviderDefault
        self.capabilities = capabilities
    }
}

public struct AgentCatalogModelSource: Codable, Hashable, Sendable {
    public let kind: AgentCatalogModelSourceKind
    public let observedAt: Date?
    public let models: [AgentCatalogModelCandidate]

    public init(kind: AgentCatalogModelSourceKind, observedAt: Date? = nil, models: [AgentCatalogModelCandidate]) {
        self.kind = kind
        self.observedAt = observedAt
        self.models = models
    }
}

public struct AgentCatalogProviderProfile: Sendable {
    public let toolControls: [ProviderComposerControlDescriptor]
    public let permissionControl: ProviderPermissionDescriptor?
    public let modelCapabilities: ProviderModelCapabilities

    public init(
        toolControls: [ProviderComposerControlDescriptor] = [],
        permissionControl: ProviderPermissionDescriptor? = nil,
        modelCapabilities: ProviderModelCapabilities = .init()
    ) {
        self.toolControls = toolControls
        self.permissionControl = permissionControl
        self.modelCapabilities = modelCapabilities
    }
}

/// Provider preference/profile state after runtime-specific persistence has been read.
/// Desktop and server adapters both project into this type before any catalog rules run.
public struct AgentCatalogProviderState: Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let enabled: Bool
    public let configured: Bool
    public let preflightReady: Bool
    public let adapterAvailable: Bool
    public let discoveryPolicy: ProviderDiscoveryPolicy
    public let modelSources: [AgentCatalogModelSource]
    public let preferredModelID: String?
    public let preferredEffortID: String?
    public let toolControls: [ProviderComposerControlDescriptor]
    public let permissionControl: ProviderPermissionDescriptor?

    public init(
        providerID: ProviderSettingsID,
        displayName: String,
        enabled: Bool,
        configured: Bool,
        preflightReady: Bool,
        adapterAvailable: Bool = true,
        discoveryPolicy: ProviderDiscoveryPolicy,
        modelSources: [AgentCatalogModelSource],
        preferredModelID: String? = nil,
        preferredEffortID: String? = nil,
        toolControls: [ProviderComposerControlDescriptor] = [],
        permissionControl: ProviderPermissionDescriptor? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.enabled = enabled
        self.configured = configured
        self.preflightReady = preflightReady
        self.adapterAvailable = adapterAvailable
        self.discoveryPolicy = discoveryPolicy
        self.modelSources = modelSources
        self.preferredModelID = preferredModelID
        self.preferredEffortID = preferredEffortID
        self.toolControls = toolControls
        self.permissionControl = permissionControl
    }
}

public struct AgentCatalogStoredSelection: Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let effortID: String?
    public let workflowID: String?
    public let permissionID: String?
    public let toolValues: [String: AgentControlValue]

    public init(providerID: ProviderSettingsID, modelID: String, effortID: String? = nil, workflowID: String? = nil, permissionID: String? = nil, toolValues: [String: AgentControlValue] = [:]) {
        self.providerID = providerID
        self.modelID = modelID
        self.effortID = effortID
        self.workflowID = workflowID
        self.permissionID = permissionID
        self.toolValues = toolValues
    }
}

public struct AgentCatalogAuthorityContext: Hashable, Sendable {
    public let now: Date
    public let activeRun: Bool
    public let externallyControlled: Bool

    public init(now: Date = Date(), activeRun: Bool = false, externallyControlled: Bool = false) {
        self.now = now
        self.activeRun = activeRun
        self.externallyControlled = externallyControlled
    }

    public var lockReasonCode: String? {
        externallyControlled ? "mcp_controlled" : (activeRun ? "active_run" : nil)
    }

    /// Desktop keeps sandbox/permission level editable during an active run.
    /// Only an external MCP controller freezes it.
    public var permissionLockReasonCode: String? {
        externallyControlled ? "mcp_controlled" : nil
    }
}

public struct AgentCatalogResolvedModel: Hashable, Sendable {
    public let descriptor: ProviderModelDescriptor
    public let variants: [AgentCatalogModelCandidate]
    public let isProviderDefault: Bool

    public init(descriptor: ProviderModelDescriptor, variants: [AgentCatalogModelCandidate], isProviderDefault: Bool) {
        self.descriptor = descriptor
        self.variants = variants
        self.isProviderDefault = isProviderDefault
    }

    /// Resolves a concrete provider value from explicit variant metadata. Model names
    /// are never parsed to infer an effort.
    public func descriptor(selectingEffortID requestedEffortID: String?) -> ProviderModelDescriptor {
        let effortID = requestedEffortID ?? descriptor.defaultEffortID
        guard let effortID,
              let variant = variants.first(where: { $0.variantEffortID == effortID })
        else { return descriptor }
        return .init(
            providerID: descriptor.providerID,
            modelID: descriptor.modelID,
            providerRawValue: variant.rawValue,
            displayName: descriptor.displayName,
            description: descriptor.description,
            supportedEffortIDs: descriptor.supportedEffortIDs,
            defaultEffortID: descriptor.defaultEffortID,
            serviceTier: descriptor.serviceTier,
            capabilities: descriptor.capabilities
        )
    }
}

public struct AgentCatalogResolvedProvider: Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let models: [AgentCatalogResolvedModel]
    public let toolControls: [ProviderComposerControlDescriptor]
    public let permissionControl: ProviderPermissionDescriptor?

    public init(providerID: ProviderSettingsID, displayName: String, models: [AgentCatalogResolvedModel], toolControls: [ProviderComposerControlDescriptor], permissionControl: ProviderPermissionDescriptor?) {
        self.providerID = providerID
        self.displayName = displayName
        self.models = models
        self.toolControls = toolControls
        self.permissionControl = permissionControl
    }
}

public struct AgentCatalogResolvedSelection: Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let effortID: String?
    public let workflowID: String?
    public let permissionID: String?
    public let toolValues: [String: AgentControlValue]
    public let unavailable: Bool

    public init(providerID: ProviderSettingsID, modelID: String, effortID: String? = nil, workflowID: String? = nil, permissionID: String? = nil, toolValues: [String: AgentControlValue] = [:], unavailable: Bool = false) {
        self.providerID = providerID
        self.modelID = modelID
        self.effortID = effortID
        self.workflowID = workflowID
        self.permissionID = permissionID
        self.toolValues = toolValues
        self.unavailable = unavailable
    }
}

public struct AgentCatalogResolution: Sendable {
    public let providers: [AgentCatalogResolvedProvider]
    public let selection: AgentCatalogResolvedSelection?

    public init(providers: [AgentCatalogResolvedProvider], selection: AgentCatalogResolvedSelection?) {
        self.providers = providers
        self.selection = selection
    }
}

/// Single pure domain authority for provider admission, discovery freshness/fallback,
/// concrete model grouping, effort metadata, control locks, and selection preservation.
public enum AgentCatalogAuthority {
    public static func resolve(
        providers providerStates: [AgentCatalogProviderState],
        storedSelection: AgentCatalogStoredSelection?,
        context: AgentCatalogAuthorityContext = .init()
    ) -> AgentCatalogResolution {
        let providers = providerStates.compactMap { state -> AgentCatalogResolvedProvider? in
            guard state.enabled, state.configured, state.preflightReady, state.adapterAvailable else { return nil }
            let candidates = selectableCandidates(state: state, now: context.now)
            let models = groupedModels(candidates, providerID: state.providerID)
            guard !models.isEmpty else { return nil }
            return AgentCatalogResolvedProvider(
                providerID: state.providerID,
                displayName: state.displayName,
                models: models,
                toolControls: state.toolControls.map { locked($0, reason: context.lockReasonCode) },
                permissionControl: state.permissionControl.map { locked($0, reason: context.permissionLockReasonCode) }
            )
        }

        let selection: AgentCatalogResolvedSelection?
        if let storedSelection {
            let selectable = providers.first { $0.providerID == storedSelection.providerID }?
                .models.contains { equalID($0.descriptor.modelID, storedSelection.modelID) } == true
            selection = AgentCatalogResolvedSelection(
                providerID: storedSelection.providerID,
                modelID: storedSelection.modelID,
                effortID: storedSelection.effortID,
                workflowID: storedSelection.workflowID,
                permissionID: storedSelection.permissionID,
                toolValues: storedSelection.toolValues,
                unavailable: !selectable
            )
        } else if let provider = providers.first,
                  let state = providerStates.first(where: { $0.providerID == provider.providerID }),
                  let model = preferredModel(in: provider, preferredID: state.preferredModelID)
        {
            let preferredEffort = state.preferredEffortID.flatMap { effort in
                model.descriptor.supportedEffortIDs.contains(effort) ? effort : nil
            }
            selection = AgentCatalogResolvedSelection(
                providerID: provider.providerID,
                modelID: model.descriptor.modelID,
                effortID: preferredEffort ?? model.descriptor.defaultEffortID,
                permissionID: provider.permissionControl?.selectedID,
                toolValues: controlValues(provider.toolControls)
            )
        } else {
            selection = nil
        }
        return AgentCatalogResolution(providers: providers, selection: selection)
    }

    public static func resolvedModels(
        providerID: ProviderSettingsID,
        policy: ProviderDiscoveryPolicy,
        sources: [AgentCatalogModelSource],
        now: Date = Date()
    ) -> [AgentCatalogResolvedModel] {
        groupedModels(selectableCandidates(policy: policy, sources: sources, now: now), providerID: providerID)
    }

    private static func selectableCandidates(state: AgentCatalogProviderState, now: Date) -> [AgentCatalogModelCandidate] {
        selectableCandidates(policy: state.discoveryPolicy, sources: state.modelSources, now: now)
    }

    private static func selectableCandidates(policy: ProviderDiscoveryPolicy, sources: [AgentCatalogModelSource], now: Date) -> [AgentCatalogModelCandidate] {
        let live = sources.first { source in
            source.kind == .live && isFresh(source, maximumAge: policy.liveFreshnessSeconds, now: now) && !source.models.isEmpty
        }?.models
        let persisted = policy.allowsPersistedFallback
            ? sources.first { source in
                source.kind == .persisted && isFresh(source, maximumAge: policy.persistedFallbackMaximumAgeSeconds, now: now) && !source.models.isEmpty
            }?.models
            : nil
        let primary = live ?? persisted ?? []
        let fallback = policy.allowsStaticFallbackAfterSuccessfulPreflight
            ? sources.first { $0.kind == .providerFallback && !$0.models.isEmpty }?.models ?? []
            : []
        if primary.isEmpty { return fallback }
        if policy.discoveryReplacesStaticChoices || fallback.isEmpty { return primary }
        return primary + fallback
    }

    private static func isFresh(_ source: AgentCatalogModelSource, maximumAge: Int, now: Date) -> Bool {
        guard let observedAt = source.observedAt else { return true }
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= TimeInterval(maximumAge)
    }

    private static func groupedModels(_ candidates: [AgentCatalogModelCandidate], providerID: ProviderSettingsID) -> [AgentCatalogResolvedModel] {
        var keys: [String] = []
        var grouped: [String: [AgentCatalogModelCandidate]] = [:]
        for candidate in candidates {
            let modelID = candidate.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = candidate.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, !rawValue.isEmpty, !displayName.isEmpty else { continue }
            let key = modelID.lowercased()
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(candidate)
        }
        return keys.compactMap { key in
            guard let variants = grouped[key], let representative = variants.first else { return nil }
            var effortIDs: [String] = []
            var seenEfforts = Set<String>()
            for variant in variants {
                for effort in variant.supportedEffortIDs + [variant.variantEffortID].compactMap(\.self) {
                    let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty, seenEfforts.insert(normalized).inserted else { continue }
                    effortIDs.append(normalized)
                }
            }
            let advertisedDefaults = variants.compactMap(\.defaultEffortID)
            let defaultEffort = advertisedDefaults.first(where: effortIDs.contains)
            let capabilities = ProviderModelCapabilities(
                nativeImages: variants.contains { $0.capabilities.nativeImages },
                steering: variants.contains { $0.capabilities.steering }
            )
            return AgentCatalogResolvedModel(
                descriptor: .init(
                    providerID: providerID,
                    modelID: representative.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                    providerRawValue: preferredRawValue(variants),
                    displayName: representative.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: variants.compactMap(\.description).first,
                    supportedEffortIDs: effortIDs,
                    defaultEffortID: defaultEffort,
                    serviceTier: representative.serviceTier,
                    capabilities: capabilities
                ),
                variants: variants,
                isProviderDefault: variants.contains(where: \.isProviderDefault)
            )
        }
    }

    private static func preferredRawValue(_ variants: [AgentCatalogModelCandidate]) -> String {
        variants.first(where: \.isProviderDefault)?.rawValue ?? variants.first?.rawValue ?? ""
    }

    private static func preferredModel(in provider: AgentCatalogResolvedProvider, preferredID: String?) -> AgentCatalogResolvedModel? {
        if let preferredID,
           let preferred = provider.models.first(where: { equalID($0.descriptor.modelID, preferredID) || $0.variants.contains(where: { equalID($0.rawValue, preferredID) }) })
        {
            return preferred
        }
        return provider.models.first(where: \.isProviderDefault) ?? provider.models.first
    }

    private static func equalID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func locked(_ descriptor: ProviderComposerControlDescriptor, reason: String?) -> ProviderComposerControlDescriptor {
        guard let reason else { return descriptor }
        switch descriptor {
        case let .toggle(id, name, detail, value, required, _, warning, _):
            return .toggle(id: id, displayName: name, detailText: detail, value: value, required: required, mutable: false, warning: warning, lockReasonCode: reason)
        case let .singleChoice(id, name, detail, selected, choices, required, _, warning, _):
            return .singleChoice(id: id, displayName: name, detailText: detail, selectedID: selected, choices: choices, required: required, mutable: false, warning: warning, lockReasonCode: reason)
        case let .multiChoice(id, name, detail, selected, choices, required, _, warning, _):
            return .multiChoice(id: id, displayName: name, detailText: detail, selectedIDs: selected, choices: choices, required: required, mutable: false, warning: warning, lockReasonCode: reason)
        }
    }

    private static func locked(_ descriptor: ProviderPermissionDescriptor, reason: String?) -> ProviderPermissionDescriptor {
        guard let reason else { return descriptor }
        return .init(
            id: descriptor.id,
            displayName: descriptor.displayName,
            selectedID: descriptor.selectedID,
            choices: descriptor.choices,
            externallyManaged: true,
            mutable: false,
            lockReasonCode: reason
        )
    }

    private static func controlValues(_ controls: [ProviderComposerControlDescriptor]) -> [String: AgentControlValue] {
        Dictionary(uniqueKeysWithValues: controls.map { control in
            switch control {
            case let .toggle(id, _, _, value, _, _, _, _): (id, .boolean(value))
            case let .singleChoice(id, _, _, selected, _, _, _, _, _): (id, .choice(selected))
            case let .multiChoice(id, _, _, selected, _, _, _, _, _): (id, .choices(selected))
            }
        })
    }
}
