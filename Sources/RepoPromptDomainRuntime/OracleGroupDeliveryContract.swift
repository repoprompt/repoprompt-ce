import Foundation

/// Agent-facing text delivered with a multi-lane Oracle group.
///
/// RepoPrompt never merges lanes; the agent that receives the group reconciles
/// them. Reconcilers are known to favor the first, the longest, or their own
/// model family's answer, and long deliveries get truncated from the end. This
/// text asks for evidence-based, claim-level reconciliation and lets the reader
/// detect a truncated group. Every function returns nil for fewer than two lanes
/// so single-lane output stays byte-for-byte unchanged.
package enum OracleGroupDeliveryContract {
    package struct Lane: Equatable {
        package let laneIndex: Int
        package let modelID: String?
        package let status: String
        package let responseLineCount: Int
        package let isPartial: Bool

        package init(laneIndex: Int, modelID: String?, status: String, response: String?, partialResponse: String? = nil) {
            self.laneIndex = laneIndex
            self.modelID = modelID
            self.status = status
            let hasResponse = Self.lineCount(response) > 0
            responseLineCount = Self.lineCount(hasResponse ? response : partialResponse)
            isPartial = !hasResponse && responseLineCount > 0
        }

        private static func lineCount(_ text: String?) -> Int {
            let trimmed = text?.trimmingCharacters(in: .newlines) ?? ""
            guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
            return trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        }
    }

    /// Reconciliation guidance plus a lane manifest, placed before the lane bodies.
    package static func preamble(lanes: [Lane]) -> String? {
        guard lanes.count > 1 else { return nil }
        let ordered = lanes.sorted { $0.laneIndex < $1.laneIndex }
        var lines = [
            "**Reconciling these Oracle lanes**",
            "\(ordered.count) independent answers to the same request follow. Lane order is not a ranking; the first lane (`\(OracleRosterContract.displayLabel(laneIndex: 0))`) is only the chat that follow-ups continue, not a more authoritative answer.",
            "- Read every lane through the line `\(endMarkerText(laneCount: ordered.count))` If a lane or that line is missing, the output was cut off: recover it or say so.",
            "- Work claim by claim: list each lane's findings, group them by root cause, and note which lanes raised each.",
            "- Weigh claims by evidence, not by answer length, lane order, or provider. Agreement across lanes raises confidence but is not proof.",
            "- A point raised by only one lane is a candidate, not noise. Check single-lane and conflicting claims against the code before adopting or rejecting them.",
            "- State disagreements you cannot resolve, and treat failed or partial lanes as missing evidence.",
            "",
            "Lanes (\(ordered.count)):"
        ]
        lines += ordered.map { lane in
            let model = lane.modelID.map { "`\($0)`" } ?? "model unspecified"
            let size = (lane.responseLineCount == 1 ? "1 line" : "\(lane.responseLineCount) lines") + (lane.isPartial ? " (partial)" : "")
            return "- \(OracleRosterContract.displayLabel(laneIndex: lane.laneIndex)) — \(model) — \(lane.status) — \(size)"
        }
        return lines.joined(separator: "\n")
    }

    /// Final line of a delivered group; its absence signals truncation.
    package static func endMarker(laneCount: Int) -> String? {
        guard laneCount > 1 else { return nil }
        return endMarkerText(laneCount: laneCount)
    }

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
        return "The file contains \(laneCount) independent Oracle lanes: read it to the end, paging if a read is truncated, and confirm you reached the \"End of Oracle group\" line before relying on it."
    }
}
