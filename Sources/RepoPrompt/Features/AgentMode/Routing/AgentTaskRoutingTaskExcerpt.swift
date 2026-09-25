import Foundation

/// A bounded view of a long task for Jev classification, not the task sent to the agent.
/// Masking is best effort; user-authored prose can still contain sensitive information.
enum AgentTaskRoutingTaskExcerpt {
    private static let segmentCharacters = 1200
    private static let segmentUTF8Bytes = 7000

    static func make(from text: String) -> String {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.count > AgentTaskRoutingEnvelopeBuilder.maximumCharacters
            || task.utf8.count > AgentTaskRoutingEnvelopeBuilder.maximumUTF8Bytes
        else { return task }

        let opening = AutoEffortTaskSummary.make(from: completePrefix(of: task))
            .map { boundedUTF8Prefix($0) }
        let ending = AutoEffortTaskSummary.make(from: completeSuffix(of: task))
            .map { boundedUTF8Prefix($0) }
        let omitted = "[Long task: middle omitted; original length \(task.count) characters]"
        return [opening, omitted, ending].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Discard cut words so a partial credential at either boundary is never sent.
    private static func completePrefix(of text: String) -> String {
        let prefix = String(text.prefix(segmentCharacters))
        guard text.count > segmentCharacters,
              let boundary = prefix.lastIndex(where: \.isWhitespace)
        else { return prefix }
        return String(prefix[..<boundary])
    }

    private static func completeSuffix(of text: String) -> String {
        let suffix = String(text.suffix(segmentCharacters))
        guard text.count > segmentCharacters,
              let boundary = suffix.firstIndex(where: \.isWhitespace)
        else { return suffix }
        return String(suffix[suffix.index(after: boundary)...])
    }

    private static func boundedUTF8Prefix(_ text: String) -> String {
        var bytes = 0
        var result = ""
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= segmentUTF8Bytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
