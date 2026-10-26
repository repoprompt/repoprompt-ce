import Foundation

/// Provider-agnostic shape of one ACP-advertised compact command turn.
///
/// Elapsed time and a generic `.completed` turn are not completion evidence. The only correlated
/// signal this detector accepts is a vouched context count strictly below the pre-compact figure.
/// Devin, Grok Build, and Antigravity are not special-cased; the same shape rules apply to every
/// ACP session that advertised `compact`.
enum AgentSelfCompactInstantReturn {
    /// Command turns that return at least this quickly, with no assistant or tool row, match the
    /// known fire-and-forget shape and enter the settle window.
    static let maximumCommandDuration: Duration = .seconds(2)
    /// Best-effort wait for a vouched drop. The deadline does not prove compaction finished.
    static let settleDuration: Duration = .seconds(90)

    static func isInstantReturn(elapsed: Duration?, assistantOrToolRowCount: Int?) -> Bool {
        guard let elapsed, elapsed >= .zero, elapsed < maximumCommandDuration,
              let assistantOrToolRowCount
        else { return false }
        return assistantOrToolRowCount == 0
    }

    static func isVouchedDrop(before: Int?, current: Int?) -> Bool {
        guard let before, let current else { return false }
        return current < before
    }
}
