import Foundation

/// OpenCode's ACP error names and retry metadata come from the session runner.
/// Earlier versions log the processor's post-retry failure before replying to
/// session/prompt. Keep raw provider messages and response bodies out of the error.
enum OpenCodeACPPromptLimit: LocalizedError {
    case rateLimitOrQuota

    var errorDescription: String? {
        "OpenCode reached a provider rate limit or quota. Retry later, check the provider quota, or select a different model."
    }

    static func matchesResponseError(_ error: [String: Any]) -> Bool {
        guard let data = error["data"] as? [String: Any], data["service"] as? String == "session" else { return false }
        let name = data["errorName"] as? String
        return matchesErrorType(name) || (name == "APIError" && matchesLimitMessage(error["message"] as? String))
    }

    static func matchesRetryError(_ error: [String: Any]) -> Bool {
        matchesErrorType(error["type"] as? String) || error["status"] as? Int == 429
    }

    static func retryDelay(_ retry: [String: Any]) -> Duration? {
        guard let date = parseTimestamp(retry["nextRetryAt"] as? String) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }

    static func processorHaltDate(_ line: String, sessionID: String) -> Date? {
        // "stream error" is logged before retry policy runs. Only the processor's
        // halt log uses message=process at ERROR for this session.
        guard line.hasPrefix("timestamp=") else { return nil }
        var fields: [String: String] = [:]
        for match in line.matches(of: /(?:^| )([\w.]+)=("(?:\\.|[^"\\])*"|[^\s"]+)/) {
            let key = String(match.1)
            guard ["timestamp", "level", "message", "session.id", "error"].contains(key), fields[key] == nil else { continue }
            let value = String(match.2)
            fields[key] = value.hasPrefix("\"") ? (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) : value
        }
        guard fields["level"] == "ERROR",
              fields["message"] == "process",
              fields["session.id"] == sessionID,
              matchesLimitMessage(fields["error"])
        else { return nil }
        return parseTimestamp(fields["timestamp"])
    }

    private static func parseTimestamp(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
    }

    private static func matchesErrorType(_ name: String?) -> Bool {
        switch name {
        case "provider.rate-limit", "provider.quota", "provider.free-limit", "provider.go-limit",
             "provider.budget-limit", "provider.model-budget-limit", "provider.chatgpt-limit", "provider.chatgpt-workspace-limit":
            true
        default:
            false
        }
    }

    private static func matchesLimitMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.lowercased().contains(/\b(?:http(?: status)? 429|status(?: code)?[:= ]+429|too many requests|rate[ _-]limit(?:ed| exceeded)?|insufficient[ _-]quota|quota[ _-](?:exceeded|exhausted))\b/)
    }
}
