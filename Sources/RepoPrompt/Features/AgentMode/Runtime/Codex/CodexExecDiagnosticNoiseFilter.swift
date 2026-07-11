import Foundation

// SEARCH-HELPER: Codex, stderr, diagnostic, noise, filter, suppress, headless
/// Filters internal Codex CLI stderr diagnostic noise so it is not surfaced
/// to users in the Context Builder agent log.
///
/// The Codex CLI (Go-based) emits structured logs, transport-level diagnostics,
/// heartbeat messages, and JSON-RPC protocol traffic on stderr. These are
/// useful for debugging but should not appear in the user-facing agent log.
///
/// Related:
/// - ClaudeAbortArtifactFilter (analogous filter for Claude Code)
/// - CodexExecAgentProvider.streamAgentMessage (call site)
enum CodexExecDiagnosticNoiseFilter {
    /// Known internal lifecycle/transport markers that indicate diagnostic noise.
    private static let lifecycleMarkers = [
        "process_terminal",
        "session_heartbeat",
        "heartbeat_scheduler",
        "model_client",
        "stream_response",
        "x-request-id",
        "x-ratelimit",
        "content-type:",
        "codex-openai"
    ]

    /// Returns `true` when the stderr line is internal diagnostic noise that
    /// should not be surfaced to the user.
    static func shouldSuppress(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if looksLikeTimestampedLog(trimmed) {
            return true
        }
        if looksLikeGoSourceReference(trimmed) {
            return true
        }
        if looksLikeProtocolJSON(trimmed) {
            return true
        }

        let lowered = trimmed.lowercased()
        return lifecycleMarkers.contains(where: lowered.contains)
    }

    // MARK: - Private helpers

    /// Matches Go structured log lines that start with an ISO-ish timestamp.
    /// e.g. "2026-04-09T10:51:37.031 INFO ..." or "2026-04-09 10:51:37 DEBUG ..."
    private static func looksLikeTimestampedLog(_ text: String) -> Bool {
        guard text.count >= 10 else { return false }
        let prefix = text.prefix(11)
        return prefix.first?.isNumber == true
            && prefix.contains("-")
            && (prefix.contains("T") || prefix.count(where: { $0 == "-" }) >= 2)
    }

    /// Matches Go source file references like "middleware.go:123".
    private static func looksLikeGoSourceReference(_ text: String) -> Bool {
        text.lowercased().contains(".go:")
    }

    /// Matches JSON protocol messages (JSON-RPC, internal events) while
    /// preserving structured errors that carry `error` or `message` fields.
    private static func looksLikeProtocolJSON(_ text: String) -> Bool {
        guard
            text.first == "{",
            text.last == "}",
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        // Keep structured errors visible
        if object["error"] != nil {
            return false
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return false
        }

        // Suppress JSON-RPC and protocol-shaped messages
        return object["jsonrpc"] != nil
            || object["method"] != nil
            || object["params"] != nil
            || object["id"] != nil
            || object["result"] != nil
    }
}
