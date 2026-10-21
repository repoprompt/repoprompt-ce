import Foundation

package enum AgentRepromptModelPreference {
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
