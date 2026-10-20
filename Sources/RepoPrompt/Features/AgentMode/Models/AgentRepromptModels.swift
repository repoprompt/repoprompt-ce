import Foundation
import RepoPromptSettingsCore

struct AgentRepromptRequest: Encodable {
    struct Answer: Codable, Equatable {
        let question: String
        var selectedOption: String?
        var customText: String?
        var skipped: Bool = false
    }

    let originalText: String
    var manifest: String = ""
    var guidance: String = AgentRepromptGuidance.defaultText
    var contextPolicy: AgentRepromptContextPolicy = .automatic
    /// Nil is the first call; an empty array still identifies refinement.
    var answers: [Answer]?
    var consultResults: [AgentRepromptConsultResult] = []

    enum CodingKeys: String, CodingKey {
        case originalText, manifest, answers, consultResults
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalText, forKey: .originalText)
        if contextPolicy != .never {
            try container.encode(manifest, forKey: .manifest)
        }
        try container.encodeIfPresent(answers, forKey: .answers)
        try container.encode(consultResults, forKey: .consultResults)
    }
}

struct AgentRepromptConsultResult: Codable, Equatable {
    let kind: AgentRepromptContextRequest.Kind
    let status: String
    let text: String
    var chatID: String?
    var selectedFileCount: Int?
}

struct AgentRepromptContextRequest: Codable, Equatable {
    enum Kind: String, Codable { case oracle, contextBuilder }
    let kind: Kind
    var question: String?
    var instructions: String?

    var text: String {
        question ?? instructions ?? ""
    }
}

struct AgentRepromptResult: Codable, Equatable {
    struct Brief: Codable, Equatable {
        let goal: String
        let constraints: [String]
        let acceptanceCriteria: [String]
        let knownContext: [String]
        let assumptions: [String]
    }

    struct Question: Codable, Equatable {
        struct Option: Codable, Equatable {
            let label: String
            var description: String?
        }

        let id: String
        let question: String
        let options: [Option]
    }

    let version: Int
    let brief: Brief
    let openQuestions: [Question]
    let contextRequests: [AgentRepromptContextRequest]

    var renderedBrief: String {
        var sections = ["## Goal\n\(brief.goal)"]
        for (title, lines) in [
            ("Constraints", brief.constraints), ("Acceptance criteria", brief.acceptanceCriteria),
            ("Relevant known context", brief.knownContext), ("Assumptions", brief.assumptions),
            ("Open questions", openQuestions.map(\.question))
        ] where !lines.isEmpty {
            sections.append("## \(title)\n" + lines.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    static func decode(_ body: String, refinement: Bool, contextPolicy: AgentRepromptContextPolicy) throws -> Self {
        guard body.utf8.count <= 64 * 1024 else { throw AgentRepromptError.sizeLimit }
        var json = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```json\n") || json.hasPrefix("```\n") {
            guard json.hasSuffix("\n```") else { throw AgentRepromptError.invalidResponse }
            json = String(json.dropFirst(json.hasPrefix("```json") ? 8 : 4).dropLast(4))
        }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { throw AgentRepromptError.invalidResponse }
        guard result.version == 1, !result.brief.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.openQuestions.count <= 3,
              Set(result.openQuestions.map(\.id)).count == result.openQuestions.count,
              result.contextRequests.count <= 2,
              Set(result.contextRequests.map(\.kind)).count == result.contextRequests.count,
              (!refinement && contextPolicy == .automatic) || result.contextRequests.isEmpty
        else { throw AgentRepromptError.invalidResponse }
        for question in result.openQuestions {
            guard !question.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.options.count <= 4,
                  Set(question.options.map(\.label)).count == question.options.count,
                  question.options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw AgentRepromptError.invalidResponse }
        }
        if !result.openQuestions.isEmpty {
            let interaction = AgentAskUserInteraction(questions: result.openQuestions.map {
                .init(id: $0.id, question: $0.question, options: $0.options.map { .init(label: $0.label, description: $0.description) })
            })
            do { try interaction.validate() } catch { throw AgentRepromptError.invalidResponse }
        }
        for request in result.contextRequests {
            let shapeIsValid = request.kind == .oracle
                ? request.question != nil && request.instructions == nil
                : request.instructions != nil && request.question == nil
            guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, shapeIsValid
            else { throw AgentRepromptError.invalidResponse }
        }
        guard result.renderedBrief.utf8.count <= 64 * 1024 else { throw AgentRepromptError.sizeLimit }
        return result
    }
}

enum AgentRepromptError: Error, LocalizedError, Equatable {
    case missingPrimaryModel, unknownPrimaryModel, unconfiguredPrimaryModel
    case sizeLimit, timeout, invalidResponse, provider, disclosureRequired

    var errorDescription: String? {
        switch self {
        case .disclosureRequired: "Re-prompt recipients or context policy changed. Cancel and click Re-prompt to review its disclosure before retrying."
        case .missingPrimaryModel: "Choose a primary Oracle model in Agent Models settings."
        case .unknownPrimaryModel: "The primary Oracle model is unavailable. Choose another in Agent Models settings."
        case .unconfiguredPrimaryModel: "Configure credentials for the primary Oracle model in Settings."
        case .sizeLimit: "Re-prompt text exceeds its size limit. Shorten it and try again."
        case .timeout: "Re-prompt timed out. Retry or send the original message."
        case .invalidResponse: "The rewrite model returned an invalid brief. Retry or send the original message."
        case .provider: "The rewrite provider could not complete the request. Check its connection and credentials."
        }
    }
}
