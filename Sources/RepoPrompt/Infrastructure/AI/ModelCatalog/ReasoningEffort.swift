import Foundation

public enum CodexReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    static let displayOrder: [CodexReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]

    static func parse(_ raw: String?) -> CodexReasoningEffort? {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        switch normalized {
        case "none":
            return CodexReasoningEffort.none
        case "minimal":
            return .minimal
        case "low":
            return .low
        case "medium":
            return .medium
        case "high":
            return .high
        case "xhigh", "x-high":
            return .xhigh
        case "max", "maximum":
            return .max
        case "ultra":
            return .ultra
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .none:
            "None"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "XHigh"
        case .max:
            "Max"
        case .ultra:
            "Ultra"
        }
    }
}
