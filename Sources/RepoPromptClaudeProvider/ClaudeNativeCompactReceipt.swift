import CoreFoundation
import Foundation
import RepoPromptDomainRuntime

/// Native command evidence. The legacy stream permits FIFO only while this is the sole
/// outstanding input; keyed mode additionally requires an exact answering input identity.
package struct ClaudeNativeCompactReceipt {
    let conversationID: String
    let turnID: UUID
    private var sawBoundary = false
    private var postTokens: Int?

    package init(conversationID: String, turnID: UUID) {
        self.conversationID = conversationID
        self.turnID = turnID
    }

    package mutating func observeBoundary(_ payload: [String: Any]) {
        guard payload["type"] as? String == "system", payload["subtype"] as? String == "compact_boundary" else { return }
        defer { sawBoundary = true }
        postTokens = nil
        guard !sawBoundary, payload["session_id"] as? String == conversationID,
              let metadata = payload["compact_metadata"] as? [String: Any],
              metadata["trigger"] as? String == "manual",
              let before = Self.positiveInteger(metadata["pre_tokens"]),
              let after = Self.positiveInteger(metadata["post_tokens"]), after < before
        else { return }
        do {
            if let ids = try ClaudeNativeTurnCorrelation.inputIDs(payload) {
                guard ids == [turnID] else { return }
            }
        } catch { return }
        postTokens = after
    }

    /// CLI 2.1.330 labels local compact results but does not stamp their input UUID.
    /// Callers must still own the sole command interval; ordinary results never use this path.
    package func unkeyedCommandAnswer(_ payload: [String: Any], currentConversation: String?) -> UUID? {
        guard currentConversation == conversationID, payload["session_id"] as? String == conversationID,
              payload["local_command"] as? String == "compact", payload["queued_turn_count"] as? Int == 0
        else { return nil }
        return turnID
    }

    package func finish(
        _ payload: [String: Any], answeredIDs: [UUID]?, isKeyed: Bool, currentConversation: String?
    ) -> ClaudeCompactEvidence? {
        guard currentConversation == conversationID, payload["session_id"] as? String == conversationID,
              payload["subtype"] as? String == "success", payload["is_error"] as? Bool == false,
              isKeyed ? answeredIDs == [turnID] : unkeyedCommandAnswer(payload, currentConversation: currentConversation) != nil,
              let postTokens else { return nil }
        do {
            if let ids = try ClaudeNativeTurnCorrelation.inputIDs(payload), ids != [turnID] { return nil }
        } catch { return nil }
        return .init(conversationID: conversationID, turnID: turnID, postTokens: postTokens)
    }

    private static func positiveInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = raw as? Int, value > 0 else { return nil }
        return value
    }
}
