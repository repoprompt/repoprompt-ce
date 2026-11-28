import Foundation

/// Storage-safe record of one `ask_user` exchange: the questions that were asked and the answers given.
///
/// Persistent transcript sanitization drops tool arguments and reduces most tool results to a
/// status-only summary. The `ask_user` card renders nothing except those two things, so a saved
/// transcript replayed as "Question / No response". This record is embedded in the persisted result
/// JSON instead. It is bounded by the persisted summary budget and is a fixed point: re-sanitizing an
/// already persisted record reproduces it byte for byte.
struct AgentAskUserTranscriptExchange: Equatable {
    struct Question: Equatable {
        var id: String
        var header: String?
        var question: String
    }

    struct Answer: Equatable {
        var text: String?
        var skipped: Bool
    }

    var title: String?
    var questions: [Question]
    var answers: [String: Answer]
    var skipped: Bool
    var timedOut: Bool

    /// Field limits, loosest first. A tier only shortens or drops fields, so a record that already
    /// fits a tighter tier passes through every looser tier unchanged.
    private struct Limits {
        let title: Int?
        let header: Int?
        let question: Int
        let answer: Int
    }

    private static let limitTiers: [Limits] = [
        Limits(title: 120, header: 60, question: 280, answer: 280),
        Limits(title: 80, header: 40, question: 160, answer: 160),
        Limits(title: 60, header: nil, question: 90, answer: 90),
        Limits(title: nil, header: nil, question: 48, answer: 48),
        // Clipping counts characters but the budget counts bytes; these keep every row of a
        // multibyte-heavy exchange as a short preview instead of losing the exchange entirely.
        Limits(title: nil, header: nil, question: 24, answer: 24),
        Limits(title: nil, header: nil, question: 12, answer: 12)
    ]

    /// Mirrors the `ask_user` request cap so a persisted record never grows past what the tool accepts.
    private static let maxQuestionCount = 10
    private static let maxPayloadSearchDepth = 6
    /// Envelope keys holding the canonical structured reply, checked before text content blocks.
    private static let structuredEnvelopeKeys = ["structuredContent", "structured_content"]

    // MARK: - Decoding

    /// Builds the exchange from the tool's arguments and result.
    ///
    /// `resultJSON` may be the raw MCP reply object, the provider-formatted text block that wraps it in a
    /// JSON fence, a CallTool result envelope, or a previously persisted record. Questions come from the
    /// arguments when present, otherwise from a persisted record. Returns nil when no question survives.
    static func decode(argsJSON: String?, resultJSON: String?) -> AgentAskUserTranscriptExchange? {
        let args = jsonValue(from: argsJSON) as? [String: Any]
        let payload = answerPayload(from: resultJSON)
        guard let questions = questions(in: args) ?? questions(in: payload) else { return nil }

        let title = normalized(args?["title"]) ?? normalized(payload?["title"])
        var answers: [String: Answer] = [:]
        if let rawAnswers = payload?["answers"] as? [String: Any] {
            for (rawID, rawAnswer) in rawAnswers {
                guard let id = normalizedID(rawID), let object = rawAnswer as? [String: Any] else { continue }
                answers[id] = answer(from: object)
            }
        }
        if answers["response"] == nil, let response = normalized(payload?["response"]) {
            answers["response"] = Answer(text: response, skipped: false)
        }

        return AgentAskUserTranscriptExchange(
            title: title,
            questions: questions,
            answers: answers,
            skipped: payload?["skipped"] as? Bool ?? false,
            timedOut: payload?["timed_out"] as? Bool ?? false
        )
    }

    private static func questions(in object: [String: Any]?) -> [Question]? {
        guard let object else { return nil }
        if let rawQuestions = object["questions"] as? [Any] {
            let questions = rawQuestions.prefix(maxQuestionCount).enumerated().compactMap { index, raw -> Question? in
                guard let question = raw as? [String: Any], let text = normalized(question["question"]) else { return nil }
                return Question(
                    id: normalizedID(question["id"] as? String) ?? "question_\(index + 1)",
                    header: normalized(question["header"]),
                    question: text
                )
            }
            return questions.isEmpty ? nil : questions
        }
        // Legacy scalar requests are answered under the fixed "response" question ID.
        if let text = normalized(object["question"]) {
            return [Question(id: "response", header: nil, question: text)]
        }
        return nil
    }

    private static func answer(from object: [String: Any]) -> Answer {
        let skipped = object["skipped"] as? Bool ?? false
        let explicit = stringArray(object["answers"])
        var parts = explicit.isEmpty ? stringArray(object["selected_options"]) : explicit
        if explicit.isEmpty, let custom = normalized(object["custom_response"]) {
            parts.append(custom)
        }
        return Answer(text: parts.isEmpty ? nil : parts.joined(separator: ", "), skipped: skipped)
    }

    /// Finds the object that carries the reply fields, unwrapping fenced text and result envelopes.
    private static func answerPayload(from raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let root: Any = jsonValue(from: raw) ?? raw
        // A bare top-level `{"response": ...}` is the oldest scalar reply shape.
        if let object = root as? [String: Any], object["response"] is String {
            return object
        }
        return answerPayload(in: root, depth: 0)
    }

    private static func isReplyObject(_ object: [String: Any]) -> Bool {
        if object["answers"] is [String: Any] {
            return true
        }
        return object["response"] is String && (object["skipped"] is Bool || object["timed_out"] is Bool)
    }

    private static func answerPayload(in value: Any, depth: Int) -> [String: Any]? {
        guard depth <= maxPayloadSearchDepth else { return nil }
        switch value {
        case let object as [String: Any]:
            if isReplyObject(object) {
                return object
            }
            let preferredKeys = structuredEnvelopeKeys.filter { object[$0] != nil }
            let remainingKeys = object.keys.filter { !structuredEnvelopeKeys.contains($0) }.sorted()
            for key in preferredKeys + remainingKeys {
                if let value = object[key], let found = answerPayload(in: value, depth: depth + 1) {
                    return found
                }
            }
            return nil
        case let array as [Any]:
            for element in array {
                if let found = answerPayload(in: element, depth: depth + 1) {
                    return found
                }
            }
            return nil
        case let string as String:
            guard let parsed = jsonValue(from: unfenced(string)) else { return nil }
            return answerPayload(in: parsed, depth: depth + 1)
        default:
            return nil
        }
    }

    private static func unfenced(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else { return trimmed }
        trimmed = String(trimmed.dropFirst(3).dropLast(3))
        if let newline = trimmed.firstIndex(of: "\n") {
            let language = trimmed[..<newline].trimmingCharacters(in: .whitespaces)
            if language.isEmpty || language.allSatisfy(\.isLetter) {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Encoding

    /// Returns the persisted result JSON, or nil when even the tightest tier exceeds `byteBudget`.
    func persistedResultJSON(statusWord: String, summaryText: String?, byteBudget: Int) -> String? {
        for limits in Self.limitTiers {
            let object = persistedObject(statusWord: statusWord, summaryText: summaryText, limits: limits)
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  data.count <= byteBudget
            else {
                continue
            }
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    private func persistedObject(statusWord: String, summaryText: String?, limits: Limits) -> [String: Any] {
        var object: [String: Any] = [
            "status": statusWord,
            "summary_only": true,
            "skipped": skipped,
            "timed_out": timedOut
        ]
        if let summaryText = Self.normalized(summaryText) {
            object["summary_text"] = summaryText
        }
        if let titleLimit = limits.title, let title {
            object["title"] = Self.clipped(title, to: titleLimit)
        }
        object["questions"] = questions.map { question -> [String: Any] in
            var entry: [String: Any] = [
                "id": question.id,
                "question": Self.clipped(question.question, to: limits.question)
            ]
            if let headerLimit = limits.header, let header = question.header {
                entry["header"] = Self.clipped(header, to: headerLimit)
            }
            return entry
        }
        let questionIDs = Set(questions.map(\.id))
        object["answers"] = answers.reduce(into: [String: Any]()) { result, entry in
            guard questionIDs.contains(entry.key) else { return }
            var answer: [String: Any] = [:]
            if entry.value.skipped {
                answer["skipped"] = true
            }
            if let text = entry.value.text {
                answer["answers"] = [Self.clipped(text, to: limits.answer)]
            }
            result[entry.key] = answer
        }
        return object
    }

    // MARK: - Helpers

    /// Idempotent clip: text at or under `limit` characters is returned unchanged.
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// IDs are never clipped: truncation could merge distinct questions' answers.
    private static func normalizedID(_ value: String?) -> String? {
        normalized(value)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { normalized($0) } ?? []
    }

    private static func jsonValue(from raw: String?) -> Any? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.first == "{" || raw.first == "[",
              let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
