import Foundation

enum ClaudeReasoningExtractionFeature {
    static let isEnabled = false
}

#if DEBUG
    enum ClaudeReasoningDebugLog {
        static let fileURL = MCPFilesystemConstants.identity.temporaryRootURL()
            .appendingPathComponent("claude-reasoning-debug.log", isDirectory: false)
        private static let lock = NSLock()

        static func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let payload = "\(timestamp) \(line)\n"
            guard let data = payload.data(using: .utf8) else { return }
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
#endif

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

    init(enableDebugLogging: Bool = false) {
        providerTranslator = ClaudeCompatiblePluginNDJSONTranslator(
            enableDebugLogging: enableDebugLogging,
            treatsToolResultErrorsAsHostOwned: { toolName in
                MCPIntegrationHelper.isRepoPromptToolName(toolName)
            }
        )
    }

    mutating func parseNDJSONLine(_ lineData: Data) -> [AIStreamResult] {
        providerTranslator.parseNDJSONLine(lineData).map {
            ClaudeCompatibleProviderRuntimeBridge.streamResult(from: $0)
        }
    }
}
