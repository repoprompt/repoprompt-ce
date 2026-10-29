import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

extension AgentACPModelRegistry {
    static let shared = AgentACPModelRegistry(dependencies: .app)
}

extension DevinModelCatalog {
    static var current: DevinModelCatalog {
        AgentACPModelRegistry.shared.currentDevinCatalog()
    }
}

extension AgentACPModelRegistry.Dependencies {
    /// Construct operations without touching the store or advertised catalog until invoked.
    static var app: Self {
        Self(
            loadAll: { ACPDynamicModelStore.loadAll() },
            load: { ACPDynamicModelStore.load(providerID: $0) },
            save: { ACPDynamicModelStore.save($0, for: $1) },
            remove: { ACPDynamicModelStore.remove(providerID: $0) },
            invalidate: { AgentAdvertisedModelCatalog.shared.invalidate($0) }
        )
    }
}

extension CursorACPModelPollingService.Registry {
    static var app: Self {
        Self(
            update: { AgentACPModelRegistry.shared.updateDiscoveredModels($0, for: .cursor) },
            snapshot: { AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor) },
            snapshotAfterWarm: { await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .cursor) }
        )
    }
}

extension CursorACPModelPollingService {
    static let shared = CursorACPModelPollingService(
        client: CursorACPControllerModelDiscoveryClient(), registry: .app
    )
}

extension GrokBuildACPModelPollingService {
    static let shared = GrokBuildACPModelPollingService(
        client: GrokBuildACPControllerModelDiscoveryClient(),
        registry: .shared,
        logFailure: { message in
            if AgentRuntimeProviderService.enableDebugLogging {
                print("[GrokBuildACPModelPolling] refresh failed: \(message)")
            }
        }
    )
}

extension OpenCodeACPModelPollingService.Registry {
    static var app: Self {
        Self(
            update: { AgentACPModelRegistry.shared.updateDiscoveredModels($0, for: .openCode) },
            snapshot: { AgentACPModelRegistry.shared.resolvedSnapshot(for: .openCode) },
            snapshotAfterWarm: { await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .openCode) }
        )
    }
}

extension OpenCodeACPModelPollingService {
    static let shared = OpenCodeACPModelPollingService(
        client: OpenCodeACPControllerModelDiscoveryClient(), registry: .app
    )
}

/// App convenience boundaries retain the existing lazy persisted-catalog lookup.
/// The interpretation owners accept that lookup explicitly and never read app storage.
extension CodexModelSpecifier {
    init(raw: String?, discoveredRecords: @autoclosure () -> [CodexDynamicModelRecord] = CodexDynamicModelStore.load()) {
        self.init(raw: raw, catalogRecords: discoveredRecords)
    }

    static func splitLegacyModelID(
        _ raw: String?,
        discoveredRecords: @autoclosure () -> [CodexDynamicModelRecord] = CodexDynamicModelStore.load()
    ) -> (baseModel: String?, reasoningEffort: ReasoningEffort?, serviceTier: String?) {
        splitLegacyModelID(raw, catalogRecords: discoveredRecords)
    }
}

extension CodexServiceTierVariantCatalog {
    static func isFastVariant(rawModel: String?) -> Bool {
        isFastVariant(rawModel: rawModel, catalogRecords: { CodexDynamicModelStore.load() })
    }

    static func serviceTierAwareBaseID(for rawModel: String) -> String {
        serviceTierAwareBaseID(for: rawModel, catalogRecords: { CodexDynamicModelStore.load() })
    }

    static func fastVariantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?,
        discoveredRecords: @autoclosure () -> [CodexDynamicModelRecord] = CodexDynamicModelStore.load()
    ) -> String? {
        fastVariantID(baseModelID: baseModelID, reasoningEffort: reasoningEffort, catalogRecords: discoveredRecords)
    }
}

extension CodexDynamicModelMapper {
    static func options(from remoteModels: [CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelOption] {
        let records = remoteModels.map { model in
            CodexDynamicModelRecord(
                id: model.id,
                model: model.model,
                displayName: model.displayName,
                description: model.description,
                isDefault: model.isDefault,
                supportedReasoningEfforts: model.supportedReasoningEfforts.map {
                    CodexDynamicReasoningRecord(reasoningEffort: $0.reasoningEffort, description: $0.description)
                },
                defaultReasoningEffort: model.defaultReasoningEffort,
                serviceTiers: model.serviceTiers
            )
        }
        return options(from: records)
    }

    static func options(from records: [CodexDynamicModelRecord]) -> [CodexDynamicModelOption] {
        options(from: records, catalogRecords: { CodexDynamicModelStore.load() })
    }

    static func optionPrecedes(_ lhs: CodexDynamicModelOption, _ rhs: CodexDynamicModelOption) -> Bool {
        optionPrecedes(lhs, rhs, catalogRecords: { CodexDynamicModelStore.load() })
    }

    static func displayName(forModelID id: String, records: [CodexDynamicModelRecord]) -> String? {
        displayName(forModelID: id, records: records, catalogRecords: { CodexDynamicModelStore.load() })
    }
}
