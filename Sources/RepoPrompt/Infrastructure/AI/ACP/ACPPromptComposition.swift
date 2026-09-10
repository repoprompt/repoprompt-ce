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

    static func promptContentParts(
        for message: AgentMessage,
        request: ACPRunRequest
    ) -> [AgentPromptContentPart] {
        guard !message.promptContentParts.isEmpty else {
            return [.text(promptText(for: message, request: request))]
        }

        var parts = message.promptContentParts
        let textIndices = parts.indices.filter { parts[$0].text != nil }
        if let index = textIndices.first, let text = parts[index].text {
            parts[index] = .text(String(text.drop(while: \.isWhitespace)))
        }
        if let index = textIndices.last, let text = parts[index].text {
            parts[index] = .text(String(text.reversed().drop(while: \.isWhitespace).reversed()))
        }
        parts.removeAll { $0.text?.isEmpty == true }

        let isFollowUp = request.resumeSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isFollowUp, !systemPrompt.isEmpty else { return parts }

        if let first = parts.first?.text {
            parts[0] = .text("\(systemPrompt)\n\n\(first)")
        } else {
            parts.insert(.text(systemPrompt), at: 0)
        }
        return parts
    }
}
