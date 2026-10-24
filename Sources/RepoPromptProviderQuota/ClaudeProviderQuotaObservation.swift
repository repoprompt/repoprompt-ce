import Foundation

/// An adapter-owned value from one Claude SDK rate-limit event. It deliberately contains
/// no SDK/package type or account identifier, so the quota runtime remains app-free.
package struct ClaudeProviderQuotaObservation: Equatable {
    package enum Status: String {
        case allowed
        case allowedWarning = "allowed_warning"
        case rejected
    }

    package let status: Status
    package let resetsAt: Double?
    package let rateLimitType: String?
    /// Fraction of the limit consumed, when explicitly reported by the SDK.
    package let utilization: Double?

    package init(status: Status, resetsAt: Double? = nil, rateLimitType: String? = nil, utilization: Double? = nil) {
        self.status = status
        self.resetsAt = resetsAt
        self.rateLimitType = rateLimitType
        self.utilization = utilization
    }
}
