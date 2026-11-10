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
            let applied = try XCTUnwrap(try AgentSessionHydrationRuntime.apply(
                payload, attempt: hydrationAttempt(for: session),
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
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: payload.sessionID, workspaceID: payload.sourceWorkspaceID))
            let previous = try hydrationAttempt(for: session)
            session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: payload.sessionID))
            let originalItems = session.items
            XCTAssertNil(AgentSessionHydrationRuntime.apply(
                payload, attempt: previous,
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
            XCTAssertNil(try AgentSessionHydrationRuntime.apply(
                payload, attempt: hydrationAttempt(for: session),
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
            let applied = try XCTUnwrap(try AgentSessionHydrationRuntime.apply(
                payload, attempt: hydrationAttempt(for: session),
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

    private func hydrationAttempt(for session: AgentTabSession) throws -> AgentSessionHydrationRuntime.Attempt {
        let scope = AgentSessionRuntimeStore().makeScope()
        scope.replaceSessions([session.tabID: session])
        return try XCTUnwrap(AgentSessionHydrationRuntime.Attempt.capture(
            session, in: scope, transition: session.persistentBindingTransitionToken()
        ))
    }

    func testHydrationCannotApplyOrGrantReadinessToAReacquiredWriter() async throws {
        try await withPayload { payload in
            for afterApplication in [false, true] {
                let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
                session.installPersistentSessionBinding(.init(
                    tabID: session.tabID, sessionID: payload.sessionID, workspaceID: payload.sourceWorkspaceID
                ))
                let attempt = try hydrationAttempt(for: session)
                @MainActor func apply() -> AgentSessionHydrationRuntime.AppliedPayload? {
                    AgentSessionHydrationRuntime.apply(
                        payload, attempt: attempt,
                        selection: .init(agent: .codexExec, modelRaw: "gpt-5", explicitReasoningEffortRaw: nil),
                        codexPolicy: .init(options: [], defaultEffort: nil, lastUsed: nil),
                        indexedPlacement: nil, usage: attempt.writer.scope.usage
                    )
                }
                let applied = afterApplication ? try XCTUnwrap(apply()) : nil
                XCTAssertTrue(attempt.writer.isCurrent, "Field application must not rotate the writer")
                let before = session.items
                let transition = session.persistentBindingTransitionToken()
                attempt.writer.scope.replaceSessions([:])
                attempt.writer.scope.replaceSessions([session.tabID: session])
                XCTAssertTrue(transition.matches(session), "Binding/revision tokens alone do not detect reacquisition")
                XCTAssertFalse(attempt.ownsBinding)
                if let applied {
                    XCTAssertFalse(applied.commitReadiness())
                } else {
                    XCTAssertNil(apply())
                }
                XCTAssertEqual(session.items, before)
                XCTAssertFalse(session.hasLoadedPersistedState)
                XCTAssertFalse(session.qualifiedRestorationReadiness.isAuthoritative)
            }
        }
    }

    func testHydrationRefusesRetirementWithoutRequiringRestoredAdmission() async throws {
        try await withPayload { payload in
            let session = AgentTabSession(tabID: payload.restoredIndexEntry.tabID)
            session.installPersistentSessionBinding(.init(
                tabID: session.tabID, sessionID: payload.sessionID, workspaceID: payload.sourceWorkspaceID
            ))
            let attempt = try hydrationAttempt(for: session)
            XCTAssertTrue(attempt.isCurrent)
            XCTAssertFalse(session.permitsBoundOperationAndSave)
            attempt.writer.scope.beginRetirement()
            XCTAssertNil(AgentSessionHydrationRuntime.Attempt.capture(
                session, in: attempt.writer.scope, transition: attempt.transition
            ))
            XCTAssertNil(AgentSessionHydrationRuntime.apply(
                payload, attempt: attempt,
                selection: .init(agent: .codexExec, modelRaw: "gpt-5", explicitReasoningEffortRaw: nil),
                codexPolicy: .init(options: [], defaultEffort: nil, lastUsed: nil),
                indexedPlacement: nil, usage: attempt.writer.scope.usage
            ))
            XCTAssertTrue(session.items.isEmpty)
            XCTAssertFalse(session.hasLoadedPersistedState)
        }
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

@MainActor
final class AgentSessionObservationRuntimeTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let store = AgentSessionRuntimeStore()
        let scope: AgentSessionRuntimeStore.Scope
        let session: AgentTabSession
        let binding: AgentPersistentSessionBindingIdentity

        init() {
            scope = store.makeScope()
            session = scope.makeSession(tabID: UUID())
            binding = .init(tabID: session.tabID, sessionID: UUID(), workspaceID: UUID())
            scope.replaceSessions([session.tabID: session])
            session.installPersistentSessionBinding(binding)
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
        }

        func stageTranscript() -> Task<Void, Never>? {
            session.appendItem(.user("request", sequenceIndex: 0))
            session.appendItem(.assistant("complete answer", sequenceIndex: 1))
            return session.derivedTranscriptRefreshTask
        }
    }

    func testTerminalMaterializesWithoutPresentationAndDuringRetirement() async throws {
        for retiring in [false, true] {
            let f = Fixture()
            let pending = try XCTUnwrap(f.stageTranscript())
            XCTAssertTrue(f.session.transcript.turns.isEmpty)
            guard case let .unique(writer) = f.store.resolveWriter(sessionID: f.binding.sessionID) else {
                return XCTFail("Expected exact writer")
            }
            if retiring { f.scope.beginRetirement() }
            f.scope.observation.prepareTerminalPublication(for: f.session)
            XCTAssertFalse(f.session.transcript.turns.isEmpty)
            XCTAssertNil(f.session.derivedTranscriptRefreshTask)
            XCTAssertNil(f.session.pendingDerivedTranscriptRefreshReason)
            XCTAssertTrue(writer.isCurrent)
            XCTAssertFalse(f.scope.presentation.isActiveUISyncSuppressed)
            let protection = AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(for: f.session)
            XCTAssertTrue(AgentSessionTranscriptRefreshRuntime.canReuseDerivedTranscriptForSave(
                for: f.session, projectionProtection: protection
            ))
            let generation = f.session.derivedTranscriptRefreshGeneration
            f.scope.observation.prepareTerminalPublication(for: f.session)
            XCTAssertEqual(f.session.derivedTranscriptRefreshGeneration, generation, "Already-current terminal projection is reused")
            await pending.value
        }
    }

    func testTerminalCannotRefreshAReplacementIntroducedByOptionalPresentationCleanup() async throws {
        let f = Fixture()
        let pending = try XCTUnwrap(f.stageTranscript())
        let generation = f.session.derivedTranscriptRefreshGeneration
        var cleanupCount = 0
        let attachment = f.scope.presentation.attach(f.session, sink: .init(
            activityChanged: { _, _ in }, refresh: { _, _, _ in },
            turnComplete: { _ in }, turnFailed: { _, _ in },
            prepareTerminal: { session in
                cleanupCount += 1
                session.installPersistentSessionBinding(.init(
                    tabID: session.tabID, sessionID: UUID(), workspaceID: f.binding.workspaceID
                ))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
            }
        ))
        f.scope.observation.prepareTerminalPublication(for: f.session)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertTrue(f.session.transcript.turns.isEmpty)
        XCTAssertEqual(f.session.derivedTranscriptRefreshGeneration, generation)
        XCTAssertFalse(f.scope.presentation.isActiveUISyncSuppressed)
        f.scope.presentation.detach(attachment)
        pending.cancel()
        await pending.value
    }

    func testConflictingWriterRefusesTerminalRefreshWithoutInvokingPresentation() async throws {
        let f = Fixture()
        let pending = try XCTUnwrap(f.stageTranscript())
        let otherScope = f.store.makeScope()
        let other = AgentTabSession(tabID: UUID())
        otherScope.replaceSessions([other.tabID: other])
        XCTAssertEqual(otherScope.bindingRejection(f.binding.sessionID, on: other), .conflictingWriter)
        // Deliberate legacy corruption after proving ordinary admission refuses the second claim.
        other.installPersistentSessionBinding(.init(
            tabID: other.tabID, sessionID: f.binding.sessionID, workspaceID: f.binding.workspaceID
        ))
        guard case .conflicting = f.store.resolveWriter(sessionID: f.binding.sessionID) else {
            return XCTFail("Expected competing claims")
        }
        var cleanupCount = 0
        let attachment = f.scope.presentation.attach(f.session, sink: .init(
            activityChanged: { _, _ in }, refresh: { _, _, _ in },
            turnComplete: { _ in }, turnFailed: { _, _ in },
            prepareTerminal: { _ in cleanupCount += 1 }
        ))
        f.scope.observation.prepareTerminalPublication(for: f.session)
        XCTAssertFalse(f.scope.observation.canSynchronizeDerivedTranscript(for: f.session))
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertTrue(f.session.transcript.turns.isEmpty)
        f.scope.presentation.detach(attachment)
        pending.cancel()
        await pending.value
        otherScope.replaceSessions([:])
    }

    func testUnboundDraftProjectionIsNotAPersistentTerminalWriter() {
        let store = AgentSessionRuntimeStore()
        let scope = store.makeScope()
        let session = AgentTabSession(tabID: UUID())
        scope.replaceSessions([session.tabID: session])
        session.appendItem(.user("local draft", sequenceIndex: 0))
        XCTAssertFalse(scope.observation.canSynchronizeDerivedTranscript(for: session))
        XCTAssertTrue(scope.observation.canSynchronizeDerivedTranscript(for: session, requiringLoadedPersistedState: false))
        scope.observation.prepareTerminalPublication(for: session)
        XCTAssertTrue(session.transcript.turns.isEmpty)
    }
}
