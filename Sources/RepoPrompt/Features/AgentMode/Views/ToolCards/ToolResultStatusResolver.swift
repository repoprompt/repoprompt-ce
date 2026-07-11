import Foundation

enum ToolResultStatusResolver {
    static func resolve(toolIsError: Bool?, raw: String?, fallback: ToolCardStatus) -> ToolCardStatus {
        guard let object = ToolRawJSON.object(from: raw) else {
            if toolIsError == true {
                return .failure
            }
            if toolIsError == false {
                return .success
            }
            return fallback
        }

        if let commandOverride = commandExecutionOverride(object) {
            return commandOverride
        }
        if toolIsError == true {
            return .failure
        }
        if let inferred = inferStructuredStatus(from: object) {
            return inferred
        }
        if toolIsError == false {
            return .success
        }
        return fallback
    }

    private static func inferStructuredStatus(from value: Any?) -> ToolCardStatus? {
        switch value {
        case let object as [String: Any]:
            return inferStructuredStatus(fromObject: object)
        case let array as [Any]:
            var sawSuccess = false
            var sawWarning = false
            for element in array {
                guard let status = inferStructuredStatus(from: element) else { continue }
                switch status {
                case .failure:
                    return .failure
                case .warning:
                    sawWarning = true
                case .success:
                    sawSuccess = true
                default:
                    break
                }
            }
            if sawWarning {
                return .warning
            }
            if sawSuccess {
                return .success
            }
            return nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
                || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
                let data = trimmed.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data)
            {
                return inferStructuredStatus(from: json)
            }
            return nil
        default:
            return nil
        }
    }

    private static func inferStructuredStatus(fromObject object: [String: Any]) -> ToolCardStatus? {
        if let isError = ToolRawJSON.bool(object, key: "is_error")
            ?? ToolRawJSON.bool(object, key: "isError")
        {
            return isError ? .failure : .success
        }

        if ToolRawJSON.bool(object, key: "summary_only") == true {
            if let topLevelStatus = mapStatusWord(ToolRawJSON.string(object, key: "status")), topLevelStatus == .failure {
                return .failure
            }
            if let renderSummary = AgentToolCardRenderSummary(summaryOnlyObject: object) {
                return ToolCardStatus.fromRenderStatus(renderSummary.status)
            }
        }

        for key in ["status", "result", "outcome", "state", "subtype"] {
            if let mapped = mapStatusWord(ToolRawJSON.string(object, key: key)) {
                return mapped
            }
        }

        if let exitCode = ToolRawJSON.int(object, key: "exitCode")
            ?? ToolRawJSON.int(object, key: "exit_code")
            ?? ToolRawJSON.int(object, key: "code")
        {
            if exitCode == 0 {
                return .success
            }
            if exitCode > 0 {
                return .failure
            }
        }

        if let errors = object["errors"] as? [Any], !errors.isEmpty {
            return .failure
        }
        if let error = ToolRawJSON.string(object, key: "error"), !error.isEmpty {
            return .failure
        }
        if let warning = ToolRawJSON.string(object, key: "warning"), !warning.isEmpty {
            return .warning
        }
        if ToolRawJSON.bool(object, key: "limit_hit") == true || ToolRawJSON.bool(object, key: "size_limit_hit") == true {
            return .warning
        }
        if ToolRawJSON.bool(object, key: "success") == true || ToolRawJSON.bool(object, key: "ok") == true {
            return .success
        }

        for key in [
            "tool_result", "toolResult", "result", "output", "response",
            "content", "payload", "data", "value", "tool_use_result", "toolUseResult"
        ] {
            if let inferred = inferStructuredStatus(from: object[key]) {
                return inferred
            }
        }

        if let content = object["content"] as? [Any], !content.isEmpty {
            return .success
        }
        return nil
    }

    private static func commandExecutionOverride(_ object: [String: Any]) -> ToolCardStatus? {
        let type = ToolRawJSON.string(object, key: "type")?.lowercased() ?? ""
        guard type.contains("command") else { return nil }
        guard let exitCode = ToolRawJSON.int(object, key: "exitCode")
            ?? ToolRawJSON.int(object, key: "exit_code")
            ?? ToolRawJSON.int(object, key: "code")
        else {
            return nil
        }
        if exitCode == 0 {
            return .success
        }
        // Completion-shaped payloads (with duration/timing hints) are definitively
        // terminal — show failure for negative exit codes instead of neutral.
        if exitCode < 0 {
            if BashToolResultParser.hasCommandCompletionTimingHint(object) {
                return .failure
            }
            return .neutral
        }
        return nil
    }

    static func mapStatusWord(_ value: String?) -> ToolCardStatus? {
        let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(value)
        let transcriptStatus = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: normalized)
        return ToolCardStatus.fromTranscriptStatus(transcriptStatus)
    }
}
