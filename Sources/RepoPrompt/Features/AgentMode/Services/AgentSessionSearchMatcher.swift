import Foundation

/// Shared, pure Agent-session search primitives used by the sidebar and Cmd-K HUD.
///
/// The matcher is intentionally string-in / score-out: callers decide how to map
/// their view models into fields and how to present matches. This keeps the
/// search backend reusable without coupling it to SwiftUI row types or actors.
struct AgentSessionSearchQuery: Equatable {
    let rawValue: String
    let tokens: [String]
    let normalizedTokens: [String]

    var isEmpty: Bool {
        normalizedTokens.isEmpty
    }

    static func parse(_ rawValue: String?) -> AgentSessionSearchQuery {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokens = Self.tokenize(trimmed)
        return AgentSessionSearchQuery(
            rawValue: trimmed,
            tokens: tokens,
            normalizedTokens: tokens.map(AgentSessionSearchNormalizer.normalize)
        )
    }

    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for character in query {
            if character == "\"" {
                appendToken(&tokens, current)
                current = ""
                inQuote.toggle()
            } else if character.isWhitespace, !inQuote {
                appendToken(&tokens, current)
                current = ""
            } else {
                current.append(character)
            }
        }
        appendToken(&tokens, current)
        return tokens
    }

    private static func appendToken(_ tokens: inout [String], _ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tokens.append(trimmed)
        }
    }
}

enum AgentSessionSearchFieldKind: Int, Equatable {
    case title
    case primary
    case status
    case model
    case worktree
    case secondary
    case path
    case identifier

    var baseScore: Int {
        switch self {
        case .title: 1000
        case .primary: 850
        case .model: 720
        case .worktree: 680
        case .status: 620
        case .secondary: 520
        case .path: 380
        case .identifier: 300
        }
    }
}

struct AgentSessionSearchField: Equatable {
    let text: String
    let normalizedText: String
    let kind: AgentSessionSearchFieldKind

    init(_ text: String?, kind: AgentSessionSearchFieldKind) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.text = trimmed
        normalizedText = AgentSessionSearchNormalizer.normalize(trimmed)
        self.kind = kind
    }

    var isEmpty: Bool {
        normalizedText.isEmpty
    }
}

struct AgentSessionSearchFields: Equatable {
    static let empty = AgentSessionSearchFields(fields: [])

    let fields: [AgentSessionSearchField]

    init(fields: [AgentSessionSearchField]) {
        self.fields = fields.filter { !$0.isEmpty }
    }

    init(
        title: String?,
        primary: [String?] = [],
        status: [String?] = [],
        model: [String?] = [],
        worktree: [String?] = [],
        secondary: [String?] = [],
        path: [String?] = [],
        identifier: [String?] = []
    ) {
        var fields: [AgentSessionSearchField] = []
        fields.append(AgentSessionSearchField(title, kind: .title))
        fields.append(contentsOf: primary.map { AgentSessionSearchField($0, kind: .primary) })
        fields.append(contentsOf: status.map { AgentSessionSearchField($0, kind: .status) })
        fields.append(contentsOf: model.map { AgentSessionSearchField($0, kind: .model) })
        fields.append(contentsOf: worktree.map { AgentSessionSearchField($0, kind: .worktree) })
        fields.append(contentsOf: secondary.map { AgentSessionSearchField($0, kind: .secondary) })
        fields.append(contentsOf: path.map { AgentSessionSearchField($0, kind: .path) })
        fields.append(contentsOf: identifier.map { AgentSessionSearchField($0, kind: .identifier) })
        self.init(fields: fields)
    }
}

struct AgentSessionSearchScore: Comparable, Equatable {
    let value: Int

    static func < (lhs: AgentSessionSearchScore, rhs: AgentSessionSearchScore) -> Bool {
        lhs.value < rhs.value
    }
}

enum AgentSessionSearchMatcher {
    static func score(query: AgentSessionSearchQuery, fields: AgentSessionSearchFields) -> AgentSessionSearchScore? {
        guard !query.isEmpty else { return AgentSessionSearchScore(value: 0) }
        guard !fields.fields.isEmpty else { return nil }

        var total = 0
        for token in query.normalizedTokens {
            guard let tokenScore = bestScore(for: token, fields: fields.fields) else { return nil }
            total += tokenScore
        }
        return AgentSessionSearchScore(value: total)
    }

    static func matches(query: AgentSessionSearchQuery, fields: AgentSessionSearchFields) -> Bool {
        score(query: query, fields: fields) != nil
    }

    private static func bestScore(for token: String, fields: [AgentSessionSearchField]) -> Int? {
        var best: Int?
        for field in fields {
            guard let score = score(token: token, field: field) else { continue }
            if best == nil || score > best! {
                best = score
            }
        }
        return best
    }

    private static func score(token: String, field: AgentSessionSearchField) -> Int? {
        let text = field.normalizedText
        guard !token.isEmpty, !text.isEmpty else { return nil }
        let base = field.kind.baseScore
        if text == token {
            return base + 80
        }
        if text.hasPrefix(token) {
            return base + 60
        }
        if wordPrefixes(in: text).contains(where: { $0.hasPrefix(token) }) {
            return base + 40
        }
        if text.contains(token) {
            return base + 10
        }
        return nil
    }

    private static func wordPrefixes(in normalizedText: String) -> [Substring] {
        normalizedText.split { character in
            !(character.isLetter || character.isNumber)
        }
    }
}

enum AgentSessionSearchNormalizer {
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
