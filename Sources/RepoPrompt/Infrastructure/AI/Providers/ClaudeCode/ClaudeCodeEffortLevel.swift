import Foundation

// MARK: - Claude Code Effort Level

enum ClaudeCodeEffortLevel: String, CaseIterable {
    // Ordered highest → lowest so UI pickers and variant menus list the
    // strongest effort first. `allCases` drives both `AgentInputBar`'s Claude
    // effort picker and `claudeEffortSortRank` in `AgentModelCatalog`.
    case max
    case xhigh
    case high
    case medium
    case low

    static func parse(_ raw: String?) -> ClaudeCodeEffortLevel? {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        switch normalized {
        case "low":
            return .low
        case "medium":
            return .medium
        case "high":
            return .high
        case "max":
            return .max
        case "xhigh", "x-high":
            return .xhigh
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        case .xhigh: "XHigh"
        }
    }

    /// Value passed to the `CLAUDE_CODE_EFFORT_LEVEL` environment variable.
    var envValue: String {
        rawValue
    }
}
