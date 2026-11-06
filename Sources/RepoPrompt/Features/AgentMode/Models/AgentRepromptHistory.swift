import Foundation

/// Text and attachment names only. Never reads provider envelopes, tools, attachment contents or reasoning.
enum AgentRepromptHistory {
    private static let maximumAssistantBytes = 1536
    private static let maximumEncodedBytes = 8 * 1024
    private static let minimumBoundedUserBytes = 256

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
    facts. A correction ("that's wrong, the timeout should be 10 seconds") changes only what it
    corrects: state that change and do not imply anything else was rejected. Only when the current
    message explicitly asks to abandon or redo the work ("start over", "try a different approach"),
    do NOT carry forward the prior approach, files or assumptions, and say that the previous approach
    should be abandoned. Never restate failed approaches as work to keep doing.
    """

    /// Requests of turns that have closed. An earlier turn is closed by the next user message and
    /// keeps no terminal state, so `isCompleted` is the proof here, not `terminalState == .completed`.
    static func closedRequestIDs(in transcript: AgentTranscript) -> Set<UUID> {
        Set(transcript.turns.filter(\.isCompleted).compactMap { $0.request?.id })
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
        while !fitsBudget(turns) {
            // Older exchanges go first. The newest one is trimmed rather than lost, so one large
            // message cannot leave a follow-up such as "proceed with that" with no context at all.
            if turns.count == 1, let bounded = boundedUserText(turns[0]) {
                return [bounded]
            }
            turns.removeFirst()
        }
        return turns
    }

    private static func fitsBudget(_ turns: [Turn]) -> Bool {
        ((try? JSONEncoder().encode(turns).count) ?? Int.max) <= maximumEncodedBytes
    }

    /// JSON escaping can inflate text, so the byte allowance halves until the encoded turn fits.
    private static func boundedUserText(_ turn: Turn) -> Turn? {
        var bytes = maximumEncodedBytes - maximumAssistantBytes
        while bytes >= minimumBoundedUserBytes {
            let candidate = Turn(user: trimmed(turn.user, bytes: bytes), assistant: turn.assistant, attachments: turn.attachments)
            if fitsBudget([candidate]) { return candidate }
            bytes /= 2
        }
        return nil
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
