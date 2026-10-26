import Foundation

/// Durable Auto Effort intent. A missing service field retains the legacy Jev selection
/// without writing it; blank and unknown explicit values remain exact and unavailable.
struct AutoEffortConfiguration: Equatable {
    let enabled: Bool
    let selectedBackendRawValue: String?
    let revision: UInt64

    var selectedBackendID: DecisionServiceID? {
        guard let raw = selectedBackendRawValue else { return .jev }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DecisionServiceID(rawValue: raw)
    }
}
