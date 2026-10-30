import Foundation

package struct ClaudeResultMessage: Codable {
    let type: String
    let subtype: String
    let totalCostUsd: Double
    let durationMs: Int
    let durationApiMs: Int
    let isError: Bool
    let numTurns: Int
    package let result: String?
    let sessionId: String
    let usage: Usage?

    struct Usage: Codable {
        let inputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
        let outputTokens: Int
        let serverToolUse: ServerToolUse
    }

    struct ServerToolUse: Codable {
        let webSearchRequests: Int
    }
}
