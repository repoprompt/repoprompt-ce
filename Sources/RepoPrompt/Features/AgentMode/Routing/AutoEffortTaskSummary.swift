import Foundation

/// A deliberately narrow, best-effort view of one user-authored turn for external effort judgment.
/// This is not anonymization: arbitrary prose can still contain private information.
enum AutoEffortTaskSummary {
    static let maximumInputCharacters = 4000
    static let maximumSummaryCharacters = 1200

    static func make(from userText: String) -> String? {
        guard !userText.isEmpty, userText.count <= maximumInputCharacters else { return nil }

        var summary = userText
        // Replace complete blocks first, then reject unmatched markers rather than sending a tail.
        summary = replacing(
            summary,
            pattern: #"(?s)-----BEGIN ([A-Z0-9 ]+)-----.*?-----END \1-----"#,
            with: "[private key omitted]"
        )
        guard !summary.contains("-----BEGIN "), !summary.contains("-----END ") else { return nil }
        summary = replacing(
            summary,
            pattern: #"(?ms)^[ \t]*(```|~~~)[^\n]*\n.*?^[ \t]*\1[ \t]*(?=\n|$)"#,
            with: "[code omitted]"
        )
        guard summary.range(of: #"(?m)^[ \t]*(?:```|~~~)"#, options: .regularExpression) == nil else { return nil }
        summary = replacing(summary, pattern: #"`[^`\n]+`"#, with: "[code omitted]")
        summary = replacing(summary, pattern: #"(?m)^(?: {4}|\t)[^\n]*"#, with: "[code omitted]")

        // Mask common credentials and identifying shapes. This is intentionally not a promise
        // to catch arbitrary secrets, personal data, or business-sensitive prose.
        summary = replacing(
            summary,
            pattern: #"(?i)\b[A-Z0-9_-]*(?:API[_-]?KEY|PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE[_-]?KEY)[A-Z0-9_-]*\b["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
            with: "[credential omitted]"
        )
        summary = replacing(
            summary,
            pattern: #"(?i)\b(?:password|passphrase|secret|token|api[_-]?key)\s+(?:is|was)\s+(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
            with: "[credential omitted]"
        )
        summary = replacing(summary, pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#, with: "[credential omitted]")
        summary = replacing(summary, pattern: #"(?i)\bAuthorization\s*:\s*Basic\s+[A-Za-z0-9+/=]+"#, with: "[credential omitted]")
        summary = replacing(
            summary,
            pattern: #"\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            with: "[credential omitted]"
        )
        summary = replacing(
            summary,
            pattern: #"\b(?:sk-[A-Za-z0-9_-]{12,}|(?:sk_live_|rk_live_|glpat-|npm_|hf_)[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{12,}|AIza[A-Za-z0-9_-]{20,})\b"#,
            with: "[credential omitted]"
        )
        summary = replacing(summary, pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, with: "[email omitted]")
        summary = replacing(summary, pattern: #"(?i)\b[a-z][a-z0-9+.-]{1,20}://[^\s<>"')\]]+"#, with: "[URL omitted]")
        summary = replacing(
            summary,
            pattern: #"(?:(?<=\s)|(?<=["'(])|^)(?:/Users/|/home/|/private/|/root/|/var/|~/|[A-Za-z]:\\)[^\s"'<>)]+"#,
            with: "[path omitted]"
        )
        summary = replacing(summary, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "[IP address omitted]")
        summary = replacing(summary, pattern: #"\b[0-9a-fA-F]{32,}\b"#, with: "[opaque value omitted]")
        summary = replacing(summary, pattern: #"\b[A-Za-z0-9_+/=-]{48,}\b"#, with: "[opaque value omitted]")
        summary = replacing(summary, pattern: #"\s+"#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let meaningful = replacing(summary, pattern: #"\[[^\]]+ omitted\]"#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard meaningful.range(of: #"[\p{L}]{3}"#, options: .regularExpression) != nil else { return nil }
        return String(summary.prefix(maximumSummaryCharacters))
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
