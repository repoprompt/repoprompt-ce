import Foundation
import RepoPromptDomainRuntime

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
              let chatID = object["chat_id"] as? String
        else { return nil }
        let trimmed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !containsChatID(in: object, excludingAuthoritativeRoot: true) { return trimmed }
        return hasCanonicalGroupIdentity(object, primaryChatID: trimmed) ? trimmed : nil
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

    /// Live groups and persisted lane digests share identity, but digests omit response bodies.
    /// Allow only their lane-root chat IDs; unrelated nested IDs remain ambiguous and fail closed.
    private static func hasCanonicalGroupIdentity(_ object: [String: Any], primaryChatID: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let group = try? JSONDecoder().decode(GroupIdentity.self, from: data),
              (2 ... OracleRosterContract.maximumCount).contains(group.count),
              group.count == group.lanes.count,
              let rawLanes = object["oracle_results"] as? [[String: Any]]
        else { return false }
        var withoutLanes = object
        withoutLanes.removeValue(forKey: "oracle_results")
        guard !containsChatID(in: withoutLanes, excludingAuthoritativeRoot: true) else { return false }
        var seenChatIDs = Set<String>()
        for (index, lane) in group.lanes.enumerated() {
            let chatID = lane.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lane.index == index,
                  lane.role == (index == 0 ? .primary : .additional),
                  !chatID.isEmpty, seenChatIDs.insert(chatID).inserted,
                  index != 0 || chatID == primaryChatID,
                  (try? OracleRosterContract.normalizedModelID(lane.modelID)) != nil,
                  !rawLanes[index].keys.contains("chatID"),
                  !containsChatID(in: rawLanes[index], excludingAuthoritativeRoot: true)
            else { return false }
        }
        return true
    }

    private struct GroupIdentity: Decodable {
        let groupID: UUID
        let count: Int
        let lanes: [LaneIdentity]

        enum CodingKeys: String, CodingKey {
            case groupID = "oracle_group_id"
            case count = "oracle_count"
            case lanes = "oracle_results"
        }
    }

    private struct LaneIdentity: Decodable {
        let index: Int
        let role: OracleLaneRole
        let chatID: String
        let modelID: String
        let status: OracleLaneResultStatus

        enum CodingKeys: String, CodingKey {
            case index = "lane_index"
            case role
            case chatID = "chat_id"
            case modelID = "model_id"
            case status
        }
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
                if containsChatID(in: nested) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsChatID(in: $0) }
        }
        return false
    }
}
