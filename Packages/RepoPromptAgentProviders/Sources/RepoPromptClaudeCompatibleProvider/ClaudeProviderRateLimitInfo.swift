import Foundation

/// Subscription telemetry from the official SDK `rate_limit_event` contract.
/// Not per-session context usage. Optional fields stay unknown; status is not a percent.
public struct ClaudeProviderRateLimitInfo: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        case allowed
        case allowedWarning = "allowed_warning"
        case rejected
    }

    public let status: Status
    public let resetsAt: Double?
    public let rateLimitType: String?
    /// Fraction consumed (0...1), not percentage points. May be absent while allowed.
    public let utilization: Double?

    public init(status: Status, resetsAt: Double? = nil, rateLimitType: String? = nil, utilization: Double? = nil) {
        self.status = status
        self.resetsAt = resetsAt
        self.rateLimitType = rateLimitType
        self.utilization = utilization
    }

    /// Pure wire boundary. No event/session identifiers or opaque extra fields escape.
    public static func decodeEvent(_ data: Data) -> Self? {
        struct Event: Decodable {
            let type: String
            let rate_limit_info: ClaudeProviderRateLimitInfo
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: data),
              event.type == "rate_limit_event"
        else { return nil }
        return event.rate_limit_info
    }
}
