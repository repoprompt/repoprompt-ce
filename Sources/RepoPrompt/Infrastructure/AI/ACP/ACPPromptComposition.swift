import Foundation

/// Shared first-turn prompt text composition for ACP providers that have no separate
/// system-prompt channel: the system prompt is prepended once on session open and never
/// repeated on a resumed session, where the agent already holds it.
enum ACPPromptComposition {
    static func promptText(for message: AgentMessage, request: ACPRunRequest) -> String {
        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFollowUp || systemPrompt.isEmpty {
            return userMessage.isEmpty ? message.userMessage : userMessage
        }
        if userMessage.isEmpty {
            return systemPrompt
        }
        return "\(systemPrompt)\n\n\(userMessage)"
    }
}
