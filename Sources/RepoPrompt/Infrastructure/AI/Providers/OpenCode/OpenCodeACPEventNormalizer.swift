import Foundation

enum OpenCodeACPEventNormalizer {
    private enum ToolEventPhase {
        case call
        case update
    }

    static func normalize(
        _ payload: [String: Any],
        toolProfile: OpenCodeAgentConfig.ToolProfile
    ) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .openCode)
        }

        switch sessionUpdate {
        case "session_info_update":
            guard !shouldSuppressStatusPayload(payload) else { return [] }
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .openCode)
        case "tool_call":
            return normalizeToolEvent(payload, toolProfile: toolProfile, phase: .call)
        case "tool_call_update":
            return normalizeToolEvent(payload, toolProfile: toolProfile, phase: .update)
        default:
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .openCode)
        }
    }

    private static func normalizeToolEvent(
        _ payload: [String: Any],
        toolProfile: OpenCodeAgentConfig.ToolProfile,
        phase: ToolEventPhase
    ) -> [NormalizedAgentRuntimeEvent] {
        let isRepoPromptTool = isRepoPromptToolPayload(payload)
        let status = ACPRuntimeEventParsing.firstString(in: payload, keys: ["status"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasTerminalFailureStatus = isTerminalFailureStatus(status)
        let isTerminal = status == "completed" || hasTerminalFailureStatus
        let isFailure = hasTerminalFailureStatus || rawOutputIndicatesFailure(payload["rawOutput"])
        let canonicalToolName = isRepoPromptTool ? nil : canonicalOpenCodeToolName(from: payload)

        guard !shouldSuppressLowLevelOpenCodeToolPayload(
            payload,
            canonicalToolName: canonicalToolName,
            toolProfile: toolProfile,
            phase: phase,
            isRepoPromptTool: isRepoPromptTool,
            isTerminal: isTerminal,
            isFailure: isFailure
        ) else {
            return []
        }

        return ACPDefaultSessionUpdateNormalizer.normalize(
            adaptedPayload(payload, canonicalToolName: canonicalToolName, isRepoPromptTool: isRepoPromptTool),
            providerID: .openCode
        )
    }

    private static func isRepoPromptToolPayload(_ payload: [String: Any]) -> Bool {
        if ACPRuntimeEventParsing.repoPromptToolName(from: payload) != nil {
            return true
        }
        for key in ["toolName", "name", "tool", "title", "kind", "toolKind"] {
            guard let value = payload[key] as? String else { continue }
            if ACPRuntimeEventParsing.explicitRepoPromptToolName(from: value) != nil {
                return true
            }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("repoprompt"), normalized.contains("tool") || normalized.contains("mcp") || normalized.contains("server") {
                return true
            }
        }
        return false
    }

    private static func canonicalOpenCodeToolName(from payload: [String: Any]) -> String? {
        let identifiers = ["kind", "toolKind", "toolName", "name", "tool", "title"]
            .compactMap { ACPRuntimeEventParsing.firstString(in: payload, keys: [$0]) }
            .map { normalizedToken($0) }
        let rawInput = dictionaryPayload(from: payload["rawInput"])
        let rawInputText = serializedLowercase(payload["rawInput"])

        if identifiers.contains(where: { matchesAny($0, ["execute", "bash", "shell", "terminal", "command", "run"]) })
            || hasAnyKey(rawInput, ["command", "cmd", "script", "shell"])
        {
            return "bash"
        }
        if identifiers.contains(where: { matchesAny($0, ["edit", "write", "patch", "update", "modify"]) })
            || hasAnyKey(rawInput, ["oldString", "newString", "replacement", "replace", "content", "diff", "patch"])
        {
            return "edit"
        }
        if identifiers.contains(where: { matchesAny($0, ["search", "grep", "glob", "codesearch", "find"]) })
            || hasAnyKey(rawInput, ["pattern", "query", "glob", "regex", "needle"])
        {
            return "search"
        }
        if identifiers.contains(where: { matchesAny($0, ["webfetch", "web-fetch", "fetch", "http"]) })
            || hasAnyKey(rawInput, ["url", "uri"])
        {
            return "webfetch"
        }
        if identifiers.contains(where: { matchesAny($0, ["websearch", "web-search"]) }) {
            return "websearch"
        }
        if identifiers.contains(where: { matchesAny($0, ["todo", "todowrite", "todo-write"]) }) {
            return "todowrite"
        }
        if identifiers.contains(where: { matchesAny($0, ["read", "view", "open", "cat"]) })
            || (hasAnyKey(rawInput, ["path", "filePath", "filepath"]) && !rawInputText.contains("oldstring") && !rawInputText.contains("newstring"))
        {
            return "read"
        }
        return nil
    }

    private static func shouldSuppressLowLevelOpenCodeToolPayload(
        _ payload: [String: Any],
        canonicalToolName: String?,
        toolProfile: OpenCodeAgentConfig.ToolProfile,
        phase: ToolEventPhase,
        isRepoPromptTool: Bool,
        isTerminal: Bool,
        isFailure: Bool
    ) -> Bool {
        if isRepoPromptTool {
            return false
        }

        switch toolProfile {
        case .headless, .noTools:
            if isTerminal, isFailure {
                return !hasMeaningfulFailurePayload(payload)
            }
            return true
        case .agentMode:
            if isTerminal, isFailure, hasMeaningfulFailurePayload(payload) {
                return false
            }
            if canonicalToolName != nil {
                if phase == .update, !isTerminal, !hasMeaningfulPayload(payload) {
                    return true
                }
                return false
            }
            if isPathLikeOrCodeLikeTitle(ACPRuntimeEventParsing.firstString(in: payload, keys: ["title", "toolName", "name", "tool", "kind", "toolKind"])) {
                return true
            }
            return !hasMeaningfulPayload(payload)
        }
    }

    private static func shouldSuppressStatusPayload(_ payload: [String: Any]) -> Bool {
        guard let title = ACPRuntimeEventParsing.firstString(in: payload, keys: ["title"]) else {
            return true
        }
        return isPathLikeOrCodeLikeTitle(title)
    }

    private static func adaptedPayload(
        _ payload: [String: Any],
        canonicalToolName: String?,
        isRepoPromptTool: Bool
    ) -> [String: Any] {
        var adapted = payload
        if let status = ACPRuntimeEventParsing.firstString(in: payload, keys: ["status"])?.lowercased(),
           ["error", "cancelled", "canceled"].contains(status)
        {
            adapted["status"] = "failed"
        }
        if !isRepoPromptTool, let canonicalToolName {
            adapted["title"] = canonicalToolName
            adapted["toolName"] = canonicalToolName
        }
        return adapted
    }

    private static func isPathLikeOrCodeLikeTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return true
        }
        let normalized = title.lowercased()
        if ["tool", "other", "resource", "resources"].contains(normalized) {
            return true
        }
        if title.count > 120 {
            return true
        }
        if normalized.hasPrefix("{")
            || normalized.hasPrefix("[")
            || normalized.hasPrefix("@@")
            || normalized.hasPrefix("diff --")
            || normalized.hasPrefix("+")
            || normalized.hasPrefix("-")
        {
            return true
        }
        if title.contains("{")
            || title.contains("}")
            || title.contains(";")
            || title.contains("=>")
            || normalized.contains("function ")
            || normalized.contains("class ")
            || normalized.contains("import ")
            || normalized.contains("const ")
            || normalized.contains("let ")
            || normalized.contains("var ")
        {
            return true
        }

        let sourceExtensions: Set = [
            "swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "kts",
            "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "cs", "php", "dart", "scala",
            "sh", "zsh", "bash", "fish", "json", "jsonl", "yaml", "yml", "toml", "xml", "html",
            "css", "scss", "md", "mdx", "txt", "sql", "graphql", "proto"
        ]
        return titleContainsPathOrFilename(title, sourceExtensions: sourceExtensions)
    }

    private static func hasMeaningfulPayload(_ payload: [String: Any]) -> Bool {
        for key in ["rawInput", "rawOutput", "content", "locations", "error", "stderr", "stdout", "output", "command", "path", "filePath", "pattern", "query"] {
            if let value = payload[key], valueIsMeaningful(value) {
                return true
            }
        }
        return false
    }

    private static func hasMeaningfulFailurePayload(_ payload: [String: Any]) -> Bool {
        if rawOutputIndicatesFailure(payload["rawOutput"]) || rawOutputIndicatesFailure(payload["content"]) {
            return true
        }
        for key in ["rawOutput", "content", "error", "stderr", "stdout", "output"] {
            if let value = payload[key], valueIsMeaningful(value) {
                return true
            }
        }
        return false
    }

    private static func isTerminalFailureStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["failed", "error", "cancelled", "canceled"].contains(status)
    }

    private static func rawOutputIndicatesFailure(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        if let success = object["success"] as? Bool, success == false {
            return true
        }
        if let status = ACPRuntimeEventParsing.firstString(in: object, keys: ["status", "result", "outcome", "state"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ["failed", "failure", "error", "cancelled", "canceled"].contains(status)
        {
            return true
        }
        for key in ["exitCode", "exit_code", "code"] {
            if let code = intValue(object[key]), code != 0 {
                return true
            }
        }
        for key in ["error", "errorMessage", "error_message", "stderr"] {
            if let message = object[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        return false
    }

    private static func titleContainsPathOrFilename(_ title: String, sourceExtensions: Set<String>) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>\"'`,`"))
        let candidates = title
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":;,.")) }
            .filter { !$0.isEmpty }
            + [title]

        for candidate in candidates {
            let normalized = candidate.lowercased()
            if normalized.contains("/") || normalized.contains("\\") {
                return true
            }
            let basename = URL(fileURLWithPath: normalized).lastPathComponent
            guard basename.contains("."), let ext = basename.split(separator: ".").last.map(String.init) else {
                continue
            }
            if sourceExtensions.contains(ext) {
                return true
            }
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func valueIsMeaningful(_ value: Any) -> Bool {
        if value is NSNull {
            return false
        }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return array.contains { valueIsMeaningful($0) }
        }
        if let object = value as? [String: Any] {
            return object.contains { _, nested in valueIsMeaningful(nested) }
        }
        return true
    }

    private static func dictionaryPayload(from value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] {
            return object
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private static func hasAnyKey(_ object: [String: Any], _ keys: Set<String>) -> Bool {
        let normalizedKeys = Set(keys.map { $0.lowercased() })
        return object.contains { key, _ in normalizedKeys.contains(key.lowercased()) }
    }

    private static func serializedLowercase(_ value: Any?) -> String {
        (ACPRuntimeEventParsing.serializeJSON(value) ?? "").lowercased()
    }

    private static func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchesAny(_ value: String, _ candidates: Set<String>) -> Bool {
        candidates.contains(value) || candidates.contains(value.replacingOccurrences(of: "_", with: "-"))
    }
}
