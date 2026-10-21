import Foundation

package enum AgentRepromptModelPreference {
    /// Legacy sentinel. Decode to the then-current concrete Oracle model, never a live linkage.
    package static let primaryOracle = "primary-oracle"
    package static let unavailableLegacyOracle = "unavailable-legacy-reprompt-oracle"

    package static func migratedRaw(_ raw: String?, primary: String?) -> String? {
        let value = normalizedRaw(raw)
        return value == primaryOracle ? (normalizedRaw(primary) ?? unavailableLegacyOracle) : value
    }

    package static func normalizedRaw(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
}

package enum AgentRepromptMode: String, Codable, CaseIterable {
    case review
    case sendAutomatically

    package var displayName: String {
        self == .review ? "Review before sending" : "Send automatically"
    }

    package init(from decoder: Decoder) throws {
        self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .review
    }
}
