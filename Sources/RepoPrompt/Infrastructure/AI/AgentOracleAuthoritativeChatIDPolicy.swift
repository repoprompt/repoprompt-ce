import Foundation

enum AgentOracleAuthoritativeChatIDPolicy {
    static func extract(fromSerializedJSON json: String?) -> String? {
        guard let json else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        return extract(fromRootObject: object)
    }

    static func extract(fromRootObject object: [String: Any]) -> String? {
        guard !object.keys.contains("chatID"),
              !containsChatID(in: object, excludingAuthoritativeRoot: true),
              let chatID = object["chat_id"] as? String
        else { return nil }
        let trimmed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func allowsLatestFallback(fromSerializedJSON json: String?) -> Bool {
        guard let json else { return false }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return false }
        return !containsChatID(in: object)
    }

    private static func containsChatID(in value: Any, excludingAuthoritativeRoot: Bool = false) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if key == "chat_id" || key == "chatID" {
                    if excludingAuthoritativeRoot, key == "chat_id" {
                        continue
                    }
                    return true
                }
                if containsChatID(in: nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsChatID(in: $0) }
        }
        return false
    }
}
