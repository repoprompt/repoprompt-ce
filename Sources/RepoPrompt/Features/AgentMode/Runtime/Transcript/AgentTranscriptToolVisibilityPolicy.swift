import Foundation

enum AgentTranscriptToolVisibilityPolicy {
    private static let placeholderToolNames: Set<String> = ["tool", "other"]
    private static let pathLikeExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "dart", "go", "h", "hpp", "html", "java", "js", "json",
        "jsx", "kt", "m", "md", "mm", "php", "plist", "py", "rb", "rs", "sh", "swift", "toml",
        "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]

    static func shouldSuppressActivity(_ activity: AgentTranscriptActivity) -> Bool {
        shouldSuppressRow(activity.toItem(), execution: activity.toolExecution)
    }

    static func shouldSuppressRow(_ row: AgentChatItem) -> Bool {
        shouldSuppressRow(row, execution: AgentTranscriptToolNormalizer.toolExecution(for: row))
    }

    static func isPlaceholderToolName(_ raw: String?) -> Bool {
        guard let normalized = normalizedToolNameForComparison(raw), !normalized.isEmpty else { return false }
        return placeholderToolNames.contains(normalized)
    }

    static func isPathLikeToolName(_ raw: String?) -> Bool {
        pathSignal(fromPathLikeToolName: raw) != nil
    }

    static func pathSignal(fromPathLikeToolName raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if MCPIntegrationHelper.canonicalRepoPromptToolName(trimmed) != nil { return nil }
        let normalized = normalizedToolNameForComparison(trimmed) ?? ""
        if canonicalAlias(forNormalizedName: normalized) != nil { return nil }
        let candidate = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !candidate.hasPrefix("/"), !candidate.hasPrefix("~") else { return nil }
        guard !candidate.contains("://"), !candidate.contains(" ") else { return nil }
        if candidate.contains("/") {
            return candidate
        }
        let fileName = (candidate as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, pathLikeExtensions.contains(ext) else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        return candidate
    }

    static func normalizedVisibleToolName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if let canonical = MCPIntegrationHelper.canonicalRepoPromptToolName(trimmed) {
            return canonical
        }
        let normalized = normalizedToolNameForComparison(trimmed) ?? trimmed.lowercased()
        if let alias = canonicalAlias(forNormalizedName: normalized) {
            return alias
        }
        if isPathLikeToolName(trimmed) {
            return "read_file"
        }
        return normalized
    }

    private static func shouldSuppressRow(_ row: AgentChatItem, execution: AgentTranscriptToolExecution?) -> Bool {
        guard row.kind == .toolCall || row.kind == .toolResult else { return false }
        let rawToolName = execution?.toolName ?? row.toolName
        guard isPlaceholderToolName(rawToolName) else { return false }
        if AgentTranscriptIO.shouldHideToolFromTranscript(rawToolName) {
            return true
        }
        if isMeaningfulError(row: row, execution: execution) {
            return false
        }
        if hasMeaningfulPayload(row.toolArgsJSON, kind: .args) {
            return false
        }
        if hasMeaningfulPayload(execution?.argsJSON, kind: .args) {
            return false
        }
        if hasMeaningfulPayload(row.toolResultJSON, kind: .result) {
            return false
        }
        if hasMeaningfulPayload(execution?.resultJSON, kind: .result) {
            return false
        }
        if hasMeaningfulPayload(row.text, kind: .text) {
            return false
        }
        if hasMeaningfulPayload(execution?.summaryText, kind: .summary) {
            return false
        }
        if execution?.keyPaths.isEmpty == false {
            return false
        }
        return true
    }

    private enum PayloadKind {
        case args
        case result
        case text
        case summary
    }

    private static func normalizedToolNameForComparison(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func canonicalAlias(forNormalizedName normalized: String) -> String? {
        switch normalized {
        case "readfile", "read_file":
            "read_file"
        case "read_file_tool", "read_file_contents":
            "read_file"
        case "file_search", "filesearch", "grep":
            "file_search"
        case "search", "web_search", "web_search_request", "google_web_search", "search_web":
            "search"
        case "bash", "shell", "local_shell", "unified_exec", "exec", "exec_command", "run_shell_command", "command":
            "bash"
        case "filechange", "file_change":
            "apply_patch"
        default:
            nil
        }
    }

    private static func isMeaningfulError(row: AgentChatItem, execution: AgentTranscriptToolExecution?) -> Bool {
        if row.toolIsError == true || execution?.toolIsError == true { return true }
        switch execution?.status {
        case .failed, .cancelled, .warning:
            return true
        case .pending, .running, .success, .unknown, nil:
            break
        }
        for raw in [row.toolResultJSON, execution?.resultJSON, row.text] {
            guard let object = ToolRawJSON.object(from: raw) else { continue }
            if containsMeaningfulErrorField(object) { return true }
        }
        return false
    }

    private static func hasMeaningfulPayload(_ raw: String?, kind: PayloadKind) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return false }
        switch kind {
        case .summary:
            let lowered = trimmed.lowercased()
            return !(lowered == "tool" || lowered == "other" || lowered.hasPrefix("tool •") || lowered.hasPrefix("other •"))
        case .args, .result, .text:
            break
        }
        if trimmed == "{}" || trimmed == "[]" { return false }
        if let object = ToolRawJSON.object(from: trimmed) {
            return hasMeaningfulObjectPayload(object, kind: kind)
        }
        return kind == .args || trimmed.count > 32
    }

    private static func hasMeaningfulObjectPayload(_ object: [String: Any], kind: PayloadKind) -> Bool {
        if containsMeaningfulErrorField(object) { return true }
        let summaryOnly = ToolRawJSON.bool(object, key: "summary_only") ?? ToolRawJSON.bool(object, key: "summaryOnly") ?? false
        let allowedSummaryKeys: Set = [
            "exitcode", "original_char_count", "original_sha256", "processid", "redacted", "render_summary", "status",
            "summary_only", "summaryonly", "summary_text", "summarytext", "type"
        ]
        let normalizedKeys = Set(object.keys.map { $0.lowercased() })
        if summaryOnly, normalizedKeys.isSubset(of: allowedSummaryKeys) {
            return false
        }

        let meaningfulKeys = [
            "assistant_text", "assistantText", "command", "content", "displayPath", "filePath", "file_path",
            "message", "output", "path", "prompt", "response", "session_id", "sessionID", "stderr", "stdout"
        ]
        for key in meaningfulKeys {
            if let value = object[key], valueIsMeaningful(value) {
                return true
            }
        }
        if kind == .args {
            return !object.isEmpty && !summaryOnly
        }
        return !summaryOnly && object.keys.contains { key in
            !allowedSummaryKeys.contains(key.lowercased())
        }
    }

    private static func containsMeaningfulErrorField(_ object: [String: Any]) -> Bool {
        let errorKeys = ["error", "error_message", "errorMessage", "exception", "failure", "stderr"]
        for key in errorKeys {
            if let value = object[key], valueIsMeaningful(value) {
                return true
            }
        }
        return false
    }

    private static func valueIsMeaningful(_ value: Any) -> Bool {
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        if let object = value as? [String: Any] {
            return !object.isEmpty
        }
        return true
    }
}
