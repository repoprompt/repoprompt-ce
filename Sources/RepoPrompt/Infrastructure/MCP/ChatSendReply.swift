import Foundation
import MCP // for Value

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
        if let r = response {
            obj["response"] = .string(r)
        }
        if let e = errors {
            obj["errors"] = .array(e.map { .string($0) })
        }

        return .object(obj)
    }
}
