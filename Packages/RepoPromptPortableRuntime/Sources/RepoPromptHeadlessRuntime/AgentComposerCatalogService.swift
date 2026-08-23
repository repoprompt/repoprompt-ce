import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptShared

public struct AgentComposerWorkflowDescriptor: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let guidance: String?
    public let providerIDs: [ProviderSettingsID]
    public let featured: Bool

    public init(id: String, displayName: String, description: String? = nil, guidance: String? = nil, providerIDs: [ProviderSettingsID] = [], featured: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.guidance = guidance
        self.providerIDs = providerIDs
        self.featured = featured
    }
}

public protocol AgentComposerCatalogProviding: Sendable {
    func snapshot(context: ComposerCatalogContext) async throws -> ComposerCatalogWireSnapshot
    func suggestions(context: ComposerCatalogContext, query: String, kinds: Set<ComposerSuggestionWire.Kind>, limit: Int) async throws -> ComposerSuggestionPageWire
    func validate(_ wire: AgentTurnConfigurationWire, context: ComposerCatalogContext, acceptedAt: Date) async throws -> (EffectiveTurnConfigurationRecord, CompiledProviderTurnConfiguration, ProviderModelDescriptor, String?)
    func compatibilityModels() async throws -> [ModelCatalogItem]
}

public actor AgentComposerCatalogService: AgentComposerCatalogProviding {
    private let providerSettings: ProviderSettingsService
    private let store: any ComposerCatalogStore
    private let adapters: [ProviderSettingsID: any ProviderTurnConfigurationAdapter]
    private let workflows: [AgentComposerWorkflowDescriptor]
    private let suggestions: [ComposerSuggestionDescriptor]
    private let emptyState: AgentEmptyStateDescriptor
    private let providerProfileLoader: (@Sendable (ProviderSettingsID) async throws -> AgentCatalogProviderProfile)?
    private let providerStateLoader: (@Sendable (Date) async throws -> [AgentCatalogProviderState])?
    private let composeModelLoader: (@Sendable () async throws -> String?)?
    private let now: @Sendable () -> Date

    public init(
        providerSettings: ProviderSettingsService,
        store: any ComposerCatalogStore,
        adapters: [ProviderSettingsID: any ProviderTurnConfigurationAdapter] = ProviderTurnConfigurationAdapters.builtIn(),
        workflows: [AgentComposerWorkflowDescriptor] = [],
        suggestions: [ComposerSuggestionDescriptor] = [],
        emptyState: AgentEmptyStateDescriptor = .init(
            featuredWorkflowIDs: [],
            tips: [
                "Tag a file to add its current contents to only this turn.",
                "Choose a concrete model before sending.",
                "Use Shift+Return to add a new line."
            ]
        ),
        providerProfileLoader: (@Sendable (ProviderSettingsID) async throws -> AgentCatalogProviderProfile)? = nil,
        providerStateLoader: (@Sendable (Date) async throws -> [AgentCatalogProviderState])? = nil,
        composeModelLoader: (@Sendable () async throws -> String?)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providerSettings = providerSettings
        self.store = store
        self.adapters = adapters
        self.workflows = workflows
        self.suggestions = suggestions
        self.emptyState = emptyState
        self.providerProfileLoader = providerProfileLoader
        self.providerStateLoader = providerStateLoader
        self.composeModelLoader = composeModelLoader
        self.now = now
    }

    public func snapshot(context: ComposerCatalogContext) async throws -> ComposerCatalogWireSnapshot {
        let resolution = try await resolve(context: context)
        let groups = resolution.providers.map { provider in
            ComposerProviderGroupWire(
                providerID: provider.providerID,
                displayName: provider.displayName,
                models: provider.models.map { Self.modelWire($0.descriptor) },
                toolControls: provider.toolControls.map(Self.controlWire),
                permissionControl: provider.permissionControl.map(Self.permissionWire)
            )
        }
        let selected = resolution.selection.map { selection in
            ComposerSelectionWire(
                providerID: selection.providerID,
                modelID: selection.modelID,
                effortID: selection.effortID,
                workflowID: selection.workflowID,
                permissionID: selection.permissionID,
                toolValues: selection.toolValues.mapValues(Self.wireValue),
                unavailable: selection.unavailable ? .init(providerID: selection.providerID, modelID: selection.modelID) : nil
            )
        }
        let activeLock = context.activeRun
            ? ComposerLockWire(locked: true, reasonCode: "active_run", reasonText: "This setting cannot change during an active run.")
            : .init()
        let controllerLock = context.mcpControlled
            ? ComposerLockWire(locked: true, reasonCode: "mcp_controlled", reasonText: "The active MCP controller owns this setting.")
            : activeLock
        let permissionLock = context.mcpControlled
            ? ComposerLockWire(locked: true, reasonCode: "mcp_controlled", reasonText: "The active MCP controller owns this setting.")
            : .init()
        let workflowWire = try await livePickerWorkflows(keeping: selected?.workflowID)
        let contextWire = ComposerContextWire(kind: context.kind == .project ? .project : .session, projectID: context.projectID, sessionID: context.sessionID)
        let capabilities = ComposerCapabilitiesWire(
            attachments: groups.contains { $0.models.contains { $0.capabilities.nativeImages } },
            taggedFiles: true,
            suggestions: !suggestions.isEmpty,
            steering: groups.contains { $0.models.contains { $0.capabilities.steering } }
        )
        let locks = ComposerLockSnapshotWire(model: controllerLock, effort: controllerLock, workflow: controllerLock, tools: controllerLock, permissions: permissionLock, attachments: activeLock, send: .init())
        let empty = try await AgentEmptyStateWire(
            heading: emptyState.heading,
            featuredWorkflowIDs: liveFeaturedWorkflowIDs(),
            tips: emptyState.tips.enumerated().map { .init(id: "tip-\($0.offset + 1)", text: $0.element) }
        )
        let seed = ComposerCatalogWireSnapshot(revision: "pending", context: contextWire, providerGroups: groups, workflows: workflowWire, selected: selected, locks: locks, capabilities: capabilities, emptyState: empty, mcpControlled: context.mcpControlled)
        let seedData = try JSONEncoder.serviceEncoder.encode(seed)
        let revision = PortableContentDigest.sha256Hex(seedData + Data(ProviderTurnConfigurationAdapters.interpretationRevision.utf8))
        return .init(revision: revision, context: contextWire, providerGroups: groups, workflows: workflowWire, selected: selected, locks: locks, capabilities: capabilities, emptyState: empty, mcpControlled: context.mcpControlled)
    }

    public func suggestions(context: ComposerCatalogContext, query: String, kinds: Set<ComposerSuggestionWire.Kind> = [.nativeCommand, .skill, .file], limit: Int = 50) async throws -> ComposerSuggestionPageWire {
        guard query.utf8.count <= 512 else { throw ServiceAPIError(code: .invalidRequest, message: "Suggestion query exceeds its bound") }
        let snapshot = try await snapshot(context: context)
        let selectedProvider = snapshot.selected?.providerID
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = suggestions.compactMap { item -> ComposerSuggestionWire? in
            guard let kind = ComposerSuggestionWire.Kind(rawValue: item.kind.rawValue), kinds.contains(kind), item.available,
                  item.providerIDs.isEmpty || selectedProvider.map(item.providerIDs.contains) == true,
                  normalized.isEmpty || item.displayName.lowercased().contains(normalized) || item.insertionText.lowercased().contains(normalized)
            else { return nil }
            return .init(kind: kind, id: item.id, insertionText: item.insertionText, displayName: item.displayName, detailText: item.detailText, providerIDs: item.providerIDs, available: item.available)
        }
        return .init(catalogRevision: snapshot.revision, items: Array(items.prefix(max(1, min(limit, 100)))))
    }

    public func validate(_ wire: AgentTurnConfigurationWire, context: ComposerCatalogContext, acceptedAt: Date) async throws -> (EffectiveTurnConfigurationRecord, CompiledProviderTurnConfiguration, ProviderModelDescriptor, String?) {
        guard wire.schemaVersion == 1 else { throw ServiceAPIError(code: .invalidRequest, message: "Turn configuration schema is unsupported") }
        let current = try await snapshot(context: context)
        guard wire.catalogRevision == current.revision else { throw ServiceAPIError(code: .staleRevision, message: "catalog_revision_stale") }
        let resolution = try await resolve(context: context)
        guard let provider = resolution.providers.first(where: { $0.providerID == wire.providerID }),
              let resolvedModel = provider.models.first(where: { $0.descriptor.modelID == wire.modelID }),
              let adapter = adapters[wire.providerID]
        else { throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider model is unavailable") }
        let model = resolvedModel.descriptor(selectingEffortID: wire.effortID)
        let workflow: ComposerWorkflowOptionWire? = if let workflowID = wire.workflowID {
            current.workflows.first { $0.id == workflowID && $0.enabled && ($0.providerIDs.isEmpty || $0.providerIDs.contains(wire.providerID)) }
        } else { nil }
        if wire.workflowID != nil, workflow == nil {
            throw ServiceAPIError(code: .staleRevision, message: "Selected workflow is unavailable")
        }
        let values = wire.toolValues.mapValues(Self.controlValue)
        let compiled = try adapter.compile(.init(
            providerID: wire.providerID,
            model: model,
            effortID: wire.effortID,
            permissionID: wire.permissionID,
            settings: ProviderTurnConfigurationAdapters.defaultSettings(for: wire.providerID),
            toolValues: values,
            workflowID: wire.workflowID
        ))
        let capabilityDigest = try PortableContentDigest.sha256Hex(JSONEncoder.serviceEncoder.encode(model))
        let effective = try EffectiveTurnConfigurationRecord(
            catalogRevision: wire.catalogRevision,
            providerID: wire.providerID,
            modelID: wire.modelID,
            providerRawModelValue: compiled.providerRawModelValue,
            effortID: wire.effortID ?? model.defaultEffortID,
            workflowID: wire.workflowID,
            permissionID: wire.permissionID,
            toolValues: compiled.normalizedToolValues,
            capabilityDigest: capabilityDigest,
            actorID: context.actorID,
            acceptedAt: acceptedAt
        ).validated()
        return (effective, compiled, model, workflow?.guidance)
    }

    public func compatibilityModels() async throws -> [ModelCatalogItem] {
        let projectID = UUID()
        let resolution = try await resolve(context: .init(kind: .project, projectID: projectID, actorID: "compatibility-catalog"), includeStoredSelection: false)
        return resolution.providers.flatMap { provider -> [ModelCatalogItem] in
            guard let runtime = provider.providerID.runtimeKind else { return [] }
            return provider.models.map { model in
                ModelCatalogItem(
                    id: model.descriptor.modelID,
                    provider: runtime,
                    providerID: provider.providerID,
                    displayName: model.descriptor.displayName,
                    enabled: true,
                    description: model.descriptor.description,
                    supportedEffortIDs: model.descriptor.supportedEffortIDs,
                    defaultEffortID: model.descriptor.defaultEffortID
                )
            }
        }
    }

    private func liveFeaturedWorkflowIDs() async throws -> [String] {
        try await store.workflowRepositorySnapshot().workflows
            .filter { $0.enabled && $0.visible && $0.featuredOrder != nil }
            .sorted { ($0.featuredOrder ?? .max, $0.workflowID) < ($1.featuredOrder ?? .max, $1.workflowID) }
            .map(\.workflowID)
    }

    private func livePickerWorkflows(keeping selectedID: String?) async throws -> [ComposerWorkflowOptionWire] {
        let repository = try await store.workflowRepositorySnapshot()
        let live = repository.workflows.filter { workflow in
            guard workflow.enabled else { return false }
            return workflow.visible || workflow.workflowID == selectedID
        }
        var options = live.sorted(by: Self.pickerOrder).map {
            ComposerWorkflowOptionWire(
                id: $0.workflowID,
                displayName: $0.name,
                description: $0.source.rawValue,
                guidance: $0.definition,
                providerIDs: [],
                enabled: $0.enabled,
                visible: $0.visible,
                featuredOrder: $0.featuredOrder
            )
        }
        let seen = Set(options.map(\.id))
        for workflow in workflows where !seen.contains(workflow.id) {
            options.append(
                ComposerWorkflowOptionWire(
                    id: workflow.id,
                    displayName: workflow.displayName,
                    description: workflow.description,
                    guidance: workflow.guidance,
                    providerIDs: workflow.providerIDs,
                    enabled: true,
                    visible: true,
                    featuredOrder: workflow.featured ? options.count : nil
                )
            )
        }
        return options
    }

    private static func pickerOrder(_ lhs: ServerWorkflowDefinition, _ rhs: ServerWorkflowDefinition) -> Bool {
        switch (lhs.featuredOrder, rhs.featuredOrder) {
        case let (left?, right?):
            (left, lhs.workflowID) < (right, rhs.workflowID)
        case (_?, nil):
            true
        case (nil, _?):
            false
        default:
            (lhs.name, lhs.workflowID) < (rhs.name, rhs.workflowID)
        }
    }

    private func resolve(context: ComposerCatalogContext, includeStoredSelection: Bool = true) async throws -> AgentCatalogResolution {
        let storedDefaults: SessionNextTurnDefaultsRecord? = if includeStoredSelection, let sessionID = context.sessionID {
            try await store.nextTurnDefaults(sessionID: sessionID)
        } else {
            nil
        }
        let storedSelection = storedDefaults.map {
            AgentCatalogStoredSelection(
                providerID: $0.configuration.providerID,
                modelID: $0.configuration.modelID,
                effortID: $0.configuration.effortID,
                workflowID: $0.configuration.workflowID,
                permissionID: $0.configuration.permissionID,
                toolValues: $0.configuration.toolValues
            )
        }
        if let providerStateLoader {
            let instant = now()
            let states = try await providerStateLoader(instant)
            return try await AgentCatalogAuthority.resolve(
                providers: states,
                storedSelection: resolvedStoredSelection(storedSelection, in: states),
                context: .init(now: instant, activeRun: context.activeRun, externallyControlled: context.mcpControlled)
            )
        }
        let catalog = try await providerSettings.composerCatalog()
        let instant = now()
        var states: [AgentCatalogProviderState] = []
        for matrix in AgentComposerProviderMatrix.entries {
            guard let settings = catalog.providers.first(where: { $0.providerID == matrix.providerID }) else { continue }
            let values = storedDefaults?.configuration.providerID == matrix.providerID ? storedDefaults?.configuration.toolValues ?? [:] : [:]
            let selectedPermission = storedDefaults?.configuration.providerID == matrix.providerID ? storedDefaults?.configuration.permissionID : nil
            let providerProfile = try await providerProfileLoader?(matrix.providerID)
            let toolControls = providerProfile?.toolControls
                ?? ProviderComposerStableControls.descriptors(providerID: matrix.providerID, values: values, mutable: true, lockReasonCode: nil)
            let permissionControl: ProviderPermissionDescriptor? = if let providerProfile {
                providerProfile.permissionControl
            } else {
                ProviderComposerStableControls.permissionDescriptor(providerID: matrix.providerID, selectedID: selectedPermission, mutable: true, lockReasonCode: nil)
            }
            var sources: [AgentCatalogModelSource] = []
            let cached = matrix.discoveryPolicy.allowsPersistedFallback
                ? try await store.composerProviderCatalog(providerID: matrix.providerID)
                : nil
            if !settings.models.isEmpty {
                let persistedDiscovery = matrix.discoveryPolicy.allowsPersistedFallback
                    ? try await store.providerModelCatalog(providerID: matrix.providerID)
                    : nil
                if let persistedDiscovery, persistedDiscovery.models == settings.models {
                    sources.append(.init(kind: .persisted, observedAt: persistedDiscovery.refreshedAt, models: settings.models.map(Self.candidate)))
                } else {
                    sources.append(.init(kind: .live, observedAt: catalog.generatedAt, models: settings.models.map(Self.candidate)))
                    if matrix.discoveryPolicy.allowsPersistedFallback, cached?.models != settings.models {
                        try await store.persistComposerProviderCatalog(.init(providerID: matrix.providerID, models: settings.models, observedAt: instant))
                    }
                }
            }
            if let cached {
                sources.append(.init(kind: .persisted, observedAt: cached.observedAt, models: cached.models.map(Self.candidate)))
            }
            let desktopFallback = DesktopProviderModelFallbackCatalog.candidates(for: matrix.providerID)
            if matrix.discoveryPolicy.allowsStaticFallbackAfterSuccessfulPreflight, !desktopFallback.isEmpty {
                sources.append(.init(kind: .providerFallback, models: desktopFallback))
            }
            // The composer is a projection of durable provider choices, not a live
            // health check. A transient CLI/auth probe must not make already-known
            // models (and their tools/permissions) disappear while a chat opens.
            // Submission still traverses the provider runtime and reports a genuine
            // admission/authentication failure if the provider cannot execute.
            let hasKnownModels = sources.contains { !$0.models.isEmpty }
            let catalogReady = settings.runtimePreflightVerified && settings.preflight.ready
                || (hasKnownModels && settings.configurationPresent)
            states.append(.init(
                providerID: matrix.providerID,
                displayName: settings.displayName,
                enabled: settings.preference.enabled && settings.deploymentAllowed,
                configured: settings.preflight.ready || settings.configurationPresent,
                preflightReady: catalogReady,
                adapterAvailable: adapters[matrix.providerID] != nil,
                discoveryPolicy: matrix.discoveryPolicy,
                modelSources: sources,
                preferredModelID: settings.preference.defaultModel,
                preferredEffortID: settings.preference.reasoningEffort,
                toolControls: toolControls,
                permissionControl: permissionControl
            ))
        }
        return try await AgentCatalogAuthority.resolve(
            providers: states,
            storedSelection: resolvedStoredSelection(storedSelection, in: states),
            context: .init(now: instant, activeRun: context.activeRun, externallyControlled: context.mcpControlled)
        )
    }

    private func resolvedStoredSelection(
        _ storedSelection: AgentCatalogStoredSelection?,
        in states: [AgentCatalogProviderState]
    ) async throws -> AgentCatalogStoredSelection? {
        if let storedSelection { return storedSelection }
        return try await Self.composeStoreSelection(composeModelLoader?(), in: states)
    }

    private static func composeStoreSelection(_ raw: String?, in states: [AgentCatalogProviderState]) -> AgentCatalogStoredSelection? {
        let needle = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !needle.isEmpty else { return nil }
        for state in states {
            for source in state.modelSources {
                if let model = source.models.first(where: {
                    $0.modelID.lowercased() == needle || $0.rawValue.lowercased() == needle
                }) {
                    return .init(providerID: state.providerID, modelID: model.modelID)
                }
            }
        }
        return nil
    }

    private static func candidate(_ entry: ProviderModelCatalogEntry) -> AgentCatalogModelCandidate {
        .init(
            modelID: entry.id,
            rawValue: entry.providerRawValue ?? entry.id,
            displayName: entry.displayName,
            description: entry.description,
            supportedEffortIDs: entry.reasoningEfforts,
            defaultEffortID: entry.defaultReasoningEffort,
            serviceTier: entry.serviceTier,
            isProviderDefault: entry.isProviderDefault,
            capabilities: .init(nativeImages: entry.supportsNativeImages, steering: entry.supportsSteering)
        )
    }

    private static func modelWire(_ value: ProviderModelDescriptor) -> ComposerModelOptionWire {
        .init(id: value.modelID, displayName: value.displayName, description: value.description, supportedEffortIDs: value.supportedEffortIDs, defaultEffortID: value.defaultEffortID, capabilities: .init(nativeImages: value.capabilities.nativeImages, steering: value.capabilities.steering))
    }

    private static func controlWire(_ value: ProviderComposerControlDescriptor) -> ComposerControlWire {
        switch value {
        case let .toggle(id, name, detail, selected, required, mutable, warning, reason):
            .toggle(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), value: selected)
        case let .singleChoice(id, name, detail, selected, choices, required, mutable, warning, reason):
            .singleChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedID: selected, choices: choices.map(choiceWire))
        case let .multiChoice(id, name, detail, selected, choices, required, mutable, warning, reason):
            .multiChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedIDs: selected, choices: choices.map(choiceWire))
        }
    }

    private static func permissionWire(_ value: ProviderPermissionDescriptor) -> ComposerPermissionControlWire {
        .init(id: value.id, displayName: value.displayName, selectedID: value.selectedID, choices: value.choices.map(choiceWire), externallyManaged: value.externallyManaged, mutable: value.mutable, lockReasonCode: value.lockReasonCode)
    }

    private static func choiceWire(_ value: ProviderComposerChoiceDescriptor) -> ComposerControlChoiceWire {
        .init(id: value.id, displayName: value.displayName, detailText: value.detailText, enabled: value.enabled, warning: value.warning)
    }

    private static func wireValue(_ value: AgentControlValue) -> ComposerControlValueWire {
        switch value { case let .boolean(v): .boolean(v)
        case let .choice(v): .choice(v)
        case let .choices(v): .choices(v) }
    }

    private static func controlValue(_ value: ComposerControlValueWire) -> AgentControlValue {
        switch value { case let .boolean(v): .boolean(v)
        case let .choice(v): .choice(v)
        case let .choices(v): .choices(v) }
    }
}
