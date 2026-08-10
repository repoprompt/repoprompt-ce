import Foundation
import MCP // for Value

enum OraclePairSendStatus: String {
    case completed
    case partialFailure = "partial_failure"
    case failed
}

struct OracleSendRoute: Equatable {
    let contextID: UUID?
    let agentSessionID: UUID?
    let agentRunID: UUID?
}

struct OracleSendResult {
    enum Payload {
        case single(ChatSendReply)
        case paired(OraclePairSendReply)
    }

    let payload: Payload
    let route: OracleSendRoute

    func primaryReply() -> ChatSendReply {
        switch payload {
        case let .single(reply): reply
        case let .paired(pair): pair.primaryReply()
        }
    }

    func toMCPObject() -> [String: Value] {
        var object: [String: Value] = switch payload {
        case let .single(reply): reply.toMCPObject()
        case let .paired(reply): reply.toMCPObject()
        }
        if let contextID = route.contextID {
            object["context_id"] = .string(contextID.uuidString)
        }
        if let agentSessionID = route.agentSessionID {
            object["agent_session_id"] = .string(agentSessionID.uuidString)
        }
        if let agentRunID = route.agentRunID {
            object["agent_run_id"] = .string(agentRunID.uuidString)
        }
        return object
    }
}

struct OracleSendFailure: LocalizedError {
    let result: OracleSendResult
    let message: String

    var errorDescription: String? {
        message
    }
}

struct OraclePairSendReply {
    let pairID: UUID
    let mode: String
    let primarySessionID: UUID
    let primaryChatID: String
    let secondaryChatID: String
    let primaryModel: AIModel
    let secondaryModel: AIModel
    let result: OraclePairCoordinator.Result<ChatSendReply>
    let historyDiverged: Bool
    let historyPersistenceError: String?

    var status: OraclePairSendStatus {
        switch (result.primary, result.secondary) {
        case (.success, .success):
            historyPersistenceError == nil ? .completed : .partialFailure
        case (.failure, .failure):
            .failed
        default:
            .partialFailure
        }
    }

    var failureSummary: String? {
        var warnings = [
            laneFailureSummary(.primary, result.primary),
            laneFailureSummary(.secondary, result.secondary)
        ].compactMap(\.self)
        if let historyPersistenceError {
            warnings.append("Oracle pair history persistence failed: \(historyPersistenceError)")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    func primaryReply() -> ChatSendReply {
        switch result.primary {
        case let .success(primary):
            ChatSendReply(
                chatId: primary.chatId,
                shortId: primaryChatID,
                mode: mode,
                response: primary.response,
                errors: failureSummary.map { [$0] }
            )
        case let .failure(failure):
            ChatSendReply(
                chatId: primarySessionID,
                shortId: primaryChatID,
                mode: mode,
                response: failure.partialResponse,
                errors: failureSummary.map { [$0] }
            )
        }
    }

    func toMCPObject() -> [String: Value] {
        var object: [String: Value]
        switch result.primary {
        case let .success(primary):
            object = primary.toMCPObject()
        case let .failure(failure):
            object = [
                "chat_id": .string(primaryChatID),
                "mode": .string(mode),
                "errors": .array([.string(failureSummary ?? failure.message)])
            ]
            if let partialResponse = failure.partialResponse {
                object["partial_response"] = .string(partialResponse)
                object["response"] = .string(partialResponse)
            }
        }
        object["status"] = .string(status.rawValue)
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["primary_chat_id"] = .string(primaryChatID)
        object["secondary_chat_id"] = .string(secondaryChatID)
        object["oracle_history_diverged"] = .bool(historyDiverged)
        if let historyPersistenceError {
            object["oracle_pair_history_persistence_error"] = .string(historyPersistenceError)
        }
        // Surface Secondary-only / history failures at the top level so single-lane
        // MCP consumers do not treat partial_failure as a clean success.
        if status != .completed, let failureSummary, object["errors"] == nil {
            object["errors"] = .array([.string(failureSummary)])
        }
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

    private func laneFailureSummary(
        _ lane: OracleLane,
        _ execution: OraclePairCoordinator.LaneExecution<ChatSendReply>
    ) -> String? {
        guard case let .failure(failure) = execution else { return nil }
        let label = lane == .primary ? "Primary" : "Secondary"
        return "\(label) Oracle failed: \(failure.message)"
    }

    private func laneValue(
        lane: OracleLane,
        execution: OraclePairCoordinator.LaneExecution<ChatSendReply>,
        chatID: String,
        model: AIModel
    ) -> Value {
        var object: [String: Value]
        switch execution {
        case let .success(reply):
            object = reply.toMCPObject()
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

    func toMCPObject() -> [String: Value] {
        var object: [String: Value] = [
            "chat_id": .string(shortId), // Only expose short ID
            "mode": .string(mode)
        ]
        if let response { object["response"] = .string(response) }
        if let errors { object["errors"] = .array(errors.map { .string($0) }) }
        return object
    }

    func toMCPValue() -> Value {
        .object(toMCPObject())
    }
}
