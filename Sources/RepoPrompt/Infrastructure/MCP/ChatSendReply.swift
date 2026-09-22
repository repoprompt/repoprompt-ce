import Foundation
import MCP // for Value

struct ChatSendReply: Codable {
    let chatId: UUID
    let shortId: String
    let mode: String
    let response: String?
    let errors: [String]?
    let oracleGroup: ContextBuilderOracleGroupReply?

    init(
        chatId: UUID,
        shortId: String,
        mode: String,
        response: String?,
        errors: [String]?,
        oracleGroup: ContextBuilderOracleGroupReply? = nil
    ) {
        self.chatId = chatId
        self.shortId = shortId
        self.mode = mode
        self.response = response
        self.errors = errors
        self.oracleGroup = oracleGroup
    }

    func toMCPValue() -> Value {
        var obj: [String: Value] = [
            "chat_id": .string(shortId), // Only expose short ID
            "mode": .string(mode)
        ]
        if let r = response { obj["response"] = .string(r) }
        if let e = errors { obj["errors"] = .array(e.map { .string($0) }) }
        if let oracleGroup {
            obj.merge(oracleGroup.toMCPFields()) { _, groupValue in groupValue }
        }

        return .object(obj)
    }
}
