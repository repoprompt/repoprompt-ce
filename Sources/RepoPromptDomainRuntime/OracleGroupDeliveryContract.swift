import Foundation

/// Agent-facing text delivered with a multi-lane Oracle group.
///
/// RepoPrompt never merges lanes; the agent that receives the group reconciles
/// them. Reconcilers are known to favor the first, the longest, or their own
/// model family's answer. This text asks for evidence-based reconciliation
/// and lets the reader detect a truncated group. Every function returns nil for
/// fewer than two lanes so single-lane output stays byte-for-byte unchanged.
package enum OracleGroupDeliveryContract {
    package struct Lane: Equatable {
        package let laneIndex: Int
        package let modelID: String?
        package let chatID: String
        package let status: String
        package let isPartial: Bool

        package init(laneIndex: Int, modelID: String?, chatID: String, status: String, response: String?, partialResponse: String? = nil) {
            self.laneIndex = laneIndex
            self.modelID = modelID
            self.chatID = chatID
            self.status = status
            let hasResponse = !(response ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasPartial = !(partialResponse ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isPartial = !hasResponse && hasPartial
        }
    }

    /// Reconciliation guidance plus a lane manifest, placed before the lane bodies.
    package static func preamble(lanes: [Lane]) -> String? {
        guard lanes.count > 1 else { return nil }
        let ordered = lanes.sorted { $0.laneIndex < $1.laneIndex }
        var lines = [
            "**Reconciling these Oracle lanes**",
            "\(ordered.count) independent answers to the same request follow. Lane order is not a ranking; the first lane supplies the top-level continuation handle, and a successful follow-up through any lane's chat ID re-runs every lane.",
            "- Read every lane through the end-of-group marker (`\(endMarkerText(laneCount: ordered.count))`). If the marker or a lane is missing, page the export or try the read-only `oracle_chat_log` with that lane's chat ID. Logs may be scoped or clipped; report any remaining gap. Do not start a follow-up just to retrieve prior text.",
            "- Reconcile by evidence, not lane order, answer length, or model identity: check material single-lane and conflicting claims against the code, and report unresolved disagreements. A failed or partial lane is incomplete evidence.",
            "- Make the reconciliation visible to the user: begin your answer with `\(reconciliationHeading)`, state how many lanes completed and name any that did not, then give each material finding with the lanes that raised it, the evidence you checked, and whether you accepted, rejected, or left it unresolved.",
            "",
            "Lanes (\(ordered.count)):"
        ]
        lines += ordered.map { lane in
            let model = lane.modelID.map { "`\($0)`" } ?? "model unspecified"
            let partial = lane.isPartial ? " (partial)" : ""
            return "- \(OracleRosterContract.displayLabel(laneIndex: lane.laneIndex)) — \(model) — \(lane.status)\(partial) — chat ID `\(lane.chatID)`"
        }
        return lines.joined(separator: "\n")
    }

    /// Final line of a delivered group; its absence signals truncation.
    package static func endMarker(laneCount: Int) -> String? {
        guard laneCount > 1 else { return nil }
        return endMarkerText(laneCount: laneCount)
    }

    /// Heading the calling agent is asked to open its reconciled answer with.
    package static let reconciliationHeading = "**Oracle reconciliation**"

    private static func endMarkerText(laneCount: Int) -> String {
        "End of Oracle group: \(laneCount) lanes above."
    }

    /// Neutral reminder for follow-up hints that trail a delivered group.
    package static func followUpReminder(laneCount: Int) -> String? {
        guard laneCount > 1 else { return nil }
        return "The \(laneCount) Oracle lanes above are independent answers; reconcile them using the guidance at the top of the group. Lane order is not a ranking."
    }

    /// Sentence appended to export read instructions for grouped exports.
    package static func exportReadingRequirement(laneCount: Int) -> String? {
        guard laneCount > 1 else { return nil }
        return "The file contains \(laneCount) independent Oracle lanes: read through the \"End of Oracle group\" marker, paging if needed, before relying on it."
    }
}
