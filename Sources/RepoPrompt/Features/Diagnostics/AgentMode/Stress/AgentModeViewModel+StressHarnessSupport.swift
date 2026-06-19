#if DEBUG
    import Foundation
    import MCP

    // MARK: - Stress Harness Helpers

    extension AgentModeViewModel {
        enum MockTranscriptRole {
            case user
            case assistant
            case assistantInline
            case thinking
            case system
        }

        func testBindSessionToActiveSessionProxies(tabID: UUID) async {
            let session = await ensureSessionReady(tabID: tabID)
            applySessionToBindings(session)
        }

        func testPrepareStressSession(tabID: UUID) async {
            let session = await ensureSessionReady(tabID: tabID)
            session.selectedAgent = .codexExec
            session.selectedModelRaw = defaultModelRaw(for: .codexExec)
            session.selectedReasoningEffortRaw = nil
            session.pendingAskUser = nil
            session.pendingApproval = nil
            session.pendingPermissionsRequest = nil
            session.pendingMCPElicitationRequest = nil
            session.queuedMCPElicitationRequests.removeAll()
            session.pendingApplyEditsReview = nil
            session.waitingPrompt = nil
            session.runningStatusText = "Stress harness running"
            session.runState = .running
            applyTranscriptViewportBindingState(
                to: session,
                viewportState: .liveBottom,
                armingState: .armed
            )
            session.hasLoadedPersistedState = true
            requestUIRefresh(tabID: tabID, urgent: true)
        }

        func testResetStressTranscript(tabID: UUID) async {
            let session = await ensureSessionReady(tabID: tabID)
            session.setItemsSilently([], reason: .stressHarnessReset)
            session.clearDerivedTranscriptCaches()
            session.pendingAskUser = nil
            session.pendingApproval = nil
            session.pendingPermissionsRequest = nil
            session.pendingMCPElicitationRequest = nil
            session.queuedMCPElicitationRequests.removeAll()
            session.pendingApplyEditsReview = nil
            session.waitingPrompt = nil
            session.runningStatusText = nil
            session.runState = .idle
            session.runID = nil
            session.endCurrentRunAttempt(source: "stress.reset")
            session.provider = nil
            session.agentTask?.cancel()
            session.agentTask = nil
            session.providerSessionID = nil
            session.providerTokenUsageByTurn = []
            session.pendingNonCodexUserInputTokenQueue = []
            session.activeNonCodexTurnTokenAccumulator = nil
            session.codexConversationID = nil
            session.codexRolloutPath = nil
            session.codexModel = nil
            session.codexReasoningEffort = nil
            session.codexContextUsage = nil
            session.contextUsageSnapshot = nil
            session.contextCompactedAt = nil
            session.codexNeedsReconnect = false
            session.codexController = nil
            session.codexControllerPermissionProfile = nil
            session.codexControllerTaskLabelKind = nil
            claudeCoordinator.test_discardRuntimeState(for: session)
            session.codexEventTask?.cancel()
            session.codexEventTask = nil
            session.codexEventTaskRunID = nil
            session.codexLastEventAt = nil

            session.claudeExpectedTurnIDs = []
            session.claudeSupersedingProtectedTurnIDs = []
            session.hasReconciledPersistedCodexCommandStatus = false
            session.activeReasoningItemID = nil
            session.reasoningItemIDsByGroupID = [:]
            session.pendingAssistantDelta = ""
            session.assistantDeltaFlushTask?.cancel()
            session.assistantDeltaFlushTask = nil
            session.pendingInstructions = []
            session.pendingClaudeSteeringInstructions = []
            session.pendingACPSteeringInstructions = []
            session.codexFallbackPumpTask?.cancel()
            session.codexFallbackPumpTask = nil
            session.codexFallbackQueue = []
            session.codexFallbackDispatchInFlight = nil
            session.codexPendingTurnKind = nil
            session.codexAuthoritativeActiveTurn = nil
            session.codexAnonymousActiveTurn = nil
            session.codexRoutingObservedTurnID = nil
            session.pendingCommandRunningByKey = [:]
            session.pendingCommandRunningFlushTask?.cancel()
            session.pendingCommandRunningFlushTask = nil
            session.pendingHandoff = .init()
            session.nextSequenceIndex = 0
            session.hasSentFirstMessage = false
            applyTranscriptViewportBindingState(
                to: session,
                viewportState: .liveBottom,
                armingState: .armed
            )
            requestUIRefresh(tabID: tabID, urgent: true)
        }

        func testAppendMockTranscriptMessage(
            tabID: UUID,
            role: MockTranscriptRole,
            text: String,
            urgentUIRefresh: Bool = true
        ) {
            let session = session(for: tabID)
            let item: AgentChatItem = switch role {
            case .user:
                .user(text, sequenceIndex: session.nextSequenceIndex)
            case .assistant:
                .assistant(text, sequenceIndex: session.nextSequenceIndex)
            case .assistantInline:
                .assistantInline(text, sequenceIndex: session.nextSequenceIndex)
            case .thinking:
                .thinking(text, sequenceIndex: session.nextSequenceIndex)
            case .system:
                .system(text, sequenceIndex: session.nextSequenceIndex)
            }
            session.appendItem(item)
            requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
        }

        func testAppendStreamingAssistantDelta(
            tabID: UUID,
            delta: String,
            urgentUIRefresh: Bool = true
        ) {
            let session = session(for: tabID)
            let fullBindingSyncCount = test_updateBindingsCallCount
            guard applyAssistantDelta(delta, session: session) else { return }
            session.assistantDeltaFlushGeneration &+= 1
            requestAssistantPresentationRefresh(
                session: session,
                sourceItemsRevision: session.sourceItemsRevision,
                flushGeneration: session.assistantDeltaFlushGeneration
            )
            if urgentUIRefresh {
                test_flushPendingUIRefresh()
                assert(test_updateBindingsCallCount == fullBindingSyncCount)
            }
        }

        func testFinalizeStreamingAssistant(
            tabID: UUID,
            urgentUIRefresh: Bool = true
        ) {
            let session = session(for: tabID)
            let fullBindingSyncCount = test_updateBindingsCallCount
            endActiveAssistantSegment(session)
            session.assistantDeltaFlushGeneration &+= 1
            requestAssistantPresentationRefresh(
                session: session,
                sourceItemsRevision: session.sourceItemsRevision,
                flushGeneration: session.assistantDeltaFlushGeneration
            )
            if urgentUIRefresh {
                test_flushPendingUIRefresh()
                assert(test_updateBindingsCallCount == fullBindingSyncCount)
            }
        }

        func testSetStressRunState(
            tabID: UUID,
            state: AgentSessionRunState,
            statusText: String?,
            urgentUIRefresh: Bool = true
        ) {
            let session = session(for: tabID)
            session.runState = state
            session.runningStatusText = statusText
            requestUIRefresh(tabID: tabID, urgent: urgentUIRefresh)
        }

        @discardableResult
        func testSeedTextDerivationFixture(tabID: UUID, reset: Bool = true) async -> [String: Int] {
            if reset {
                await testResetStressTranscript(tabID: tabID)
            }
            let session = await ensureSessionReady(tabID: tabID)
            session.selectedAgent = .codexExec
            session.selectedModelRaw = defaultModelRaw(for: .codexExec)
            session.runState = .completed
            session.runningStatusText = nil
            session.pendingAskUser = nil
            session.pendingApproval = nil
            session.pendingPermissionsRequest = nil
            session.pendingMCPElicitationRequest = nil
            session.queuedMCPElicitationRequests.removeAll()
            session.pendingApplyEditsReview = nil
            session.waitingPrompt = nil
            session.hasLoadedPersistedState = true

            var appended: [String: Int] = [:]
            func append(_ item: AgentChatItem, bucket: String) {
                session.appendItem(item)
                appended[bucket, default: 0] += 1
            }

            append(.user("Seed DEBUG text-derivation fixture for transcript rendering measurement.", sequenceIndex: session.nextSequenceIndex), bucket: "user")
            append(.assistant(Self.testLongAssistantText(label: "old-collapsible-assistant", includeCodeFence: true), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")

            let plainInvocationID = UUID()
            append(
                .toolCall(
                    name: "debug_text_derivation_plain",
                    invocationID: plainInvocationID,
                    argsJSON: Self.testLargeToolArgsJSON(kind: "plain"),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolCall"
            )
            append(
                .toolResult(
                    name: "debug_text_derivation_plain",
                    invocationID: plainInvocationID,
                    resultJSON: Self.testPlainToolOutput(),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolResult"
            )

            let diffInvocationID = UUID()
            append(
                .toolCall(
                    name: "debug_text_derivation_diff",
                    invocationID: diffInvocationID,
                    argsJSON: Self.testLargeToolArgsJSON(kind: "diff"),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolCall"
            )
            append(
                .toolResult(
                    name: "debug_text_derivation_diff",
                    invocationID: diffInvocationID,
                    resultJSON: Self.testDiffToolOutput(),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolResult"
            )

            let jsonInvocationID = UUID()
            append(
                .toolCall(
                    name: "debug_text_derivation_json",
                    invocationID: jsonInvocationID,
                    argsJSON: Self.testLargeToolArgsJSON(kind: "json"),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolCall"
            )
            append(
                .toolResult(
                    name: "debug_text_derivation_json",
                    invocationID: jsonInvocationID,
                    resultJSON: Self.testJSONToolOutput(),
                    sequenceIndex: session.nextSequenceIndex
                ),
                bucket: "toolResult"
            )

            append(.assistant(Self.testLongAssistantText(label: "recent-assistant-one", includeCodeFence: false), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")
            append(.assistant(Self.testLongAssistantText(label: "recent-assistant-two", includeCodeFence: true), sequenceIndex: session.nextSequenceIndex), bucket: "assistant")

            applyTranscriptViewportBindingState(
                to: session,
                viewportState: .liveBottom,
                armingState: .armed
            )
            session.clearDerivedTranscriptCaches()
            requestUIRefresh(tabID: tabID, urgent: true)
            return appended
        }

        private static func testLongAssistantText(label: String, includeCodeFence: Bool) -> String {
            var lines = (1 ... 480).map { index in
                "\(label) line \(index): synthetic assistant transcript content for DEBUG measurement. This intentionally long line keeps the fixture measurable without changing release behavior."
            }
            if includeCodeFence {
                lines.append(contentsOf: [
                    "```swift",
                    "struct DebugFixture {",
                    "\tlet value: String",
                    "\tfunc render() -> String { value }",
                    "}",
                    "```"
                ])
            }
            return lines.joined(separator: "\n")
        }

        private static func testLargeToolArgsJSON(kind: String) -> String {
            let payload = (1 ... 80).map { "arg-\(kind)-\($0)" }.joined(separator: "\\n")
            return "{\"kind\":\"\(kind)\",\"payload\":\"\(payload)\"}"
        }

        private static func testPlainToolOutput() -> String {
            (1 ... 240).map { "plain output line \($0): fixture payload with enough text to require preview derivation." }
                .joined(separator: "\n")
        }

        private static func testDiffToolOutput() -> String {
            let hunks = (1 ... 80).flatMap { index in
                [
                    "@@ -\(index),3 +\(index),4 @@",
                    " context line \(index)",
                    "-old value \(index)",
                    "+new value \(index)",
                    "+added detail \(index)"
                ]
            }
            return (["--- a/Fixture.swift", "+++ b/Fixture.swift"] + hunks).joined(separator: "\n")
        }

        private static func testJSONToolOutput() -> String {
            let rows = (1 ... 120).map { index in
                "{\"index\":\(index),\"name\":\"fixture-\(index)\",\"status\":\"ok\"}"
            }.joined(separator: ",")
            return "{\"status\":\"ok\",\"rows\":[\(rows)],\"summary\":\"debug text derivation JSON fixture\"}"
        }
    }

    // MARK: - Stress Harness Persistence & Simulation

    #if DEBUG
        extension AgentModeViewModel {
            enum StressHarnessPersistenceError: Error {
                case noActiveWorkspace
                case missingComposeTab(UUID)
                case missingWorkspaceRoot
                case missingFixture(String)
                case invalidFixture(String, Error)
            }

            nonisolated static func persistedStressSessionFixtureURL(
                named fixtureName: String,
                workspaceRootPaths: [String]
            ) -> URL? {
                let candidateURLs = workspaceRootPaths
                    .filter { !$0.isEmpty }
                    .map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                            .standardizedFileURL
                            .appendingPathComponent("RepoPromptTests", isDirectory: true)
                            .appendingPathComponent("Fixtures", isDirectory: true)
                            .appendingPathComponent("AgentSessions", isDirectory: true)
                            .appendingPathComponent(fixtureName, isDirectory: false)
                    }
                guard !candidateURLs.isEmpty else {
                    return nil
                }
                if let existingURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    return existingURL
                }
                return candidateURLs.first
            }

            nonisolated static func loadPersistedStressSessionFixture(
                named fixtureName: String,
                workspaceRootPaths: [String]
            ) throws -> AgentSession {
                guard let fixtureURL = persistedStressSessionFixtureURL(
                    named: fixtureName,
                    workspaceRootPaths: workspaceRootPaths
                ) else {
                    throw StressHarnessPersistenceError.missingWorkspaceRoot
                }
                guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
                    throw StressHarnessPersistenceError.missingFixture(fixtureName)
                }
                do {
                    let data = try Data(contentsOf: fixtureURL)
                    let session = try JSONDecoder().decode(AgentSession.self, from: data)
                    return AgentSession(
                        serializationVersion: session.serializationVersion,
                        workspaceID: nil,
                        composeTabID: nil,
                        name: session.name,
                        savedAt: session.savedAt,
                        fileURL: nil,
                        items: session.items,
                        transcript: session.transcript,
                        itemCount: session.itemCount,
                        lastUserMessageAt: session.lastUserMessageAt,
                        agentKind: session.agentKind,
                        agentModel: session.agentModel,
                        agentReasoningEffort: session.agentReasoningEffort,
                        lastRunState: session.lastRunState,
                        providerSessionID: session.providerSessionID,
                        autoEditEnabled: session.autoEditEnabled,
                        providerTokenUsageByTurn: session.providerTokenUsageByTurn,
                        codexConversationID: session.codexConversationID,
                        codexRolloutPath: session.codexRolloutPath,
                        codexModel: session.codexModel,
                        codexReasoningEffort: session.codexReasoningEffort,
                        codexContextWindow: session.codexContextWindow,
                        codexLastTotalTokens: session.codexLastTotalTokens,
                        codexTotalTotalTokens: session.codexTotalTotalTokens,
                        codexMcpSessionKey: session.codexMcpSessionKey,
                        pendingHandoffPayload: session.pendingHandoffPayload,
                        pendingHandoffCreatedAt: session.pendingHandoffCreatedAt,
                        pendingHandoffSourceItemID: session.pendingHandoffSourceItemID,
                        pendingHandoffDefersProviderLockUntilSend: session.pendingHandoffDefersProviderLockUntilSend
                    )
                } catch {
                    throw StressHarnessPersistenceError.invalidFixture(fixtureName, error)
                }
            }

            @discardableResult
            func testStagePersistedStressSession(
                tabID: UUID,
                fixtureNamed fixtureName: String,
                workspaceRootPaths: [String]
            ) async throws -> AgentSession {
                let session = try Self.loadPersistedStressSessionFixture(
                    named: fixtureName,
                    workspaceRootPaths: workspaceRootPaths
                )
                return try await testStagePersistedStressSession(tabID: tabID, agentSession: session)
            }

            @discardableResult
            func testStagePersistedStressSession(
                tabID: UUID,
                agentSession seedSession: AgentSession
            ) async throws -> AgentSession {
                guard let workspace = test_workspaceManager?.activeWorkspace else {
                    throw StressHarnessPersistenceError.noActiveWorkspace
                }
                guard test_workspaceManager?.composeTab(with: tabID) != nil else {
                    throw StressHarnessPersistenceError.missingComposeTab(tabID)
                }

                var agentSession = seedSession
                agentSession.workspaceID = workspace.id
                agentSession.composeTabID = tabID
                agentSession.savedAt = Date()
                let fileURL = try await test_dataService.saveAgentSession(agentSession, for: workspace)
                agentSession.fileURL = fileURL

                upsertSessionIndex(
                    sessionID: agentSession.id,
                    tabID: tabID,
                    name: agentSession.name,
                    lastUserMessageAt: agentSession.lastUserMessageAt,
                    savedAt: agentSession.savedAt,
                    lastRunStateRaw: agentSession.lastRunState,
                    itemCount: agentSession.effectiveItemCount,
                    agentKindRaw: agentSession.agentKind,
                    agentModelRaw: agentSession.agentModel,
                    agentReasoningEffortRaw: agentSession.agentReasoningEffort,
                    autoEditEnabled: agentSession.autoEditEnabled
                )

                let liveSession = session(for: tabID)
                _ = test_installPersistentSessionBinding(
                    sessionID: agentSession.id,
                    on: liveSession,
                    updateWorkspaceMetadata: true
                )
                if liveSession.activeAgentSessionID == agentSession.id {
                    cancelPersistedLoad(for: liveSession)
                    removePendingUIRefresh(for: tabID)
                    liveSession.hasLoadedPersistedState = false
                    applyTranscriptViewportBindingState(
                        to: liveSession,
                        viewportState: .liveBottom,
                        armingState: .armed
                    )
                    liveSession.selectedAgent = AgentModelCatalog.normalizeSelection(
                        agentRaw: agentSession.agentKind,
                        modelRaw: agentSession.agentModel
                    ).agent
                    liveSession.selectedModelRaw = AgentModelCatalog.normalizeSelection(
                        agentRaw: agentSession.agentKind,
                        modelRaw: agentSession.agentModel
                    ).modelRaw
                    liveSession.selectedReasoningEffortRaw = agentSession.agentReasoningEffort
                    liveSession.runState = .idle
                    liveSession.runningStatusText = nil
                    liveSession.setItemsSilently([], reason: .stressHarnessReset)
                    liveSession.clearDerivedTranscriptCaches()
                    if tabID == currentTabID {
                        test_setActiveSessionBindingsAreHydrated(false)
                        applySessionToBindings(liveSession)
                    }
                }

                return agentSession
            }

            func testReplayCodexNativeEvent(
                tabID: UUID,
                event: CodexNativeSessionController.Event
            ) async {
                guard let session = session(for: tabID, createIfNeeded: false) else { return }
                session.selectedAgent = .codexExec
                await test_codexCoordinator.test_handleCodexNativeEvent(event, session: session)
            }

            func testSimulateCodexRepoPromptToolCall(
                tabID: UUID,
                invocationID: UUID?,
                toolName: String,
                args: [String: Value]? = nil
            ) {
                guard let session = session(for: tabID, createIfNeeded: false) else { return }
                test_codexCoordinator.testSimulateRepoPromptToolCall(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    session: session
                )
            }

            func testSimulateCodexRepoPromptToolResult(
                tabID: UUID,
                invocationID: UUID?,
                toolName: String,
                args: [String: Value]? = nil,
                resultJSON: String,
                isError: Bool
            ) {
                guard let session = session(for: tabID, createIfNeeded: false) else { return }
                test_codexCoordinator.testSimulateRepoPromptToolResult(
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError,
                    session: session
                )
            }

            func testSimulateCodexBashRunningUpdate(
                tabID: UUID,
                invocationID: UUID?,
                processID: String,
                appendedOutput: String,
                sealsAssistantBoundary: Bool = false
            ) async {
                guard let session = session(for: tabID, createIfNeeded: false) else { return }
                await test_codexCoordinator.testSimulateBashRunningUpdate(
                    invocationID: invocationID,
                    processID: processID,
                    appendedOutput: appendedOutput,
                    sealsAssistantBoundary: sealsAssistantBoundary,
                    session: session
                )
            }
        }
    #endif
#endif
