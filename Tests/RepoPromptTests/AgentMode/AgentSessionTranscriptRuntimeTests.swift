import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionTranscriptRuntimeTests: XCTestCase {
    func testRealSavedPayloadAppliesCanonicalTranscriptWithoutPresentationModels() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.selectedAgent = payload.normalizedSelection.agent
            session.nextSequenceIndex = payload.transcript.nextSequenceIndex
            session.setItemsSilently(payload.canonicalLiveItems, reason: .persistedSessionHydration)
            XCTAssertTrue(AgentSessionTranscriptRuntime.apply(
                payload.builtPresentation, sourceItems: payload.canonicalLiveItems, to: session
            ))
            XCTAssertEqual(session.transcript, payload.builtPresentation.transcript)
            XCTAssertEqual(session.fullTranscriptProjection, payload.builtPresentation.fullProjection)
            XCTAssertEqual(session.workingTranscriptProjection, payload.builtPresentation.workingProjection)
            XCTAssertEqual(session.archivedTranscriptSnapshot, payload.builtPresentation.archivedSnapshot)
            XCTAssertEqual(session.transcriptProjectionCounts, payload.builtPresentation.projectionCounts)
            XCTAssertEqual(session.derivedTranscriptSyncState, AgentSessionTranscriptRuntime.syncState(
                for: session, projectionProtection: payload.builtPresentation.projectionProtection
            ))
            XCTAssertEqual(session.items.map(\.id), payload.canonicalLiveItems.map(\.id))
            XCTAssertFalse(
                session.qualifiedRestorationReadiness.isAuthoritative,
                "Transcript application alone cannot earn a full-payload restoration receipt"
            )
        }
    }

    func testStaleBuiltPayloadCannotReplaceNewerRuntimeTranscript() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            let current = AgentChatItem(kind: .assistant, text: "Newer runtime content", sequenceIndex: 9)
            session.setItemsSilently([current], reason: .persistedSessionHydration)
            let originalTranscript = session.transcript
            let originalProjection = session.fullTranscriptProjection
            let originalSeed = session.localInputIndex.records
            XCTAssertFalse(AgentSessionTranscriptRuntime.apply(
                payload.builtPresentation, sourceItems: payload.canonicalLiveItems, to: session
            ))
            XCTAssertEqual(session.items, [current])
            XCTAssertEqual(session.transcript, originalTranscript)
            XCTAssertEqual(session.fullTranscriptProjection, originalProjection)
            XCTAssertEqual(session.localInputIndex.records, originalSeed)
            XCTAssertNil(session.derivedTranscriptSyncState)
        }
    }

    func testFullPayloadHydrationEarnsReadinessWithoutViewModels() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.installPersistentSessionBinding(.init(
                tabID: session.tabID, sessionID: payload.sessionID, workspaceID: payload.persistedSession.workspaceID
            ))
            let policy = AgentCodexSelectionPolicy(options: [.low, .high], defaultEffort: .low, lastUsed: nil)
            let selection = AgentSessionHydrationRuntime.selection(for: payload, availability: .current, codexDynamicModels: nil)
            var placement = payload.restoredIndexEntry
            placement.organizationalParentID = UUID()
            placement.delegationScopeID = UUID()
            let applied = try XCTUnwrap(AgentSessionHydrationRuntime.apply(
                payload, to: session, expected: session.persistentBindingTransitionToken(),
                selection: selection, codexPolicy: policy, indexedPlacement: placement, usage: AgentSessionUsageRuntime()
            ))
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
            XCTAssertEqual(session.organizationalParentID, placement.organizationalParentID)
            XCTAssertEqual(session.delegationScopeID, placement.delegationScopeID)
            XCTAssertTrue(applied.commitReadiness())
            XCTAssertEqual(session.items.map(\.id), payload.canonicalLiveItems.map(\.id))
            XCTAssertEqual(session.parentSessionID, payload.persistedSession.parentSessionID)
            XCTAssertEqual(session.createdByOverseerSessionID, payload.persistedSession.createdByOverseerSessionID)
            XCTAssertTrue(session.isMCPOriginated)
            XCTAssertTrue(session.autoEditEnabled)
            XCTAssertEqual(session.oversight.autoWakeTargetSessionIDs, payload.persistedSession.agentSessionLinkAutoWakeTargetSessionIDs)
            XCTAssertEqual(session.providerSessionID, "persisted-provider")
            XCTAssertEqual(session.runState, payload.normalizedRunState)
            XCTAssertEqual(session.lastUserMessageAt, payload.lastUserMessageAt)
            XCTAssertEqual(session.contextWindowCapacity, payload.persistedSession.contextWindowCapacity)
            XCTAssertEqual(session.contextWindowCapacity?.tokens, 200_000)
            XCTAssertTrue(session.qualifiedRestorationReadiness.isAuthoritative)
            XCTAssertTrue(session.hasLoadedPersistedState)
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: payload.sessionID))
            XCTAssertFalse(applied.commitReadiness(), "A completed load cannot grant readiness to a later incarnation")
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testFullHydrationRejectsStaleIncarnationBeforeAnyPayloadMutation() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: payload.sessionID))
            let previous = session.persistentBindingTransitionToken()
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: payload.sessionID))
            let originalItems = session.items
            XCTAssertNil(AgentSessionHydrationRuntime.apply(
                payload, to: session, expected: previous,
                selection: .init(agent: .codexExec, modelRaw: "gpt-5", explicitReasoningEffortRaw: "high"),
                codexPolicy: .init(options: [.high], defaultEffort: .high, lastUsed: nil),
                indexedPlacement: nil, usage: AgentSessionUsageRuntime()
            ))
            XCTAssertEqual(session.items, originalItems)
            XCTAssertNil(session.providerSessionID)
            XCTAssertNil(session.parentSessionID)
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testFullHydrationRejectsForeignWorkspaceBeforeAnyPayloadMutation() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.installPersistentSessionBinding(.init(
                tabID: session.tabID, sessionID: payload.sessionID, workspaceID: UUID()
            ))
            XCTAssertNil(AgentSessionHydrationRuntime.apply(
                payload, to: session, expected: session.persistentBindingTransitionToken(),
                selection: .init(agent: .codexExec, modelRaw: "gpt-5", explicitReasoningEffortRaw: nil),
                codexPolicy: .init(options: [], defaultEffort: nil, lastUsed: nil),
                indexedPlacement: nil, usage: AgentSessionUsageRuntime()
            ))
            XCTAssertTrue(session.items.isEmpty)
            XCTAssertNil(session.providerSessionID)
            XCTAssertFalse(session.hasLoadedPersistedState)
            XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
        }
    }

    func testLegacyPayloadUsesExactLoadWorkspaceWithoutInventingEmbeddedIdentity() async throws {
        try await withPayload(legacyWorkspace: true) { payload in
            XCTAssertNil(payload.persistedSession.workspaceID)
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.installPersistentSessionBinding(.init(
                tabID: session.tabID, sessionID: payload.sessionID, workspaceID: payload.sourceWorkspaceID
            ))
            let applied = try XCTUnwrap(AgentSessionHydrationRuntime.apply(
                payload, to: session, expected: session.persistentBindingTransitionToken(),
                selection: AgentSessionHydrationRuntime.selection(for: payload, availability: .current, codexDynamicModels: nil),
                codexPolicy: .init(options: [], defaultEffort: nil, lastUsed: nil),
                indexedPlacement: nil, usage: AgentSessionUsageRuntime()
            ))
            XCTAssertTrue(applied.commitReadiness())
            XCTAssertEqual(session.persistentSessionBindingIdentity?.workspaceID, payload.sourceWorkspaceID)
            XCTAssertNil(payload.persistedSession.workspaceID)
        }
    }

    func testCodexFrozenPolicyPreservesExplicitParsedAndPreferencePrecedence() {
        let policy = AgentCodexSelectionPolicy(options: [.low, .medium, .high], defaultEffort: .low, lastUsed: .medium)
        XCTAssertEqual(policy.reasoningEffort(modelRaw: "gpt-5", explicitRaw: "high"), .high)
        XCTAssertEqual(policy.reasoningEffort(modelRaw: "gpt-5", explicitRaw: "unsupported"), .medium)
        XCTAssertEqual(
            AgentCodexSelectionPolicy(options: [], defaultEffort: .high, lastUsed: .high)
                .reasoningEffort(modelRaw: "gpt-5", explicitRaw: "high"),
            nil
        )
    }

    private func withPayload(legacyWorkspace: Bool = false, _ body: (AgentSessionHydrationPayload) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M9TranscriptRuntime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(name: "Window-free transcript", repoPaths: [], customStoragePath: root)
        let service = AgentSessionDataService()
        let tabID = UUID(), sessionID = UUID()
        var saved = AgentSession(
            id: sessionID, workspaceID: legacyWorkspace ? nil : workspace.id, composeTabID: tabID, name: "Saved transcript",
            items: [
                AgentChatItem(kind: .user, text: "Persist this request", sequenceIndex: 0),
                AgentChatItem(kind: .assistant, text: "Persist this response", sequenceIndex: 1)
            ].map { AgentChatItemPersist(from: $0) },
            lastRunState: "completed"
        )
        saved.parentSessionID = UUID()
        saved.createdByOverseerSessionID = UUID()
        saved.isMCPOriginated = true
        saved.autoEditEnabled = true
        saved.agentSessionLinkAutoWakeTargetSessionIDs = [UUID()]
        saved.providerSessionID = "persisted-provider"
        saved.contextWindowCapacity = .init(tokens: 200_000, agentRaw: "codexExec", modelRaw: "gpt-5")
        _ = try await service.saveAgentSession(saved, for: workspace)
        let payload = try await service.preparePersistedHydration(.init(
            workspace: workspace, tabID: tabID, sessionID: sessionID, resolvedDisplayName: "Saved transcript",
            hasPendingQuestionUI: false, transcriptViewportState: .init(isDetachedFromLiveBottom: false), isCompressedHistoryRevealed: false,
            initialPerformanceSnapshot: .empty
        ))
        try body(XCTUnwrap(payload))
    }
}
