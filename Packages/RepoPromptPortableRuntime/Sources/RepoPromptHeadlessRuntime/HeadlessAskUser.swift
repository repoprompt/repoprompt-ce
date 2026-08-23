import Foundation
import RepoPromptAuthorityAPI

/// Desktop `ask_user` payload recognition and answer shaping for Linux.
/// The macOS wizard is the authority; this only identifies the same envelope
/// and returns the same response object the Desktop tool gives the agent.
enum HeadlessAskUser {
    static let authorityOperation = "mcp.ask_user"

    static func isAskUserPayload(_ data: Data) -> Bool {
        guard let object = jsonObject(data) else { return false }
        if object["authorityOperation"] as? String == authorityOperation { return true }
        if object["questions"] is [Any] { return true }
        if let question = object["question"] as? String, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    static func timeoutSeconds(from data: Data, defaultTimeout: Int = 300) -> Int {
        guard let object = jsonObject(data) else { return defaultTimeout }
        let raw = object["timeout_seconds"] ?? object["timeoutSeconds"]
        if let value = raw as? Int, value > 0 { return min(value, 3600) }
        if let value = raw as? Double, value > 0 { return min(Int(value), 3600) }
        return defaultTimeout
    }

    static func desktopResponse(from answer: Data, timedOut: Bool = false, elapsedSeconds: Int = 0) -> Data {
        if timedOut {
            return encode(strippedDesktopResponse([:], timedOut: true, elapsedSeconds: elapsedSeconds))
        }
        if let object = jsonObject(answer), looksLikeDesktopResponse(object) {
            return encode(strippedDesktopResponse(object, timedOut: false, elapsedSeconds: elapsedSeconds))
        }
        return encode(normalizedResponse(from: jsonObject(answer), elapsedSeconds: elapsedSeconds))
    }

    static func presentationPayload(request: Data, answer: Data, timedOut: Bool = false, elapsedSeconds: Int = 0) -> Data {
        var merged = jsonObject(request) ?? [:]
        let response = jsonObject(desktopResponse(from: answer, timedOut: timedOut, elapsedSeconds: elapsedSeconds)) ?? [:]
        merged["authorityOperation"] = authorityOperation
        merged["answers"] = response["answers"] ?? [String: Any]()
        merged["timed_out"] = response["timed_out"] ?? false
        merged["skipped"] = response["skipped"] ?? false
        merged["elapsed_seconds"] = response["elapsed_seconds"] ?? max(0, elapsedSeconds)
        return encode(merged)
    }

    static func presentationPrompt(from payload: Data) -> String {
        String(data: payload, encoding: .utf8).map { String($0.prefix(8192)) } ?? "The agent needs your response."
    }

    static func resolutionLabel(from payload: Data) -> String {
        guard let object = jsonObject(payload) else { return "answered" }
        if object["timed_out"] as? Bool == true { return "timed_out" }
        if object["skipped"] as? Bool == true { return "skipped" }
        return "answered"
    }

    private static func looksLikeDesktopResponse(_ object: [String: Any]) -> Bool {
        object["answers"] is [String: Any] && (object["timed_out"] != nil || object["timedOut"] != nil)
    }

    private static func strippedDesktopResponse(_ object: [String: Any], timedOut: Bool, elapsedSeconds: Int) -> [String: Any] {
        [
            "answers": object["answers"] ?? [String: Any](),
            "timed_out": timedOut || (object["timed_out"] as? Bool ?? object["timedOut"] as? Bool ?? false),
            "skipped": object["skipped"] as? Bool ?? false,
            "elapsed_seconds": object["elapsed_seconds"] ?? object["elapsedSeconds"] ?? max(0, elapsedSeconds)
        ]
    }

    private static func normalizedResponse(from object: [String: Any]?, elapsedSeconds: Int) -> [String: Any] {
        var answers: [String: Any] = [:]
        if let map = object?["answers"] as? [String: Any] {
            answers = map
        } else if let rows = object?["answers"] as? [[String: Any]] {
            for row in rows {
                let id = string(row["questionId"] ?? row["id"]) ?? "question"
                let text = string(row["text"] ?? row["answer"]) ?? ""
                answers[id] = [
                    "answers": text.isEmpty ? [] : [text],
                    "selected_options": [],
                    "custom_response": (text.isEmpty ? NSNull() : text) as Any,
                    "skipped": false
                ]
            }
        } else if let text = string(object?["text"] ?? object?["answer"] ?? object?["custom_response"]), !text.isEmpty {
            answers["question"] = [
                "answers": [text],
                "selected_options": [],
                "custom_response": text as Any,
                "skipped": false
            ]
        }
        return [
            "answers": answers,
            "timed_out": false,
            "skipped": object?["skipped"] as? Bool ?? false,
            "elapsed_seconds": max(0, elapsedSeconds)
        ]
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
