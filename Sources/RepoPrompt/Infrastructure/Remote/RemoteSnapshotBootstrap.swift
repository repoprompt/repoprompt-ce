import Foundation
import RepoPromptRemoteProtocol

enum RemoteSnapshotBootstrap {
    static let maximumJSONBytes = RemoteWireProtocol.maximumSnapshotJSONBytes

    static func encode(_ snapshot: RemoteSnapshot, with encoder: JSONEncoder) throws -> Data {
        let full = try encoder.encode(snapshot)
        if full.count <= maximumJSONBytes {
            return full
        }

        let compactSessions = snapshot.sessions.map { compactSession($0) }
        let compactAttention = snapshot.attentionItems.map {
            RemoteAttentionItem(
                id: $0.id, kind: $0.kind, sessionID: $0.sessionID,
                title: preview($0.title), createdAt: $0.createdAt
            )
        }
        let reduced = try encoder.encode(copy(
            snapshot, workspaces: snapshot.workspaces, sessions: compactSessions,
            attention: compactAttention, includeCatalogs: true
        ))
        if reduced.count <= maximumJSONBytes {
            return reduced
        }

        // Keep open workspaces first if an exceptional amount of saved metadata needs deferring.
        let sortedWorkspaces = snapshot.workspaces.filter(\.isOpen) + snapshot.workspaces.filter { !$0.isOpen }
        var workspaces = sortedWorkspaces.map {
            RemoteWorkspaceSummary(
                workspaceID: $0.workspaceID, name: preview($0.name),
                repositoryRootSummary: $0.repositoryRootSummary.map(preview),
                isOpen: $0.isOpen, lastActivityAt: $0.lastActivityAt
            )
        }
        var sessions = compactSessions.filter(\.isLive) + compactSessions.filter { !$0.isLive }
        while true {
            let workspaceIDs = Set(workspaces.map(\.workspaceID))
            let visibleSessions = sessions.filter { workspaceIDs.contains($0.workspaceID) }
            let sessionIDs = Set(visibleSessions.map(\.sessionID))
            let linkedSessions = visibleSessions.map { compactSession($0, retaining: sessionIDs) }
            let core = try encoder.encode(copy(
                snapshot, workspaces: workspaces, sessions: linkedSessions,
                attention: compactAttention.filter { sessionIDs.contains($0.sessionID) },
                includeCatalogs: false
            ))
            if core.count <= maximumJSONBytes {
                return core
            }
            if !sessions.isEmpty {
                sessions.removeLast(max(1, sessions.count / 2))
            } else if !workspaces.isEmpty {
                workspaces.removeLast(max(1, workspaces.count / 2))
            } else {
                throw RemoteWireContractError.frameTooLarge(actual: core.count, maximum: maximumJSONBytes)
            }
        }
    }

    private static func compactSession(
        _ session: RemoteSessionSummary,
        retaining sessionIDs: Set<UUID>? = nil
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            sessionID: session.sessionID, workspaceID: session.workspaceID, composeTabID: session.composeTabID,
            parentSessionID: session.parentSessionID.flatMap { sessionIDs?.contains($0) == false ? nil : $0 },
            sessionName: session.sessionName.map(preview),
            workflow: session.workflow.map(preview), workflowID: session.workflowID, runStartedAt: session.runStartedAt,
            transcriptRevision: session.transcriptRevision, agent: session.agent, model: session.model,
            reasoningEffort: session.reasoningEffort, runState: session.runState, lifecycleStage: session.lifecycleStage,
            latestMeaningfulActivity: session.latestMeaningfulActivity.map(preview),
            pendingInteraction: session.pendingInteraction.map(compactInteraction),
            childSessionIDs: session.childSessionIDs.filter { sessionIDs?.contains($0) != false },
            worktreeSummary: session.worktreeSummary.map(preview), mergeAttention: session.mergeAttention.map(preview),
            failureSummary: session.failureSummary.map(preview), lastUpdatedAt: session.lastUpdatedAt, isLive: session.isLive
        )
    }

    private static func compactInteraction(_ interaction: RemoteInteractionSummary) -> RemoteInteractionSummary {
        if [interaction.title, interaction.prompt, interaction.responseUnavailableReason]
            .compactMap(\.self).allSatisfy({ $0.utf8.count <= previewBytes })
        {
            return interaction
        }
        return RemoteInteractionSummary(
            id: interaction.id, kind: interaction.kind, title: interaction.title.map(preview),
            requiresSecureEntry: interaction.requiresSecureEntry,
            responseUnavailableReason: "Open this chat to load the complete request before responding.",
            createdAt: interaction.createdAt
        )
    }

    private static func copy(
        _ snapshot: RemoteSnapshot,
        workspaces: [RemoteWorkspaceSummary],
        sessions: [RemoteSessionSummary],
        attention: [RemoteAttentionItem],
        includeCatalogs: Bool
    ) -> RemoteSnapshot {
        RemoteSnapshot(
            protocolVersion: snapshot.protocolVersion, desktop: snapshot.desktop, connection: snapshot.connection,
            authorization: snapshot.authorization, workspaces: workspaces, sessions: sessions, attentionItems: attention,
            workflowCatalog: includeCatalogs ? snapshot.workflowCatalog : [],
            agentCatalog: includeCatalogs ? snapshot.agentCatalog : [],
            agentCatalogMetadata: includeCatalogs ? snapshot.agentCatalogMetadata : nil,
            eventCursor: snapshot.eventCursor, transcriptRevisionEpoch: snapshot.transcriptRevisionEpoch
        )
    }

    private static let previewBytes = 256

    private static func preview(_ value: String) -> String {
        String(decoding: value.utf8.prefix(previewBytes), as: UTF8.self)
    }
}

enum RemoteBootstrapSessionGraph {
    static func relatedIDs(liveIDs: Set<UUID>, parentByChild: [UUID: UUID]) -> Set<UUID> {
        let childrenByParent = parentByChild.reduce(into: [UUID: [UUID]]()) { result, link in
            result[link.value, default: []].append(link.key)
        }
        var included = liveIDs
        var pending = Array(liveIDs)
        while let sessionID = pending.popLast() {
            if let parentID = parentByChild[sessionID], included.insert(parentID).inserted {
                pending.append(parentID)
            }
            for childID in childrenByParent[sessionID, default: []] where included.insert(childID).inserted {
                pending.append(childID)
            }
        }
        return included
    }
}
