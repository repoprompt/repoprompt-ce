import Foundation

public enum AgentPresentationToolStatus: String, Codable, Hashable, Sendable {
    case pending, running, success, warning, failed, cancelled, unknown
}

public struct AgentPresentationToolWire: Codable, Hashable, Sendable {
    public let executionID: String
    public let name: String
    public let status: AgentPresentationToolStatus
    public let summary: String?
    public let displayArguments: String?
    public let displayResult: String?
    public let keyPaths: [String]
    public let processID: Int?
    public let exitCode: Int?

    public init(executionID: String, name: String, status: AgentPresentationToolStatus, summary: String? = nil, displayArguments: String? = nil, displayResult: String? = nil, keyPaths: [String] = [], processID: Int? = nil, exitCode: Int? = nil) {
        self.executionID = executionID
        self.name = name
        self.status = status
        self.summary = summary
        self.displayArguments = displayArguments
        self.displayResult = displayResult
        self.keyPaths = keyPaths
        self.processID = processID
        self.exitCode = exitCode
    }

    private enum CodingKeys: String, CodingKey { case executionID = "executionId", name, status, summary, displayArguments, displayResult, keyPaths
        case processID = "processId"
        case exitCode
    }
}

public enum AgentPresentationRowWire: Codable, Hashable, Sendable {
    case userRequest(id: String, text: String, attachmentIDs: [UUID], taggedFiles: [ComposerTaggedFileReferenceWire])
    case assistant(id: String, text: String)
    case thinking(id: String, text: String)
    case progress(id: String, text: String)
    case tool(id: String, tool: AgentPresentationToolWire)
    case note(id: String, text: String)
    case error(id: String, text: String, code: String?)

    private enum CodingKeys: String, CodingKey { case type, id, text, attachmentIDs, taggedFiles, tool, code }
    private enum Kind: String, Codable { case userRequest, assistant, thinking, progress, tool, note, error }

    public var id: String {
        switch self {
        case let .userRequest(id, _, _, _), let .assistant(id, _), let .thinking(id, _), let .progress(id, _), let .tool(id, _), let .note(id, _), let .error(id, _, _): id
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        switch try values.decode(Kind.self, forKey: .type) {
        case .userRequest: self = try .userRequest(id: id, text: values.decode(String.self, forKey: .text), attachmentIDs: values.decodeIfPresent([UUID].self, forKey: .attachmentIDs) ?? [], taggedFiles: values.decodeIfPresent([ComposerTaggedFileReferenceWire].self, forKey: .taggedFiles) ?? [])
        case .assistant: self = try .assistant(id: id, text: values.decode(String.self, forKey: .text))
        case .thinking: self = try .thinking(id: id, text: values.decode(String.self, forKey: .text))
        case .progress: self = try .progress(id: id, text: values.decode(String.self, forKey: .text))
        case .tool: self = try .tool(id: id, tool: values.decode(AgentPresentationToolWire.self, forKey: .tool))
        case .note: self = try .note(id: id, text: values.decode(String.self, forKey: .text))
        case .error: self = try .error(id: id, text: values.decode(String.self, forKey: .text), code: values.decodeIfPresent(String.self, forKey: .code))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .userRequest(id, text, attachmentIDs, taggedFiles):
            try values.encode(Kind.userRequest, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(text, forKey: .text)
            try values.encode(attachmentIDs, forKey: .attachmentIDs)
            try values.encode(taggedFiles, forKey: .taggedFiles)
        case let .assistant(id, text): try encodeText(.assistant, id: id, text: text, into: &values)
        case let .thinking(id, text): try encodeText(.thinking, id: id, text: text, into: &values)
        case let .progress(id, text): try encodeText(.progress, id: id, text: text, into: &values)
        case let .tool(id, tool): try values.encode(Kind.tool, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(tool, forKey: .tool)
        case let .note(id, text): try encodeText(.note, id: id, text: text, into: &values)
        case let .error(id, text, code): try encodeText(.error, id: id, text: text, into: &values)
            try values.encodeIfPresent(code, forKey: .code)
        }
    }

    private func encodeText(_ kind: Kind, id: String, text: String, into values: inout KeyedEncodingContainer<CodingKeys>) throws {
        try values.encode(kind, forKey: .type)
        try values.encode(id, forKey: .id)
        try values.encode(text, forKey: .text)
    }
}

public struct AgentActivityClusterSummaryWire: Codable, Hashable, Sendable {
    public let activityCount: Int
    public let toolCount: Int
    public let toolGroups: [String]
    public let keyPaths: [String]
    public let running: Bool
    public let warning: Bool
    public let failed: Bool
    public let narration: String?
    public let title: String
    public let iconSemantic: String
    public let defaultExpanded: Bool

    public init(activityCount: Int, toolCount: Int, toolGroups: [String] = [], keyPaths: [String] = [], running: Bool = false, warning: Bool = false, failed: Bool = false, narration: String? = nil, title: String, iconSemantic: String = "activity", defaultExpanded: Bool = false) {
        self.activityCount = activityCount
        self.toolCount = toolCount
        self.toolGroups = toolGroups
        self.keyPaths = keyPaths
        self.running = running
        self.warning = warning
        self.failed = failed
        self.narration = narration
        self.title = title
        self.iconSemantic = iconSemantic
        self.defaultExpanded = defaultExpanded
    }
}

public enum AgentPresentationBlockWire: Codable, Hashable, Sendable {
    case request(id: String, row: AgentPresentationRowWire)
    case activityCluster(id: String, rows: [AgentPresentationRowWire], summary: AgentActivityClusterSummaryWire)
    case groupedHistory(id: String, rows: [AgentPresentationRowWire], title: String)
    case collapsedHistoryRange(id: String, count: Int, title: String)
    case standaloneAssistant(id: String, row: AgentPresentationRowWire)
    case standaloneTool(id: String, row: AgentPresentationRowWire)
    case standaloneNote(id: String, row: AgentPresentationRowWire)
    case middleSummary(id: String, text: String)
    case conclusion(id: String, row: AgentPresentationRowWire)

    private enum CodingKeys: String, CodingKey { case type, id, row, rows, summary, title, count, text }
    private enum Kind: String, Codable { case request, activityCluster, groupedHistory, collapsedHistoryRange, standaloneAssistant, standaloneTool, standaloneNote, middleSummary, conclusion }

    public var id: String {
        switch self {
        case let .request(id, _), let .activityCluster(id, _, _), let .groupedHistory(id, _, _), let .collapsedHistoryRange(id, _, _), let .standaloneAssistant(id, _), let .standaloneTool(id, _), let .standaloneNote(id, _), let .middleSummary(id, _), let .conclusion(id, _): id
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        switch try values.decode(Kind.self, forKey: .type) {
        case .request: self = try .request(id: id, row: values.decode(AgentPresentationRowWire.self, forKey: .row))
        case .activityCluster: self = try .activityCluster(id: id, rows: values.decode([AgentPresentationRowWire].self, forKey: .rows), summary: values.decode(AgentActivityClusterSummaryWire.self, forKey: .summary))
        case .groupedHistory: self = try .groupedHistory(id: id, rows: values.decode([AgentPresentationRowWire].self, forKey: .rows), title: values.decode(String.self, forKey: .title))
        case .collapsedHistoryRange: self = try .collapsedHistoryRange(id: id, count: values.decode(Int.self, forKey: .count), title: values.decode(String.self, forKey: .title))
        case .standaloneAssistant: self = try .standaloneAssistant(id: id, row: values.decode(AgentPresentationRowWire.self, forKey: .row))
        case .standaloneTool: self = try .standaloneTool(id: id, row: values.decode(AgentPresentationRowWire.self, forKey: .row))
        case .standaloneNote: self = try .standaloneNote(id: id, row: values.decode(AgentPresentationRowWire.self, forKey: .row))
        case .middleSummary: self = try .middleSummary(id: id, text: values.decode(String.self, forKey: .text))
        case .conclusion: self = try .conclusion(id: id, row: values.decode(AgentPresentationRowWire.self, forKey: .row))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .request(id, row): try encodeRow(.request, id: id, row: row, into: &values)
        case let .activityCluster(id, rows, summary): try values.encode(Kind.activityCluster, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(rows, forKey: .rows)
            try values.encode(summary, forKey: .summary)
        case let .groupedHistory(id, rows, title): try values.encode(Kind.groupedHistory, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(rows, forKey: .rows)
            try values.encode(title, forKey: .title)
        case let .collapsedHistoryRange(id, count, title): try values.encode(Kind.collapsedHistoryRange, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(count, forKey: .count)
            try values.encode(title, forKey: .title)
        case let .standaloneAssistant(id, row): try encodeRow(.standaloneAssistant, id: id, row: row, into: &values)
        case let .standaloneTool(id, row): try encodeRow(.standaloneTool, id: id, row: row, into: &values)
        case let .standaloneNote(id, row): try encodeRow(.standaloneNote, id: id, row: row, into: &values)
        case let .middleSummary(id, text): try values.encode(Kind.middleSummary, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(text, forKey: .text)
        case let .conclusion(id, row): try encodeRow(.conclusion, id: id, row: row, into: &values)
        }
    }

    private func encodeRow(_ kind: Kind, id: String, row: AgentPresentationRowWire, into values: inout KeyedEncodingContainer<CodingKeys>) throws {
        try values.encode(kind, forKey: .type)
        try values.encode(id, forKey: .id)
        try values.encode(row, forKey: .row)
    }
}

public struct AgentPresentationInteractionWire: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case question, approval, editReview, conflict }
    public let interactionID: UUID
    public let kind: Kind
    public let state: String
    public let prompt: String
    public let choices: [String]
    public let resolution: String?
    public let turnID: String
    public let activityID: String?
    public let liveTail: Bool
    public let requiresAttention: Bool
    public let mutable: Bool
    public let revision: Int64

    public init(interactionID: UUID, kind: Kind, state: String, prompt: String, choices: [String] = [], resolution: String? = nil, turnID: String, activityID: String? = nil, liveTail: Bool = false, requiresAttention: Bool = true, mutable: Bool, revision: Int64) {
        self.interactionID = interactionID
        self.kind = kind
        self.state = state
        self.prompt = prompt
        self.choices = choices
        self.resolution = resolution
        self.turnID = turnID
        self.activityID = activityID
        self.liveTail = liveTail
        self.requiresAttention = requiresAttention
        self.mutable = mutable
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case interactionID = "interactionId", kind, state, prompt, choices, resolution, turnID = "turnId", activityID = "activityId", liveTail, requiresAttention, mutable, revision }
}

public struct AgentPresentationTurnWire: Codable, Hashable, Sendable {
    public let turnID: String
    public let responseSpanID: String?
    public let requestAnchorID: UUID?
    public let terminalState: String?
    public let blocks: [AgentPresentationBlockWire]
    public let interactions: [AgentPresentationInteractionWire]
    public let legacyStandalone: Bool

    public init(turnID: String, responseSpanID: String? = nil, requestAnchorID: UUID? = nil, terminalState: String? = nil, blocks: [AgentPresentationBlockWire], interactions: [AgentPresentationInteractionWire] = [], legacyStandalone: Bool = false) {
        self.turnID = turnID
        self.responseSpanID = responseSpanID
        self.requestAnchorID = requestAnchorID
        self.terminalState = terminalState
        self.blocks = blocks
        self.interactions = interactions
        self.legacyStandalone = legacyStandalone
    }

    private enum CodingKeys: String, CodingKey { case turnID = "turnId", responseSpanID = "responseSpanId", requestAnchorID = "requestAnchorId", terminalState, blocks, interactions, legacyStandalone }
}

public struct AgentTranscriptPresentationPageWire: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let presentationRevision: Int64
    public let presentationCursor: String
    public let turns: [AgentPresentationTurnWire]
    public let nextPageToken: String?
    public let pendingInteractions: [AgentPresentationInteractionWire]

    public init(schemaVersion: Int = 1, presentationRevision: Int64, presentationCursor: String, turns: [AgentPresentationTurnWire], nextPageToken: String? = nil, pendingInteractions: [AgentPresentationInteractionWire] = []) {
        self.schemaVersion = schemaVersion
        self.presentationRevision = presentationRevision
        self.presentationCursor = presentationCursor
        self.turns = turns
        self.nextPageToken = nextPageToken
        self.pendingInteractions = pendingInteractions
    }
}
