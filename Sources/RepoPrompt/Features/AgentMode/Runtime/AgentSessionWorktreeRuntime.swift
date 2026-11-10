import Foundation
import MCP
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptWorkspaceContext

/// Execution-location transactions belong to the exact writer, not its presenting tab. The host
/// supplies resource/protocol adapters; this owner sequences preparation, effects and persistence.
@MainActor
final class AgentSessionWorktreeRuntime {
    typealias Intent = AgentModeViewModel.WorktreeBindingTransitionIntent
    typealias Confirmation = AgentModeViewModel.ExecutionLocationChangeConfirmation

    enum TransitionError: LocalizedError {
        case unavailable(String)
        case stale
        case confirmationRequired(Confirmation)
        case retainedWorktree(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message): message
            case .stale: "The thread changed while its execution location was being prepared. Try again."
            case .confirmationRequired(.startedThreadRestart): "Changing execution location restarts the agent context and requires confirmation."
            case .confirmationRequired(.activeRunStop): "Changing execution location stops the active run and requires confirmation."
            case let .retainedWorktree(path, underlying):
                "The new worktree was created at \(path), but the thread could not be switched. It was not removed. Error: \(underlying)"
            }
        }
    }

    /// An effect already happened. This is never a retryable pre-effect refusal, even if authority
    /// was revoked, cancellation arrived, or the originating writer disappeared before its save.
    struct PartialTransition: LocalizedError {
        let writer: AgentSessionRuntimeStore.WriterIdentity
        let bindingsPublished: Bool
        let providerRetired: Bool
        let recoverySaved: Bool
        let detail: String
        var cause: Error?

        var errorDescription: String? {
            "Execution-location change for session \(writer.sessionID): bindings published=\(bindingsPublished), provider retired=\(providerRetired), recovery saved=\(recoverySaved). \(detail) Inspect the session before retrying; no turn was replayed."
        }
    }

    struct Resources {
        let store: WorkspaceFileContextStore?
        let fallbackWorkspacePath: String?
        let declaredRepoPaths: [String]
        let isCurrent: @MainActor () -> Bool

        init(
            store: WorkspaceFileContextStore?, fallbackWorkspacePath: String?,
            declaredRepoPaths: [String], isCurrent: @escaping @MainActor () -> Bool
        ) {
            self.store = store
            self.fallbackWorkspacePath = fallbackWorkspacePath
            self.declaredRepoPaths = declaredRepoPaths
            self.isCurrent = isCurrent
        }
    }

    struct Effects {
        let drainOracle: @MainActor (AgentTabSession) async -> Bool
        let cancelRun: @MainActor (AgentTabSession) async -> Void
        let stageRecovery: @MainActor (AgentTabSession) async -> AgentSessionHandoffRuntime.RecoveryResult
        /// Must detach synchronously before its first await and retire only captured instances.
        let retireProvider: @MainActor (AgentTabSession) async -> Void
    }

    struct Presentation {
        let gateChanged: @MainActor (AgentTabSession) -> Void
        let location: @MainActor (AgentTabSession) -> AgentSessionLinkLocationProjection?
        let bindingsChanged: @MainActor (AgentTabSession, AgentSessionLinkLocationProjection?) -> Void
        let recoveryChanged: @MainActor (AgentTabSession) -> Void
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?
    var captureResources: (@MainActor (AgentSessionRuntimeStore.Command) -> Resources?)?
    var effects: Effects?
    var presentation: Presentation?
    private(set) var pendingTransitions = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForTransitions() async {
        guard pendingTransitions > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    @discardableResult
    func transition(
        _ desiredBindings: [AgentSessionWorktreeBinding],
        command: AgentSessionRuntimeStore.Command,
        intent: Intent,
        startupContext: WorktreeStartupContext? = nil,
        initializationHintsByBindingID: [String: WorkspaceRootMaterializationHint] = [:],
        beforeCommit: (@MainActor () async throws -> Void)? = nil,
        revalidateAuthority: (@MainActor () async throws -> Void)? = nil,
        commitAuthority: (@MainActor (@MainActor () throws -> Void) throws -> Void)? = nil,
        afterCommit: (@MainActor () -> Void)? = nil
    ) async throws -> [AgentSessionWorktreeBinding] {
        guard let scope, command.writer.scope === scope, command.isCurrent else { throw TransitionError.stale }
        try Task.checkCancellation()
        let session = command.writer.session
        let sessionID = command.identity.sessionID
        let previousBindings = session.worktreeBindings
        // Even no-ops require the original writer, but do not touch resources/provider/presentation.
        guard previousBindings != desiredBindings else { return previousBindings }
        guard let resources = captureResources?(command), resources.isCurrent(), let effects else {
            throw TransitionError.unavailable("The session's execution workspace is unavailable.")
        }
        do { try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings) }
        catch { throw TransitionError.unavailable(error.localizedDescription) }
        guard !session.worktreeBindingTransitionInProgress else { throw TransitionError.stale }
        pendingTransitions += 1
        let gateOwner = UUID()
        session.worktreeBindingTransitionInProgress = true
        session.worktreeBindingTransitionOwner = gateOwner
        var ownsExecutionLocationGate = false
        func ownsOrigin() -> Bool {
            command.writer.ownsPersistentClaim && session.currentRestorationBindingToken == command.identity.restoration
        }
        defer {
            pendingTransitions -= 1
            // Release only this operation's resource leases, including after claim loss. A direct
            // successor setter clears the token, so old cleanup cannot release a successor gate.
            if session.worktreeBindingTransitionOwner == gateOwner {
                session.worktreeBindingTransitionInProgress = false
            }
            if session.executionLocationChangeOwner == gateOwner {
                session.isChangingExecutionLocation = false
            }
            if ownsOrigin() { presentation?.gateChanged(session) }
            if pendingTransitions == 0 {
                let waiters = drainWaiters
                drainWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        func requireCurrent() throws {
            guard command.isCurrent, resources.isCurrent(), session.worktreeBindings == previousBindings else {
                throw TransitionError.stale
            }
        }
        if let startupContext { WorktreeStartupInstrumentation.record(.bindingTransitionStarted, context: startupContext) }
        let executionRootsChanged = Self.changesExecutionRoots(
            from: previousBindings, to: desiredBindings, fallbackWorkspacePath: resources.fallbackWorkspacePath
        )
        let changedDuringActiveRun = session.runState.isActive
        if changedDuringActiveRun, executionRootsChanged {
            switch intent {
            case .userExecutionLocationChange(confirmation: .activeRunStop): break
            case .userExecutionLocationChange: throw TransitionError.confirmationRequired(.activeRunStop)
            case .externalManagement:
                throw MCPError.invalidParams("Stop the active Agent run before changing its execution worktree. The in-flight prompt will not be migrated or replayed automatically.")
            case .initialSend: throw MCPError.invalidParams("A running Agent thread cannot apply an initial execution location.")
            }
        }
        if executionRootsChanged {
            guard await effects.drainOracle(session) else { throw TransitionError.stale }
            try requireCurrent()
        }
        if executionRootsChanged, case .externalManagement = intent {
            try Self.requireIdle(session)
            session.isChangingExecutionLocation = true
            session.executionLocationChangeOwner = gateOwner
            ownsExecutionLocationGate = true
            presentation?.gateChanged(session)
            try await Self.requireIdleProvider(session)
            try requireCurrent()
            try Self.requireIdle(session, ownsExecutionLocationGate: true)
        }
        let materializer = resources.store.map(WorkspaceRootBindingProjectionMaterializer.init(store:))
        let preparation: WorkspaceRootBindingProjectionPreparation?
        if let materializer {
            do {
                preparation = try await materializer.prepare(
                    sessionID: sessionID, bindings: desiredBindings, startupContext: startupContext,
                    initializationHintsByBindingID: initializationHintsByBindingID
                )
            } catch { throw TransitionError.unavailable(error.localizedDescription) }
        } else if desiredBindings.isEmpty {
            preparation = nil
        } else {
            throw TransitionError.unavailable("The selected worktree roots could not be prepared for this thread.")
        }
        var ownershipCommitted = preparation == nil
        var providerContextInvalidated = false
        var bindingsPublished = false
        var handoffRollback: (previous: AgentPendingHandoffState, staged: AgentPendingHandoffState)?
        func saveOrigin() async -> Result<Void, AgentSessionPersistenceFailure> {
            // Cleanup may persist after command retirement, never after replacement/restoration.
            guard command.writer.isCurrent, resources.isCurrent() else {
                return .failure(.init(operation: .save, tabID: session.tabID, message: "The originating writer or workspace changed before persistence."))
            }
            return await Task<Result<Void, AgentSessionPersistenceFailure>, Never> { @MainActor in
                guard command.writer.isCurrent, resources.isCurrent() else {
                    return .failure(.init(operation: .save, tabID: session.tabID, message: "The originating writer changed before persistence."))
                }
                return await scope.persistence.flushSaveRequired(writer: command.writer)
            }.value
        }
        do {
            try requireCurrent()
            guard !executionRootsChanged || session.runState.isActive == changedDuringActiveRun else { throw TransitionError.stale }
            try Task.checkCancellation()
            if executionRootsChanged, case .externalManagement = intent {
                try Self.requireIdle(session, ownsExecutionLocationGate: ownsExecutionLocationGate)
                try await Self.requireIdleProvider(session)
                try requireCurrent()
                try Self.requireIdle(session, ownsExecutionLocationGate: ownsExecutionLocationGate)
            }
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
            try await revalidateAuthority?()
            try requireCurrent()
            try await beforeCommit?()
            try requireCurrent()
            try await revalidateAuthority?()
            try requireCurrent()
            try Task.checkCancellation()
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
            guard !executionRootsChanged || session.runState.isActive == changedDuringActiveRun else { throw TransitionError.stale }
            if executionRootsChanged, case .externalManagement = intent {
                try Self.requireIdle(session, ownsExecutionLocationGate: ownsExecutionLocationGate)
            }
            if executionRootsChanged {
                if changedDuringActiveRun {
                    // Terminal publication detaches the old runtime: a later failure is already
                    // partial even if this command never reaches the idle-retirement adapter.
                    providerContextInvalidated = true
                    await effects.cancelRun(session)
                    try requireCurrent()
                }
                guard !session.runState.isActive else { throw TransitionError.stale }
                if !changedDuringActiveRun {
                    try commitAuthority? {}
                    try requireCurrent()
                    let previousHandoff = session.pendingHandoff
                    switch await effects.stageRecovery(session) {
                    case let .staged(staged): handoffRollback = (previousHandoff, staged)
                    case .unchanged: break
                    case .refused: throw TransitionError.stale
                    }
                    try requireCurrent()
                    try await revalidateAuthority?()
                    try requireCurrent()
                }
                try commitAuthority? {}
                try requireCurrent()
                providerContextInvalidated = true
                await effects.retireProvider(session)
                try requireCurrent()
                guard !session.runState.isActive else { throw TransitionError.stale }
            }
            try await revalidateAuthority?()
            try requireCurrent()
            try Task.checkCancellation()
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
            if let materializer, let preparation {
                _ = try await materializer.commit(preparation)
                ownershipCommitted = true
            }
            try await revalidateAuthority?()
            try requireCurrent()
            try Task.checkCancellation()
            guard !executionRootsChanged || !session.runState.isActive else { throw TransitionError.stale }
            let previousLocation = presentation?.location(session)
            let publish: @MainActor () throws -> Void = {
                try requireCurrent()
                try Task.checkCancellation()
                try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(desiredBindings)
                session.worktreeBindings = desiredBindings
            }
            if let commitAuthority { try commitAuthority(publish) } else { try publish() }
            bindingsPublished = true
            session.isDirty = true
            scope.persistence.scheduleSave(for: session)
            presentation?.bindingsChanged(session, previousLocation)
            afterCommit?()
            if case .externalManagement = intent {
                switch await saveOrigin() {
                case .success:
                    guard command.writer.isCurrent, session.worktreeBindings == desiredBindings else {
                        throw PartialTransition(writer: command.identity, bindingsPublished: true, providerRetired: providerContextInvalidated, recoverySaved: true, detail: "The binding save completed, but its writer changed before acknowledgement.")
                    }
                case let .failure(failure):
                    throw PartialTransition(writer: command.identity, bindingsPublished: true, providerRetired: providerContextInvalidated, recoverySaved: false, detail: failure.message)
                }
            }
            // Return the committed value, never fields from a tab's later occupant.
            return desiredBindings
        } catch {
            if !providerContextInvalidated, let handoffRollback, ownsOrigin(),
               session.pendingHandoff == handoffRollback.staged
            {
                session.pendingHandoff = handoffRollback.previous
                session.isDirty = true
                _ = await saveOrigin()
                if command.writer.isCurrent { scope.persistence.scheduleSave(for: session) }
            }
            if !ownershipCommitted, let materializer, let preparation {
                await materializer.abort(preparation)
            } else if executionRootsChanged, ownershipCommitted, !bindingsPublished, let materializer, let preparation,
                      !preparation.ownership.reusesInstalledOwnership
            {
                // Token-qualified cleanup does not require today's writer and cannot release a
                // successor's installation. The old bindings rematerialize on demand. Same-root
                // metadata edits retain ownership: their old provider may still be executing there.
                await materializer.release(ifOwnedBy: preparation.ownership.token)
            }
            if let partial = error as? PartialTransition { throw partial }
            if providerContextInvalidated || bindingsPublished {
                var saved = false
                var detail: String = if let hostError = error as? SessionAdminHostError, case .authorityEnded = hostError {
                    "Delegated authority ended after provider retirement; the binding was not published."
                } else {
                    error.localizedDescription
                }
                if !bindingsPublished, ownsOrigin(), session.worktreeBindings == previousBindings {
                    detail = "The worktree switch did not apply. The previous execution binding is unchanged, but its provider runtime was retired. The next user message will restart at the previous location using the retained handoff; no turn was replayed. Cause: \(detail)"
                    session.appendItem(.system(detail, sequenceIndex: session.nextSequenceIndex))
                    session.isDirty = true
                    presentation?.recoveryChanged(session)
                    if case .success = await saveOrigin() { saved = true }
                    if !saved, command.writer.isCurrent { scope.persistence.scheduleSave(for: session) }
                }
                throw PartialTransition(writer: command.identity, bindingsPublished: bindingsPublished, providerRetired: providerContextInvalidated, recoverySaved: saved, detail: detail, cause: error)
            }
            if MCPDomainMutationCommitContext.controller != nil, error is MCPError {
                throw DomainMutationRefusedBeforeEffects(error)
            }
            throw error
        }
    }

    static func changesExecutionRoots(
        from previous: [AgentSessionWorktreeBinding], to desired: [AgentSessionWorktreeBinding], fallbackWorkspacePath: String?
    ) -> Bool {
        func primary(_ bindings: [AgentSessionWorktreeBinding]) -> [String?] {
            let binding = AgentWorktreeRuntimeWorkspaceResolver.primaryExecutionBinding(in: bindings, fallbackWorkspacePath: fallbackWorkspacePath)
            return [
                binding?.repositoryID,
                binding?.worktreeID,
                AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(binding?.worktreeRootPath)
                    ?? AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(fallbackWorkspacePath)
            ]
        }
        func mappings(_ bindings: [AgentSessionWorktreeBinding]) -> [String: [String]] {
            bindings.reduce(into: [:]) { result, binding in
                let key = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(binding.logicalRootPath) ?? binding.logicalRootPath
                result[key] = [
                    binding.repositoryID,
                    binding.worktreeID,
                    AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(binding.worktreeRootPath) ?? binding.worktreeRootPath
                ]
            }
        }
        return primary(previous) != primary(desired) || mappings(previous) != mappings(desired)
    }

    static func requireIdle(_ session: AgentTabSession, ownsExecutionLocationGate: Bool = false) throws {
        guard !session.runState.isActive, session.activeRunLiveness == nil, session.agentTask == nil,
              !session.terminalCommitInProgress, !session.bindingTransitionInProgress,
              !session.isComposerSubmissionInFlight, !session.isPreparingInitialWorktree,
              ownsExecutionLocationGate || !session.isChangingExecutionLocation,
              !session.mcpFollowUpRunPending, session.pendingSupersedingTurnCompletions == 0,
              session.pendingInstructions.isEmpty, session.pendingClaudeSteeringInstructions.isEmpty,
              session.pendingACPSteeringInstructions.isEmpty, session.claudeSteeringFlushTask == nil,
              session.acpSteeringFlushTask == nil, session.codexNativeToolLiveness.inFlight.isEmpty,
              session.oversight.pendingAutoWake == nil, !session.selfCompactState.blocksOverseerDelivery,
              !session.stopState.isStopping(binding: session.persistentSessionBindingIdentity),
              !session.isSettlingACPBackgroundCompaction, !session.hasBindingBlockingInteraction
        else {
            throw MCPError.invalidParams("Wait until this Agent session is idle with no queued work or pending interactions before changing its execution worktree. The current turn is not migrated or replayed.")
        }
    }

    static func requireIdleProvider(_ session: AgentTabSession) async throws {
        let claudeController = session.claudeController
        let acpController = session.acpController
        let codexController = session.codexController
        if let controller = claudeController, await controller.hasTurnInFlight {
            throw MCPError.invalidParams("The Claude runtime still has a turn in flight. Wait for it to settle before switching worktrees.")
        }
        if let controller = acpController, await controller.hasExecutionInFlight {
            throw MCPError.invalidParams("The ACP runtime still has execution in flight. Wait for it to settle before switching worktrees.")
        }
        if let controller = codexController {
            let snapshot: CodexNativeSessionController.ThreadSnapshot
            do { snapshot = try await controller.readThreadSnapshot(includeTurns: false, timeout: 2) }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw MCPError.invalidParams("Could not verify that the Codex runtime is idle. Its execution binding and runtime were not changed. Wait for it to settle and inspect the session before retrying. \(error.localizedDescription)")
            }
            let outstandingTools = await controller.outstandingBlockingNativeToolCallNames()
            guard snapshot.runtimeStatus == .idle, !snapshot.hasActiveTurn, outstandingTools.isEmpty else {
                throw MCPError.invalidParams("The Codex runtime still has a turn or native tool in flight. Wait for it to settle before switching worktrees.")
            }
        }
        guard session.claudeController === claudeController, session.acpController === acpController,
              session.codexController === codexController else { throw TransitionError.stale }
        try Task.checkCancellation()
    }
}
