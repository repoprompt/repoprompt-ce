#if DEBUG
    import Foundation
    import MCP
    import RepoPromptDomainRuntime
    import XCTest
    @_spi(TestSupport) @testable import RepoPromptApp

    /// Injected W0 handler body. It is not registered, described to a model, or production-certified.
    /// Entry calls the real attempt ledger before validation or authorization can refuse/suspend.
    @MainActor
    final class AgentQuietDeclarationBodyFeasibilityTests: XCTestCase {
        @MainActor
        private final class Fixture {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session: AgentTabSession
            let owner: AgentRunOwnership
            let wakeID = UUID()
            let origin: AgentSelfMCPCallOrigin
            var endpoint: DomainAgentSessionLinkEndpointIdentity
            let context = ToolInvocationContext.trustedLocal(toolName: "read_file", metadata: .init(connectionID: nil, clientName: nil, windowID: nil))

            init() {
                session = harness.makeSession(agent: .claudeCode)
                session.testInstallPersistentSessionBinding(sessionID: UUID())
                session.installRunID(UUID())
                session.runState = .running
                owner = session.beginRunAttempt(source: "W0-injected-declaration-body")
                endpoint = .init(
                    windowID: 1,
                    workspaceID: UUID(),
                    tabID: owner.binding.tabID,
                    sessionID: owner.binding.persistentSessionID!,
                    persistentBindingGeneration: owner.binding.persistentBindingGeneration,
                    bindingTransitionGeneration: owner.binding.bindingTransitionGeneration
                )
                origin = .init(endpoint: endpoint, runID: session.runID!, runAttemptID: owner.attemptID)
                session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID)
            }

            func body(
                valid: Bool = true,
                capturedOrigin: AgentSelfMCPCallOrigin? = nil,
                authorize: () async -> Void = {}
            ) async -> Value? {
                guard session.quietLedger.enterDeclarationBody(owner: owner, hostInvocationID: context.invocationID) else { return nil }
                // Refusal happens after body-entry accounting, never at wrapper registration.
                guard valid else { session.quietLedger.noteOccurrence(owner: owner)
                    return nil
                }
                let captured = capturedOrigin ?? origin
                await authorize()
                guard session.quietLedger.acceptDeclarationBody(
                    owner: owner,
                    hostInvocationID: context.invocationID,
                    wakeID: wakeID,
                    origin: captured,
                    currentEndpoint: endpoint,
                    currentRunID: session.runID
                ) else { return nil }
                return .object(["result": .string("done")])
            }

            var eligible: Bool {
                session.quietLedger.declarationMaySeal(owner: owner, canonicalInvocations: [context.invocationID])
            }
        }

        func testBodyEntryPrecedesRefusalAndSaturatesIndependentlyOfCanonicalIdentity() async {
            let refused = Fixture()
            let refusal = await refused.body(valid: false)
            XCTAssertNil(refusal)
            XCTAssertEqual(refused.session.quietLedger.declarationBodyEntryCardinality(owner: refused.owner), 1)
            XCTAssertFalse(refused.eligible)
            let repeated = Fixture()
            let first = await repeated.body()
            XCTAssertEqual(first, .object(["result": .string("done")]))
            XCTAssertTrue(repeated.eligible)
            for _ in 0 ..< 3 {
                _ = await repeated.body()
            }
            XCTAssertEqual(repeated.session.quietLedger.declarationBodyEntryCardinality(owner: repeated.owner), 2)
            XCTAssertFalse(repeated.eligible, "One deduplicated canonical UUID cannot hide repeated body execution")
        }

        func testTransportCacheWithoutBodyReentryNeedsNoExceptionAndTextPolicyIsDirectional() async {
            let fixture = Fixture()
            var cached: Value?
            @MainActor
            func transport() async -> Value? {
                if let cached { return cached }
                cached = await fixture.body()
                return cached
            }
            let first = await transport()
            let replay = await transport()
            XCTAssertEqual(first, replay)
            XCTAssertEqual(fixture.session.quietLedger.declarationBodyEntryCardinality(owner: fixture.owner), 1)
            fixture.session.quietLedger.noteDeclarationAssistantText(owner: fixture.owner, text: "Done.")
            XCTAssertTrue(fixture.eligible, "Approved trailing text-only close does not add a tool/body")
            let leading = Fixture()
            leading.session.quietLedger.noteDeclarationAssistantText(owner: leading.owner, text: "I will close.")
            _ = await leading.body()
            XCTAssertFalse(leading.eligible, "Text before the declaration remains irreversible ordinary")
        }

        func testSiblingArrivingDuringAuthorizationSuspensionCannotBeErasedByAcceptance() async throws {
            let fixture = Fixture()
            let gate = TestReleaseFence(name: "W0 declaration authorization")
            let task = Task { await fixture.body(authorize: { await gate.enterAndWait() }) }
            guard await gate.waitUntilEntered() else { gate.release()
                _ = await task.value
                return
            }
            try await fixture.harness.host.test_handleStreamResult(
                .init(type: "tool_call", text: nil, toolName: "file_search", toolInvocationID: UUID()),
                session: fixture.session,
                runID: XCTUnwrap(fixture.session.runID),
                runAttemptID: fixture.owner.attemptID
            )
            gate.release()
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertFalse(fixture.eligible)
            XCTAssertNil(fixture.session.quietLedger.candidateStartKey(owner: fixture.owner))
        }

        func testCapturedEndpointRunAttemptAndWakeAreExactAndCancellationOrSuccessorCannotBorrowAcceptance() async {
            for variant in 0 ..< 5 {
                let fixture = Fixture()
                var endpoint = fixture.endpoint
                if variant == 0 {
                    endpoint = .init(
                        windowID: endpoint.windowID,
                        workspaceID: UUID(),
                        tabID: endpoint.tabID,
                        sessionID: endpoint.sessionID,
                        persistentBindingGeneration: endpoint.persistentBindingGeneration,
                        bindingTransitionGeneration: endpoint.bindingTransitionGeneration
                    )
                }
                let origin = AgentSelfMCPCallOrigin(
                    endpoint: endpoint,
                    runID: variant == 1 ? UUID() : fixture.origin.runID,
                    runAttemptID: variant == 2 ? UUID() : fixture.owner.attemptID
                )
                let gate = TestReleaseFence(name: "W0 stale declaration origin")
                let task = Task { await fixture.body(capturedOrigin: origin, authorize: { await gate.enterAndWait() }) }
                guard await gate.waitUntilEntered() else { gate.release()
                    _ = await task.value
                    continue
                }
                if variant == 3 { fixture.session.sealQuietCheckIn(owner: fixture.owner, terminalState: .cancelled, normal: false, hasSuccessor: false) }
                if variant == 4 {
                    _ = fixture.session.endRunAttempt(ifCurrent: fixture.owner, source: "W0 successor")
                    let successor = fixture.session.beginRunAttempt(source: "W0 successor")
                    fixture.session.quietLedger.markRoutineWake(owner: successor, wakeID: UUID())
                }
                let facts = fixture.session.quietLedger.facts
                gate.release()
                let result = await task.value
                XCTAssertNil(result, "variant \(variant)")
                XCTAssertFalse(fixture.eligible)
                if variant >= 3 { XCTAssertEqual(fixture.session.quietLedger.facts, facts, "Late acceptance cannot mutate sealed/cancelled settlement or successor") }
            }
            let fixture = Fixture()
            XCTAssertTrue(fixture.session.quietLedger.enterDeclarationBody(owner: fixture.owner, hostInvocationID: fixture.context.invocationID))
            XCTAssertFalse(fixture.session.quietLedger.acceptDeclarationBody(
                owner: fixture.owner,
                hostInvocationID: fixture.context.invocationID,
                wakeID: UUID(),
                origin: fixture.origin,
                currentEndpoint: fixture.endpoint,
                currentRunID: fixture.session.runID
            ))
        }
    }

    @MainActor
    final class AgentSelfNoopTests: XCTestCase {
        @MainActor
        final class Fixture {
            let window: WindowState
            var workspace: WorkspaceManagerViewModel
            let session: AgentTabSession
            let owner: AgentRunOwnership
            let endpoint: DomainAgentSessionLinkEndpointIdentity
            let context: ToolInvocationContext
            let wakeID = UUID()
            var origin: AgentSelfMCPCallOrigin
            var returnedEndpoint: DomainAgentSessionLinkEndpointIdentity?
            var beforeMetadata: () async -> Void = {}

            init(routine: Bool = true, ordinaryRows: [AgentChatItem]? = nil, preparedWindow: WindowState? = nil, preparedTabID: UUID? = nil) throws {
                let window = preparedWindow ?? WindowState()
                self.window = window
                let tabID = preparedTabID ?? UUID()
                workspace = preparedWindow != nil ? window.workspaceManager : AgentSessionLinkEndpointTestSupport.installWorkspace(on: window.agentModeViewModel, tabID: tabID, name: "Self noop body")
                session = window.agentModeViewModel.session(for: tabID)
                session.selectedAgent = .claudeCode
                session.hasLoadedPersistedState = true
                _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session, updateWorkspaceMetadata: true))
                session.recordRestorationAuthoritative(.persistedPayloadApplied)
                session.installRunID(UUID())
                for row in ordinaryRows ?? [.user("Existing ordinary request", sequenceIndex: 0), .assistant("Existing ordinary conclusion", sequenceIndex: 1)] {
                    session.appendItem(row)
                }
                // Imported test tool payloads must first pass the normal active retention
                // writer, before a physical attempt owns the source range. Otherwise
                // the first running publication structurally reconciles that raw fixture.
                if ordinaryRows != nil {
                    let imported = session.items
                    session.runState = .running
                    window.agentModeViewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                    print("W4_FIXTURE normalizedImportedRows=\(zip(imported, session.items).count(where: { $0.0 != $0.1 })) beforeAttempt=true")
                }
                session.runState = .completed
                window.agentModeViewModel.refreshDerivedTranscriptState(for: session, publishActivePresentation: false)
                owner = session.beginRunAttempt(source: "self-noop-body-test")
                let preparedRevision = session.sourceItemsRevision
                session.runState = .running
                if ordinaryRows != nil { XCTAssertEqual(session.sourceItemsRevision, preparedRevision, "Imported fixture must be normalized before opening an attempt") }
                endpoint = try AgentSessionLinkEndpointTestSupport.endpoint(window.agentModeViewModel, tabID: tabID)
                context = .trustedLocal(toolName: MCPWindowToolName.selfNoop, metadata: .init(connectionID: UUID(), clientName: "self-noop-test", windowID: window.windowID))
                origin = try .init(endpoint: endpoint, runID: XCTUnwrap(session.runID), runAttemptID: owner.attemptID)
                returnedEndpoint = endpoint
                if routine { session.quietLedger.markRoutineWake(owner: owner, wakeID: wakeID) }
            }

            /// Use the actual window manager and existing workspace-adoption owner BEFORE
            /// creating/binding/beginning the session. A VM-only endpoint manager does not
            /// establish the pane owner needed by window readers and published hydration.
            static func assembled() async throws -> Fixture {
                let window = WindowState()
                let manager = window.workspaceManager
                let vm = window.agentModeViewModel
                await manager.awaitInitialized()
                let tabID = UUID()
                let model = WorkspaceModel(name: "W4 assembled fake", repoPaths: [], ephemeralFlag: true, composeTabs: [ComposeTabState(id: tabID, name: "T1")], activeComposeTabID: tabID)
                manager.workspaces = [model]
                manager.activeWorkspace = model
                vm.workspaceManager = manager
                window.promptManager.loadComposeTabsFromWorkspace(model, syncPromptText: false)
                let adoption = vm.test_receiveWorkspaceSwitchNotification(model)
                await vm.test_handleWorkspaceSwitch(model, owner: adoption)
                await vm.test_waitForSessionListCacheRefresh()
                vm.test_setCurrentTabIDOverride(tabID)
                XCTAssertEqual(vm.currentPaneOwner?.workspaceID, model.id)
                return try Fixture(preparedWindow: window, preparedTabID: tabID)
            }

            func body() async throws -> Value {
                let captured = origin
                let service = AgentSelfMCPToolService(
                    captureRequestMetadata: {
                        await self.beforeMetadata()
                        return self.context.metadata
                    },
                    requireTargetWindow: { self.window },
                    resolveObserverEndpoint: { _, _ in self.returnedEndpoint },
                    captureCallOrigin: { captured },
                    enterNoop: { window, origin, invocationID, argumentsAreEmpty in
                        window.agentModeViewModel.enterSelfNoopBody(
                            origin: origin, invocationID: invocationID, argumentsAreEmpty: argumentsAreEmpty
                        )
                    },
                    acceptNoop: { window, origin, endpoint, invocationID in
                        window.agentModeViewModel.acceptSelfNoopBody(origin: origin, endpoint: endpoint, invocationID: invocationID)
                    },
                    readSelf: { _, _, _ in nil },
                    scheduleCompact: { _, _, _, _, _ in .unavailable }
                )
                return try await MCPInvocationContextBridge.withInvocation(context) {
                    try await service.executeNoop(args: [:])
                }
            }

            func appendDeclaration(invocationID: UUID? = nil) {
                session.appendItem(.toolCall(name: "self_noop", invocationID: invocationID ?? context.invocationID, argsJSON: "{}", sequenceIndex: session.nextSequenceIndex))
                session.appendItem(.toolResult(name: "self_noop", invocationID: invocationID ?? context.invocationID, resultJSON: "{\"result\":\"done\"}", isError: false, sequenceIndex: session.nextSequenceIndex))
            }

            func seal() -> AgentRunQuietFacts? {
                session.sealQuietCheckIn(owner: owner, terminalState: .completed, normal: true, hasSuccessor: false)
                return session.quietLedger.facts
            }
        }

        func testBodyAlwaysAcknowledgesCallWhileEligibilityAndBodyCountRemainIndependent() async throws {
            for variant in ["eligible", "not-routine", "duplicate", "stale-origin", "stale-endpoint", "own-prompt", "leading-text"] {
                let f = try Fixture(routine: variant != "not-routine")
                if variant == "stale-origin" { f.origin = .init(endpoint: f.endpoint, runID: UUID(), runAttemptID: UUID()) }
                if variant == "stale-endpoint" { f.returnedEndpoint = nil }
                if variant == "own-prompt" { f.session.waitingPrompt = "Own pending question" }
                if variant == "leading-text" { f.session.noteAcceptedStream(.init(type: "content", text: "Before declaration"), owner: f.owner) }
                let result = try await f.body()
                XCTAssertEqual(result, .object(["result": .string("done")]), variant)
                if variant == "duplicate" {
                    let repeated = try await f.body()
                    XCTAssertEqual(repeated, result)
                    XCTAssertEqual(f.session.quietLedger.declarationBodyEntryCardinality(owner: f.owner), 2)
                }
                f.appendDeclaration()
                XCTAssertEqual(f.seal()?.ordinaryThrough, variant == "eligible" ? 0 : 1, variant)
                XCTAssertEqual(f.session.items.count(where: { $0.quietCheckInWakeID == f.wakeID }), variant == "eligible" ? 2 : 0)
                XCTAssertEqual(f.session.quietLedger.hiddenSourceIDs.contains(f.wakeID), variant == "eligible")
            }
        }

        func testClosingTextAfterDeclarationIncludingEmptyOutputRepromptNeedsNoFinalChannel() async throws {
            let f = try Fixture()
            let acknowledgement = try await f.body()
            XCTAssertEqual(acknowledgement, AgentSelfNoopTool.acknowledgement)
            f.appendDeclaration()
            // The ordinary Claude re-prompt may produce content rather than a distinct final channel.
            f.session.noteAcceptedStream(.init(type: "content", text: ""), owner: f.owner)
            f.session.noteAcceptedStream(.init(type: "content", text: "Nothing further is needed."), owner: f.owner)
            f.session.appendItem(.assistant("Nothing further is needed.", sequenceIndex: f.session.nextSequenceIndex))
            XCTAssertEqual(f.seal()?.ordinaryThrough, 0)
            XCTAssertEqual(f.session.items.count(where: { $0.quietCheckInWakeID == f.wakeID }), 3)
        }

        func testNoDeclarationOrMissingCanonicalIdentityAndFurtherToolsStayOrdinary() async throws {
            for variant in ["silence", "ack", "other-keyword", "missing-id", "extra-canonical", "other-tool", "input", "unknown"] {
                let f = try Fixture()
                if variant == "ack" || variant == "other-keyword" {
                    f.session.appendItem(.assistant(variant == "ack" ? "[ack]" : "quiet / done / NOOP", sequenceIndex: f.session.nextSequenceIndex))
                } else if variant != "silence" {
                    _ = try await f.body()
                    f.appendDeclaration()
                    switch variant {
                    case "missing-id":
                        f.session.mutateItem(at: 2) { $0.toolInvocationID = nil }
                    case "extra-canonical":
                        f.session.appendItem(.toolResult(name: "self_noop", invocationID: UUID(), resultJSON: "{\"result\":\"done\"}", isError: false, sequenceIndex: f.session.nextSequenceIndex))
                    case "other-tool":
                        f.session.noteAcceptedStream(.init(type: "tool_call", text: nil, toolName: "read_file", toolInvocationID: UUID()), owner: f.owner)
                    case "input": f.session.noteAcceptedTaskInput()
                    default: f.session.noteAcceptedStream(.init(type: "event", text: "unknown semantic output"), owner: f.owner)
                    }
                }
                XCTAssertEqual(f.seal()?.ordinaryThrough, 1, variant)
            }
        }

        func testTwoHundredDeclarationSealsWithLongUnrelatedHistoryStayBounded() throws {
            // Exercise the actual W2 ledger pass over exact attempt slices. Full host/source refresh
            // work is an inherited W0/W1 boundary, not a component timing measurement.
            let binding = AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
            let endpoint = try DomainAgentSessionLinkEndpointIdentity(
                windowID: 1, workspaceID: UUID(), tabID: binding.tabID, sessionID: XCTUnwrap(binding.persistentSessionID),
                persistentBindingGeneration: binding.persistentBindingGeneration, bindingTransitionGeneration: binding.bindingTransitionGeneration
            )
            let runID = UUID()
            var ledger = AgentRunQuietLedger()
            var history = (0 ..< 10000).map { AgentChatItem.assistant("Ordinary retained history", sequenceIndex: $0) }
            history.append(.user("Current request", sequenceIndex: history.count))
            let start = ContinuousClock.now
            for _ in 0 ..< 200 {
                let owner = AgentRunOwnership(binding: binding)
                let firstKey = history.count
                ledger.begin(owner: owner, startKey: firstKey, provider: .claudeCode)
                ledger.markRoutineWake(owner: owner, wakeID: UUID())
                let invocationID = UUID()
                XCTAssertTrue(ledger.enterDeclarationBody(owner: owner, hostInvocationID: invocationID))
                XCTAssertTrue(try ledger.acceptDeclarationBody(
                    owner: owner, hostInvocationID: invocationID, wakeID: XCTUnwrap(ledger.routineWakeID(owner: owner)),
                    origin: .init(endpoint: endpoint, runID: runID, runAttemptID: owner.attemptID),
                    currentEndpoint: endpoint, currentRunID: runID
                ))
                history.append(.toolCall(name: "self_noop", invocationID: invocationID, argsJSON: "{}", sequenceIndex: firstKey))
                history.append(.toolResult(name: "self_noop", invocationID: invocationID, resultJSON: "{\"result\":\"done\"}", isError: false, sequenceIndex: firstKey + 1))
                ledger.noteDeclarationAssistantText(owner: owner, text: "Closing")
                history.append(.assistant("Closing", sequenceIndex: firstKey + 2))
                XCTAssertEqual(ledger.settle(
                    owner: owner, terminalState: .completed, classifiesQuietCheckIn: true,
                    endKey: firstKey + 2, rangeIsComplete: true, rows: history.suffix(3)
                )?.isQuiet, true)
                XCTAssertTrue(ledger.end(owner: owner, authoritativeOwner: owner))
            }
            XCTAssertEqual(ledger.facts?.settledThrough, 200)
            XCTAssertEqual(ledger.facts?.ordinaryThrough, 0)
            let elapsed = start.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(30), "W2 component fake budget; not an importer benchmark")
            print("W2_CLASSIFICATION_SCALE wakes=200 unrelatedRows=10000 elapsed=\(elapsed)")
        }

        func testBodyEntryBeforeSuspensionCannotEraseSiblingOrBorrowSuccessor() async throws {
            for replaceOwner in [false, true] {
                let f = try Fixture()
                let gate = TestReleaseFence(name: "self-noop metadata")
                f.beforeMetadata = { await gate.enterAndWait() }
                let task = Task { try await f.body() }
                guard await gate.waitUntilEntered() else { gate.release()
                    _ = try? await task.value
                    return
                }
                XCTAssertEqual(f.session.quietLedger.declarationBodyEntryCardinality(owner: f.owner), 1)
                XCTAssertNil(f.session.quietLedger.acceptedDeclarationInvocationID(owner: f.owner))
                if replaceOwner {
                    _ = f.session.endRunAttempt(ifCurrent: f.owner, source: "self-noop successor")
                    let successor = f.session.beginRunAttempt(source: "self-noop successor")
                    f.session.quietLedger.markRoutineWake(owner: successor, wakeID: UUID())
                } else { f.session.noteAcceptedTaskInput() }
                gate.release()
                let acknowledgement = try await task.value
                XCTAssertEqual(acknowledgement, AgentSelfNoopTool.acknowledgement)
                if replaceOwner {
                    let successor = try XCTUnwrap(f.session.activeRunOwnership)
                    XCTAssertNil(f.session.quietLedger.acceptedDeclarationInvocationID(owner: successor))
                    XCTAssertEqual(f.session.quietLedger.declarationBodyEntryCardinality(owner: successor), 0)
                } else {
                    f.appendDeclaration()
                    XCTAssertEqual(f.seal()?.ordinaryThrough, 1)
                }
            }
        }
    }
#endif
