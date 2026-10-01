import Foundation
import RepoPromptDomainRuntime

/// Lane coverage facts for a multi-lane Oracle result, shown in tool-card headers.
///
/// This reports only what RepoPrompt knows: how many lanes completed and why the
/// others did not. It never claims the lanes were reconciled; that is the calling
/// agent's job and lives in its answer.
struct OracleLaneCoverage: Equatable {
    struct IncompleteLane: Equatable {
        let label: String
        let model: String
        let reason: String
    }

    let completedCount: Int
    let totalCount: Int
    let incompleteLanes: [IncompleteLane]

    /// Returns nil for single-lane results so their cards stay unchanged.
    init?(lanes: [ToolResultDTOs.ChatSendDTO.OracleLaneDTO]?) {
        guard let lanes, lanes.count > 1 else { return nil }
        let ordered = lanes.sorted { $0.laneIndex < $1.laneIndex }
        let completed = OracleLaneResultStatus.completed.rawValue
        totalCount = ordered.count
        completedCount = ordered.count { $0.status == completed }
        incompleteLanes = ordered.filter { $0.status != completed }.map { lane in
            IncompleteLane(
                label: OracleRosterContract.displayLabel(laneIndex: lane.laneIndex),
                model: Self.shortModelName(lane.executionProfile?.modelID ?? lane.modelID),
                reason: Self.reason(status: lane.status, error: lane.error)
            )
        }
    }

    var isComplete: Bool {
        completedCount == totalCount
    }

    /// Compact header text, e.g. `1/2 lanes · claude-opus-5 timed out`.
    var summaryText: String {
        var text = "\(completedCount)/\(totalCount) lanes"
        if let first = incompleteLanes.first {
            text += " · \(first.model) \(first.reason)"
            if incompleteLanes.count > 1 {
                text += " +\(incompleteLanes.count - 1)"
            }
        }
        return text
    }

    var accessibilityText: String {
        var text = "\(completedCount) of \(totalCount) Oracle lanes completed"
        for lane in incompleteLanes {
            text += "; \(lane.label), \(lane.model), \(lane.reason)"
        }
        return text
    }

    /// Partial coverage is a warning, not a success.
    var cardStatus: ToolCardStatus? {
        if isComplete { return nil }
        return completedCount == 0 ? .failure : .warning
    }

    static func shortModelName(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterSlash = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let last = afterSlash.components(separatedBy: "__").last ?? afterSlash
        return last.isEmpty ? "model" : last
    }

    static func reason(
        status: String,
        error: ToolResultDTOs.ChatSendDTO.OracleLaneErrorDTO?
    ) -> String {
        let haystack = "\(error?.code ?? "") \(error?.message ?? "")".lowercased()
        if haystack.contains("timeout") || haystack.contains("timed out") || haystack.contains("timed_out") {
            return "timed out"
        }
        if status == OracleLaneResultStatus.cancelled.rawValue || error?.code == "cancelled" {
            return "cancelled"
        }
        if error?.code == "empty_response" {
            return "empty response"
        }
        return "failed"
    }
}
