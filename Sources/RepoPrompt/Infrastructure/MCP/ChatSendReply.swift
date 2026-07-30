import Foundation
import MCP // for Value

enum OraclePairSendStatus: String {
    case completed
    case partialFailure = "partial_failure"
    case failed
}

struct OraclePairSendReply {
    let pairID: UUID
    let primaryChatID: String
    let secondaryChatID: String
    let primaryModel: AIModel
    let secondaryModel: AIModel
    let result: OraclePairCoordinator.Result<[String: Value]>
    let historyDiverged: Bool
    let historyPersistenceError: String?

    var status: OraclePairSendStatus {
        switch (result.primary, result.secondary) {
        case (.success, .success): .completed
        case (.failure, .failure): .failed
        default: .partialFailure
        }
    }

    func toMCPObject(mode: String) -> [String: Value] {
        var object: [String: Value] = switch result.primary {
        case let .success(primary):
            primary
        case let .failure(failure):
            [
                "chat_id": .string(primaryChatID),
                "mode": .string(mode),
                "errors": .array([.string(failure.message)])
            ]
        }
        object["status"] = .string(status.rawValue)
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["primary_chat_id"] = .string(primaryChatID)
        object["secondary_chat_id"] = .string(secondaryChatID)
        object["oracle_decision_policy"] = .string("caller_decides")
        object["oracle_history_diverged"] = .bool(historyDiverged)
        if let historyPersistenceError {
            object["oracle_pair_history_persistence_error"] = .string(historyPersistenceError)
            if status == .completed { object["status"] = .string(OraclePairSendStatus.partialFailure.rawValue) }
        }
        object["oracle_combined_response"] = .string(combinedResponse)
        object["oracle_results"] = .object([
            "primary": laneValue(
                lane: .primary,
                execution: result.primary,
                chatID: primaryChatID,
                model: primaryModel
            ),
            "secondary": laneValue(
                lane: .secondary,
                execution: result.secondary,
                chatID: secondaryChatID,
                model: secondaryModel
            )
        ])
        return object
    }

    private var combinedResponse: String {
        [
            "# Primary Oracle\n\n\(laneText(result.primary))",
            "# Secondary Oracle\n\n\(laneText(result.secondary))"
        ].joined(separator: "\n\n")
    }

    private func laneText(_ execution: OraclePairCoordinator.LaneExecution<[String: Value]>) -> String {
        switch execution {
        case let .success(value):
            value["response"]?.stringValue ?? "(No response)"
        case let .failure(failure):
            failure.partialResponse ?? "Failed: \(failure.message)"
        }
    }

    private func laneValue(
        lane: OracleLane,
        execution: OraclePairCoordinator.LaneExecution<[String: Value]>,
        chatID: String,
        model: AIModel
    ) -> Value {
        var object: [String: Value]
        switch execution {
        case let .success(value):
            object = value
            object["status"] = .string("completed")
        case let .failure(failure):
            object = [
                "status": .string("failed"),
                "error": .string(failure.message),
                "error_code": .string(failure.code.rawValue)
            ]
            if let partialResponse = failure.partialResponse {
                object["partial_response"] = .string(partialResponse)
            }
        }
        object["oracle_lane"] = .string(lane.rawValue)
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["chat_id"] = .string(chatID)
        object["model_raw_id"] = .string(model.rawValue)
        object["model_display_name"] = .string(model.displayName)
        return .object(object)
    }
}

struct ChatSendReply: Codable {
    let chatId: UUID
    let shortId: String
    let mode: String
    let response: String?
    let errors: [String]?

    func toMCPValue() -> Value {
        var obj: [String: Value] = [
            "chat_id": .string(shortId), // Only expose short ID
            "mode": .string(mode)
        ]
        if let r = response { obj["response"] = .string(r) }
        if let e = errors { obj["errors"] = .array(e.map { .string($0) }) }

        return .object(obj)
    }
}
