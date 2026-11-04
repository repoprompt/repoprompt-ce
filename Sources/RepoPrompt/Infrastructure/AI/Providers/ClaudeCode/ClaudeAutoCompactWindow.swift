import Foundation

/// Claude Code's `CLAUDE_CODE_AUTO_COMPACT_WINDOW` sets the context capacity it compacts against.
/// Claude Code caps the value at the model's own window, and result events keep reporting the
/// model's full window, so the effective denominator is the smaller of the two.
enum ClaudeAutoCompactWindow {
    static let environmentKey = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"

    /// The positive token count configured in a launch environment; malformed values are ignored,
    /// matching Claude Code.
    static func tokens(in environment: [String: String]) -> Int? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw),
              value > 0
        else { return nil }
        return value
    }

    /// The effective window for a known model window. An unknown model window leaves the configured
    /// auto-compact window as the best available denominator.
    static func effectiveWindow(modelWindow: Int?, autoCompactWindow: Int?) -> Int? {
        guard let autoCompactWindow, autoCompactWindow > 0 else { return modelWindow }
        guard let modelWindow, modelWindow > 0 else { return autoCompactWindow }
        return min(modelWindow, autoCompactWindow)
    }

    /// Caps a provider-reported window without inventing one when the report carried none. A
    /// non-positive report (a withdrawal signal) passes through unchanged.
    static func cappedReportedWindow(_ reportedWindow: Int?, autoCompactWindow: Int?) -> Int? {
        guard let reportedWindow, reportedWindow > 0 else { return reportedWindow }
        return effectiveWindow(modelWindow: reportedWindow, autoCompactWindow: autoCompactWindow)
    }
}
