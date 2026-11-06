import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// What the rewriter may know about a file sent with a message: its name and kind, never its
/// contents or absolute location. Tagged files use the workspace-relative path the user tagged.
struct AgentRepromptAttachment: Codable, Equatable {
    static let limit = 20
    static let maximumEncodedBytes = 8 * 1024
    private static let nameBytes = 200
    private static let taggedFileKind = "taggedFile"

    let name: String
    let kind: String

    static func list(files: [AgentFileAttachment], tagged: [AgentTaggedFileAttachment]) -> [Self] {
        let all = files.map { Self(name: bounded(name(of: $0)), kind: $0.kind.rawValue) }
            + tagged.map { Self(name: bounded(name(ofTagged: $0.relativePath)), kind: taggedFileKind) }
        var entries = Array(all.prefix(limit))
        // Names are bounded in raw bytes, but JSON escaping can still grow them. An unusual file
        // name must cost a list entry, not fail the rewrite of an otherwise short draft.
        while let encoded = try? JSONEncoder().encode(entries), encoded.count > maximumEncodedBytes {
            entries.removeLast()
        }
        return entries
    }

    private static func name(of file: AgentFileAttachment) -> String {
        var name = file.facts.fileName
        if name.isEmpty {
            switch file.source {
            case let .localFile(path): name = path
            case let .url(value): name = URL(string: value)?.lastPathComponent ?? ""
            }
        }
        // A decoded URL component can itself contain separators.
        let component = AttachmentFacts.lastPathComponent(name)
        return component.isEmpty ? "attachment" : component
    }

    /// A tagged path is meant to be workspace-relative; never forward an absolute one.
    private static func name(ofTagged path: String) -> String {
        path.hasPrefix("/") || path.hasPrefix("~") ? AttachmentFacts.lastPathComponent(path) : path
    }

    private static func bounded(_ name: String) -> String {
        AgentRepromptHistory.trimmed(name, bytes: nameBytes)
    }
}

struct AgentRepromptRequest: Encodable {
    struct Answer: Codable, Equatable {
        let question: String
        var selectedOption: String?
        var customText: String?
        var skipped = false
    }

    let originalText: String
    var guidance = AgentRepromptGuidance.defaultText
    var answers: [Answer]?
    var recentChat: [AgentRepromptHistory.Turn] = []
    /// Files sent with this draft. Names and kinds only.
    var attachments: [AgentRepromptAttachment] = []
    var sessionTitle: String?

    enum CodingKeys: String, CodingKey { case originalText, answers, recentChat, attachments, sessionTitle }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(originalText, forKey: .originalText)
        try values.encodeIfPresent(answers, forKey: .answers)
        if !recentChat.isEmpty {
            try values.encode(recentChat, forKey: .recentChat)
        }
        if !attachments.isEmpty {
            try values.encode(attachments, forKey: .attachments)
        }
        try values.encodeIfPresent(sessionTitle, forKey: .sessionTitle)
    }
}

struct AgentRepromptResult: Equatable {
    struct Question: Codable, Equatable {
        struct Option: Codable, Equatable {
            let label: String
            var description: String?
        }

        let id: String
        let question: String
        let options: [Option]
    }

    let body: String
    var openQuestions: [Question] = []
}

/// The body is plain Markdown. Only a complete, explicitly framed trailer is metadata.
/// A possible delimiter prefix is withheld across arbitrary provider chunk boundaries.
struct AgentRepromptStreamParser {
    static let delimiter = "\n<<<REPROMPT_QUESTIONS_V2>>>\n"
    static let endDelimiter = "\n<<<END_REPROMPT_QUESTIONS_V2>>>"
    private var raw = ""
    private(set) var body = ""

    mutating func append(_ delta: String) throws {
        guard raw.utf8.count + delta.utf8.count <= 80 * 1024 else { throw AgentRepromptError.sizeLimit }
        raw += delta
        if let range = raw.range(of: Self.delimiter) {
            body = String(raw[..<range.lowerBound])
        } else {
            var withheld = 0
            for length in 1 ..< Self.delimiter.count where raw.hasSuffix(String(Self.delimiter.prefix(length))) {
                withheld = length
            }
            body = String(raw.dropLast(withheld))
        }
        guard body.utf8.count <= 64 * 1024 else { throw AgentRepromptError.sizeLimit }
    }

    func finish(refinement: Bool) throws -> AgentRepromptResult {
        var questions: [AgentRepromptResult.Question] = []
        if let range = raw.range(of: Self.delimiter) {
            let trailer = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let end = Self.endDelimiter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailer.hasSuffix(end) else { throw AgentRepromptError.invalidResponse }
            let json = String(trailer.dropLast(end.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard json.utf8.count <= 16 * 1024,
                  let decoded = try? JSONDecoder().decode([AgentRepromptResult.Question].self, from: Data(json.utf8)),
                  decoded.count <= 1, Set(decoded.map(\.id)).count == decoded.count,
                  !refinement || decoded.isEmpty
            else { throw AgentRepromptError.invalidResponse }
            let interaction = AgentAskUserInteraction(questions: decoded.map {
                .init(id: $0.id, question: $0.question, options: $0.options.map { .init(label: $0.label, description: $0.description) })
            })
            if !decoded.isEmpty {
                do { try interaction.validate() } catch { throw AgentRepromptError.invalidResponse }
            }
            guard decoded.allSatisfy({ $0.options.count <= 3 }) else { throw AgentRepromptError.invalidResponse }
            questions = decoded
        } else if body != raw, raw != body + "\n" {
            // EOF in a delimiter prefix is truncation, not a successful brief.
            throw AgentRepromptError.invalidResponse
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentRepromptError.invalidResponse }
        return .init(body: text, openQuestions: questions)
    }
}

enum AgentRepromptError: Error, LocalizedError, Equatable {
    case missingModel, sizeLimit, timeout, invalidResponse, provider, disclosureRequired, incomplete

    var errorDescription: String? {
        switch self {
        case .disclosureRequired: "Re-prompt's data disclosure needs review. Turn Re-prompt off and on to review it, or press Return to send as typed."
        case .missingModel: "The selected Re-prompt model is unavailable. Connect it or choose another in Agent Models settings."
        case .sizeLimit: "Re-prompt text exceeds its size limit. Shorten it and try again."
        case .timeout: "Re-prompt timed out. Partial text is recoverable; retry or use the original."
        case .invalidResponse: "The rewrite ended with invalid or incomplete questions. Partial text is recoverable."
        case .provider: "The rewrite provider could not complete the request. Check its connection and credentials."
        case .incomplete: "The rewrite was truncated. Partial text is recoverable; retry or use the original."
        }
    }
}
