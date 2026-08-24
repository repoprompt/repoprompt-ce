import Foundation
import RepoPromptDomainRuntime

enum OracleGroupLanePayloadLoader {
    enum LoadError: LocalizedError {
        case missingGroup
        case mismatchedProjection

        var errorDescription: String? {
            switch self {
            case .missingGroup:
                "Canonical Oracle group was not found."
            case .mismatchedProjection:
                "The selected chat is not a member of its canonical Oracle group."
            }
        }
    }

    @MainActor
    static func load(
        groupID: OracleGroupID,
        owner: OracleConversationOwner,
        selectedSessionID: UUID,
        sessions: [ChatSession],
        liveMessages: (UUID) -> [AIChatMessage],
        store: DomainOracleConversationStore
    ) async throws -> OracleLaneMarkdownPayload {
        guard let group = try await store.load(groupID: groupID, owner: owner) else {
            throw LoadError.missingGroup
        }
        guard group.members.contains(where: { $0.memberID.rawValue == selectedSessionID }) else {
            throw LoadError.mismatchedProjection
        }
        return payload(group: group, sessions: sessions, liveMessages: liveMessages)
    }

    static func payload(
        group: OracleGroupDocument,
        sessions: [ChatSession],
        liveMessages: (UUID) -> [AIChatMessage]
    ) -> OracleLaneMarkdownPayload {
        guard let turn = group.turns.last else {
            return OracleLaneMarkdownPayload(lanes: group.members.map(unavailableLane))
        }
        if turn.state == .terminal {
            let results = Dictionary(turn.results.map { ($0.laneIndex, $0) }, uniquingKeysWith: { first, _ in first })
            return OracleLaneMarkdownPayload(lanes: group.members.map { member in
                guard let result = results[member.laneID.index] else { return unavailableLane(member) }
                return terminalLane(result, member: member)
            })
        }

        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return OracleLaneMarkdownPayload(lanes: group.members.map { member in
            guard let session = sessionsByID[member.memberID.rawValue] else {
                return unavailableLane(member)
            }
            let content = currentAssistantContent(
                session: session,
                liveMessages: liveMessages(session.id),
                turnStartedAt: turn.startedAt
            )
            if let failure = splitFailure(content) {
                return lane(
                    member: member,
                    status: .failed,
                    partialResponse: failure.partialResponse,
                    errorCode: "runtime_error",
                    errorMessage: failure.message
                )
            }
            return lane(member: member, status: .running, partialResponse: content)
        })
    }

    private static func terminalLane(
        _ result: OracleLaneResult,
        member: OracleGroupMember
    ) -> OracleLaneMarkdownPayload.Lane {
        let profile = result.executionProfile
        return OracleLaneMarkdownPayload.Lane(
            laneIndex: member.laneID.index,
            chatID: member.publicChatID,
            providerID: profile?.providerID ?? result.providerID ?? member.model.providerID,
            modelID: profile?.modelID ?? result.modelID,
            effectiveReasoningEffort: profile?.effectiveReasoningEffort,
            status: result.status == .completed ? .completed : .failed,
            response: result.response,
            partialResponse: result.error?.partialResponse,
            errorCode: result.error?.code,
            errorMessage: result.error?.message
        )
    }

    private static func unavailableLane(_ member: OracleGroupMember) -> OracleLaneMarkdownPayload.Lane {
        lane(member: member, status: .unavailable)
    }

    private static func lane(
        member: OracleGroupMember,
        status: OracleLaneMarkdownPayload.Status,
        partialResponse: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> OracleLaneMarkdownPayload.Lane {
        OracleLaneMarkdownPayload.Lane(
            laneIndex: member.laneID.index,
            chatID: member.publicChatID,
            providerID: member.model.providerID,
            modelID: member.model.modelID,
            effectiveReasoningEffort: nil,
            status: status,
            response: nil,
            partialResponse: partialResponse,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    private static func currentAssistantContent(
        session: ChatSession,
        liveMessages: [AIChatMessage],
        turnStartedAt: Date
    ) -> String? {
        let storedCurrentUserIDs = Set(
            session.messages.lazy
                .filter { $0.isUser && $0.timestamp >= turnStartedAt }
                .map(\.id)
        )
        let storedIDs = Set(session.messages.map(\.id))
        if let userIndex = liveMessages.lastIndex(where: {
            $0.isUser && (!storedIDs.contains($0.id) || storedCurrentUserIDs.contains($0.id))
        }),
            let assistant = liveMessages[(userIndex + 1)...].last(where: { !$0.isUser }),
            let content = nonempty(assistant.content)
        {
            return content
        }

        let currentStored = session.messages.filter { $0.timestamp >= turnStartedAt }
        if let userIndex = currentStored.lastIndex(where: \.isUser),
           let assistant = currentStored[(userIndex + 1)...].last(where: { !$0.isUser })
        {
            return nonempty(assistant.rawText)
        }
        return nil
    }

    private static func splitFailure(_ content: String?) -> (partialResponse: String?, message: String)? {
        guard let content = nonempty(content) else { return nil }
        let separator = "\n\n--\nError:\n"
        if let range = content.range(of: separator) {
            let partial = nonempty(String(content[..<range.lowerBound]))
            let message = nonempty(String(content[range.upperBound...])) ?? "Oracle lane failed."
            return (partial, message)
        }
        guard content.hasPrefix("Error:") else { return nil }
        let message = nonempty(String(content.dropFirst("Error:".count))) ?? "Oracle lane failed."
        return (nil, message)
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
