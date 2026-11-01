import Foundation

/// Title metadata is additive to the session format. Raw JSON is retained so that an older reader
/// cannot erase future fields (or turn an unreadable ownership record into an automatic title).
struct AgentSessionTitleMetadata: Codable, Equatable {
    private var raw: AgentSessionTitleJSON
    /// Sidebar projections read this repeatedly; decode once per envelope, not per row refresh.
    private var understoodState: AgentSessionTitleState?

    init(_ state: AgentSessionTitleState) throws {
        raw = try JSONDecoder().decode(AgentSessionTitleJSON.self, from: JSONEncoder().encode(state))
        understoodState = state.isUnderstood ? state : nil
    }

    init(from decoder: Decoder) throws {
        raw = try AgentSessionTitleJSON(from: decoder)
        understoodState = Self.decodeState(raw)
    }

    func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    var state: AgentSessionTitleState? {
        understoodState
    }

    private static func decodeState(_ raw: AgentSessionTitleJSON) -> AgentSessionTitleState? {
        guard let data = try? JSONEncoder().encode(raw),
              let value = try? JSONDecoder().decode(AgentSessionTitleState.self, from: data),
              value.isUnderstood
        else { return nil }
        return value
    }

    var isMalformedCurrentVersion: Bool {
        guard case let .object(fields) = raw else { return false }
        return fields["metadataVersion"] == .unsigned(1) && state == nil
    }

    var revision: UInt64? {
        guard case let .object(fields) = raw, case let .unsigned(value) = fields["revision"] else { return nil }
        return value
    }

    func replacingState(_ state: AgentSessionTitleState) throws -> Self {
        var result = try Self(state)
        result.raw = raw.mergingKnownFields(result.raw)
        result.understoodState = Self.decodeState(result.raw)
        return result
    }
}

/// Unlike a Double-backed JSON value, this keeps all UInt64 revisions/PR identifiers exact.
private indirect enum AgentSessionTitleJSON: Codable, Equatable {
    case null, bool(Bool), unsigned(UInt64), signed(Int64), decimal(Decimal), string(String)
    case array([Self]), object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(UInt64.self) { self = .unsigned(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .signed(decoded) }
        else if let decoded = try? value.decode(Decimal.self) { self = .decimal(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: Self].self) { self = .object(decoded) }
        else { self = try .array(value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(decoded): try value.encode(decoded)
        case let .unsigned(decoded): try value.encode(decoded)
        case let .signed(decoded): try value.encode(decoded)
        case let .decimal(decoded): try value.encode(decoded)
        case let .string(decoded): try value.encode(decoded)
        case let .array(decoded): try value.encode(decoded)
        case let .object(decoded): try value.encode(decoded)
        }
    }

    func mergingKnownFields(_ replacement: Self) -> Self {
        switch (self, replacement) {
        case let (.object(old), .object(new)):
            .object(old.merging(new) { $0.mergingKnownFields($1) })
        case let (.array(old), .array(new)):
            .array(new.map { entry in
                guard case let .object(fields) = entry, let identity = fields["identity"],
                      let prior = old.first(where: {
                          if case let .object(fields) = $0 { return fields["identity"] == identity }
                          return false
                      }) else { return entry }
                return prior.mergingKnownFields(entry)
            })
        default: replacement
        }
    }
}

struct AgentSessionTitleState: Codable, Equatable {
    var metadataVersion = 1
    var revision: UInt64 = 0
    var baseTitle: String
    var source: String
    var refinement = AgentSessionTitleRefinement()
    var pullRequests: [AgentSessionPullRequestAssociation] = []
    var suppressedPullRequests: [AgentSessionPullRequestSuppression] = []

    var isUnderstood: Bool {
        metadataVersion == 1 && !baseTitle.isEmpty
            && ["automaticPlaceholder", "automaticTaskSeed", "agentProposal", "human", "delegatedAgent", "legacyProtected"].contains(source)
            && ["awaitingFirstTask", "firstTask", "closed"].contains(refinement.phase)
            && (0 ... 2).contains(refinement.qualityRejections)
            && (refinement.phase != "firstTask" || refinement.turnID != nil)
            && pullRequests.allSatisfy { $0.identity.isValid && AgentSessionPullRequestAssociation.provenances.contains($0.provenance) }
            && suppressedPullRequests.allSatisfy { $0.identity.isValid && ["human", "delegatedAgent"].contains($0.suppressedBy) }
    }

    var displayName: String {
        AgentSessionTitleFormatter.displayName(self)
    }

    var isHumanProtected: Bool {
        source == "human" || source == "legacyProtected"
    }

    var isAutomatic: Bool {
        ["automaticPlaceholder", "automaticTaskSeed", "agentProposal"].contains(source)
    }

    static func legacy(_ name: String) -> Self {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.count > 1 && ["T", "t"].contains(String(trimmed.prefix(1))) && Int(trimmed.dropFirst()) != nil
        let placeholder = trimmed.isEmpty || ChatSession.isPlaceholderName(trimmed) || trimmed == "Agent Session" || numeric
        return Self(
            baseTitle: trimmed.isEmpty ? "Agent Session" : name,
            source: placeholder ? "automaticPlaceholder" : "legacyProtected"
        )
    }
}

struct AgentSessionTitleRefinement: Codable, Equatable {
    var phase = "awaitingFirstTask"
    var turnID: UUID?
    var qualityRejections = 0
}

struct AgentSessionTitleProjection: Codable, Equatable {
    var sessionID: UUID?
    var titleMetadata: AgentSessionTitleMetadata
}

struct AgentSessionPullRequestIdentity: Codable, Equatable, Hashable, Comparable {
    var host: String
    var owner: String
    var repository: String
    var number: UInt64

    var url: String {
        "https://\(host)/\(owner)/\(repository)/pull/\(number)"
    }

    var isValid: Bool {
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let validComponent: (String) -> Bool = { !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(characters.contains) }
        return number > 0 && !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            && host.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains)
            && validComponent(owner) && validComponent(repository)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.host != rhs.host { return lhs.host < rhs.host }
        if lhs.owner != rhs.owner { return lhs.owner < rhs.owner }
        if lhs.repository != rhs.repository { return lhs.repository < rhs.repository }
        return lhs.number < rhs.number
    }

    init(url: String, trustedHosts: Set<String> = ["github.com"]) throws {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), trustedHosts.contains(host)
        else { throw AgentSessionTitleError.denied("unsupported_pr_url") }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[3] == "pull",
              !parts[1].isEmpty, !parts[2].isEmpty,
              parts[1 ... 2].allSatisfy({ $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) } }),
              parts[4].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(parts[4]), number > 0
        else { throw AgentSessionTitleError.denied("invalid_pr_url") }
        self.host = host
        owner = parts[1].lowercased()
        repository = parts[2].lowercased()
        self.number = number
    }
}

struct AgentSessionPullRequestAssociation: Codable, Equatable {
    static let provenances: Set<String> = ["structuredCreation", "agentReportedCreation", "agentReportedAssociation", "humanAssociation", "delegatedAgentAssociation", "observedShellCreation"]
    var identity: AgentSessionPullRequestIdentity
    var provenance: String
    var firstAssociatedAt: Date
    var executionID: String?
}

struct AgentSessionPullRequestSuppression: Codable, Equatable {
    var identity: AgentSessionPullRequestIdentity
    var suppressedBy: String
    var removedAt: Date
}

enum AgentSessionTitleFormatter {
    static func prefix(_ state: AgentSessionTitleState) -> String? {
        let identities = Set(state.pullRequests.map(\.identity)).sorted()
        guard !identities.isEmpty else { return nil }
        let repositories = Set(identities.map { "\($0.host)/\($0.owner)/\($0.repository)" })
        let multipleHosts = Set(identities.map(\.host)).count > 1
        let values = identities.map { identity in
            if repositories.count == 1 { return "#\(identity.number)" }
            return "\(multipleHosts ? identity.host + "/" : "")\(identity.owner)/\(identity.repository)#\(identity.number)"
        }
        return "PR " + values.joined(separator: ", ")
    }

    static func displayName(_ state: AgentSessionTitleState) -> String {
        prefix(state).map { $0 + " — " + state.baseTitle } ?? state.baseTitle
    }
}

struct AgentSessionTitleSnapshot: Equatable {
    var metadata: AgentSessionTitleMetadata?
    var name: String
    var persistenceState: String
    var revision: UInt64 {
        metadata?.revision ?? 0
    }
}

enum AgentSessionTitleError: Error, Equatable, LocalizedError {
    case denied(String)
    case conflict
    var errorDescription: String? {
        switch self { case let .denied(reason): reason
        case .conflict: "title_revision_conflict" }
    }
}

enum AgentSessionTitleCommand {
    case humanRename(String)
    case adminRename(String)
    case seed(String, turnID: UUID)
    case startupProposal(String)
    case agentProposal(String, turnID: UUID)
    case closeRefinement(turnID: UUID)
    case associate([AgentSessionPullRequestAssociation], human: Bool)
    case correct(add: [AgentSessionPullRequestAssociation], remove: [AgentSessionPullRequestIdentity], human: Bool)
    case restore(AgentSessionTitleMetadata)
}

enum AgentSessionTitlePolicy {
    static let activityLeads = ["working on", "looking into", "prepare", "preparing", "run", "running", "thinking", "investigating", "starting", "continuing", "finishing", "waiting"]
    private static let wrappers: Set<String> = ["deep plan mode", "plan", "task", "instructions", "context", "goal"]

    static func normalizedAutomatic(_ value: String) -> String {
        String(value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(64))
    }

    static func activityLead(_ text: String) -> String? {
        let lower = text.lowercased()
        return activityLeads.first { lower == $0 || lower.hasPrefix($0 + " ") }
    }

    static func seed(from payload: String) -> String? {
        var text = payload
        for tag in ["context", "file_map", "selected_files", "system-reminder"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)(?:\\s[^>]*)?>.*?(?:</\(tag)>|$)", with: "", options: .regularExpression)
        }
        if let range = text.range(of: "(?is)<task>(.*?)</task>", options: .regularExpression) {
            text = String(text[range]).replacingOccurrences(of: "(?is)</?task>", with: "", options: .regularExpression)
        }
        var inFence = false
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("```") { inFence.toggle()
                return nil
            }
            guard !inFence, !value.hasPrefix(">"), !value.hasPrefix("<"), !value.isEmpty else { return nil }
            let cleaned = value.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)^(plan|task|goal):\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            guard !wrappers.contains(cleaned.lowercased()),
                  !["you are", "act as", "read ", "review ", "exact requested model", "$ ", "git ", "gh ", "make ", "swift ", "./"].contains(where: { cleaned.lowercased().hasPrefix($0) })
            else { return nil }
            return value.hasPrefix("#") ? "#" + cleaned : cleaned
        }
        guard var value = lines.first(where: { $0.hasPrefix("#") })?.dropFirst().description ?? lines.first else { return nil }
        if let lead = activityLead(value) { value = String(value.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces) }
        value = value.replacingOccurrences(of: "\\s*\\([^()]*\\)\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        value = normalizedAutomatic(value)
        guard !value.isEmpty else { return nil }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    /// Returns a new envelope only for an actual metadata change. Rejected quality proposals can
    /// advance the bounded rejection counter, but never change the displayed base.
    static func apply(_ command: AgentSessionTitleCommand, to metadata: AgentSessionTitleMetadata?, name: String, now: Date = Date()) throws -> AgentSessionTitleMetadata? {
        var state: AgentSessionTitleState
        if let metadata {
            guard let decoded = metadata.state else { throw AgentSessionTitleError.denied("unsupported_title_metadata") }
            state = decoded
        } else { state = .legacy(name) }
        let original = state
        var envelope = metadata
        switch command {
        case let .humanRename(text), let .adminRename(text):
            let human = if case .humanRename = command { true } else { false }
            if !human, state.isHumanProtected { throw AgentSessionTitleError.denied(state.source == "human" ? "human_owned" : "legacy_protected") }
            if !human, !state.isAutomatic, state.source != "delegatedAgent" { throw AgentSessionTitleError.denied("unsupported_title_metadata") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionTitleError.denied("empty_title") }
            state.baseTitle = AgentSession.validatedName(text)
            state.source = human ? "human" : "delegatedAgent"
            state.refinement.phase = "closed"
        case let .seed(payload, turnID):
            guard state.source == "automaticPlaceholder", state.refinement.phase == "awaitingFirstTask" else { return nil }
            guard let title = seed(from: payload) else { return nil }
            state.baseTitle = title
            state.source = "automaticTaskSeed"
            state.refinement = .init(phase: "firstTask", turnID: turnID)
        case let .startupProposal(text):
            guard state.source == "automaticPlaceholder" else { return nil }
            let title = normalizedAutomatic(text)
            guard !title.isEmpty, activityLead(title) == nil,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
            else { throw AgentSessionTitleError.denied("activity_phrase") }
            state.baseTitle = title
            state.source = "agentProposal"
            state.refinement.phase = "closed"
        case let .agentProposal(text, turnID):
            guard state.isAutomatic, state.refinement.phase == "firstTask", state.refinement.turnID == turnID else {
                throw AgentSessionTitleError.denied(state.source == "human" ? "human_owned" : state.source == "legacyProtected" ? "legacy_protected" : "refinement_closed")
            }
            let title = normalizedAutomatic(text)
            guard !title.isEmpty else { throw AgentSessionTitleError.denied("empty_title") }
            if activityLead(title) != nil || text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) {
                state.refinement.qualityRejections += 1
                if state.refinement.qualityRejections >= 2 { state.refinement.phase = "closed" }
            } else {
                state.baseTitle = title
                state.source = "agentProposal"
                state.refinement.phase = "closed"
            }
        case let .closeRefinement(turnID):
            guard state.refinement.phase == "firstTask", state.refinement.turnID == turnID else { return nil }
            state.refinement.phase = "closed"
        case let .associate(additions, human):
            try associate(additions, human: human, state: &state)
        case let .correct(additions, removals, human):
            if !human, state.pullRequests.contains(where: { removals.contains($0.identity) && $0.provenance == "humanAssociation" }) {
                throw AgentSessionTitleError.denied("human_owned")
            }
            for identity in Set(removals) {
                state.pullRequests.removeAll { $0.identity == identity }
                state.suppressedPullRequests.removeAll { $0.identity == identity && (human || $0.suppressedBy != "human") }
                if !state.suppressedPullRequests.contains(where: { $0.identity == identity }) {
                    state.suppressedPullRequests.append(.init(identity: identity, suppressedBy: human ? "human" : "delegatedAgent", removedAt: now))
                }
            }
            let delegated = state.suppressedPullRequests.filter { $0.suppressedBy != "human" }.sorted { $0.removedAt < $1.removedAt }
            let evicted = Set(delegated.prefix(max(0, delegated.count - 64)).map(\.identity))
            state.suppressedPullRequests.removeAll { $0.suppressedBy != "human" && evicted.contains($0.identity) }
            try associate(additions, human: human, explicitCorrection: true, state: &state)
        case let .restore(previous):
            guard let restored = previous.state else { throw AgentSessionTitleError.denied("unsupported_title_metadata") }
            state = restored
            envelope = previous
            state.revision = original.revision
            state.refinement.phase = "closed"
        }
        guard state != original else { return nil }
        guard original.revision < UInt64.max else { throw AgentSessionTitleError.denied("title_revision_overflow") }
        state.revision = original.revision + 1
        state.pullRequests.sort { $0.identity < $1.identity }
        return try envelope?.replacingState(state) ?? AgentSessionTitleMetadata(state)
    }

    private static func associate(_ additions: [AgentSessionPullRequestAssociation], human: Bool, explicitCorrection: Bool = false, state: inout AgentSessionTitleState) throws {
        for var addition in additions {
            if let suppression = state.suppressedPullRequests.first(where: { $0.identity == addition.identity }) {
                guard human || (explicitCorrection && suppression.suppressedBy != "human") else { throw AgentSessionTitleError.denied("suppressed") }
                state.suppressedPullRequests.removeAll { $0.identity == addition.identity }
            }
            if human { addition.provenance = "humanAssociation" }
            if let index = state.pullRequests.firstIndex(where: { $0.identity == addition.identity }) {
                if human { state.pullRequests[index].provenance = "humanAssociation" }
            } else {
                guard state.pullRequests.count < 64 else { throw AgentSessionTitleError.denied("capacity") }
                guard addition.identity.isValid, AgentSessionPullRequestAssociation.provenances.contains(addition.provenance) else { throw AgentSessionTitleError.denied("invalid_pr") }
                state.pullRequests.append(addition)
            }
        }
    }
}
