import Foundation
import RepoPromptDomainRuntime

struct OracleMemberPresentation: Equatable {
    enum Status: String {
        case streaming = "In progress"
        case settled = "Settled · awaiting group"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case unknown = "Status unknown"
    }

    let status: Status
    var errorMessage: String?
    var providerID: String?
    var capturedModelName: String?
    var elapsedSeconds: Double?

    static let unknown = Self(status: .unknown)
}

/// A small, transient projection of one canonical turn, not another outcome store.
struct OracleGroupPresentation: Equatable {
    struct Key: Hashable {
        let groupID: OracleGroupID
        let owner: OracleConversationOwner

        @MainActor
        init?(session: ChatSession) {
            guard let groupID = session.oracleGroupID, let tabID = session.composeTabID,
                  let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: session.workspaceID, tabID: tabID)
            else { return nil }
            self.init(groupID: OracleGroupID(rawValue: groupID), owner: owner)
        }

        init(groupID: OracleGroupID, owner: OracleConversationOwner) {
            self.groupID = groupID
            self.owner = owner
        }
    }

    let key: Key
    let revision: UInt64
    let turnID: OracleTurnID?
    let isTerminal: Bool
    let members: [OracleGroupMember]
    private(set) var lanes: [OracleLaneID: OracleMemberPresentation]
    /// The existing app runtime invocation is evidence for live events, unlike a loaded prepared record.
    var invocationID: UUID?
    private(set) var timing: OracleGroupTiming?
    private(set) var timingRevision: UInt64 = 0
    private let elapsedSeconds: Double?
    private var sequences: [OracleLaneID: UInt64] = [:]

    init(document: OracleGroupDocument, invocationID: UUID? = nil, timing: OracleGroupTiming? = nil) {
        key = Key(groupID: document.group.id, owner: document.owner)
        revision = document.revision
        turnID = document.turns.last?.id
        isTerminal = document.turns.last?.state == .terminal
        members = document.members
        self.invocationID = isTerminal ? nil : invocationID
        elapsedSeconds = isTerminal ? document.turns.last?.elapsedSeconds : nil
        if !isTerminal, let timing, timing.invocationID == invocationID,
           timing.group == document.group, timing.turnID == turnID,
           timing.laneIDs == document.members.map(\.laneID)
        {
            self.timing = timing
            timingRevision = timing.read(.group).revision
        }
        lanes = [:]
        if isTerminal, let turn = document.turns.last {
            for member in members {
                guard let result = turn.results.first(where: {
                    $0.laneIndex == member.laneID.index && $0.chatID == member.publicChatID
                }) else { continue }
                let status: OracleMemberPresentation.Status = switch result.status {
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
                lanes[member.laneID] = OracleMemberPresentation(
                    status: status,
                    errorMessage: result.error.map { "[\($0.code)] \($0.message)" },
                    providerID: result.executionProfile?.providerID ?? result.providerID ?? member.model.providerID,
                    capturedModelName: result.capturedModelName,
                    elapsedSeconds: result.elapsedSeconds
                )
            }
        }
    }

    @MainActor
    func matchingMember(_ session: ChatSession) -> OracleGroupMember? {
        guard Key(session: session) == key,
              let member = members.first(where: { $0.memberID.rawValue == session.id }),
              session.shortID == member.publicChatID,
              session.oracleLaneIndex == member.laneID.index,
              session.oracleGroupSize == members.count,
              session.oracleModelRaw == member.model.modelID
        else { return nil }
        return member
    }

    @MainActor
    func member(_ session: ChatSession) -> OracleMemberPresentation {
        guard let member = matchingMember(session) else { return .unknown }
        var presentation = lanes[member.laneID] ?? .unknown
        presentation.providerID = presentation.providerID ?? member.model.providerID
        return presentation
    }

    mutating func captureModelName(
        _ name: String?,
        providerID: String? = nil,
        member: OracleGroupMember,
        turnID: OracleTurnID,
        invocationID: UUID
    ) {
        guard !isTerminal, self.invocationID == invocationID, self.turnID == turnID,
              members.contains(member)
        else { return }
        var presentation = lanes[member.laneID] ?? .unknown
        presentation.capturedModelName = name
        presentation.providerID = providerID ?? presentation.providerID
        lanes[member.laneID] = presentation
    }

    mutating func receive(_ event: OracleProgressEvent) {
        guard invocationID != nil, !isTerminal,
              event.groupID == key.groupID, event.turnID == turnID,
              event.kind == .laneStarted || event.kind == .laneSettled,
              let laneID = event.laneID, members.contains(where: { $0.laneID == laneID }),
              let sequence = event.sequence,
              sequences[laneID].map({ sequence > $0 }) ?? true
        else { return }
        sequences[laneID] = sequence
        // Settlement is live, nonterminal evidence; only durable results establish an outcome.
        let capturedModelName = lanes[laneID]?.capturedModelName
        let providerID = lanes[laneID]?.providerID
        lanes[laneID] = .init(
            status: event.kind == .laneStarted ? .streaming : .settled,
            providerID: providerID,
            capturedModelName: capturedModelName
        )
    }

    /// Reads the runtime authority, never a copied anchor. Ended invocations cannot tick.
    func elapsedSample(_ slot: OracleGroupTiming.Slot) -> OracleGroupTiming.Sample {
        if isTerminal {
            let seconds: Double? = switch slot {
            case .group: elapsedSeconds
            case let .lane(id): lanes[id]?.elapsedSeconds
            }
            return seconds.map(OracleGroupTiming.Sample.frozen) ?? .unavailable
        }
        guard let timing else { return .unavailable }
        let sample = timing.read(slot).sample
        if case .running = sample, invocationID != timing.invocationID { return .unavailable }
        return sample
    }

    mutating func timingChanged(_ handle: OracleGroupTiming, invocationID: UUID) {
        guard !isTerminal, timing === handle, handle.invocationID == invocationID,
              handle.groupID == key.groupID, handle.turnID == turnID,
              handle.laneIDs == members.map(\.laneID),
              self.invocationID == nil || self.invocationID == invocationID else { return }
        timingRevision = handle.read(.group).revision
    }

    mutating func endExecution() {
        invocationID = nil
        if !isTerminal { lanes = [:] }
    }
}
