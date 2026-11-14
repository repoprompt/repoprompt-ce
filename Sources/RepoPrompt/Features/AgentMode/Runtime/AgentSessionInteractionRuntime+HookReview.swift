import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

extension AgentSessionInteractionRuntime {
    func codexHookCommand(for session: AgentTabSession) throws -> AgentSessionRuntimeStore.Command {
        guard let command = try? scope?.admit(session: session) else { throw AgentCodexHookReviewResolutionError.staleWriter }
        return command
    }

    private func hookOriginIsCurrent(
        _ origin: AgentTabSession.CodexHookGateOrigin,
        session: AgentTabSession
    ) -> Bool {
        session.codexHookGateOrigin == origin
            && session.runID == origin.runID && session.activeRunAttemptID == origin.runAttemptID
    }

    /// Only the exact original gate may be settled. A successor run/gate is never reset.
    private func cancelHookGate(
        origin: AgentTabSession.CodexHookGateOrigin,
        generation: UInt64,
        session: AgentTabSession
    ) {
        guard session.codexHookGateOrigin == origin,
              session.codexHookGateGeneration == generation else { return }
        let isOriginalRun = session.runID == origin.runID && session.activeRunAttemptID == origin.runAttemptID
        session.resetCodexHookGateBinding()
        if isOriginalRun, session.persistentSessionBindingIdentity == origin.writer.restoration.bindingIdentity {
            Self.reconcileInteractiveRunState(session)
            if scope?.originatingWriter(identity: origin.writer, session: session) != nil {
                publishCodexHookGateState(for: session)
                return
            }
        }
        if scope?.sessions[session.tabID] === session {
            scope?.presentation.interactionChanged(session)
        }
    }

    private func validateHookResult(
        command: AgentSessionRuntimeStore.Command,
        authority: CodexHookGateOperationAuthority,
        trustWriteAttempted: Bool
    ) throws {
        let session = command.writer.session
        guard authority.isCurrent(in: session) else {
            throw AgentCodexHookReviewResolutionError.superseded(trustWriteAttempted: trustWriteAttempted)
        }
        guard command.isCurrent, hookOriginIsCurrent(authority.origin, session: session) else {
            cancelHookGate(origin: authority.origin, generation: authority.generation, session: session)
            throw AgentCodexHookReviewResolutionError.superseded(trustWriteAttempted: trustWriteAttempted)
        }
    }

    func isCodexHookApprovalStrictModeEnabled(workspaceID: UUID?) -> Bool {
        codexHookApprovalSettings?.codexHookApprovalStrictModeEnabled(workspaceID: workspaceID) ?? true
    }

    func isCodexHookApprovalStrictModeEnabled(for session: AgentTabSession) -> Bool {
        // Unknown placement must never inherit a permissive global/default policy.
        guard let workspaceID = session.persistentSessionBindingIdentity?.workspaceID else { return true }
        return isCodexHookApprovalStrictModeEnabled(workspaceID: workspaceID)
    }

    private struct CodexHookGateOperationAuthority {
        enum Scope {
            case initialDiscovery
            case review(requestID: UUID, gateGeneration: UInt64)
        }

        let attemptToken: UUID
        let scope: Scope
        let binding: AgentTabSession.CodexHookGateBindingIdentity
        let origin: AgentTabSession.CodexHookGateOrigin
        let generation: UInt64

        init(
            attemptToken: UUID,
            scope: Scope,
            binding: AgentTabSession.CodexHookGateBindingIdentity,
            origin: AgentTabSession.CodexHookGateOrigin,
            generation: UInt64
        ) {
            self.attemptToken = attemptToken
            self.scope = scope
            self.binding = binding
            self.origin = origin
            self.generation = generation
        }

        @MainActor
        func isCurrent(in session: AgentTabSession) -> Bool {
            guard session.codexHookGateGeneration == generation,
                  session.codexHookGateOrigin == origin,
                  session.codexHookGateAttemptToken == attemptToken,
                  let currentController = session.codexController,
                  ObjectIdentifier(currentController as AnyObject) == binding.controllerInstanceID,
                  binding.controllerGeneration == session.codexControllerGeneration
            else {
                return false
            }
            switch scope {
            case .initialDiscovery:
                return true
            case let .review(requestID, gateGeneration):
                return session.pendingCodexHookReview?.id == requestID
                    && session.codexHookGateGeneration == gateGeneration
                    && session.codexHookGateActiveBinding == binding
            }
        }
    }

    private func codexHookGateBinding(
        for session: AgentTabSession,
        controller: any CodexSessionControlling
    ) -> AgentTabSession.CodexHookGateBindingIdentity {
        .init(
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration
        )
    }

    private func isCurrentCodexHookGateBinding(
        _ binding: AgentTabSession.CodexHookGateBindingIdentity,
        session: AgentTabSession,
        controller: any CodexSessionControlling
    ) -> Bool {
        guard let currentController = session.codexController else { return false }
        return ObjectIdentifier(currentController) == ObjectIdentifier(controller)
            && binding == codexHookGateBinding(for: session, controller: controller)
    }

    private func synchronizeCodexThreadReferenceAfterHookGate(
        session: AgentTabSession,
        controller: any CodexSessionControlling
    ) {
        guard let currentController = session.codexController,
              ObjectIdentifier(currentController) == ObjectIdentifier(controller),
              let reference = controller.currentSessionReference
        else {
            return
        }
        let conversationID = reference.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationID.isEmpty,
              conversationID != session.codexConversationID
              || reference.rolloutPath != session.codexRolloutPath
        else {
            return
        }
        session.codexConversationID = conversationID
        session.codexRolloutPath = reference.rolloutPath
        session.providerCleanupHandle = ProviderConversationCleanupHandle(
            provider: AgentProviderKind.codexExec.rawValue,
            conversationID: conversationID,
            rolloutPath: reference.rolloutPath
        )
        session.codexModel = reference.model
        session.codexReasoningEffort = reference.reasoningEffort
        session.isDirty = true
        scope?.persistence.scheduleSave(for: session)
    }

    private func publishCodexHookGateState(for session: AgentTabSession) {
        AgentSessionInteractionRuntime.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .codexHookReviewChanged)
        scope?.presentation.requestUIRefresh(for: session, urgent: true)
        scope?.mcp.handleObservedMCPStateChange(for: session)
    }

    private func finishCodexHookReviewAttempt(
        session: AgentTabSession,
        request: AgentCodexHookReviewRequest,
        phase: AgentCodexHookReviewRequest.Phase,
        errorMessage: String?
    ) {
        session.codexHookGateAttemptToken = nil
        var transitionedRequest = request
        transitionedRequest.phase = phase
        transitionedRequest.errorMessage = errorMessage
        session.pendingCodexHookReview = transitionedRequest
        publishCodexHookGateState(for: session)
    }

    private func codexHookReviewRequest(
        session: AgentTabSession,
        executionCWD: String,
        hooks: [CodexHookMetadata],
        warnings: [String],
        phase: AgentCodexHookReviewRequest.Phase,
        errorMessage: String? = nil
    ) -> AgentCodexHookReviewRequest {
        AgentCodexHookReviewRequest(
            tabID: session.tabID,
            runAttemptID: session.activeRunAttemptID,
            runID: session.runID,
            executionCWD: executionCWD,
            hooks: hooks.map(AgentCodexHookReviewHook.init(metadata:)),
            warnings: warnings,
            phase: phase,
            errorMessage: errorMessage,
            gateGeneration: session.codexHookGateGeneration
        )
    }

    private func codexHookDiscoveryFailureMessage(_ error: Error) -> String {
        if let hookError = error as? CodexHookTrustError,
           case let .discoveryFailed(cwdErrors) = hookError
        {
            let details = cwdErrors.prefix(3).map { raw in
                let normalized = raw
                    .components(separatedBy: .newlines)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return String(normalized.prefix(300))
            }.filter { !$0.isEmpty }
            if !details.isEmpty {
                return "Codex hook discovery failed: \(details.joined(separator: "; "))"
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "Codex hook discovery failed. Retry hook discovery."
    }

    private func suspendForCodexHookReview(
        command: AgentSessionRuntimeStore.Command,
        binding: AgentTabSession.CodexHookGateBindingIdentity,
        origin: AgentTabSession.CodexHookGateOrigin,
        generation: UInt64
    ) async throws {
        let session = command.writer.session
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, command.isCurrent,
                      hookOriginIsCurrent(origin, session: session), session.codexHookGateGeneration == generation,
                      session.codexHookGateActiveBinding == binding,
                      session.hasPendingCodexHookReviewRequest,
                      session.codexHookReviewContinuation == nil
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                session.codexHookReviewContinuation = continuation
                publishCodexHookGateState(for: session)
            }
        } onCancel: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.cancelHookGate(origin: origin, generation: generation, session: session)
            }
        }
    }

    private func awaitActiveCodexHookGate(
        session: AgentTabSession,
        binding: AgentTabSession.CodexHookGateBindingIdentity
    ) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled,
                      session.codexHookGateActiveBinding == binding,
                      session.hasActiveCodexHookGateOperation
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                session.codexHookGateCoalescedContinuations[waiterID] = continuation
                #if DEBUG
                    test_onHookGateCoalescedWaiterInstalled?()
                #endif
            }
        } onCancel: { [weak session] in
            Task { @MainActor in
                session?.cancelCodexHookGateCoalescedWaiter(waiterID)
            }
        }
    }

    func gateFirstTurnForProjectHooks(
        command: AgentSessionRuntimeStore.Command,
        controller: any CodexSessionControlling,
        executionCWD: String
    ) async throws -> UUID? {
        guard command.writer.scope === scope, command.isCurrent else {
            throw AgentCodexHookReviewResolutionError.staleWriter
        }
        let session = command.writer.session
        let origin = AgentTabSession.CodexHookGateOrigin(writer: command.identity, runID: session.runID, runAttemptID: session.activeRunAttemptID)
        let binding = codexHookGateBinding(for: session, controller: controller)
        guard isCurrentCodexHookGateBinding(binding, session: session, controller: controller) else {
            throw AgentCodexHookReviewResolutionError.staleController
        }
        if session.hasActiveCodexHookGateOperation {
            guard session.codexHookGateActiveBinding == binding, session.codexHookGateOrigin == origin else {
                throw AgentCodexHookReviewResolutionError.staleController
            }
            try await awaitActiveCodexHookGate(session: session, binding: binding)
            guard command.isCurrent, session.runID == origin.runID,
                  session.activeRunAttemptID == origin.runAttemptID else { throw CancellationError() }
            synchronizeCodexThreadReferenceAfterHookGate(
                session: session,
                controller: controller
            )
            return nil
        }
        if session.codexHookGateBindingMemo == binding {
            return nil
        }

        session.codexHookGateGeneration &+= 1
        let generation = session.codexHookGateGeneration
        session.codexHookGateOrigin = origin
        session.codexHookGateActiveBinding = binding
        session.codexHookGateAudit = nil
        let dispatchOwnerToken = UUID()
        session.codexHookGateDispatchOwnerToken = dispatchOwnerToken
        let attemptToken = UUID()
        session.codexHookGateAttemptToken = attemptToken
        let authority = CodexHookGateOperationAuthority(
            attemptToken: attemptToken,
            scope: .initialDiscovery,
            binding: binding, origin: origin, generation: generation
        )

        do {
            let inventory = try await performHookInventoryEffect(for: session) {
                try self.validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                return try await controller.listHooksForCurrentWorkspace()
            }
            try Task.checkCancellation()
            guard authority.isCurrent(in: session), command.isCurrent, hookOriginIsCurrent(origin, session: session) else {
                cancelHookGate(origin: origin, generation: generation, session: session)
                throw CancellationError()
            }
            let unresolved = inventory.unresolvedProjectHooks
            if unresolved.isEmpty {
                session.codexHookGateAttemptToken = nil
                session.codexHookGateInventoryFingerprint = nil
                session.codexHookGateBindingMemo = binding
                synchronizeCodexThreadReferenceAfterHookGate(
                    session: session,
                    controller: controller
                )
                return dispatchOwnerToken
            }
            session.codexHookGateAttemptToken = nil
            session.codexHookGateInventoryFingerprint = inventory.fingerprint
            session.pendingCodexHookReview = codexHookReviewRequest(
                session: session,
                executionCWD: inventory.executionCWD,
                hooks: unresolved,
                warnings: inventory.warnings,
                phase: .reviewRequired
            )
        } catch is CancellationError {
            cancelHookGate(origin: origin, generation: generation, session: session)
            throw CancellationError()
        } catch {
            guard authority.isCurrent(in: session), command.isCurrent, hookOriginIsCurrent(origin, session: session) else {
                cancelHookGate(origin: origin, generation: generation, session: session)
                throw CancellationError()
            }
            session.codexHookGateAttemptToken = nil
            session.codexHookGateInventoryFingerprint = nil
            session.pendingCodexHookReview = codexHookReviewRequest(
                session: session,
                executionCWD: executionCWD,
                hooks: [],
                warnings: [],
                phase: .discoveryFailed,
                errorMessage: codexHookDiscoveryFailureMessage(error)
            )
        }

        do {
            try await suspendForCodexHookReview(command: command, binding: binding, origin: origin, generation: generation)
            guard command.isCurrent, hookOriginIsCurrent(origin, session: session) else { throw CancellationError() }
        } catch {
            cancelHookGate(origin: origin, generation: generation, session: session)
            throw error
        }
        synchronizeCodexThreadReferenceAfterHookGate(
            session: session,
            controller: controller
        )
        return dispatchOwnerToken
    }

    /// Track only the admitted provider effect. Consent validation and phase consumption remain
    /// synchronous with the caller's authorization check, before this task boundary.
    private func performHookInventoryEffect(
        for session: AgentTabSession,
        operation: @escaping @MainActor () async throws -> CodexHookInventory
    ) async throws -> CodexHookInventory {
        var result: Result<CodexHookInventory, Error>?
        let task = performEffect(for: session) {
            do {
                try Task.checkCancellation()
                result = try await .success(operation())
            } catch {
                result = .failure(error)
            }
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard let result else { throw CancellationError() }
        return try result.get()
    }

    func submitCodexHookReviewDecision(
        command: AgentSessionRuntimeStore.Command,
        requestID: UUID,
        decision: AgentCodexHookReviewDecision
    ) async throws {
        guard command.writer.scope === scope, command.isCurrent else {
            throw AgentCodexHookReviewResolutionError.staleWriter
        }
        let session = command.writer.session
        guard let origin = session.codexHookGateOrigin, origin.writer == command.identity,
              hookOriginIsCurrent(origin, session: session)
        else {
            throw AgentCodexHookReviewResolutionError.staleWriter
        }
        guard var request = session.pendingCodexHookReview else {
            throw AgentCodexHookReviewResolutionError.noPendingReview
        }
        guard request.id == requestID else {
            throw AgentCodexHookReviewResolutionError.staleRequest(currentID: request.id)
        }
        guard request.phase != .submitting, request.phase != .discovering else {
            throw AgentCodexHookReviewResolutionError.busy
        }
        guard let controller = session.codexController,
              let binding = session.codexHookGateActiveBinding,
              request.gateGeneration == session.codexHookGateGeneration,
              isCurrentCodexHookGateBinding(binding, session: session, controller: controller)
        else {
            throw AgentCodexHookReviewResolutionError.staleController
        }

        switch decision {
        case .continueWithoutHooks:
            guard request.phase.allowsContinueWithoutHooks else {
                throw AgentCodexHookReviewResolutionError.invalidDecision
            }
            guard !isCodexHookApprovalStrictModeEnabled(for: session) else {
                throw AgentCodexHookReviewResolutionError.strictModeRequiresApproval
            }
            let skippedCount = request.phase == .discoveryFailed ? nil : request.hooks.count
            let skippedDescription = skippedCount.map { "\($0) Codex project hook(s)" }
                ?? "an unknown number of Codex project hooks"
            try completeCodexHookReview(
                command: command,
                session: session,
                request: request,
                binding: binding,
                status: .continuedWithoutHooks,
                approvedCount: 0,
                skippedCount: skippedCount,
                notice: "Continued without trusting \(skippedDescription). The hooks remain untrusted for this controller binding."
            )

        case .retryDiscovery:
            guard request.phase.allowsDiscoveryRetry else {
                throw AgentCodexHookReviewResolutionError.invalidDecision
            }
            request.phase = .discovering
            request.errorMessage = nil
            session.pendingCodexHookReview = request
            let token = UUID()
            session.codexHookGateAttemptToken = token
            let authority = CodexHookGateOperationAuthority(
                attemptToken: token,
                scope: .review(requestID: requestID, gateGeneration: request.gateGeneration),
                binding: binding, origin: origin, generation: request.gateGeneration
            )
            publishCodexHookGateState(for: session)
            do {
                try validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                let inventory = try await performHookInventoryEffect(for: session) {
                    try self.validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                    return try await controller.listHooksForCurrentWorkspace()
                }
                try Task.checkCancellation()
                try validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                try applyCodexHookInventoryRefresh(
                    inventory,
                    command: command,
                    session: session,
                    priorRequest: request,
                    binding: binding
                )
            } catch is CancellationError {
                cancelHookGate(origin: origin, generation: request.gateGeneration, session: session)
                throw CancellationError()
            } catch let error as AgentCodexHookReviewResolutionError {
                throw error
            } catch {
                try validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                finishCodexHookReviewAttempt(
                    session: session,
                    request: request,
                    phase: .discoveryFailed,
                    errorMessage: codexHookDiscoveryFailureMessage(error)
                )
            }

        case let .approveSelected(hookKeys):
            guard !hookKeys.isEmpty,
                  Set(hookKeys.map(CodexHookUTF8Identity.init)).count == hookKeys.count
            else {
                throw AgentCodexHookReviewResolutionError.invalidSelection
            }
            let requestedKeys = Set(hookKeys.map(CodexHookUTF8Identity.init))
            let selected = request.hooks.filter { requestedKeys.contains(CodexHookUTF8Identity($0.key)) }
            guard selected.count == hookKeys.count else {
                throw AgentCodexHookReviewResolutionError.invalidSelection
            }
            let allUnresolvedKeys = Set(request.hooks.map { CodexHookUTF8Identity($0.key) })
            guard !isCodexHookApprovalStrictModeEnabled(for: session) || requestedKeys == allUnresolvedKeys else {
                throw AgentCodexHookReviewResolutionError.strictModeRequiresApproval
            }
            try await submitCodexHookApproval(
                command: command,
                session: session,
                request: request,
                candidates: selected.map(\.trustCandidate),
                status: .approvedSelected,
                controller: controller,
                binding: binding
            )

        case .approveAll:
            guard !request.hooks.isEmpty else {
                throw AgentCodexHookReviewResolutionError.invalidSelection
            }
            try await submitCodexHookApproval(
                command: command,
                session: session,
                request: request,
                candidates: request.trustCandidates,
                status: .approvedAll,
                controller: controller,
                binding: binding
            )
        }
    }

    private func submitCodexHookApproval(
        command: AgentSessionRuntimeStore.Command,
        session: AgentTabSession,
        request: AgentCodexHookReviewRequest,
        candidates: [CodexHookTrustCandidate],
        status: AgentCodexHookGateAudit.Status,
        controller: any CodexSessionControlling,
        binding: AgentTabSession.CodexHookGateBindingIdentity
    ) async throws {
        guard let origin = session.codexHookGateOrigin, origin.writer == command.identity else {
            throw AgentCodexHookReviewResolutionError.staleWriter
        }
        guard request.phase.allowsTrustDecision else {
            throw AgentCodexHookReviewResolutionError.invalidDecision
        }
        guard let fingerprint = session.codexHookGateInventoryFingerprint else {
            throw AgentCodexHookReviewResolutionError.invalidDecision
        }
        var submittingRequest = request
        submittingRequest.phase = .submitting
        submittingRequest.errorMessage = nil
        session.pendingCodexHookReview = submittingRequest
        let token = UUID()
        session.codexHookGateAttemptToken = token
        let authority = CodexHookGateOperationAuthority(
            attemptToken: token,
            scope: .review(requestID: request.id, gateGeneration: request.gateGeneration),
            binding: binding, origin: origin, generation: request.gateGeneration
        )
        publishCodexHookGateState(for: session)

        do {
            try validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
            // The admitted candidate/fingerprint consent may finish once submitted. This is not
            // an atomic writer or external-file CAS fence; only the result publication is fenced.
            let verified = try await performHookInventoryEffect(for: session) {
                try self.validateHookResult(command: command, authority: authority, trustWriteAttempted: false)
                return try await controller.trustHooksForCurrentWorkspace(
                    expectedCandidates: candidates,
                    expectedInventoryFingerprint: fingerprint
                )
            }
            try Task.checkCancellation()
            try validateHookResult(command: command, authority: authority, trustWriteAttempted: true)
            guard verified.verifies(candidates) else {
                finishCodexHookReviewAttempt(
                    session: session,
                    request: request,
                    phase: .verificationFailed,
                    errorMessage: CodexHookTrustError.postWriteVerificationFailed(latest: verified).localizedDescription
                )
                return
            }
            let approvedIdentities = Set(candidates.map(\.selectionIdentity))
            let expectedSkippedIdentities = Set(request.trustCandidates.map(\.selectionIdentity))
                .subtracting(approvedIdentities)
            let verifiedUnresolvedIdentities = Set(verified.unresolvedProjectHooks.map(\.selectionIdentity))
            let strictModeRequiresRefresh = isCodexHookApprovalStrictModeEnabled(for: session)
                && !verifiedUnresolvedIdentities.isEmpty
            guard !strictModeRequiresRefresh,
                  verifiedUnresolvedIdentities.isSubset(of: expectedSkippedIdentities)
            else {
                try applyCodexHookInventoryRefresh(
                    verified,
                    command: command,
                    session: session,
                    priorRequest: request,
                    binding: binding
                )
                return
            }
            let selectionSkippedCount = max(0, request.hooks.count - candidates.count)
            try completeCodexHookReview(
                command: command,
                session: session,
                request: request,
                binding: binding,
                status: status,
                approvedCount: candidates.count,
                skippedCount: selectionSkippedCount,
                notice: "Trusted \(candidates.count) Codex project hook(s); \(verifiedUnresolvedIdentities.count) remain untrusted for this controller binding."
            )
        } catch is CancellationError {
            cancelHookGate(origin: origin, generation: request.gateGeneration, session: session)
            throw CancellationError()
        } catch let error as AgentCodexHookReviewResolutionError {
            throw error
        } catch let error as CodexHookTrustError {
            try validateHookResult(command: command, authority: authority, trustWriteAttempted: true)
            switch error {
            case let .inventoryChanged(replacement):
                session.codexHookGateAttemptToken = nil
                try applyCodexHookInventoryRefresh(
                    replacement,
                    command: command,
                    session: session,
                    priorRequest: request,
                    binding: binding
                )
            case .postWriteVerificationFailed:
                finishCodexHookReviewAttempt(
                    session: session,
                    request: request,
                    phase: .verificationFailed,
                    errorMessage: error.localizedDescription
                )
            default:
                finishCodexHookReviewAttempt(
                    session: session,
                    request: request,
                    phase: .writeFailed,
                    errorMessage: error.localizedDescription
                )
            }
        } catch {
            try validateHookResult(command: command, authority: authority, trustWriteAttempted: true)
            finishCodexHookReviewAttempt(
                session: session,
                request: request,
                phase: .writeFailed,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func applyCodexHookInventoryRefresh(
        _ inventory: CodexHookInventory,
        command: AgentSessionRuntimeStore.Command,
        session: AgentTabSession,
        priorRequest: AgentCodexHookReviewRequest,
        binding: AgentTabSession.CodexHookGateBindingIdentity
    ) throws {
        let unresolved = inventory.unresolvedProjectHooks
        if unresolved.isEmpty {
            try completeCodexHookReview(
                command: command,
                session: session,
                request: priorRequest,
                binding: binding,
                status: .resolvedExternally,
                approvedCount: 0,
                skippedCount: 0,
                notice: "Codex project hooks were resolved externally after the review was shown."
            )
            return
        }
        session.codexHookGateAttemptToken = nil
        session.codexHookGateInventoryFingerprint = inventory.fingerprint
        session.pendingCodexHookReview = codexHookReviewRequest(
            session: session,
            executionCWD: inventory.executionCWD,
            hooks: unresolved,
            warnings: inventory.warnings,
            phase: .reviewRequired
        )
        publishCodexHookGateState(for: session)
    }

    private func completeCodexHookReview(
        command: AgentSessionRuntimeStore.Command,
        session: AgentTabSession,
        request: AgentCodexHookReviewRequest,
        binding: AgentTabSession.CodexHookGateBindingIdentity,
        status: AgentCodexHookGateAudit.Status,
        approvedCount: Int,
        skippedCount: Int?,
        notice: String
    ) throws {
        guard command.isCurrent,
              let origin = session.codexHookGateOrigin,
              origin.writer == command.identity, hookOriginIsCurrent(origin, session: session),
              session.pendingCodexHookReview?.id == request.id,
              session.codexHookGateActiveBinding == binding
        else { throw AgentCodexHookReviewResolutionError.staleWriter }
        let continuation = session.codexHookReviewContinuation
        session.codexHookReviewContinuation = nil
        session.pendingCodexHookReview = nil
        session.codexHookGateAttemptToken = nil
        session.codexHookGateInventoryFingerprint = nil
        session.codexHookGateBindingMemo = binding
        session.codexHookGateAudit = AgentCodexHookGateAudit(
            status: status,
            approvedCount: approvedCount,
            skippedCount: skippedCount,
            resolvedAt: Date(),
            interactionID: request.id
        )
        session.appendItem(AgentChatItem.system(
            notice,
            sequenceIndex: session.nextSequenceIndex
        ))
        scope?.persistence.scheduleSave(for: session)
        publishCodexHookGateState(for: session)
        guard command.isCurrent, hookOriginIsCurrent(origin, session: session) else {
            cancelHookGate(origin: origin, generation: request.gateGeneration, session: session)
            continuation?.resume(throwing: CancellationError())
            throw AgentCodexHookReviewResolutionError.superseded(trustWriteAttempted: approvedCount > 0)
        }
        continuation?.resume()
    }
}
