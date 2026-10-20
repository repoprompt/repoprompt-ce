import Foundation

package enum AgentRepromptContextPolicy: String, Codable, CaseIterable {
    case automatic
    case never

    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .never
    }
}
