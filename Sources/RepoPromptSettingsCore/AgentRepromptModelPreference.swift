import Foundation

package enum AgentRepromptModelPreference {
    /// Nil is Automatic. This sentinel opts into the scoped primary Oracle explicitly.
    package static let primaryOracle = "primary-oracle"

    package static func normalizedRaw(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
}
