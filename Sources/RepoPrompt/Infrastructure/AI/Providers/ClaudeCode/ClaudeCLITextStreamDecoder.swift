import Foundation

enum ClaudeCLITextStreamFailure: Error { case incomplete }

/// Bounded NDJSON text-only decoder for an isolated Claude print stream.
struct ClaudeCLITextStreamDecoder {
    private var pending = Data()
    private var emittedDelta = false
    private(set) var completed = false
    private var incomplete = false

    mutating func append(_ data: Data) throws -> [String] {
        pending.append(data)
        guard pending.count <= 1024 * 1024 else { throw AIProviderError.invalidResponse(detail: "Claude stream exceeded its frame limit") }
        var deltas: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if let text = try decode(Data(line)) { deltas.append(text) }
        }
        return deltas
    }

    mutating func finish() throws -> [String] {
        var tail: [String] = []
        if !pending.isEmpty, let text = try decode(pending) { tail.append(text) }
        pending.removeAll()
        guard completed, !incomplete else { throw ClaudeCLITextStreamFailure.incomplete }
        return tail
    }

    private mutating func decode(_ data: Data) throws -> String? {
        guard !data.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse(detail: "Invalid Claude stream frame")
        }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return nil }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String
            {
                emittedDelta = true
                return text
            }
            if let delta = event["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String,
               stop != "end_turn", stop != "stop_sequence" { incomplete = true }
        case "assistant":
            // Older CLIs may send whole assistant messages despite --include-partial-messages.
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            if let stop = message["stop_reason"] as? String, stop != "end_turn", stop != "stop_sequence" { incomplete = true }
            if content.contains(where: { $0["type"] as? String == "tool_use" }) { throw AIProviderError.invalidResponse(detail: "Claude text-only stream did not complete successfully") }
            guard !emittedDelta else { return nil }
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case "result":
            guard object["is_error"] as? Bool != true, object["subtype"] as? String == "success" else {
                throw AIProviderError.invalidResponse(detail: "Claude text-only stream did not complete successfully")
            }
            completed = true
        default: break
        }
        return nil
    }
}
