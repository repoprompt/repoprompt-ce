import Foundation

@inline(__always)
func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
        true
    default:
        false
    }
}

@inline(__always)
func trimmedASCIIWhitespace(_ data: Data) -> Data? {
    var start = data.startIndex
    var end = data.endIndex
    while start < end, isASCIIWhitespace(data[start]) {
        start = data.index(after: start)
    }
    while end > start, isASCIIWhitespace(data[data.index(before: end)]) {
        end = data.index(before: end)
    }
    if start == end {
        return nil
    }
    return data.subdata(in: start ..< end)
}

enum ClaudeAbortArtifactFilter {
    static func shouldSuppressUserFacingError(_ message: String) -> Bool {
        let lowered = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lowered.isEmpty else { return false }

        if lowered.contains("json parse error") || lowered.contains("syntaxerror") {
            if lowered.contains("unrecognized token '/'")
                || lowered.contains("/$bunfs/root/src/entrypoints/cli.js")
                || lowered.contains("entrypoints/cli.js")
                || lowered.contains("at <parse>")
                || lowered.contains("at parse")
            {
                return true
            }
        }
        if lowered.contains("non-fatal") && lowered.contains("lock acquisition failed") {
            return true
        }
        if lowered.contains("aborterror")
            || lowered.contains("the operation was aborted")
            || lowered.contains("request was aborted")
        {
            return true
        }
        if lowered.hasPrefix("[ede_diagnostic]")
            || lowered.contains("internal diagnostic:")
        {
            return true
        }
        return false
    }
}

struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let contextUsedTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?
}
