import Foundation
import MCP // for Value

enum OraclePairSendStatus: String {
    case completed
    case partialFailure = "partial_failure"
    case failed
}

typealias OracleGroupSendStatus = OraclePairSendStatus

enum OracleGroupReplyValidationError: LocalizedError, Equatable {
    case laneMetadataMismatch(expected: [OracleLane])

    var errorDescription: String? {
        switch self {
        case let .laneMetadataMismatch(expected):
            "Oracle group metadata must contain exactly the lanes [\(expected.map(\.rawValue).joined(separator: ", "))]."
        }
    }
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
    let sessionIDsByLane: [OracleLane: UUID]
    let chatIDsByLane: [OracleLane: String]
    let modelsByLane: [OracleLane: AIModel]
    let result: OraclePairCoordinator.Result<ChatSendReply>
    let historyDiverged: Bool
    let historyPersistenceError: String?

    var groupID: UUID { pairID }
    var oracleCount: Int { result.orderedResults.count }
    var orderedLanes: [OracleLane] { result.orderedLanes }
    var primaryChatID: String { requiredChatID(for: .primary) }
    var secondaryChatID: String { requiredChatID(for: .secondary) }
    var primaryModel: AIModel { requiredModel(for: .primary) }
    var secondaryModel: AIModel { requiredModel(for: .secondary) }

    /// Compatibility initializer for the original two-lane runtime.
    init(
        pairID: UUID,
        mode: String,
        primarySessionID: UUID,
        primaryChatID: String,
        secondaryChatID: String,
        primaryModel: AIModel,
        secondaryModel: AIModel,
        result: OraclePairCoordinator.Result<ChatSendReply>,
        historyDiverged: Bool,
        historyPersistenceError: String?
    ) {
        self.pairID = pairID
        self.mode = mode
        self.primarySessionID = primarySessionID
        var resolvedSessionIDs: [OracleLane: UUID] = [.primary: primarySessionID]
        if let secondarySessionID = Self.sessionID(for: .secondary, in: result) {
            resolvedSessionIDs[.secondary] = secondarySessionID
        }
        sessionIDsByLane = resolvedSessionIDs
        chatIDsByLane = [.primary: primaryChatID, .secondary: secondaryChatID]
        modelsByLane = [.primary: primaryModel, .secondary: secondaryModel]
        self.result = result
        self.historyDiverged = historyDiverged
        self.historyPersistenceError = historyPersistenceError
    }

    /// Generic ordered group initializer. All metadata maps must cover the same
    /// complete 2...5 lane prefix represented by `result`.
    init(
        groupID: UUID,
        mode: String,
        sessionIDsByLane: [OracleLane: UUID],
        chatIDsByLane: [OracleLane: String],
        modelsByLane: [OracleLane: AIModel],
        result: OraclePairCoordinator.Result<ChatSendReply>,
        historyDiverged: Bool,
        historyPersistenceError: String?
    ) throws {
        let lanes = result.orderedLanes
        guard (2 ... OracleLane.allCases.count).contains(lanes.count) else {
            throw OracleLaneValidationError.invalidCount(lanes.count)
        }
        try OracleLane.validateOrderedPrefix(lanes)
        let expected = Set(lanes)
        guard Set(sessionIDsByLane.keys) == expected,
              Set(chatIDsByLane.keys) == expected,
              Set(modelsByLane.keys) == expected,
              let primarySessionID = sessionIDsByLane[.primary]
        else {
            throw OracleGroupReplyValidationError.laneMetadataMismatch(expected: lanes)
        }

        pairID = groupID
        self.mode = mode
        self.primarySessionID = primarySessionID
        self.sessionIDsByLane = sessionIDsByLane
        self.chatIDsByLane = chatIDsByLane
        self.modelsByLane = modelsByLane
        self.result = result
        self.historyDiverged = historyDiverged
        self.historyPersistenceError = historyPersistenceError
    }

    var status: OraclePairSendStatus {
        let successCount = result.orderedResults.reduce(into: 0) { count, laneResult in
            if case .success = laneResult.execution { count += 1 }
        }
        if successCount == result.orderedResults.count {
            return historyPersistenceError == nil ? .completed : .partialFailure
        }
        return successCount == 0 ? .failed : .partialFailure
    }

    var failureSummary: String? {
        var warnings = result.orderedResults.compactMap { laneResult in
            laneFailureSummary(laneResult.lane, laneResult.execution)
        }
        if let historyPersistenceError {
            let noun = oracleCount == 2 ? "pair" : "group"
            warnings.append("Oracle \(noun) history persistence failed: \(historyPersistenceError)")
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
        object["oracle_group_id"] = .string(groupID.uuidString)
        object["oracle_count"] = .int(oracleCount)
        object["oracle_chat_ids"] = .object(Dictionary(uniqueKeysWithValues: orderedLanes.map { lane in
            (lane.rawValue, .string(requiredChatID(for: lane)))
        }))
        object["oracle_result_order"] = .array(orderedLanes.map { .string($0.rawValue) })
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["primary_chat_id"] = .string(primaryChatID)
        object["secondary_chat_id"] = .string(secondaryChatID)
        object["oracle_history_diverged"] = .bool(historyDiverged)
        if let historyPersistenceError {
            object["oracle_group_history_persistence_error"] = .string(historyPersistenceError)
            object["oracle_pair_history_persistence_error"] = .string(historyPersistenceError)
        }
        // Surface Secondary-only / history failures at the top level so single-lane
        // MCP consumers do not treat partial_failure as a clean success.
        if status != .completed, let failureSummary, object["errors"] == nil {
            object["errors"] = .array([.string(failureSummary)])
        }
        let orderedValues = result.orderedResults.map { laneResult in
            laneValue(
                lane: laneResult.lane,
                execution: laneResult.execution,
                chatID: requiredChatID(for: laneResult.lane),
                model: requiredModel(for: laneResult.lane)
            )
        }
        object["oracle_results"] = .object(Dictionary(uniqueKeysWithValues: zip(
            orderedLanes.map(\.rawValue),
            orderedValues
        )))
        object["oracle_group_results"] = .array(orderedValues)
        return object
    }

    private func laneFailureSummary(
        _ lane: OracleLane,
        _ execution: OraclePairCoordinator.LaneExecution<ChatSendReply>
    ) -> String? {
        guard case let .failure(failure) = execution else { return nil }
        return "\(lane.displayLabel) failed: \(failure.message)"
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
        object["oracle_ordinal"] = .int(lane.ordinal)
        object["oracle_label"] = .string(lane.displayLabel)
        object["oracle_group_id"] = .string(groupID.uuidString)
        object["oracle_count"] = .int(oracleCount)
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["chat_id"] = .string(chatID)
        object["model_raw_id"] = .string(model.rawValue)
        object["model_display_name"] = .string(model.displayName)
        return .object(object)
    }

    private static func sessionID(
        for lane: OracleLane,
        in result: OraclePairCoordinator.Result<ChatSendReply>
    ) -> UUID? {
        guard let execution = result[lane] else { return nil }
        switch execution {
        case let .success(reply): reply.chatId
        case .failure: nil
        }
    }

    private func requiredChatID(for lane: OracleLane) -> String {
        guard let chatID = chatIDsByLane[lane] else {
            preconditionFailure("Validated Oracle group is missing \(lane.rawValue) chat identity")
        }
        return chatID
    }

    private func requiredModel(for lane: OracleLane) -> AIModel {
        guard let model = modelsByLane[lane] else {
            preconditionFailure("Validated Oracle group is missing \(lane.rawValue) model identity")
        }
        return model
    }
}

typealias OracleGroupSendReply = OraclePairSendReply

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
