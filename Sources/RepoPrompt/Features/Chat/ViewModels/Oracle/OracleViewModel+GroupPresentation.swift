import Foundation
import RepoPromptDomainRuntime

struct OracleMemberPresentation: Equatable {
    enum Status: String {
        case streaming = "In progress"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case unknown = "Status unknown"
    }

    let status: Status
    var errorMessage: String?

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
    private var sequences: [OracleLaneID: UInt64] = [:]

    init(document: OracleGroupDocument, invocationID: UUID? = nil) {
        key = Key(groupID: document.group.id, owner: document.owner)
        revision = document.revision
        turnID = document.turns.last?.id
        isTerminal = document.turns.last?.state == .terminal
        members = document.members
        self.invocationID = isTerminal ? nil : invocationID
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
                    errorMessage: result.error.map { "[\($0.code)] \($0.message)" }
                )
            }
        }
    }

    @MainActor
    func member(_ session: ChatSession) -> OracleMemberPresentation {
        guard Key(session: session) == key,
              let member = members.first(where: { $0.memberID.rawValue == session.id }),
              session.shortID == member.publicChatID,
              session.oracleLaneIndex == member.laneID.index,
              session.oracleGroupSize == members.count,
              session.oracleModelRaw == member.model.modelID
        else { return .unknown }
        return lanes[member.laneID] ?? .unknown
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
        // Settled progress precedes durable publication; it cannot establish terminal success.
        lanes[laneID] = event.kind == .laneStarted ? .init(status: .streaming) : .unknown
    }

    mutating func endExecution() {
        invocationID = nil
        if !isTerminal { lanes = [:] }
    }
}
