import Darwin
import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

/// Context fixtures must use the real admitted claim, including pending-restoration claims;
/// a fabricated identity would hide precisely the routing failures these tests exercise.
@MainActor
func controlWriterIdentity(
    for session: AgentTabSession, scope: AgentSessionRuntimeStore.Scope? = nil
) throws -> AgentSessionRuntimeStore.WriterIdentity {
    let id = try XCTUnwrap(session.activeAgentSessionID)
    let resolution = scope?.resolveWriter(sessionID: id) ?? AgentSessionRuntimeStore.shared.resolveWriter(sessionID: id)
    guard case let .unique(writer) = resolution, writer.session === session else {
        throw NSError(domain: "Control fixture requires an exact runtime writer", code: 1)
    }
    return writer.identity
}

/// Direct coordinator tests bypass the runner, so supply its real restored admission and
/// attempt setup explicitly. Invalid fixtures fail rather than gaining an unfenced send path.
@MainActor
extension CodexAgentModeCoordinator {
    @discardableResult
    func test_sendCodexNativeMessage(
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        text: String,
        attachments: [AgentFileAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        stopFence: AgentRunStartStopFence? = nil,
        attachmentReservationID: UUID? = nil,
        policyAlreadyInstalled: Bool = false,
        terminalizeRejectedSend: Bool = true,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> NativeSendOutcome {
        guard let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID),
              writer.session === session,
              case let .success(command) = writer.admitCommand(.restored),
              let receipt = AgentSessionRuntimeStore.WriterReceipt(command)
        else {
            XCTFail("Direct Codex send requires an exact restored writer", file: file, line: line)
            return .preDispatchRejected(message: "Invalid Codex test fixture admission")
        }
        XCTAssertEqual(session.activeRunOwnership, ownership, file: file, line: line)
        return await sendCodexNativeMessage(
            session: session, writerReceipt: receipt, ownership: ownership, text: text,
            attachments: attachments, fallbackContext: fallbackContext, stopFence: stopFence,
            attachmentReservationID: attachmentReservationID, policyAlreadyInstalled: policyAlreadyInstalled,
            terminalizeRejectedSend: terminalizeRejectedSend, autoEffortSelection: autoEffortSelection,
            selfCompactDispatchID: selfCompactDispatchID
        )
    }
}

/// Direct Claude coordinator fixtures bypass runner admission. Require the same real restored
/// writer here before exercising their existing intent/configuration assertions. This helper does
/// not create a binding, restore a session, or synthesize an active run attempt. Older-attempt
/// intents intentionally remain allowed here so the production stale-intent checks are exercised.
@MainActor
extension ClaudeAgentModeCoordinator {
    private func test_hasRestoredWriter(_ session: AgentTabSession, file: StaticString, line: UInt) -> Bool {
        guard let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID),
              writer.session === session,
              case .success = writer.admitCommand(.restored)
        else {
            XCTFail("Direct Claude operation requires an exact restored writer", file: file, line: line)
            return false
        }
        return true
    }

    func test_ensureClaudeNativeSession(
        session: AgentTabSession,
        intent: NativeSessionIntent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> EnsureSessionOutcome {
        guard test_hasRestoredWriter(session, file: file, line: line) else { return .superseded }
        return await ensureClaudeNativeSession(session: session, intent: intent)
    }

    @discardableResult
    func test_sendClaudeNativeMessage(
        session: AgentTabSession,
        text: String,
        attachments: [AgentFileAttachment],
        intent: NativeSessionIntent,
        allowsCatalogRouteControllerRecovery: Bool,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        reinstallRunRoutingPolicy: (@MainActor () async -> Bool)? = nil,
        inputAttemptChanged: (@MainActor (Bool) -> Void)? = nil,
        providerLaunchInput: AgentProviderLaunchInput? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> NativeSendOutcome {
        guard test_hasRestoredWriter(session, file: file, line: line) else { return .superseded }
        return await sendClaudeNativeMessage(
            session: session, text: text, attachments: attachments, intent: intent,
            allowsCatalogRouteControllerRecovery: allowsCatalogRouteControllerRecovery,
            autoEffortSelection: autoEffortSelection, providerControlCommand: providerControlCommand,
            selfCompactDispatchID: selfCompactDispatchID, reinstallRunRoutingPolicy: reinstallRunRoutingPolicy,
            inputAttemptChanged: inputAttemptChanged,
            providerLaunchInput: providerLaunchInput
        )
    }
}

/// Runner-level harness for the cross-window oversight prompt supplement.
///
/// Builds the real `HeadlessAgentModeRunner` / `ACPIntegratedAgentModeRunner` (through
/// `AgentModeRunService`) with `AgentModeRunService.Hooks` whose session-link hooks are wired to a
/// **real** `AgentSessionLinkOutboundPromptClaimStore`. That is the whole point: these suites must
/// exercise the adapter call sites and their acceptance signals, not a re-implementation of them.
///
/// Deliberately avoids `MCPSharedServerTestLease`, window registration, and the view model's real
/// connection-policy installer: the lease is satisfied with a no-op installer and a granting
/// expected-PID armer, exactly as the run-service lifecycle suite does.
@MainActor
final class AgentSessionLinkRunnerHarness {
    let service: AgentModeRunService
    let resources: AgentRunProviderComposition
    let workspace: AgentRunWorkspaceInput
    var composition: AgentModeRunComposition {
        AgentModeRunComposition(execution: service, resources: resources, workspace: workspace)
    }

    let host: AgentModeViewModel
    let claimStore = AgentSessionLinkOutboundPromptClaimStore()
    let recorder: LifecycleRecorder
    /// The exact hooks the service's runners use, so a test can also build one runner directly.
    ///
    /// The headless runner is not reachable through `AgentModeRunComposition.startRun` for any shipping
    /// agent kind (Codex, Claude-compatible, and ACP kinds each route elsewhere), so its adapter can
    /// only be exercised by constructing the runner itself.
    private(set) var hooks: AgentModeRunService.Hooks!
    private let headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory

    /// Live observer inventory the claim hook reads. Mutating this mid-run is how a test simulates a
    /// monitor being added or revoked while a dispatch is suspended.
    private(set) var inventory: AgentSessionLinkPromptInventory

    var onTurnComplete: (() -> Void)?
    /// Runs after ACP message construction but before dispatch decoration. Controller preparation
    /// and stream acquisition now precede prompt entry; this hook tests the later projection window.
    var onAttachmentsConsumed: (@MainActor () -> Void)?

    /// Runs while the message is being built, i.e. the last synchronous MainActor point before the
    /// headless runner's lease `providerInitializationStarted` hop. A test uses it to enqueue a
    /// membership change that lands *during* that suspension.
    var onHeadlessMessageBuilt: (@MainActor () -> Void)?

    /// System prompt the message builder stamps, so a test can cover both Claude-compatible
    /// (`nativeSystemPrompt`) and generic (`userMessageXML`, empty system) headless shapes.
    var stubSystemPrompt: String

    private(set) var acceptedClaims: [AgentSessionLinkOutboundPromptClaim] = []
    private(set) var acceptedDispatchCount = 0
    let observerSessionID = UUID()

    /// The observer incarnation these runs dispatch as.
    ///
    /// Claims are epoch-scoped, so the harness needs one stable identity rather than a bare session
    /// UUID; mutating `allowsSupplement` here is how a test simulates an eligibility transition.
    lazy var promptEpoch = AgentSessionLinkPromptEpoch(
        endpoint: DomainAgentSessionLinkEndpointIdentity(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: observerSessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        ),
        allowsSupplement: true
    )

    /// Passive status batch offered to each claim, or `nil` for the membership-only default every
    /// pre-existing runner suite assumes.
    var passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?
    /// When set, provider-shaped dispatch IDs are rewritten to this wake identity exactly as the live
    /// view-model seam does. This lets adapter tests exercise required-claim refusal at the physical
    /// provider boundary without duplicating runner logic.
    var forcedAutoWakeID: UUID?
    /// Fake exact-returned support at reservation and final provider handoff.
    var routineQuietCheckIn = false
    private(set) var physicalNotAttemptedCount = 0
    var beforeProviderInputProof: (() async -> Void)?
    var providerInputReleaseOverride: (() -> AgentSessionLinkProviderInputRelease.ReleasedDispatchContext)?
    var pendingHandoffSendOutcome: ((AgentTabSession, Bool) -> Void)?
    var localInputFixture: AgentSessionLinkTransportLocalInputFixture?
    private var workspaces: [WorkspaceManagerViewModel] = []

    init(
        stubSystemPrompt: String = "BASE INSTRUCTIONS",
        headlessProviderFactory: @escaping AgentModeViewModel.HeadlessProviderFactory,
        acpProviderFactory: @escaping AgentModeViewModel.ACPProviderFactory = { _, _ in nil },
        workspacePath: String = FileManager.default.currentDirectoryPath,
        sessionLinkHost: AgentModeViewModel? = nil,
        replayTranscript: Bool = false,
        codexController: (any CodexSessionControlling)? = nil,
        claudeControllerFactory: ClaudeAgentModeCoordinator.ClaudeControllerFactory? = nil,
        testWindowID: Int = 1,
        testMCPServer: MCPServerViewModel? = nil,
        initialWorkspaceTabID: UUID? = nil,
        attachmentHooks: AgentModeRunService.AttachmentLifecycleHooks? = nil
    ) {
        self.stubSystemPrompt = stubSystemPrompt
        workspace = AgentRunWorkspaceInput(fallbackWorkspacePath: workspacePath)
        self.headlessProviderFactory = headlessProviderFactory
        let recorder = LifecycleRecorder()
        self.recorder = recorder
        inventory = AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: 0,
            items: []
        )

        let codexController = codexController ?? LifecycleNoopCodexController(recorder: recorder)
        let policyInstaller: AgentModeViewModel.ConnectionPolicyInstaller = { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
            // No MCP infrastructure in these suites: signal routing immediately so the bootstrap lease
            // resolves instead of waiting for a connection that will never arrive.
            if let runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
        }
        let serverEnabler: AgentModeViewModel.MCPServerEnabler = { true }
        let initialWorkspace = initialWorkspaceTabID.map {
            AgentSessionLinkEndpointTestSupport.makeWorkspace(tabID: $0, name: "Positive runner authority")
        }
        let host = AgentModeViewModel(
            testWindowID: testWindowID,
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in codexController },
            claudeControllerFactory: claudeControllerFactory,
            headlessProviderFactory: headlessProviderFactory,
            acpProviderFactory: acpProviderFactory,
            connectionPolicyInstaller: policyInstaller,
            mcpServerEnabler: serverEnabler,
            testMCPServer: testMCPServer,
            testWorkspaceManager: initialWorkspace
        )
        self.host = host
        if let initialWorkspace { workspaces.append(initialWorkspace) }
        if let initialWorkspaceTabID { host.test_setCurrentTabIDOverride(initialWorkspaceTabID) }

        resources = AgentRunProviderComposition(
            headless: headlessProviderFactory, acp: acpProviderFactory,
            controller: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
            }
        )
        let dependencies = AgentModeRunService.Dependencies(
            windowID: 1,
            connectionPolicyInstaller: policyInstaller,
            expectedPIDPolicyArmer: { _ in true },
            mcpServerEnabler: serverEnabler,
            codexCoordinator: host.test_codexCoordinator,
            claudeCoordinator: host.claudeCoordinator,
            shouldManageCodexTooling: false,
            providerRuntimePermissionResolver: { [bindingService = host.providerBindingService] agent, profile in
                bindingService.runtimePermission(for: agent, profile: profile)
            },
            bindPendingOracleReviewContext: { _, _ in },
            cancelMCPToolsForRun: { _, _ in },
            awaitNoActiveMCPTools: { _ in },
            activeAgentRunWaitQuery: { _ in false },
            childAgentRunWaitDrainTimeoutSeconds: 0.01
        )

        // `hooks` needs `self`, which is not fully initialized yet; build it through a box the
        // closures capture weakly.
        var harnessBox: AgentSessionLinkRunnerHarness?
        let hooks = AgentModeRunService.Hooks(
            usage: .init(
                estimateRuntimeTokens: { $0.count },
                addUserInputTokensToActiveNonCodexTurn: { _, _ in },
                startNonCodexTurnAccountingIfNeeded: { _, _ in },
                finalizeNonCodexTurnUsage: { _, _, _, _ in }
            ),
            attachments: attachmentHooks ?? .init(
                reserveAttachmentsForTurn: { _, _ in nil },
                markAttachmentsConsumed: { _, _ in
                    MainActor.assumeIsolated { harnessBox?.onAttachmentsConsumed?() }
                },
                stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
                consumeDeferredAttachmentCleanup: { _, _ in },
                finalizeAttachmentsForTurn: { _, _, _ in }
            ),
            presentation: .init(
                setAgentRunActive: { _, _ in },
                requestUIRefresh: { _, _ in },
                notifyAgentTurnComplete: { _ in harnessBox?.onTurnComplete?() }
            ),
            bindingObservation: .init(
                updateBindings: { _ in }
            ),
            queuedWorkRecovery: .init(
                restoreDraftText: { _, _, _, _ in }
            ),
            persistence: .init(
                scheduleSave: { _ in }
            ),
            transcript: .init(
                handleHeadlessStreamResult: { result, session, runID, attemptID in
                    if replayTranscript { await harnessBox?.host.test_handleStreamResult(result, session: session, runID: runID, runAttemptID: attemptID) }
                },
                finalizeStreamingItems: { session in if replayTranscript { harnessBox?.host.streamRuntime.finalizeStreamingItems(in: session) } },
                finalizePendingToolCalls: { _, _ in },
                finalizePendingToolCallsWithUpperBound: { _, _, _ in },
                flushPendingAssistantDelta: { session in if replayTranscript { harnessBox?.host.streamRuntime.flushPendingAssistantDelta(session) } },
                beginClaudeProviderOutputSegment: { session in
                    if replayTranscript {
                        harnessBox?.host.streamRuntime.flushPendingAssistantDelta(session)
                        harnessBox?.host.streamRuntime.endActiveAssistantSegment(session)
                    }
                },
                clearPendingAssistantDelta: { _ in }
            ),
            providerInput: .init(
                buildHeadlessAgentMessage: { _, text, _, _ in
                    MainActor.assumeIsolated {
                        harnessBox?.onHeadlessMessageBuilt?()
                        return AgentMessage(
                            systemPrompt: harnessBox?.stubSystemPrompt ?? "",
                            userMessage: text
                        )
                    }
                },
                augmentUserMessageForProviderSend: { text, _, _, _, _, _ in .init(text: text) },
                stageResumeRecoveryHandoffIfNeeded: { _ in true },
                prependPendingHandoffIfNeeded: { text, session in
                    sessionLinkHost?.handoffRuntime.prependPendingHandoffIfNeeded(text, session: session) ?? text
                },
                recordPendingHandoffSendOutcome: { session, sent in harnessBox?.pendingHandoffSendOutcome?(session, sent) },
                claimAgentSessionLinkPrompt: { session, dispatchID in
                    MainActor.assumeIsolated {
                        if let sessionLinkHost = harnessBox?.localInputFixture?.viewModel ?? sessionLinkHost {
                            return sessionLinkHost.linkExecutionRuntime.agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatchID)
                        }
                        guard let harnessBox else {
                            // Family-first, exactly like the production fence: a reserved-family
                            // value that does not parse must never degrade to "nothing owed".
                            return dispatchID.isAutoWakeFamily
                                ? .requiredLaneBatchUnavailable
                                : .nothingOwed
                        }
                        let effectiveDispatchID = harnessBox.forcedAutoWakeID.map {
                            AgentSessionLinkPromptDispatchID.autoWake(wakeID: $0)
                        } ?? dispatchID
                        return harnessBox.claimStore.claimOutcome(
                            dispatchID: effectiveDispatchID,
                            epoch: harnessBox.promptEpoch,
                            inventory: harnessBox.inventory,
                            passiveNotices: harnessBox.passiveNotices,
                            routineQuietCheckIn: harnessBox.routineQuietCheckIn
                        ) { request in
                            AgentSessionLinkPrompts.rendered(request)
                        }
                    }
                },
                acquireAgentSessionLinkPhysicalDispatch: { session, dispatchID in
                    sessionLinkHost?.linkExecutionRuntime.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: dispatchID) ?? true
                },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { session, dispatchID in
                    MainActor.assumeIsolated { harnessBox?.physicalNotAttemptedCount += 1 }
                    sessionLinkHost?.linkExecutionRuntime.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
                },
                recordAgentSessionLinkPhysicalDispatchFailure: { session, dispatchID in
                    sessionLinkHost?.linkExecutionRuntime.agentSessionLinkRecordPhysicalDispatchFailure(for: session, dispatchID: dispatchID)
                },
                acceptAgentSessionLinkPrompt: { session, context, claim in
                    MainActor.assumeIsolated {
                        harnessBox?.acceptedDispatchCount += 1
                        (harnessBox?.localInputFixture?.viewModel ?? sessionLinkHost)?.linkExecutionRuntime.acceptAgentSessionLinkDispatch(session: session, context: context, claim: claim)
                        guard let claim else { return }
                        harnessBox?.claimStore.accept(claim)
                        harnessBox?.acceptedClaims.append(claim)
                    }
                },
                proveAgentSessionLinkProviderInput: { session, claim in
                    await harnessBox?.beforeProviderInputProof?()
                    if let host = harnessBox?.localInputFixture?.viewModel ?? sessionLinkHost {
                        return await host.linkExecutionRuntime.agentSessionLinkProveProviderInput(for: session, claim: claim)
                    }
                    return await AgentSessionLinkProviderInputRelease.prove(claim) { _ in false }
                },
                handoffAgentSessionLinkProviderInput: { session, dispatchID, claim, proof in
                    if let release = harnessBox?.providerInputReleaseOverride { return release() }
                    if let host = harnessBox?.localInputFixture?.viewModel ?? sessionLinkHost {
                        return host.linkExecutionRuntime.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatchID, claim: claim, proof: proof)
                    }
                    return AgentSessionLinkProviderInputRelease.handoff(
                        original: claim,
                        proof: proof,
                        current: {
                            guard let harnessBox else { return .nothingOwed }
                            let effectiveID = harnessBox.forcedAutoWakeID.map { AgentSessionLinkPromptDispatchID.autoWake(wakeID: $0) } ?? dispatchID
                            return harnessBox.claimStore.claimOutcome(
                                dispatchID: effectiveID, epoch: harnessBox.promptEpoch, inventory: harnessBox.inventory,
                                passiveNotices: harnessBox.passiveNotices, routineQuietCheckIn: harnessBox.routineQuietCheckIn,
                                render: AgentSessionLinkPrompts.rendered
                            )
                        },
                        isPending: { _ in true },
                        consume: { _ in false }
                    )
                }
            ),
            interactions: .init(
                cancelPendingQuestion: { _ in },
                cancelPendingApproval: { _ in },
                cancelPendingApplyEditsReview: { _, _ in },
                cancelPendingWorktreeMergeReview: { _, _ in }
            ),
            terminalSettlement: .init(
                prepareTerminalPublication: { _ in },
                makeTerminalPublicationEnvelope: { _, _, _, _, _ in nil },
                publishTerminalCommit: { _, _, _ in .accepted(successorEpoch: nil) }
            ),
            continuation: .init(
                startFollowUpRun: { _, _ in },
                startTypedACPFollowUpRun: { _, _ in },
                signalMCPInstructionDelivered: { _ in }
            )
        )
        self.hooks = hooks
        service = AgentModeRunService(
            dependencies: dependencies,
            hooks: hooks,
            toolTrackingHooks: .noOp
        )
        harnessBox = self
    }

    /// A factory-free runner using the same execution hooks; `resources` fulfills its requests.
    func makeHeadlessRunner() -> HeadlessAgentModeRunner {
        HeadlessAgentModeRunner(
            hooks: hooks,
            terminalCommitBarrier: AgentRunTerminalCommitBarrier()
        )
    }

    /// Bootstrap lease with every side effect stubbed out: no MCP server, no connection policy, and
    /// routing signalled immediately so `acquire()` cannot park.
    nonisolated func makeLease(runID: UUID, tabID: UUID) -> MCPBootstrapLease {
        MCPBootstrapLease(
            spec: MCPBootstrapLeaseSpec(
                runID: runID,
                gateID: UUID(),
                windowID: 1,
                tabID: tabID,
                clientName: "RepoPromptCE",
                restrictedTools: [],
                additionalTools: nil,
                oneShot: true,
                reason: "monitor-runner-test",
                ttl: 60,
                purpose: .agentModeRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false
            ),
            mcpServerEnabler: { true },
            policyInstaller: { spec in
                await MCPRoutingWaiter.notifyRouted(runID: spec.runID)
            },
            expectedPIDPolicyArmer: { _ in true },
            policyClearer: { _ in }
        )
    }

    /// Publishes a new observer membership revision, like the runtime bridge does.
    func publishInventory(revision: UInt64, targetCount: Int) {
        inventory = AgentSessionLinkPromptInventory(
            observerSessionID: observerSessionID,
            linkSetRevision: revision,
            items: (0 ..< targetCount).map { index in
                AgentSessionLinkPromptInventoryItem(
                    targetSessionID: UUID(
                        uuidString: String(format: "0000000%d-0000-0000-0000-00000000FACE", index)
                    )!,
                    displayName: "Target \(index)",
                    capabilityNames: ["poll", "read", "send_when_idle", "wait"]
                )
            }
        )
    }

    func startCommand(for session: AgentTabSession) throws -> AgentSessionRuntimeStore.Command {
        let id = try XCTUnwrap(session.activeAgentSessionID)
        let command = try XCTUnwrap(host.runtimeCommand(sessionID: id))
        XCTAssertTrue(command.writer.session === session)
        return command
    }

    func makeBoundSession(agent: AgentProviderKind, tabID suppliedTabID: UUID? = nil) throws -> AgentModeViewModel.TabSession {
        let tabID = suppliedTabID ?? UUID()
        if suppliedTabID == nil {
            workspaces.append(AgentSessionLinkEndpointTestSupport.installWorkspace(on: host, tabID: tabID, name: "Positive runner authority"))
        } else {
            XCTAssertEqual(host.workspaceManager?.activeWorkspace?.activeComposeTabID, tabID)
            XCTAssertEqual(host.managedInputEnvironment().workspaceID, host.workspaceManager?.activeWorkspaceID)
        }
        let session = host.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        _ = try XCTUnwrap(host.test_installPersistentSessionBinding(
            sessionID: UUID(), on: session, updateWorkspaceMetadata: true
        ))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        return session
    }

    func makeSession(agent: AgentProviderKind) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        return session
    }
}

// MARK: - Headless provider fake

/// Captures the exact `AgentMessage` that crossed `streamAgentMessage`, and can fail stream creation.
actor AgentSessionLinkCapturingHeadlessProvider: HeadlessAgentProvider {
    struct StreamCreationFailure: Error {}

    private(set) var messages: [AgentMessage] = []
    private var failuresRemaining: Int
    private let beforeStream: (@Sendable (UUID?) async -> Void)?
    private let onDispose: (@Sendable () async -> Void)?

    init(
        failuresRemaining: Int = 0,
        beforeStream: (@Sendable (UUID?) async -> Void)? = nil,
        onDispose: (@Sendable () async -> Void)? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.beforeStream = beforeStream
        self.onDispose = onDispose
    }

    var messageCount: Int {
        messages.count
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        await beforeStream?(runID)
        messages.append(message)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw StreamCreationFailure()
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func dispose() async {
        await onDispose?()
    }
}

// MARK: - ACP provider fake

/// Records the `AgentMessage` the real `ACPAgentSessionController` passes to `buildPromptBlocks`,
/// which is exactly the message that reached `controller.prompt`.
final class AgentSessionLinkCapturingACPProvider: ACPAgentProvider, @unchecked Sendable {
    let providerID: ACPProviderID
    let commandPath: String
    var environment: [String: String] = [:]
    /// Normalizes session updates with the shipped default normalizer instead of dropping them, so
    /// `usage_update` reaches the usage estimator in view-model-level suites.
    var usesDefaultNormalizer = false

    private let lock = NSLock()
    private var captured: [AgentMessage] = []
    private var supportChecks = 0
    private let supportOperation: (@Sendable () async throws -> ACPSupportResult)?

    var supportCallCount: Int {
        lock.withLock { supportChecks }
    }

    init(providerID: ACPProviderID, commandPath: String, environment: [String: String] = [:], supportOperation: (@Sendable () async throws -> ACPSupportResult)? = nil) {
        self.supportOperation = supportOperation
        self.providerID = providerID
        self.commandPath = commandPath
        self.environment = environment
    }

    var promptedMessages: [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    var supportsParameterizedModelPicker: Bool {
        providerID == .devin
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        providerID == .devin && input.category == "thought_level" ? .thinking : nil
    }

    func support(for _: ACPRunRequest) async throws -> ACPSupportResult {
        lock.withLock { supportChecks += 1 }
        if let supportOperation { return try await supportOperation() }
        return .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: environment["ACP_FAIL_LOAD"] == "1" || environment["ACP_LOAD"] == "1"
                ? request.resumeSessionID.map { .load(existingSessionID: $0) } ?? .new : .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request _: ACPRunRequest
    ) throws -> [[String: Any]] {
        lock.lock()
        captured.append(message)
        lock.unlock()
        return [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        usesDefaultNormalizer
            ? ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID)
            : []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

// MARK: - Fake ACP server

/// A pipe gate holds an actual JSON-RPC response without timing sleeps or blocking the test actor.
final class AgentSessionLinkACPResponseGate {
    let path: String
    private let handle: FileHandle
    private var released = false

    init(directory: URL) throws {
        path = directory.appendingPathComponent("response-gate").path
        guard mkfifo(path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
    }

    func waitUntilEntered() async throws {
        let marker = path + ".entered"
        try await AsyncTestWait.waitUntil("scripted ACP response to reach its gate") {
            FileManager.default.fileExists(atPath: marker)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        try? handle.write(contentsOf: Data([1]))
    }

    deinit {
        if !released {
            try? handle.write(contentsOf: Data([1]))
        }
        try? handle.close()
    }
}

enum AgentSessionLinkACPServerScript {
    /// Minimal ACP server. `ACP_FAIL_PROMPTS_CONTAINING` makes `session/prompt` return an error when
    /// the prompt text contains that marker, which is how a test forces a failed steer.
    ///
    /// Synthetic slash-command fixtures, modelled on the ACP spec's shapes (no provider-recorded
    /// traffic exists yet, so these are live-unverified):
    /// - `ACP_ADVERTISE_COMMANDS` (comma list): an `available_commands_update` right after
    ///   `session/new`; `__malformed__` sends a non-list `availableCommands`.
    /// - `ACP_ADVERTISE_BEFORE_NEW_RESPONSE` (`1`): delivers the bootstrap advertisement before
    ///   the `session/new` response, while the controller's session identity is still unopened.
    /// - `ACP_ADVERTISE_AFTER_PROMPT` (comma list, may be empty): a replacement list during each prompt.
    /// - `ACP_PROMPT_LOG` (path): each `session/prompt` `prompt` array, one JSON line per prompt.
    /// - `ACP_RPC_LOG` (path): actual JSON-RPC requests and successful responses.
    /// - `ACP_FAIL_METHOD`: rejects the named RPC after any response gate has released.
    /// - `ACP_DEVIN_FIXTURE` (`1`): advertises SWE-2 with medium/high/max thinking choices.
    /// - `ACP_USAGE_UPDATE_ON_PROMPT` (`used,size`): a `usage_update` during each prompt.
    /// - `ACP_FOREIGN_ADVERTISE_AFTER_PROMPT` (comma list): a list for another session during each prompt.
    /// - `ACP_UNMATCHED_RESPONSE_ON_PROMPT`: a response with an unknown id during each prompt (a protocol
    ///   violation that fails the controller).
    /// - `ACP_ADVERTISE_ON_CANCEL` (comma list): a list for the cancelled session on each `session/cancel`.
    /// - `ACP_LOAD` (`1`): open the request's `resumeSessionID` with a successful `session/load`, which
    ///   also advertises `ACP_ADVERTISE_COMMANDS`.
    static func write(to directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("monitor_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        fail_marker = os.environ.get("ACP_FAIL_PROMPTS_CONTAINING")
        prompt_log = os.environ.get("ACP_PROMPT_LOG")
        devin_fixture = os.environ.get("ACP_DEVIN_FIXTURE") == "1"
        current_model = "swe-2-high" if devin_fixture else "model-a"
        current_thinking = "high"
        current_mode = "ask"

        def trace(direction, payload):
            path = os.environ.get("ACP_RPC_LOG")
            if path:
                with open(path, "a") as log:
                    log.write(json.dumps({"direction": direction, "payload": payload}) + "\n")

        def config_options():
            # The controller refuses to run against a runtime that does not advertise a modern
            # session-mode select, so both selects are required here.
            options = [
                {
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": current_model,
                    "options": [{"value": "swe-2-high", "name": "SWE-2"}] if devin_fixture else [{"value": "model-a", "name": "Model A"}]
                },
                {
                    "id": "mode",
                    "name": "Session Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": current_mode,
                    "options": [
                        {"value": "ask", "name": "Ask"},
                        {"value": "repoprompt_acp", "name": "RepoPrompt"},
                        {"value": "repoprompt_acp_full_access", "name": "RepoPrompt Full Access"},
                        {"value": "auto_edit", "name": "Auto Edit"}
                    ]
                }
            ]
            if devin_fixture:
                options.append({
                    "id": "thought_level", "name": "Thinking", "category": "thought_level",
                    "type": "select", "currentValue": current_thinking,
                    "options": [{"value": value, "name": value} for value in ["medium", "high", "max"]]
                })
            return options

        def notify_update(session_id, update):
            print(json.dumps({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"sessionId": session_id, "update": update}
            }), flush=True)

        def advertise(session_id, raw):
            if raw == "__malformed__":
                commands = "not-a-list"
            else:
                commands = [
                    {"name": name, "description": name + " command", "input": None}
                    for name in raw.split(",") if name
                ]
            notify_update(session_id, {
                "sessionUpdate": "available_commands_update",
                "availableCommands": commands
            })

        def respond(request_id, result=None):
            response = {"jsonrpc": "2.0", "id": request_id, "result": result or {}}
            trace("response", response)
            print(json.dumps(response), flush=True)

        def respond_error(request_id, message):
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32000, "message": message}
            }), flush=True)

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            trace("request", request)
            method = request.get("method")
            params = request.get("params") or {}
            if method == os.environ.get("ACP_HOLD_METHOD"):
                gate_path = os.environ["ACP_RESPONSE_GATE"]
                with open(gate_path + ".entered", "w"):
                    pass
                with open(gate_path, "rb", buffering=0) as gate:
                    gate.read(1)
            if method == os.environ.get("ACP_FAIL_METHOD"):
                respond_error(request.get("id"), "injected startup failure")
                continue
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True}, "authMethods": []})
            elif method == "session/load" and os.environ.get("ACP_FAIL_LOAD"):
                respond_error(request.get("id"), "session not found: invalid params")
            elif method == "session/load":
                respond(request.get("id"), {"configOptions": config_options()})
                if os.environ.get("ACP_ADVERTISE_COMMANDS") is not None:
                    advertise(params.get("sessionId"), os.environ["ACP_ADVERTISE_COMMANDS"])
            elif method == "session/new":
                advertises_before = os.environ.get("ACP_ADVERTISE_BEFORE_NEW_RESPONSE") == "1"
                if advertises_before and os.environ.get("ACP_ADVERTISE_COMMANDS") is not None:
                    advertise("monitor-acp-session", os.environ["ACP_ADVERTISE_COMMANDS"])
                respond(request.get("id"), {
                    "sessionId": "monitor-acp-session",
                    "configOptions": config_options()
                })
                if not advertises_before and os.environ.get("ACP_ADVERTISE_COMMANDS") is not None:
                    advertise("monitor-acp-session", os.environ["ACP_ADVERTISE_COMMANDS"])
            elif method == "session/cancel" and os.environ.get("ACP_ADVERTISE_ON_CANCEL") is not None:
                advertise(params.get("sessionId"), os.environ["ACP_ADVERTISE_ON_CANCEL"])
            elif method == "session/set_config_option":
                if params.get("configId") == "model":
                    current_model = params.get("value")
                elif params.get("configId") == "mode":
                    current_mode = params.get("value")
                elif params.get("configId") == "thought_level":
                    current_thinking = params.get("value")
                respond(request.get("id"), {"configOptions": config_options()})
            elif method == "session/prompt":
                if prompt_log:
                    with open(prompt_log, "a") as log:
                        log.write(json.dumps(params.get("prompt")) + "\n")
                if os.environ.get("ACP_UNMATCHED_RESPONSE_ON_PROMPT"):
                    respond(987654, {})
                if os.environ.get("ACP_ADVERTISE_AFTER_PROMPT") is not None:
                    advertise(params.get("sessionId"), os.environ["ACP_ADVERTISE_AFTER_PROMPT"])
                if os.environ.get("ACP_FOREIGN_ADVERTISE_AFTER_PROMPT") is not None:
                    advertise("foreign-session", os.environ["ACP_FOREIGN_ADVERTISE_AFTER_PROMPT"])
                if os.environ.get("ACP_USAGE_UPDATE_ON_PROMPT"):
                    used, size = os.environ["ACP_USAGE_UPDATE_ON_PROMPT"].split(",")
                    notify_update(params.get("sessionId"), {
                        "sessionUpdate": "usage_update",
                        "used": int(used),
                        "size": int(size)
                    })
                text = json.dumps(params)
                if fail_marker and fail_marker in text:
                    respond_error(request.get("id"), "prompt rejected")
                else:
                    respond(request.get("id"), {
                        "stopReason": "end_turn",
                        "usage": {"inputTokens": 1, "outputTokens": 1}
                    })
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }
}
