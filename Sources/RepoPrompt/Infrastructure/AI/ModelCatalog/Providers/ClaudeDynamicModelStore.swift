import Foundation

/// Claude Code's initialize response is the authority for the connected runtime.
/// Compatible backends keep their separately configured model mappings.
enum ClaudeDynamicModelStore {
    struct Record: Codable, Equatable {
        let value: String
        let displayName: String
        let description: String
        let supportsEffort: Bool?
        let supportedEffortLevels: [String]?

        var efforts: [ClaudeCodeEffortLevel] {
            guard supportsEffort != false else { return [] }
            return (supportedEffortLevels ?? []).compactMap(ClaudeCodeEffortLevel.parse)
        }
    }

    private static let cache = ProviderModelDiscoveryCache<Record>(key: "ClaudeCodeDiscoveredModels", identity: { $0.value })

    static func records(defaults: UserDefaults = .standard) -> [Record] {
        cache.current(defaults: defaults)
    }

    static func record(for raw: String?, defaults: UserDefaults = .standard) -> Record? {
        guard let raw else { return nil }
        return cache.remembered(defaults: defaults).first { $0.value.caseInsensitiveCompare(raw) == .orderedSame }
    }

    static func effort(_ requested: ClaudeCodeEffortLevel?, forModel raw: String?, defaults: UserDefaults = .standard) -> ClaudeCodeEffortLevel? {
        guard let record = record(for: raw, defaults: defaults) else { return requested }
        guard let requested, record.efforts.contains(requested) else { return nil }
        return requested
    }

    @discardableResult
    static func update(json: String, defaults: UserDefaults = .standard) -> Bool {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Record].self, from: data),
              decoded.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        return cache.save(decoded, defaults: defaults)
    }
}
