import Foundation
import RepoPromptAIContracts
import RepoPromptSettingsCore

enum ACPDynamicModelStore {
    private static let storageKey = "ACPDynamicModelProviders"

    static func save(
        _ snapshot: ACPDiscoveredSessionModels,
        for providerID: ACPProviderID,
        defaults: UserDefaults = .standard
    ) {
        guard let record = ACPDynamicModelCanonicalization.canonicalProviderRecord(from: snapshot, providerID: providerID) else {
            remove(providerID: providerID, defaults: defaults)
            return
        }
        var records = loadProviderRecords(defaults: defaults)
        records.removeAll { $0.providerID == providerID.rawValue }
        records.append(record)
        records.sort {
            $0.providerID.localizedCaseInsensitiveCompare($1.providerID) == .orderedAscending
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func load(
        providerID: ACPProviderID,
        defaults: UserDefaults = .standard
    ) -> ACPDiscoveredSessionModels? {
        loadAll(defaults: defaults)[providerID]
    }

    static func loadAll(
        defaults: UserDefaults = .standard
    ) -> [ACPProviderID: ACPDiscoveredSessionModels] {
        var snapshots: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
        for record in loadProviderRecords(defaults: defaults) {
            guard let providerID = ACPProviderID(rawValue: record.providerID),
                  let snapshot = ACPDynamicModelCanonicalization.snapshot(from: record),
                  snapshots[providerID] == nil else { continue }
            snapshots[providerID] = snapshot
        }
        return snapshots
    }

    static func remove(
        providerID: ACPProviderID,
        defaults: UserDefaults = .standard
    ) {
        var records = loadProviderRecords(defaults: defaults)
        records.removeAll { $0.providerID == providerID.rawValue }
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadProviderRecords(defaults: UserDefaults) -> [ACPDynamicProviderRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([ACPDynamicProviderRecord].self, from: data)
        else {
            return []
        }
        return records.filter { ACPProviderID(rawValue: $0.providerID) != nil }
    }
}

enum ACPAIModelCatalog {
    static func openCodeModelOptionsFromStore() -> [AgentModelOption] {
        AgentACPModelRegistry.shared.resolvedSnapshot(for: .openCode)?.options ?? []
    }

    static func openCodeModelsFromStore() -> [AIModel] {
        openCodeModelOptionsFromStore().map { .openCodeCustom(name: $0.rawValue) }
    }

    static func cursorModelsFromStore() -> [AIModel] {
        cursorModelOptionsForPicker().map { .cursorCustom(name: $0.rawValue) }
    }

    static func grokBuildModelsFromStore() -> [AIModel] {
        grokBuildModelOptionsFromStore().map { .grokBuildCustom(name: $0.rawValue) }
    }

    static func devinModelOptionsFromStore() -> [AgentModelOption] {
        DevinModelCatalog.current.entries.map(\.option)
    }

    static func devinModelsFromStore() -> [AIModel] {
        devinModelOptionsFromStore().map { .devinCustom(name: $0.rawValue) }
    }

    static func openCodeModelOption(for rawValue: String) -> AgentModelOption? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return openCodeModelOptionsFromStore()
            .first { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    static func cursorModelOption(for rawValue: String) -> AgentModelOption? {
        CursorAIModelCatalog.option(matching: rawValue)
    }

    static func grokBuildModelOption(for rawValue: String) -> AgentModelOption? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return grokBuildModelOptionsFromStore()
            .first { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    static func devinModelOption(for rawValue: String) -> AgentModelOption? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return devinModelOptionsFromStore()
            .first { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    static func normalizedCursorModelAlias(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: Substring = if let bracketIndex = trimmed.firstIndex(of: "[") {
            trimmed[..<bracketIndex]
        } else {
            trimmed[...]
        }
        return String(base)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// All Cursor surfaces use the same discovered membership, with Auto before discovery.
    private static func cursorModelOptionsForPicker() -> [AgentModelOption] {
        CursorAIModelCatalog.options
    }

    private static func grokBuildModelOptionsFromStore() -> [AgentModelOption] {
        AgentModelCatalog.options(
            for: .grokBuild,
            availability: AgentModelCatalog.AvailabilityContext(grokBuildAvailable: true)
        )
    }
}
