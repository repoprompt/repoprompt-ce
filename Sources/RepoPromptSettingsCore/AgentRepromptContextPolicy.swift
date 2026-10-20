import Foundation

package enum AgentRepromptContextPolicy: String, Codable, Sendable, CaseIterable {
    case automatic
    case never

    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .automatic
    }
}
