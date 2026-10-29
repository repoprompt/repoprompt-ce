import Foundation

/// Composes Oracle system prompts from a prompt body plus the code-owned response-format
/// suffixes. Production (`PromptViewModel.captureOraclePromptConfiguration`) and the
/// Prompt Experiments harness both call this, so an evaluated candidate renders exactly
/// as the Agent/MCP oracle path would render the built-in body.
///
/// Only the Agent/MCP oracle form is reproduced here. `PromptViewModel.packagePrompt`'s
/// plan branch and the headless review path append a variant whose chat-name tag keeps
/// literal backslashes (`<chatName=\"…\"/>`), and headless plan appends no suffix; those
/// legacy bytes are intentionally left unchanged and are not what experiments measure.
enum OracleSystemPromptRenderer {
    static let chatNameSuffix = "\n\nYou may include one chat-name tag on its own line near the top: <chatName=\"Unique name describing user request\"/>"
    static let markdownSuffix = "\n\nProvide your response in clean, well-formatted Markdown. Use proper headings, lists, code blocks, and other Markdown elements to make your response easy to read and understand. Do not emit machine-readable edit blocks."

    /// Plan and stored-system-prompt (Review) bodies carry both response-format suffixes.
    static func appendingResponseFormat(to body: String) -> String {
        body + chatNameSuffix + markdownSuffix
    }

    /// The full system prompt for a built-in Oracle prompt body.
    static func render(_ id: BuiltInPromptID, body: String) -> String {
        switch id {
        case .oraclePlan, .oracleReview:
            appendingResponseFormat(to: body)
        case .oracleChat, .oracleChatNoRoots:
            body
        case .engineer:
            preconditionFailure("Engineer prompts require the Agent Mode renderer and tool-using harness.")
        }
    }
}
