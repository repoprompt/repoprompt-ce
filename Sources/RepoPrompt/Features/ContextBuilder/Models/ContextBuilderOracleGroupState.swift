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
    private var groupPrepared = false
    private var startedLanes: Set<OracleLaneID> = []
    private var settledLanes: Set<OracleLaneID> = []
    private var groupSettled = false

    mutating func beginRun() -> UInt64 {
        generation &+= 1
        groupID = nil
        turnID = nil
        members = []
        resetLifecycle()
        return generation
    }

    mutating func bind(
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        members: [ContextBuilderOracleMemberHandle],
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard generation == expectedGeneration,
              self.groupID == nil,
              self.turnID == nil,
              self.members.isEmpty,
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
        resetLifecycle()
        return true
    }

    mutating func accept(
        _ event: OracleProgressEvent,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard generation == expectedGeneration,
              event.groupID == groupID,
              event.turnID == turnID,
              !groupSettled
        else {
            return false
        }

        switch event.kind {
        case .groupPrepared:
            guard event.laneID == nil,
                  event.sequence == nil,
                  !groupPrepared,
                  startedLanes.isEmpty
            else {
                return false
            }
            groupPrepared = true
            return true

        case .groupSettled:
            guard event.laneID == nil,
                  event.sequence == nil,
                  groupPrepared,
                  settledLanes.count == members.count
            else {
                return false
            }
            groupSettled = true
            return true

        case .laneStarted, .laneDelta, .laneSettled:
            guard groupPrepared,
                  let laneID = event.laneID,
                  members.indices.contains(laneID.index),
                  members[laneID.index].laneID == laneID,
                  let sequence = event.sequence,
                  sequence == nextSequenceByLane[laneID, default: 0]
            else {
                return false
            }

            let lifecycleValid = switch event.kind {
            case .laneStarted:
                !startedLanes.contains(laneID) && !settledLanes.contains(laneID)
            case .laneDelta:
                startedLanes.contains(laneID) && !settledLanes.contains(laneID)
            case .laneSettled:
                startedLanes.contains(laneID) && !settledLanes.contains(laneID)
            case .groupPrepared, .groupSettled:
                false
            }
            guard lifecycleValid else { return false }

            nextSequenceByLane[laneID] = sequence &+ 1
            if event.kind == .laneStarted {
                startedLanes.insert(laneID)
            } else if event.kind == .laneSettled {
                settledLanes.insert(laneID)
            }
            return true
        }
    }

    func acceptsLaneCallback(_ laneID: OracleLaneID, generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
            && !groupSettled
            && !settledLanes.contains(laneID)
            && members.indices.contains(laneID.index)
            && members[laneID.index].laneID == laneID
    }

    func matchesFinalResult(
        _ result: OracleGroupResult,
        generation expectedGeneration: UInt64
    ) -> Bool {
        generation == expectedGeneration
            && result.groupID == groupID
            && result.oracleResults.count == members.count
            && zip(result.oracleResults, members).allSatisfy { result, member in
                result.laneIndex == member.laneID.index && result.chatID == member.chatID
            }
    }

    mutating func invalidateAndTakeMembers() -> [ContextBuilderOracleMemberHandle] {
        generation &+= 1
        let cancelledMembers = members
        groupID = nil
        turnID = nil
        members = []
        resetLifecycle()
        return cancelledMembers
    }

    mutating func finish(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        groupID = nil
        turnID = nil
        members = []
        resetLifecycle()
    }

    private mutating func resetLifecycle() {
        nextSequenceByLane = [:]
        groupPrepared = false
        startedLanes = []
        settledLanes = []
        groupSettled = false
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

enum ContextBuilderOraclePrimaryCompletionError: Error, LocalizedError, Equatable {
    case notCompleted(status: OracleLaneResultStatus, code: String, message: String)
    case missingResponse

    var errorDescription: String? {
        switch self {
        case let .notCompleted(status, code, message):
            "Primary Oracle did not complete successfully (status: \(status.rawValue), code: \(code)): \(message)"
        case .missingResponse:
            "Primary Oracle completed without a response."
        }
    }
}

struct ContextBuilderOracleGroupReply: Codable, Equatable {
    let result: OracleGroupResult

    var orderedResults: [OracleLaneResult] {
        result.oracleResults
    }

    func requiredCompletedPrimaryResponse() throws -> String {
        let primary = result.primary
        guard primary.status == .completed else {
            let error = primary.error
            throw ContextBuilderOraclePrimaryCompletionError.notCompleted(
                status: primary.status,
                code: error?.code ?? "oracle_primary_not_completed",
                message: error?.message ?? "Primary Oracle did not complete successfully."
            )
        }
        guard let response = primary.response,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ContextBuilderOraclePrimaryCompletionError.missingResponse
        }
        return response
    }

    func toMCPFields() -> [String: Value] {
        OracleGroupMCPCodec.groupFields(result)
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
