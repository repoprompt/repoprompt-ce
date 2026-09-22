import Foundation
import MCP
import RepoPromptDomainRuntime

/// Maps the stable `ask_user` request/response envelope onto MCP form elicitation.
/// The transport-facing provider remains connection scoped; this type only owns
/// the schema and value conversion needed to preserve the public tool contract.
enum MCPAskUserElicitationBridge {
    struct Question {
        let id: String
        let text: String
        let context: String?
        let optionLabels: [String]
        let allowsMultiple: Bool
        let allowsCustom: Bool
    }

    static func provider(
        connection: BootstrapSocketConnectionManager
    ) -> DomainInteractionProvider {
        DomainInteractionProvider(
            kind: .elicitation,
            isAvailable: { _ in
                await connection.supportsFormElicitation()
            },
            present: { request in
                try await present(request, connection: connection)
            },
            cancel: { _ in
                await connection.cancelFormElicitation()
            }
        )
    }

    static func present(
        _ request: DomainInteractionRequest,
        connection: BootstrapSocketConnectionManager
    ) async throws -> Value {
        let defaultTimeout = max(1, request.deadline.timeIntervalSinceNow - 1)
        let parsed = try MCPAskUserToolProvider.parseAskUserInteraction(
            args: request.payload,
            defaultTimeout: defaultTimeout
        )
        let questions = questions(from: parsed.interaction)
        let startedAt = Date()
        let result = try await connection.requestFormElicitation(
            message: message(from: request.payload, questions: questions),
            requestedSchema: schema(from: request.payload, questions: questions)
        )
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
        switch result.action {
        case .accept:
            return response(
                questions: questions,
                content: result.content ?? [:],
                elapsedSeconds: elapsed,
                includeLegacyResponse: parsed.includeLegacyResponse
            )
        case .decline:
            return skippedResponse(
                questions: questions,
                elapsedSeconds: elapsed,
                includeLegacyResponse: parsed.includeLegacyResponse
            )
        case .cancel:
            throw CancellationError()
        }
    }

    static func questions(
        from payload: [String: Value],
        defaultTimeout: TimeInterval = 300
    ) throws -> [Question] {
        let parsed = try MCPAskUserToolProvider.parseAskUserInteraction(
            args: payload,
            defaultTimeout: defaultTimeout
        )
        return questions(from: parsed.interaction)
    }

    private static func questions(from interaction: AgentAskUserInteraction) -> [Question] {
        interaction.questions.map { question in
            Question(
                id: question.id,
                text: question.question,
                context: question.context,
                optionLabels: question.optionLabels,
                allowsMultiple: question.allowsMultiple,
                allowsCustom: question.allowsCustom
            )
        }
    }

    static func schema(
        from payload: [String: Value],
        questions: [Question]
    ) -> Elicitation.RequestSchema {
        var properties: [String: Value] = [:]
        for question in questions {
            var descriptionParts = [question.text]
            if let context = question.context {
                descriptionParts.append(context)
            }
            if question.allowsCustom, !question.optionLabels.isEmpty {
                descriptionParts.append("Suggested answers: \(question.optionLabels.joined(separator: ", "))")
            }
            var itemSchema: [String: Value] = [
                "type": .string("string")
            ]
            if !question.allowsCustom, !question.optionLabels.isEmpty {
                itemSchema["enum"] = .array(question.optionLabels.map(Value.string))
            }
            var property: [String: Value] = [
                "title": .string(question.text),
                "description": .string(descriptionParts.joined(separator: "\n"))
            ]
            if question.allowsMultiple {
                property["type"] = .string("array")
                property["items"] = .object(itemSchema)
                property["uniqueItems"] = .bool(true)
            } else {
                property.merge(itemSchema) { _, itemValue in itemValue }
            }
            properties[question.id] = .object(property)
        }
        return Elicitation.RequestSchema(
            title: normalizedString(payload["title"]),
            description: normalizedString(payload["context"]),
            properties: properties,
            required: nil
        )
    }

    static func response(
        questions: [Question],
        content: [String: Value],
        elapsedSeconds: Int,
        includeLegacyResponse: Bool
    ) -> Value {
        var answers: [String: Value] = [:]
        for question in questions {
            let values = strings(content[question.id])
            let optionSet = Set(question.optionLabels)
            let selected = values.filter(optionSet.contains)
            let custom = values.first { !optionSet.contains($0) }
            answers[question.id] = answer(
                values: values,
                selected: selected,
                custom: custom,
                skipped: values.isEmpty
            )
        }
        var object: [String: Value] = [
            "answers": .object(answers),
            "timed_out": .bool(false),
            "skipped": .bool(false),
            "elapsed_seconds": .int(elapsedSeconds)
        ]
        if includeLegacyResponse {
            object["response"] = strings(content["response"]).first.map(Value.string) ?? .null
        }
        return .object(object)
    }

    private static func skippedResponse(
        questions: [Question],
        elapsedSeconds: Int,
        includeLegacyResponse: Bool
    ) -> Value {
        var answers: [String: Value] = [:]
        for question in questions {
            answers[question.id] = answer(values: [], selected: [], custom: nil, skipped: true)
        }
        var object: [String: Value] = [
            "answers": .object(answers),
            "timed_out": .bool(false),
            "skipped": .bool(true),
            "elapsed_seconds": .int(elapsedSeconds)
        ]
        if includeLegacyResponse {
            object["response"] = .null
        }
        return .object(object)
    }

    private static func answer(
        values: [String],
        selected: [String],
        custom: String?,
        skipped: Bool
    ) -> Value {
        .object([
            "answers": .array(values.map(Value.string)),
            "selected_options": .array(selected.map(Value.string)),
            "custom_response": custom.map(Value.string) ?? .null,
            "skipped": .bool(skipped)
        ])
    }

    private static func message(from payload: [String: Value], questions: [Question]) -> String {
        var parts: [String] = []
        if let title = normalizedString(payload["title"]) {
            parts.append(title)
        }
        if let context = normalizedString(payload["context"]) {
            parts.append(context)
        }
        parts.append(contentsOf: questions.map(\.text))
        return parts.joined(separator: "\n\n")
    }

    private static func strings(_ value: Value?) -> [String] {
        guard let value else { return [] }
        if let string = normalizedString(value) { return [string] }
        return value.arrayValue?.compactMap(normalizedString) ?? []
    }

    private static func normalizedString(_ value: Value?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else {
            return nil
        }
        return string
    }
}
