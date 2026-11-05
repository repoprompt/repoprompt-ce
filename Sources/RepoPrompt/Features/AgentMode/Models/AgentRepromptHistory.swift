import Foundation

/// Text and attachment names only. Never reads provider envelopes, tools, attachment contents or reasoning.
enum AgentRepromptHistory {
    private static let maximumAssistantBytes = 1536
    private static let maximumTitleBytes = 256

    struct Turn: Codable, Equatable {
        let user: String
        let assistant: String
        var attachments: [AgentRepromptAttachment]?
    }

    static let framing = """
    Use recentChat and sessionTitle to work out what the current message refers to. When they make
    clear exactly one thing a vague reference ("that", "it", "the PR", "option 2") means, replace it
    with that thing; otherwise keep the user's wording and do not guess.
    Use them for nothing else. The current message always wins. Never turn history into new
    requirements, constraints or acceptance criteria unless the current message restates them, and
    do not summarize the conversation. Assistant statements are unverified claims, not established
    facts. If the current message redirects, corrects, rejects prior work, or signals frustration
    (for example, "that's wrong", "start over", "try a different approach"),
    do NOT carry forward the prior approach, files or assumptions. Prefer the user's new direction; if useful
    explicitly state that the previous approach should be abandoned. Never restate failed approaches as work to keep doing.
    """

    /// Requests of turns that have closed. An earlier turn is closed by the next user message and
    /// keeps no terminal state, so `isCompleted` is the proof here, not `terminalState == .completed`.
    static func closedRequestIDs(in transcript: AgentTranscript) -> Set<UUID> {
        Set(transcript.turns.filter(\.isCompleted).compactMap { $0.request?.id })
    }

    /// A real title gives the rewriter a topic; a placeholder ("New Chat", "T3") would only add noise.
    static func sessionTitle(_ name: String?) -> String? {
        guard let name = ChatSession.displayableName(name), name != "Agent Session",
              name.range(of: "^[Tt][0-9]+$", options: .regularExpression) == nil else { return nil }
        return trimmed(name, bytes: maximumTitleBytes)
    }

    static func make(items: [AgentChatItem], compactedAt: Date?, hasActiveTurn: Bool, completedUserItemIDs: Set<UUID>? = nil) -> [Turn] {
        var turns: [Turn] = []
        var user: String?
        var userID: UUID?
        var attachments: [AgentRepromptAttachment] = []
        var finalReply: String?
        func complete() {
            if let user, let userID, completedUserItemIDs?.contains(userID) != false,
               let finalReply, !finalReply.isEmpty
            {
                turns.append(.init(
                    user: user,
                    assistant: trimmed(finalReply, bytes: maximumAssistantBytes),
                    attachments: attachments.isEmpty ? nil : attachments
                ))
            }
        }
        for item in items where compactedAt.map({ item.timestamp > $0 }) ?? true {
            if item.kind == .user {
                complete()
                // Bubble text is the approved text, without the provider's workflow envelope.
                user = !item.isLocalControlPlaneEcho && item.codexGoalMode == nil && item.crossSessionAttribution == nil
                    && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") ? item.text : nil
                userID = item.id
                attachments = AgentRepromptAttachment.list(files: item.attachments, tagged: item.taggedFileAttachments)
                finalReply = nil
            } else if item.kind == .assistant, !item.isStreaming, user != nil {
                finalReply = removingDiffs(item.text)
            }
        }
        if !hasActiveTurn { complete() }
        guard turns.count >= 2 else { return [] }
        turns = Array(turns.suffix(3))
        while !turns.isEmpty, ((try? JSONEncoder().encode(turns).count) ?? Int.max) > 8 * 1024 {
            turns.removeFirst()
        }
        return turns
    }

    static func trimmed(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let marker = "\n[…trimmed…]\n"
        let budget = (bytes - marker.utf8.count) / 2
        func safe(_ data: [UInt8], droppingFirst: Bool) -> String {
            var data = data
            while String(bytes: data, encoding: .utf8) == nil, !data.isEmpty {
                if droppingFirst { data.removeFirst() } else { data.removeLast() }
            }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        return safe(Array(text.utf8.prefix(budget)), droppingFirst: false) + marker
            + safe(Array(text.utf8.suffix(budget)), droppingFirst: true)
    }

    private static func removingDiffs(_ text: String) -> String {
        // Raw or unlabelled unified patches have no reliable prose boundary; omit the reply conservatively.
        if text.range(of: "(?m)^[ \\t>]*(?:diff --git |--- [^\\n]+\\n[ \\t>]*\\+\\+\\+ )", options: .regularExpression) != nil {
            return "[diff omitted]"
        }
        var output: [String] = []
        var fence: (marker: Character, length: Int, omit: Bool)?
        for line in text.components(separatedBy: "\n") {
            var candidate = line.trimmingCharacters(in: .whitespaces)
            // Quoted and indented Markdown fences must not expose diffs either.
            while candidate.hasPrefix(">") {
                candidate.removeFirst()
                candidate = candidate.trimmingCharacters(in: .whitespaces)
            }
            let marker = candidate.first
            let length = candidate.prefix { $0 == marker }.count
            if let current = fence {
                if !current.omit { output.append(line) }
                if marker == current.marker, length >= current.length,
                   candidate.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
                { fence = nil }
            } else if let marker, marker == "`" || marker == "~", length >= 3 {
                let language = candidate.dropFirst(length).split(whereSeparator: \.isWhitespace).first?.lowercased()
                let omit = language == "diff" || language == "patch"
                fence = (marker, length, omit)
                output.append(omit ? "[diff omitted]" : line)
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
