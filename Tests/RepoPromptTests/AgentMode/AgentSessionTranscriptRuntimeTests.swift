import Foundation
import MCP
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

/// Saved transcripts drop tool args and reduce tool results to summaries. These tests pin that an
/// `ask_user` card replayed from storage still shows the questions and answers, instead of the
/// placeholder "Question / No response" a bare status summary produced.
final class AgentAskUserTranscriptPersistenceTests: XCTestCase {
    private let structuredArgs = """
    {"title":"Phase 3 decisions","context":"Pricing and rollout depend on these.","questions":[\
    {"id":"pricing","header":"Pricing","question":"Publish our own prices?","options":[{"label":"Yes","description":"Show them"},"No"]},\
    {"id":"regions","question":"Which regions launch first?","allows_multiple":true},\
    {"id":"later","question":"Anything else?"}]}
    """

    private let structuredResult = """
    {"answers":{\
    "pricing":{"answers":["Yes"],"selected_options":["Yes"],"custom_response":null,"skipped":false},\
    "regions":{"answers":[],"selected_options":["JP","US"],"custom_response":"EU later","skipped":false},\
    "later":{"answers":[],"selected_options":[],"custom_response":null,"skipped":true}},\
    "timed_out":false,"skipped":false,"elapsed_seconds":42}
    """

    private func persistedResultJSON(args: String?, result: String) throws -> String {
        let item = AgentChatItem.toolResult(name: "ask_user", argsJSON: args, resultJSON: result, isError: false, sequenceIndex: 1)
        return try XCTUnwrap(AgentToolResultPersistencePolicy.persistedToolResultSummary(for: item)).resultJSON
    }

    func testPersistedSummaryKeepsQuestionsAndAnswersForTheSavedCard() throws {
        let persisted = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

        // Saved transcripts carry no args, so the card must render from the persisted result alone.
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertFalse(card.detailsUnavailable)
        XCTAssertEqual(card.displayTitle, "Phase 3 decisions (3 questions)")
        XCTAssertEqual(card.questions.map(\.header), ["Pricing", nil, nil])
        XCTAssertEqual(
            card.questions.map(\.question),
            ["Publish our own prices?", "Which regions launch first?", "Anything else?"]
        )
        XCTAssertEqual(card.questions.map(\.answer), ["Yes", "JP, US, EU later", "Skipped"])
        XCTAssertNil(card.statusText)
    }

    func testPersistedRecordIsAFixedPointUnderResanitization() throws {
        let first = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        let second = try persistedResultJSON(args: nil, result: first)
        XCTAssertEqual(second, first)
    }

    func testProviderFormattedAndEnvelopedResultsPersistTheSameRecord() throws {
        let raw = try persistedResultJSON(args: structuredArgs, result: structuredResult)
        let fenced = "```json\n\(structuredResult)\n```"
        let response = try JSONDecoder().decode(Value.self, from: Data(structuredResult.utf8))
        let content = ToolOutputFormatter.buildContentBlocks(
            toolName: "ask_user", args: [:], result: response, emitResources: false
        )
        let envelope = try String(
            decoding: JSONEncoder().encode(["Ok": CallTool.Result(content: content, isError: false)]),
            as: UTF8.self
        )

        XCTAssertEqual(try persistedResultJSON(args: structuredArgs, result: fenced), raw)
        XCTAssertEqual(try persistedResultJSON(args: structuredArgs, result: envelope), raw)
    }

    func testOversizedExchangeIsClippedWithinTheBudget() throws {
        let longText = String(repeating: "long question text ", count: 60)
        let questions = (1 ... 10).map { #"{"id":"q\#($0)","header":"\#(longText)","question":"\#(longText)"}"# }
        let answers = (1 ... 10).map { #""q\#($0)":{"answers":["\#(longText)"],"skipped":false}"# }
        let args = #"{"title":"\#(longText)","questions":[\#(questions.joined(separator: ","))]}"#
        let result = #"{"answers":{\#(answers.joined(separator: ","))},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.count, 10)
        for question in card.questions {
            XCTAssertTrue(question.question.hasSuffix("…"))
            XCTAssertTrue(question.answer?.hasSuffix("…") == true)
        }
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testLongIDsSharingAPrefixKeepTheirOwnAnswers() throws {
        let prefix = String(repeating: "x", count: 63) + " "
        let args = #"{"questions":[{"id":"\#(prefix)a","question":"First?"},{"id":"\#(prefix)b","question":"Second?"}]}"#
        let result = #"{"answers":{"\#(prefix)a":{"answers":["one"]},"\#(prefix)b":{"answers":["two"]}},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.map(\.answer), ["one", "two"])
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testMultibyteHeavyExchangeKeepsEveryRowAcrossPasses() throws {
        let emoji = String(repeating: "🧪", count: 48)
        let questions = (1 ... 10).map { #"{"id":"q\#($0)","question":"\#(emoji)"}"# }
        let answers = (1 ... 10).map { #""q\#($0)":{"answers":["\#(emoji)"]}"# }
        let args = #"{"questions":[\#(questions.joined(separator: ","))]}"#
        let result = #"{"answers":{\#(answers.joined(separator: ","))},"timed_out":false,"skipped":false}"#

        let persisted = try persistedResultJSON(args: args, result: result)
        XCTAssertLessThanOrEqual(persisted.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: persisted)
        XCTAssertEqual(card.questions.count, 10)
        XCTAssertTrue(card.questions.allSatisfy { $0.answer?.hasPrefix("🧪") == true })
        XCTAssertEqual(try persistedResultJSON(args: nil, result: persisted), persisted)
    }

    func testEnvelopePrefersStructuredContentOverConflictingText() throws {
        let decoy = #"{"answers":{"pricing":{"answers":["decoy"]}},"timed_out":false,"skipped":false}"#
        let canonical = #"{"answers":{"pricing":{"answers":["canonical"]}},"timed_out":false,"skipped":false}"#
        let decoyText = try String(decoding: JSONEncoder().encode(decoy), as: UTF8.self)
        let envelope = """
        {"Ok":{"content":[{"type":"text","text":\(decoyText)}],\
        "isError":false,"structuredContent":\(canonical)}}
        """

        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: envelope))
        XCTAssertEqual(card.questions.first?.answer, "canonical")
    }

    func testLegacyScalarExchangePersistsItsQuestionAndResponse() throws {
        let args = #"{"question":"Which database?","options":["Postgres","SQLite"]}"#
        let result = """
        {"answers":{"response":{"answers":["Postgres"],"selected_options":["Postgres"],"custom_response":null,"skipped":false}},\
        "response":"Postgres","timed_out":false,"skipped":false,"elapsed_seconds":3}
        """

        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: args, result: result))
        XCTAssertEqual(card.questions.map(\.question), ["Which database?"])
        XCTAssertEqual(card.questions.map(\.answer), ["Postgres"])
    }

    func testTimedOutExchangeKeepsItsStatus() throws {
        let result = #"{"answers":{"pricing":{"answers":["No"],"skipped":false}},"timed_out":true,"skipped":false}"#
        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: result))
        XCTAssertEqual(card.questions.map(\.answer), ["No", "No response (timed out)", "No response (timed out)"])
        XCTAssertEqual(card.statusText, "Timed out")
    }

    func testSkippedInteractionKeepsItsStatus() throws {
        let result = #"{"answers":{},"timed_out":false,"skipped":true}"#
        let card = try parseAskUserQuestionSummaryRobust(args: nil, result: persistedResultJSON(args: structuredArgs, result: result))
        XCTAssertEqual(card.questions.map(\.answer), ["Skipped", "Skipped", "Skipped"])
        XCTAssertEqual(card.statusText, "Skipped")
    }

    func testLegacyStatusOnlyRecordRendersAnUnavailableStateInsteadOfAPlaceholderAnswer() {
        let legacy = #"{"status":"success","summary_only":true,"summary_text":"ask_user • success"}"#
        let card = parseAskUserQuestionSummaryRobust(args: nil, result: legacy)
        XCTAssertTrue(card.detailsUnavailable)
        XCTAssertTrue(card.questions.isEmpty)
        XCTAssertEqual(card.displayTitle, "Question")
    }

    func testTranscriptPersistenceDropsArgsButKeepsTheExchange() throws {
        let startedAt = Date(timeIntervalSince1970: 0)
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: "exec-ask-user",
            // Provider-prefixed name as Claude reports it; persistence normalizes it to ask_user.
            toolName: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__ask_user",
            invocationID: UUID(),
            argsJSON: structuredArgs,
            resultJSON: structuredResult,
            toolIsError: false,
            status: .success
        )
        let activity = AgentTranscriptActivity(
            id: UUID(),
            timestamp: startedAt,
            sequenceIndex: 1,
            role: .toolExecution,
            itemKind: .toolResult,
            text: structuredResult,
            toolExecution: execution
        )
        let transcript = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("request", sequenceIndex: 0)),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            lastActivityAt: startedAt,
                            completedAt: startedAt,
                            activities: [activity]
                        )
                    ],
                    retentionTier: .full,
                    terminalState: .completed,
                    startedAt: startedAt,
                    lastActivityAt: startedAt,
                    completedAt: startedAt
                )
            ],
            nextSequenceIndex: 2
        )

        let persisted = AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(transcript)
        let persistedActivity = try XCTUnwrap(persisted.turns.first?.responseSpans.first?.activities.first)
        let persistedExecution = try XCTUnwrap(persistedActivity.toolExecution)
        XCTAssertNil(persistedExecution.argsJSON)

        let row = persistedActivity.toItem()
        let card = parseAskUserQuestionSummaryRobust(args: row.toolArgsJSON, result: row.toolResultJSON)
        XCTAssertEqual(card.questions.map(\.answer), ["Yes", "JP, US, EU later", "Skipped"])
        XCTAssertEqual(AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence(persisted), persisted)
    }
}
