import Foundation

final class DirectCodexProgressTail: @unchecked Sendable {
    typealias Reporter = @Sendable (String) async -> Void

    private static let maximumLineBytes = 1024 * 1024

    private let lock = NSLock()
    private let reporter: Reporter
    private var pendingLine = Data()
    private var discardingOversizedLine = false
    private var lastMessage: String?
    private var latestAssistantText: String?

    init(reporter: @escaping Reporter) {
        self.reporter = reporter
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let messages: [String]
        lock.lock()
        var parsed: [String] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if discardingOversizedLine {
                guard let newline = data[cursor...].firstIndex(of: 0x0A) else { break }
                discardingOversizedLine = false
                cursor = data.index(after: newline)
                continue
            }

            if let newline = data[cursor...].firstIndex(of: 0x0A) {
                appendLineBytes(data[cursor ..< newline])
                if !discardingOversizedLine {
                    consumeCompleteLine(pendingLine, messages: &parsed)
                }
                pendingLine.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
                cursor = data.index(after: newline)
            } else {
                appendLineBytes(data[cursor...])
                break
            }
        }
        messages = parsed
        lock.unlock()

        for message in messages {
            Task { await reporter(message) }
        }
    }

    func finalAssistantText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latestAssistantText
    }

    private func appendLineBytes(_ bytes: Data.SubSequence) {
        guard !discardingOversizedLine else { return }
        guard pendingLine.count + bytes.count <= Self.maximumLineBytes else {
            pendingLine.removeAll(keepingCapacity: false)
            discardingOversizedLine = true
            return
        }
        pendingLine.append(contentsOf: bytes)
    }

    private func consumeCompleteLine(_ line: Data, messages: inout [String]) {
        if let assistantText = Self.assistantText(from: line) {
            latestAssistantText = assistantText
        }
        if let message = Self.progressMessage(from: line), message != lastMessage {
            lastMessage = message
            messages.append(message)
        }
    }

    nonisolated static func assistantText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = object["item"] as? [String: Any],
              item["type"] as? String == "agent_message",
              let text = item["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    nonisolated static func progressMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "thread.started":
            return "Provider session started"
        case "turn.started":
            return "Provider began analyzing the workspace"
        case "turn.completed":
            return "Provider completed analysis"
        case "turn.failed":
            return "Provider reported a failed turn"
        case "item.started", "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return nil }
            let verb = type == "item.started" ? "started" : "completed"
            return switch itemType {
            case "command_execution": "Workspace inspection \(verb)"
            case "mcp_tool_call": "RepoPrompt tool call \(verb)"
            case "agent_message": type == "item.started" ? "Provider is synthesizing a response" : "Provider response completed"
            case "reasoning": "Provider reasoning \(verb)"
            case "file_change": "Provider file-change step \(verb)"
            default: nil
            }
        default:
            return nil
        }
    }
}
