import Foundation

/// Only native subscription backends participate; API keys and MCP OAuth are not profiles.
package enum SubscriptionBackend: String, Codable, Hashable {
    case claudeCode
    case codex
}

package struct SubscriptionProfileID: Codable, Hashable {
    package let backend: SubscriptionBackend
    package let uuid: UUID

    package init(backend: SubscriptionBackend, uuid: UUID) {
        self.backend = backend
        self.uuid = uuid
    }
}

package enum SubscriptionAccountSelection: Equatable {
    case legacy(SubscriptionBackend)
    case profile(SubscriptionProfileID)
}

/// Local metadata only. Presence or restoration of a profile does not establish credential readiness.
package struct SubscriptionProfileCatalog: Codable, Equatable {
    package struct Profile: Codable, Equatable {
        package let id: SubscriptionProfileID
        package fileprivate(set) var label: String
        package fileprivate(set) var isArchived: Bool
    }

    package enum CatalogError: Error, Equatable {
        case unsupportedVersion
        case invalidLabel
        case duplicateID
        case missingProfile
        case archivedProfile
        case invalidDefault
    }

    private static let schemaVersion = 1
    package private(set) var profiles: [Profile] = []
    private var defaults: [SubscriptionBackend: SubscriptionProfileID] = [:]

    package init() {}

    @discardableResult
    package mutating func add(backend: SubscriptionBackend, label: String) throws -> SubscriptionProfileID {
        let label = try Self.normalizedLabel(label)
        let id = SubscriptionProfileID(backend: backend, uuid: UUID())
        profiles.append(Profile(id: id, label: label, isArchived: false))
        return id
    }

    package mutating func rename(_ id: SubscriptionProfileID, label: String) throws {
        let index = try index(of: id)
        profiles[index].label = try Self.normalizedLabel(label)
    }

    package mutating func setArchived(_ archived: Bool, for id: SubscriptionProfileID) throws {
        let index = try index(of: id)
        profiles[index].isArchived = archived
        if archived, defaults[id.backend] == id {
            defaults.removeValue(forKey: id.backend)
        }
    }

    /// A preference for new requests only, not permission to launch or to rebind an existing session.
    package mutating func setDefault(_ selection: SubscriptionAccountSelection) throws {
        switch selection {
        case let .legacy(backend):
            defaults.removeValue(forKey: backend)
        case let .profile(id):
            let index = try index(of: id)
            guard !profiles[index].isArchived else { throw CatalogError.archivedProfile }
            defaults[id.backend] = id
        }
    }

    package func defaultSelection(for backend: SubscriptionBackend) -> SubscriptionAccountSelection {
        guard let id = defaults[backend] else { return .legacy(backend) }
        return .profile(id)
    }

    private func index(of id: SubscriptionProfileID) throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw CatalogError.missingProfile }
        return index
    }

    private static func normalizedLabel(_ label: String) throws -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw CatalogError.invalidLabel }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case profiles
        case defaults
    }

    package init(from decoder: any Decoder) throws {
        do {
            try self.init(validating: decoder)
        } catch let error as CatalogError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid subscription profile catalog",
                underlyingError: error
            ))
        }
    }

    private init(validating decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw CatalogError.unsupportedVersion
        }
        profiles = try container.decode([Profile].self, forKey: .profiles)
        var activeIDs: Set<SubscriptionProfileID> = []
        var allIDs: Set<SubscriptionProfileID> = []
        for profile in profiles {
            guard allIDs.insert(profile.id).inserted else { throw CatalogError.duplicateID }
            _ = try Self.normalizedLabel(profile.label)
            if !profile.isArchived { activeIDs.insert(profile.id) }
        }
        let storedDefaults = try container.decode([String: SubscriptionProfileID].self, forKey: .defaults)
        for (backend, id) in storedDefaults {
            guard backend == id.backend.rawValue, activeIDs.contains(id) else { throw CatalogError.invalidDefault }
            defaults[id.backend] = id
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(Dictionary(uniqueKeysWithValues: defaults.map { ($0.key.rawValue, $0.value) }), forKey: .defaults)
    }
}
