import Foundation

/// Closed wire evidence. Never carries arbitrary provider text into terminal diagnostics.
public struct ClaudeSDKSizeFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case inputContextRejected
        case generationContextLimit
        case outputLimit
        case requestTooLarge
        case unknownSizeLimit
    }

    public enum Source: String, Sendable {
        case localCLIRejection
        case apiError
        case resultStopReason
    }

    public let kind: Kind
    public let source: Source
    public let inputTokens: Int?
    public let limitTokens: Int?

    private static let cliSentinel = "Prompt is too long"

    public static func isSyntheticRejection(_ payload: [String: Any]) -> Bool {
        guard ["assistant", "message"].contains(payload["type"] as? String ?? ""), isMainThread(payload),
              payload["error"] as? String == "invalid_request",
              let message = payload["message"] as? [String: Any],
              message["model"] as? String == "<synthetic>",
              let content = message["content"] as? [[String: Any]], content.count == 1
        else { return false }
        return content[0]["type"] as? String == "text" && content[0]["text"] as? String == cliSentinel
    }

    public static func classifyResult(_ payload: [String: Any]) -> Self? {
        guard payload["type"] as? String == "result", isMainThread(payload) else { return nil }
        switch (payload["stop_reason"] ?? payload["stopReason"]) as? String {
        case "model_context_window_exceeded": return .init(kind: .generationContextLimit, source: .resultStopReason)
        case "max_tokens": return .init(kind: .outputLimit, source: .resultStopReason)
        default: break
        }
        let failed = payload["is_error"] as? Bool == true || payload["isError"] as? Bool == true
        // CLI 2.1.330's local blocking limit reports subtype success despite is_error.
        // The sentinel alone (even in a failed result) does not identify this rejection.
        if failed, payload["result"] as? String == cliSentinel,
           payload["terminal_reason"] as? String == "blocking_limit",
           payload["duration_api_ms"] as? Int == 0,
           payload["api_error_status"] is NSNull
        {
            return .init(kind: .inputContextRejected, source: .localCLIRejection)
        }
        let error = payload["error"] as? [String: Any]
        let errorType = error?["type"] as? String ?? payload["error"] as? String
        if errorType == "request_too_large" || (failed && payload["api_error_status"] as? Int == 413) {
            return .init(kind: .requestTooLarge, source: .apiError)
        }
        guard errorType == "invalid_request_error" else { return nil }
        let message = error?["message"] as? String ?? payload["message"] as? String
        if let message, message.utf8.count <= 96,
           let report = try? #/prompt is too long: ([0-9]{1,9}) tokens > ([0-9]{1,9}) maximum/#.wholeMatch(in: message),
           let input = Int(report.1), let limit = Int(report.2), input > limit, limit > 0
        {
            return .init(kind: .inputContextRejected, source: .apiError, inputTokens: input, limitTokens: limit)
        }
        if message == "prompt is too long" || message == cliSentinel {
            return .init(kind: .unknownSizeLimit, source: .apiError)
        }
        return nil
    }

    private init(kind: Kind, source: Source, inputTokens: Int? = nil, limitTokens: Int? = nil) {
        self.kind = kind
        self.source = source
        self.inputTokens = inputTokens
        self.limitTokens = limitTokens
    }

    private static func isMainThread(_ payload: [String: Any]) -> Bool {
        ["parent_tool_use_id", "parentToolUseId"].allSatisfy { key in
            payload[key] == nil || payload[key] is NSNull
        }
    }
}
