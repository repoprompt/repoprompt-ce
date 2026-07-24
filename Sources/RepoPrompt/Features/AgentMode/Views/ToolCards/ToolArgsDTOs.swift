import Foundation

enum ToolArgsDTOs {
    struct ReadFileArgs: Decodable {
        let path: String?
        let startLine: Int?
        let limit: Int?
    }

    struct NativeReadArgs: Decodable {
        let path: String?
        let filePath: String?
        let offset: Int?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case path
            case filePath = "file_path"
            case offset
            case limit
        }
    }

    struct FileSearchArgs: Decodable {
        struct Filter: Decodable {
            let paths: [String]?
        }

        let pattern: String?
        let mode: String?
        let maxResults: Int?
        let path: String?
        let filter: Filter?

        var scopePaths: [String] {
            if let paths = filter?.paths, !paths.isEmpty { return paths }
            if let path, !path.isEmpty { return [path] }
            return []
        }
    }

    struct ApplyEditsArgs: Decodable {
        let path: String?
        let search: String?
        let replace: String?
        let rewrite: String?
    }

    struct ApplyPatchArgs: Decodable {
        let path: String?
        let paths: [String]?
        let changeCount: Int?

        enum CodingKeys: String, CodingKey {
            case path
            case paths
            case changeCount = "change_count"
        }
    }

    struct FileTreeArgs: Decodable {
        let path: String?
        let type: String?
        let mode: String?
        let maxDepth: Int?
    }

    struct FileActionsArgs: Decodable {
        let action: String?
        let path: String?
        let newPath: String?

        enum CodingKeys: String, CodingKey {
            case action
            case path
            case newPath = "new_path"
        }
    }

    struct CodeStructureArgs: Decodable {
        let paths: [String]?
        let expand: String?
        let depth: Int?
        let signatures: Bool?
        let maxTokens: Int?
    }

    struct ManageSelectionArgs: Decodable {
        let op: String?
        let view: String?
        let mode: String?
    }

    struct WorkspaceContextArgs: Decodable {
        let include: [String]?
    }

    struct PromptArgs: Decodable {
        let op: String?
        let path: String?
        let text: String?
        let preset: String?
        let copyPreset: String?

        enum CodingKeys: String, CodingKey {
            case op
            case path
            case text
            case preset
            case copyPreset = "copy_preset"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            preset = Self.decodeSelector(from: container, key: .preset)
            copyPreset = Self.decodeSelector(from: container, key: .copyPreset)
        }

        private static func decodeSelector(
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> String? {
            if let value = try? container.decode(String.self, forKey: key),
               !value.isEmpty
            {
                return value
            }
            if let object = try? container.decode([String: String].self, forKey: key) {
                return object["name"] ?? object["kind"] ?? object["id"]
            }
            return nil
        }
    }

    struct AskOracleArgs: Decodable {
        let message: String?
        let mode: String?
        let chatID: String?
        let newChat: Bool?

        enum CodingKeys: String, CodingKey {
            case message
            case mode
            case chatID = "chat_id"
            case newChat = "new_chat"
        }
    }

    struct ChatsArgs: Decodable {
        let action: String?
        let chatID: String?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case action
            case chatID = "chat_id"
            case limit
        }
    }

    struct BindContextArgs: Decodable {
        let op: String?
        let windowID: Int?
        let contextID: String?

        enum CodingKeys: String, CodingKey {
            case op
            case windowID = "window_id"
            case contextID = "context_id"
        }
    }

    struct ManageWorkspacesArgs: Decodable {
        let action: String?
        let workspace: String?
        let name: String?
        let tab: String?
        let windowID: Int?

        enum CodingKeys: String, CodingKey {
            case action
            case workspace
            case name
            case tab
            case windowID = "window_id"
        }
    }

    struct GitArgs: Decodable {
        let op: String?
        let compare: String?
        let detail: String?
        let repoRoot: String?

        enum CodingKeys: String, CodingKey {
            case op
            case compare
            case detail
            case repoRoot = "repo_root"
        }
    }

    // MARK: - Agent Control DTOs

    struct AgentRunArgs: Decodable {
        let op: String?
        let message: String?
        let sessionID: String?
        let sessionName: String?
        let agent: String?
        let model: String?
        let workflowID: String?
        let workflowName: String?
        let reasoningEffort: String?
        let interactionID: String?
        let response: String?
        let decision: String?
        let reason: String?
        let amendment: String?
        let detach: Bool?
        let timeout: Double?
        let wait: Bool?
        let timeoutSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case op
            case message
            case sessionID = "session_id"
            case sessionName = "session_name"
            case agent
            case model
            case workflowID = "workflow_id"
            case workflowName = "workflow_name"
            case reasoningEffort = "reasoning_effort"
            case interactionID = "interaction_id"
            case response
            case decision
            case reason
            case amendment
            case detach
            case timeout
            case wait
            case timeoutSeconds = "timeout_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
            workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
            reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
            interactionID = try container.decodeIfPresent(String.self, forKey: .interactionID)
            response = try container.decodeIfPresent(String.self, forKey: .response)
            decision = try container.decodeIfPresent(String.self, forKey: .decision)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            amendment = try container.decodeIfPresent(String.self, forKey: .amendment)
            detach = try ToolArgsDTOs.decodeBool(from: container, forKey: .detach)
            timeout = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeout)
            wait = try ToolArgsDTOs.decodeBool(from: container, forKey: .wait)
            timeoutSeconds = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeoutSeconds)
        }
    }

    struct AgentExploreArgs: Decodable {
        let op: String?
        let message: String?
        let messages: [String]?
        let sessionID: String?
        let sessionIDs: [String]?
        let detach: Bool?
        let timeout: Double?

        enum CodingKeys: String, CodingKey {
            case op
            case message
            case messages
            case sessionID = "sessionId"
            case sessionIDs = "sessionIds"
            case detach
            case timeout
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            messages = try container.decodeIfPresent([String].self, forKey: .messages)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionIDs = try container.decodeIfPresent([String].self, forKey: .sessionIDs)
            detach = try ToolArgsDTOs.decodeBool(from: container, forKey: .detach)
            timeout = try ToolArgsDTOs.decodeDouble(from: container, forKey: .timeout)
        }
    }

    struct AgentManageArgs: Decodable {
        let op: String?
        let sessionID: String?
        let sessionName: String?
        let agent: String?
        let model: String?
        let limit: Int?
        let name: String?
        let state: String?
        let offset: Int?
        let rolesOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case op
            case sessionID = "session_id"
            case sessionName = "session_name"
            case agent
            case model
            case limit
            case name
            case state
            case offset
            case rolesOnly = "roles_only"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            op = try container.decodeIfPresent(String.self, forKey: .op)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
            agent = try container.decodeIfPresent(String.self, forKey: .agent)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            limit = try container.decodeIfPresent(Int.self, forKey: .limit)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            state = try container.decodeIfPresent(String.self, forKey: .state)
            offset = try container.decodeIfPresent(Int.self, forKey: .offset)
            rolesOnly = try ToolArgsDTOs.decodeBool(from: container, forKey: .rolesOnly)
        }
    }

    private static func decodeDouble<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Double? {
        if let value = try container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decodeBool<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Bool? {
        if let value = try container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
