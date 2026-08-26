import Foundation
import RepoPromptDomainRuntime

struct OracleLaneMarkdownPayload: Equatable {
    enum Status: String {
        case running = "Running"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case unavailable = "Unavailable"
    }

    struct Lane: Equatable {
        let laneIndex: Int
        let chatID: String
        let providerID: String?
        let modelID: String
        let effectiveReasoningEffort: String?
        let status: Status
        let response: String?
        let partialResponse: String?
        let errorCode: String?
        let errorMessage: String?
    }

    let lanes: [Lane]
}

enum OracleLaneMarkdownFormatter {
    static let unspecifiedMetadata = "Provider default / not specified"

    static func format(_ payload: OracleLaneMarkdownPayload) -> String {
        payload.lanes
            .sorted { $0.laneIndex < $1.laneIndex }
            .map(formatLane)
            .joined(separator: "\n\n")
    }

    private static func formatLane(_ lane: OracleLaneMarkdownPayload.Lane) -> String {
        var lines = [
            "### \(OracleRosterContract.displayLabel(laneIndex: lane.laneIndex))",
            "- Status: \(lane.status.rawValue)",
            "- Provider: \(metadata(lane.providerID))",
            "- Model: \(metadata(lane.modelID))",
            "- Effective effort: \(metadata(lane.effectiveReasoningEffort))",
            "- Chat: `\(lane.chatID)`"
        ]

        if let response = nonempty(lane.response) {
            lines.append("")
            lines.append(response)
        }
        if let partial = nonempty(lane.partialResponse) {
            lines.append("")
            lines.append("Partial response:")
            lines.append(partial)
        }
        if let message = nonempty(lane.errorMessage) {
            lines.append("")
            if let code = nonempty(lane.errorCode) {
                lines.append("Error [\(code)]: \(message)")
            } else {
                lines.append("Error: \(message)")
            }
        } else if lane.status == .unavailable {
            lines.append("")
            lines.append("Response unavailable.")
        }
        return lines.joined(separator: "\n")
    }

    private static func metadata(_ value: String?) -> String {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return unspecifiedMetadata }
        return "`\(value)`"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
