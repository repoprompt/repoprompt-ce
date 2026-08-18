import Foundation
import MCP
import RepoPromptDomainRuntime

struct ContextBuilderOracleMemberHandle: Equatable {
    let laneID: OracleLaneID
    let sessionID: UUID
    let chatID: String
}

/// Per-tab post-discovery group state. The generation is advanced before replacement cancellation,
/// so callbacks from an older group cannot mutate the next run while its members drain.
struct ContextBuilderOracleGroupState {
    private(set) var generation: UInt64 = 0
    private(set) var groupID: OracleGroupID?
    private(set) var turnID: OracleTurnID?
    private(set) var members: [ContextBuilderOracleMemberHandle] = []
    private var nextSequenceByLane: [OracleLaneID: UInt64] = [:]

    mutating func beginRun() -> UInt64 {
        generation &+= 1
        groupID = nil
        turnID = nil
        members = []
        nextSequenceByLane = [:]
        return generation
    }

    mutating func bind(
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        members: [ContextBuilderOracleMemberHandle],
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard generation == expectedGeneration,
              members.count >= 2,
              members.map(\.laneID.index) == Array(members.indices),
              Set(members.map(\.sessionID)).count == members.count,
              Set(members.map(\.chatID)).count == members.count
        else {
            return false
        }
        self.groupID = groupID
        self.turnID = turnID
        self.members = members
        nextSequenceByLane = [:]
        return true
    }

    mutating func accept(
        _ event: OracleProgressEvent,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard generation == expectedGeneration,
              event.groupID == groupID,
              event.turnID == turnID
        else {
            return false
        }
        guard let laneID = event.laneID else {
            return event.sequence == nil
        }
        guard members.indices.contains(laneID.index),
              members[laneID.index].laneID == laneID,
              let sequence = event.sequence,
              sequence == nextSequenceByLane[laneID, default: 0]
        else {
            return false
        }
        nextSequenceByLane[laneID] = sequence &+ 1
        return true
    }

    func acceptsLaneCallback(_ laneID: OracleLaneID, generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
            && members.indices.contains(laneID.index)
            && members[laneID.index].laneID == laneID
    }

    mutating func invalidateAndTakeMembers() -> [ContextBuilderOracleMemberHandle] {
        generation &+= 1
        let cancelledMembers = members
        groupID = nil
        turnID = nil
        members = []
        nextSequenceByLane = [:]
        return cancelledMembers
    }

    mutating func finish(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        groupID = nil
        turnID = nil
        members = []
        nextSequenceByLane = [:]
    }
}

struct ContextBuilderFrozenOraclePack {
    static let evidenceCitationInstructions = "Cite each important factual claim with one or more tool-ready `path:start-end` references drawn from the frozen Context Builder evidence. Label each cited claim as a direct observation or an inference. For an inference, identify and cite the supporting observations. Ground important recommendations in those cited claims."

    static var reviewAdviserInstructions: String {
        """
        Review the frozen package independently. Check the task's exact requirements against observed evidence.
        Treat command and test output as stronger evidence than claims of success, and flag unresolved errors or failed verification.
        Report concrete correctness, regression, state-safety, and test gaps with file references. Do not synthesize other Oracle answers.

        \(evidenceCitationInstructions)
        """
    }

    let message: AIMessage
    let input: OracleInput
    let reference: OracleFrozenPackReference
    let reservation: OracleArtifactReservation
    let data: Data

    @MainActor
    static func make(
        mode: HeadlessMode,
        prompt: String,
        selection: StoredSelection,
        message: AIMessage,
        store: DomainOracleConversationStore
    ) async throws -> Self {
        let oracleMode = mode.oracleMode
        let pack = try OracleFrozenContextPack(
            mode: oracleMode,
            content: render(message),
            provenance: selection.selectedPaths.map { OracleEvidenceReference(path: $0) }
        )
        let data = try pack.canonicalData()
        let reservation = try await store.reserveArtifact(data)
        do {
            let reference = try OracleFrozenPackReference(artifactID: reservation.artifactID)
            let input = try OracleInput(
                mode: oracleMode,
                userMessage: prompt,
                context: OracleContextEnvelope(
                    content: .durableArtifact(id: reservation.artifactID),
                    sha256: reservation.artifactID,
                    provenance: pack.provenance
                )
            )
            return Self(message: message, input: input, reference: reference, reservation: reservation, data: data)
        } catch {
            try await store.releaseArtifactReservation(reservation, removeIfUnreferenced: true)
            throw error
        }
    }

    static func prompt(for mode: HeadlessMode, prompt: String) -> String {
        switch mode {
        case .plan:
            prompt + "\n\n" + evidenceCitationInstructions
        case .review:
            prompt + "\n\n" + reviewAdviserInstructions
        case .chat:
            prompt
        }
    }

    static func render(_ message: AIMessage) -> String {
        var sections: [String] = []
        if !message.systemPrompt.isEmpty {
            sections.append("<system_prompt>\n\(message.systemPrompt)\n</system_prompt>")
        }
        let context = message.buildTail(embedSystemPrompt: false)
        if !context.isEmpty {
            sections.append("<context>\n\(context)\n</context>")
        }
        if !message.conversationMessages.isEmpty {
            let conversation = message.conversationMessages.map { entry in
                let role = entry.role == .user ? "user" : "assistant"
                return "<message role=\"\(role)\">\n\(entry.content)\n</message>"
            }.joined(separator: "\n")
            sections.append("<conversation>\n\(conversation)\n</conversation>")
        }
        return sections.joined(separator: "\n\n")
    }
}

struct ContextBuilderOracleGroupReply: Codable, Equatable {
    let result: OracleGroupResult

    var orderedResults: [OracleLaneResult] {
        result.oracleResults
    }

    func toMCPFields() -> [String: Value] {
        OracleGroupMCPCodec.groupFields(result)
    }

    static func decode(_ object: [String: Value]) throws -> Self {
        guard let groupRaw = object["oracle_group_id"]?.stringValue,
              let groupID = UUID(uuidString: groupRaw),
              let statusRaw = object["status"]?.stringValue,
              let status = OracleGroupStatus(rawValue: statusRaw),
              let laneValues = object["oracle_results"]?.arrayValue
        else {
            throw ChatToolError.internalError("Invalid Context Builder Oracle group result")
        }
        let results = try laneValues.map(decodeLane)
        guard object["oracle_count"]?.intValue == results.count else {
            throw ChatToolError.internalError("Invalid Context Builder Oracle group count")
        }
        let warnings = try (object["warnings"]?.arrayValue ?? []).map { value in
            guard let warning = value.objectValue,
                  let code = warning["code"]?.stringValue,
                  let message = warning["message"]?.stringValue
            else {
                throw ChatToolError.internalError("Invalid Context Builder Oracle group warning")
            }
            return OracleGroupWarning(code: code, message: message)
        }
        return try Self(result: OracleGroupResult(
            groupID: OracleGroupID(rawValue: groupID),
            status: status,
            oracleResults: results,
            warnings: warnings
        ))
    }

    private static func decodeLane(_ value: Value) throws -> OracleLaneResult {
        guard let lane = value.objectValue,
              let laneIndex = lane["lane_index"]?.intValue,
              let roleRaw = lane["role"]?.stringValue,
              let role = OracleLaneRole(rawValue: roleRaw),
              let chatID = lane["chat_id"]?.stringValue,
              let modelID = lane["model_id"]?.stringValue,
              let statusRaw = lane["status"]?.stringValue,
              let status = OracleLaneResultStatus(rawValue: statusRaw)
        else {
            throw ChatToolError.internalError("Invalid Context Builder Oracle lane result")
        }
        let expectedRole: OracleLaneRole = laneIndex == 0 ? .primary : .additional
        guard role == expectedRole else {
            throw ChatToolError.internalError("Invalid Context Builder Oracle lane role")
        }
        let error: OracleLaneError? = if let errorValue = lane["error"]?.objectValue,
                                         let code = errorValue["code"]?.stringValue,
                                         let message = errorValue["message"]?.stringValue
        {
            OracleLaneError(
                code: code,
                message: message,
                partialResponse: errorValue["partial_response"]?.stringValue
            )
        } else {
            nil
        }
        return try OracleLaneResult(
            laneIndex: laneIndex,
            chatID: chatID,
            providerID: lane["provider_id"]?.stringValue,
            modelID: modelID,
            status: status,
            response: lane["response"]?.stringValue,
            error: error
        )
    }
}

extension HeadlessMode {
    var oracleMode: OracleMode {
        switch self {
        case .plan: .plan
        case .review: .review
        case .chat: .chat
        }
    }
}

enum ContextBuilderOracleGroupProgressProjection {
    static func activity(for event: OracleProgressEvent) -> (ContextBuilderMCPProgressPhase, String)? {
        guard let laneID = event.laneID else { return nil }
        let label = OracleRosterContract.displayLabel(laneIndex: laneID.index)
        switch event.kind {
        case .laneStarted:
            return (.streaming, "\(label) response streaming started")
        case .laneDelta:
            return (.streaming, "Still in \(label) response streaming")
        case .laneSettled:
            return (.messageFinalization, "\(label) settled: \(event.text ?? "unknown")")
        case .groupPrepared, .groupSettled:
            return nil
        }
    }
}
