import Foundation

/// Core compatibility facade for Claude SDK NDJSON translation.
///
/// The protocol-specific translation rules live in the Claude-compatible
/// provider package. Core keeps this small adapter so the process controller can
/// continue to consume app-owned `AIStreamResult` values and keep RepoPrompt MCP
/// tool-result status ownership in the host.
struct ClaudeSDKNDJSONTranslator {
    private var providerTranslator: ClaudeCompatiblePluginNDJSONTranslator

    var cliSessionID: String? {
        providerTranslator.cliSessionID
    }

    init(enableDebugLogging: Bool = false, isRepoPromptToolName: @escaping @Sendable (String) -> Bool) {
        providerTranslator = ClaudeCompatiblePluginNDJSONTranslator(
            enableDebugLogging: enableDebugLogging,
            treatsToolResultErrorsAsHostOwned: isRepoPromptToolName
        )
    }

    mutating func parseNDJSONLine(_ lineData: Data) -> [AIStreamResult] {
        providerTranslator.parseNDJSONLine(lineData).map {
            ClaudeCompatibleProviderRuntimeBridge.streamResult(from: $0)
        }
    }
}
