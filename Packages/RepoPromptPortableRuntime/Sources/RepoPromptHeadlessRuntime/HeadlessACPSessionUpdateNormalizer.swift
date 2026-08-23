import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Linux projection of Desktop `CursorACPEventNormalizer` + `ACPDefaultSessionUpdateNormalizer`.
/// Cursor extension methods (`cursor/ask_question`, plans, todos) stay rejected, matching Desktop.
public enum HeadlessACPSessionUpdateNormalizer {
    public static func normalize(_ data: Data) throws -> [ProviderRuntimeEvent] {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let method = frame["method"] as? String ?? ""
        let params = frame["params"] as? [String: Any] ?? [:]
        if frame["id"] != nil, method == "session/request_permission" {
            let id = String(describing: frame["id"]!)
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            let choices = (params["options"] as? [[String: Any]] ?? []).compactMap { $0["optionId"] as? String }
            let prompt = firstString(in: tool, keys: ["title"]) ?? "Tool approval"
            return [.interactionRequested(providerRequestID: id, kind: .approval, prompt: prompt, choices: choices)]
        }
        guard method == "session/update", let update = params["update"] as? [String: Any] else { return [] }
        return normalizeSessionUpdate(update)
    }

    public static func normalizeSessionUpdate(_ update: [String: Any]) -> [ProviderRuntimeEvent] {
        let type = (update["sessionUpdate"] as? String ?? "").lowercased()
        switch type {
        case "agent_message_chunk":
            let text = extractContentText(from: update["content"]) ?? ""
            return text.isEmpty ? [] : [.assistantDelta(text)]
        case "agent_thought_chunk":
            let text = extractContentText(from: update["content"]) ?? ""
            return text.isEmpty ? [] : [.reasoning(text)]
        case "session_info_update":
            guard let title = firstString(in: update, keys: ["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { return [] }
            return [.runStatusChanged(phase: .thinking, statusCode: HeadlessRunStatusCopy.thinkingCode, statusText: title)]
        case "tool_call", "tool_call_update":
            return normalizeToolEvent(update, sessionUpdate: type)
        case "usage_update":
            return normalizeUsageUpdate(update)
        case "plan", "available_commands_update", "user_message_chunk", "config_option_update":
            return []
        default:
            return []
        }
    }

    /// Desktop `ACPAgentSessionController.messageStopResult`: Grok Build carries
    /// usage under `_meta.usage` with the same field names; top-level `usage`
    /// remains the preferred ACP-standard location.
    public static func contextUsageFromPromptResult(_ result: [String: Any]) -> ContextUsageWireSnapshot? {
        let usage = (result["usage"] as? [String: Any])
            ?? ((result["_meta"] as? [String: Any])?["usage"] as? [String: Any])
        let inputTokens = intValue(usage?["inputTokens"])
        let cachedReadTokens = intValue(usage?["cachedReadTokens"])
        let cachedWriteTokens = intValue(usage?["cachedWriteTokens"])
        let hasContextBreakdown = inputTokens != nil || cachedReadTokens != nil || cachedWriteTokens != nil
        guard hasContextBreakdown else { return nil }
        let used = max(0, inputTokens ?? 0) + max(0, cachedReadTokens ?? 0) + max(0, cachedWriteTokens ?? 0)
        return ContextUsageWireSnapshot(lastTotalTokens: used, totalTotalTokens: used)
    }

    private static func normalizeToolEvent(_ update: [String: Any], sessionUpdate: String) -> [ProviderRuntimeEvent] {
        guard !shouldSuppressPlaceholderToolEvent(update) else { return [] }
        let adapted = adaptedToolUpdatePayload(update, sessionUpdate: sessionUpdate)
        let id = firstString(in: adapted, keys: ["toolCallId"]) ?? UUID().uuidString
        let name = normalizedToolName(from: adapted)
        let arguments = encodedJSON(adapted["rawInput"])
        let status = firstString(in: adapted, keys: ["status"])?.lowercased() ?? ""
        if sessionUpdate == "tool_call" {
            return [.toolStarted(providerToolID: id, name: name, arguments: arguments)]
        }
        if ["completed", "failed"].contains(status) {
            let output = serializeJSON(adapted["rawOutput"])
                ?? serializeJSON(adapted["content"])
                ?? extractContentText(from: adapted["content"])
            return [.toolCompleted(providerToolID: id, name: name, output: output, status: status == "failed" ? .failed : .success)]
        }
        if ["in_progress", "inprogress", "in-progress", "running", "pending"].contains(status) {
            let output = extractContentText(from: adapted["content"]) ?? status
            return [.toolUpdated(providerToolID: id, output: output)]
        }
        if let output = extractContentText(from: adapted["content"]) ?? serializeJSON(adapted["rawOutput"]) {
            return [.toolUpdated(providerToolID: id, output: output)]
        }
        return []
    }

    private static func shouldSuppressPlaceholderToolEvent(_ payload: [String: Any]) -> Bool {
        let normalized = normalizedToolName(from: payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "other" || normalized == "tool" else { return false }
        return !hasMeaningfulPlaceholderPayload(payload)
    }

    private static func hasMeaningfulPlaceholderPayload(_ payload: [String: Any]) -> Bool {
        valueIsMeaningful(payload["rawInput"]) || valueIsMeaningful(payload["rawOutput"]) || valueIsMeaningful(payload["content"])
    }

    private static func adaptedToolUpdatePayload(_ payload: [String: Any], sessionUpdate: String) -> [String: Any] {
        guard sessionUpdate == "tool_call_update",
              let status = firstString(in: payload, keys: ["status"])?.lowercased(),
              status == "completed" || status == "failed"
        else { return payload }
        var adapted = payload
        var result: [String: Any] = [
            "status": rawOutputIndicatesFailure(payload["rawOutput"]) || status == "failed" ? "failed" : "success",
            "acp_status": status
        ]
        if let title = firstString(in: payload, keys: ["title"]), !title.isEmpty { result["title"] = title }
        if let kind = firstString(in: payload, keys: ["kind", "toolKind"]), !kind.isEmpty { result["kind"] = kind }
        if let rawOutput = payload["rawOutput"] { result["rawOutput"] = rawOutput }
        if let content = payload["content"] { result["content"] = content }
        if let rawInput = payload["rawInput"], valueIsMeaningful(rawInput) { result["rawInput"] = rawInput }
        adapted["rawOutput"] = result
        if (result["status"] as? String) == "failed" { adapted["status"] = "failed" }
        return adapted
    }

    public static func normalizedToolName(from payload: [String: Any]) -> String {
        if let parenthesized = repoPromptToolName(fromTitle: firstString(in: payload, keys: ["title"])) {
            return parenthesized
        }
        if let identifier = firstMachineIdentifier(in: payload, keys: ["toolName", "name", "tool"]) {
            return canonicalToolName(identifier)
        }
        if let kind = firstMachineIdentifier(in: payload, keys: ["toolKind", "kind"]) {
            return canonicalToolName(kind)
        }
        if let title = firstString(in: payload, keys: ["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return canonicalToolName(title)
        }
        return "tool"
    }

    private static func repoPromptToolName(fromTitle rawTitle: String?) -> String? {
        guard let rawTitle, let open = rawTitle.lastIndex(of: "("), let close = rawTitle.lastIndex(of: ")"),
              open < close
        else { return nil }
        let server = rawTitle[rawTitle.index(after: open) ..< close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard server.contains("repoprompt") else { return nil }
        let tool = rawTitle[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        return canonicalToolName(tool)
    }

    private static func canonicalToolName(_ raw: String) -> String {
        let suffix = raw.split(separator: ".").last.map(String.init) ?? raw
        let lowered = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["local_shell", "shell", "unified_exec", "exec_command", "run_shell_command", "bash"].contains(lowered) {
            return "bash"
        }
        if ["search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch"].contains(lowered) {
            return "search"
        }
        if ["filechange", "file_change", "apply_patch", "apply_edits"].contains(lowered) {
            return "apply_patch"
        }
        if ["read_file", "read"].contains(lowered) {
            return "read_file"
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstMachineIdentifier(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  trimmed.range(of: #"^[A-Za-z0-9_.:\-/]+$"#, options: .regularExpression) != nil
            else { continue }
            return trimmed
        }
        return nil
    }

    private static func extractContentText(from value: Any?) -> String? {
        guard let value else { return nil }
        if let dict = value as? [String: Any] {
            if (dict["type"] as? String)?.lowercased() == "text", let text = dict["text"] as? String, !text.isEmpty {
                return text
            }
            return extractContentText(from: dict["content"]) ?? extractContentText(from: dict["text"]) ?? extractContentText(from: dict["output"])
        }
        if let array = value as? [Any] {
            let joined = array.compactMap { extractContentText(from: $0) }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    private static func serializeJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        return encodedJSON(value).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func encodedJSON(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    private static func valueIsMeaningful(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let string = value as? String { return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return array.contains { valueIsMeaningful($0) } }
        if let object = value as? [String: Any] { return object.contains { _, nested in valueIsMeaningful(nested) } }
        return true
    }

    private static func rawOutputIndicatesFailure(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        if let success = object["success"] as? Bool, success == false { return true }
        if let status = firstString(in: object, keys: ["status", "result", "outcome", "state"])?.lowercased(),
           ["failed", "failure", "error", "cancelled", "canceled"].contains(status)
        {
            return true
        }
        return false
    }

    private static func normalizeUsageUpdate(_ payload: [String: Any]) -> [ProviderRuntimeEvent] {
        let used = intValue(payload["used"])
        let size = intValue(payload["size"])
        guard used != nil || size != nil else { return [] }
        return [
            .contextUsage(
                ContextUsageWireSnapshot(
                    modelContextWindow: size,
                    lastTotalTokens: used,
                    totalTotalTokens: used
                )
            )
        ]
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let int64 as Int64:
            Int(int64)
        case let double as Double:
            Int(double)
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }
}
