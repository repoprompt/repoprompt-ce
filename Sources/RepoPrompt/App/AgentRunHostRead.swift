import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer

extension AgentRunHostAdmission {
    /// One read's exact target. Epochs can advance within the captured registration, but a
    /// new registration, writer, or carrier must never inherit an in-flight read.
    @MainActor
    struct ReadTarget {
        fileprivate let command: AgentSessionRuntimeStore.Command
        fileprivate let activation: AgentSessionHostWorkspaceActivation
        fileprivate let registration: AgentRunSessionStore.Registration?
        fileprivate let controlActivationID: UUID?

        var sessionID: UUID {
            command.identity.sessionID
        }

        fileprivate var runtime: AgentSessionMCPRuntime {
            command.writer.scope.mcp
        }

        fileprivate var controlIsCurrent: Bool {
            let session = command.writer.session
            let context = session.mcpControlContext
            guard context?.registration == registration, context?.activationID == controlActivationID else { return false }
            guard let registration else { return true }
            return runtime.controlRead(sessionID: sessionID, registration: registration).session === session
        }
    }

    func captureReadTargets(_ sessionIDs: [UUID], operation: DomainAgentSessionTargetOperation) async throws -> [ReadTarget] {
        let snapshot = try await canonicalSnapshot()
        return try sessionIDs.map { sessionID in
            let command = try target(sessionID, for: operation)
            let scope = command.writer.scope
            guard let host = scope.executableHost, let activation = host.workspaceActivation,
                  activation.owns(scope: scope, route: host.route), activation.executionTab(in: snapshot, command: command) != nil
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
            let context = command.writer.session.mcpControlContext
            let read = ReadTarget(
                command: command, activation: activation,
                registration: context?.registration, controlActivationID: context?.activationID
            )
            guard read.controlIsCurrent else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
            return read
        }
    }

    func requireReadTargets(_ targets: [ReadTarget], operation: DomainAgentSessionTargetOperation) async throws {
        let snapshot = try await canonicalSnapshot()
        try validateReadTargets(targets, operation: operation, snapshot: snapshot)
    }

    private func validateReadTargets(
        _ targets: [ReadTarget], operation: DomainAgentSessionTargetOperation, snapshot: DomainWorkspaceSnapshot
    ) throws {
        for target in targets {
            guard readTargetIsCurrent(target, operation: operation),
                  target.activation.executionTab(in: snapshot, command: target.command) != nil
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: target.sessionID) }
        }
    }

    private func readTargetIsCurrent(_ target: ReadTarget, operation: DomainAgentSessionTargetOperation) -> Bool {
        let scope = target.command.writer.scope
        guard (try? requireTarget(target.command, for: operation)) != nil,
              let host = scope.executableHost, host.workspaceActivation === target.activation,
              target.activation.owns(scope: scope, route: host.route) else { return false }
        return target.controlIsCurrent
    }

    func beginReadWait(
        for targets: [ReadTarget], timeoutSeconds: TimeInterval, operation: DomainAgentSessionTargetOperation = .runWait
    ) -> AgentRunWaitScopeRegistration? {
        guard sourceIsCurrent, let parentRunID = connection.runID else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.sessionID, $0) })
        return host.route.toolExecutionRuntime.beginAgentRunWaitScope(
            parentRunID: parentRunID, metadata: invocation.metadata, sessionIDs: Set(byID.keys),
            timeoutSeconds: timeoutSeconds, exactPublication: { sessionID in
                guard let target = byID[sessionID], readTargetIsCurrent(target, operation: operation),
                      let publication = target.runtime.waitPublication(sessionID: sessionID),
                      publication.cursor.registration == target.registration else { return nil }
                return publication
            }
        )
    }

    func readAccess(
        for targets: [ReadTarget], operation: DomainAgentSessionTargetOperation, residentSnapshots: [UUID: AgentRunMCPSnapshot] = [:]
    ) -> AgentRunMCPToolService.RunReadAccess {
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.sessionID, $0) })
        return .init(waitCursor: { sessionID in
            guard let target = byID[sessionID], readTargetIsCurrent(target, operation: operation),
                  let cursor = target.runtime.waitCursor(sessionID: sessionID), cursor.registration == target.registration
            else { return nil }
            return cursor
        }, snapshot: { sessionID in
            guard let target = byID[sessionID], readTargetIsCurrent(target, operation: operation) else {
                return AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)
            }
            if let resident = residentSnapshots[sessionID] { return resident }
            guard let registration = target.registration else { return AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID) }
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            guard readTargetIsCurrent(target, operation: operation) else { return AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID) }
            if let stored, stored.status.isTerminal { return stored }
            return target.runtime.mcpReadSnapshot(for: target.command.writer.session) ?? stored ?? AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)
        }, unavailable: { _ in nil })
    }

    /// No writer is installed for a read. A verified durable carrier without a live control
    /// registration can report only the expired run handle, never a saved transcript preview.
    private func captureExpiredRead(
        sessionID: UUID, operation: DomainAgentSessionTargetOperation
    ) async throws -> AgentSavedSessionTargetLoader.Target {
        let denial = AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        func absent() -> Bool {
            guard sourceIsCurrent,
                  case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID)
            else { return false }
            return true
        }
        guard absent(),
              let lookup = try? await AppSavedAgentSessionExecution.resolve(
                  sessionID, store: activation.authority.store, isStillAuthorized: absent
              ), lookup.target.workspace.id == workspaceID else { throw denial }
        let target = lookup.target
        let workspace = try await canonicalWorkspace()
        guard absent(), target.carrier(in: workspace) != nil else { throw denial }
        try authorizeExpiredRead(target, operation: operation)
        return target
    }

    private func authorizeExpiredRead(
        _ target: AgentSavedSessionTargetLoader.Target, operation: DomainAgentSessionTargetOperation
    ) throws {
        let sessionID = target.entry.id
        guard !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID),
              case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID)
        else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        try AgentSessionTargetOperationGuard.require(
            operation: operation, caller: caller,
            provenance: .known(targetSessionID: sessionID, parentSessionID: target.entry.parentSessionID),
            reference: sessionID.uuidString
        )
    }

    /// Reuse the exact single/multi wait policies without an adapter that can select a window.
    func executeControlRead(_ args: [String: Value], poll: Bool) async throws -> Value {
        let usesArray = args["session_ids"] != nil
        let references: [String] = if usesArray {
            try AgentRunMCPToolService.parseSessionIDArray(args)
        } else {
            try [Self.requireControlSessionReference(args)]
        }
        var seen: Set<UUID> = []
        let sessionIDs = try references.compactMap { reference -> UUID? in
            let id = try Self.controlSessionID(reference)
            return seen.insert(id).inserted ? id : nil
        }
        let operation: DomainAgentSessionTargetOperation = poll ? .runPoll : .runWait
        var liveIDs: [UUID] = []
        var expired: [AgentSavedSessionTargetLoader.Target] = []
        for id in sessionIDs {
            if case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: id) {
                try await expired.append(captureExpiredRead(sessionID: id, operation: operation))
            } else {
                liveIDs.append(id)
            }
        }
        let targets = try await captureReadTargets(liveIDs, operation: operation)
        var residents: [UUID: AgentRunMCPSnapshot] = [:]
        var overseers: [UUID: Value] = [:]
        if poll {
            for target in targets where AgentModeViewModel.isMCPResidentAppOwned(target.command.writer.session) {
                let (snapshot, overseer) = try await residentPoll(target)
                residents[target.sessionID] = snapshot
                overseers[target.sessionID] = overseer
            }
        }
        let read = readAccess(for: targets, operation: operation, residentSnapshots: residents)
        let tools = makeHostToolService(waitTargets: targets)
        let timeout = try poll ? 0 : AgentRunMCPToolService.resolvedWaitTimeoutSeconds(
            args["timeout"], capturedDefaultWaitSeconds: AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds()
        )
        let value: Value = if poll, usesArray {
            await tools.executeResolvedPollMany(sessionIDs: sessionIDs, read: read, overseers: overseers)
        } else if let resident = residents[sessionIDs[0]] {
            .object(resident.asObject().merging(["overseer": overseers[resident.sessionID] ?? .null]) { _, new in new })
        } else if sessionIDs.count == 1 {
            try await tools.executeResolvedWait(
                sessionID: sessionIDs[0], read: read, metadata: invocation.metadata, timeoutSeconds: timeout
            )
        } else {
            try await tools.executeResolvedWaitAny(
                sessionIDs: sessionIDs, read: read, metadata: invocation.metadata, timeoutSeconds: timeout
            )
        }
        for target in expired {
            let current = try await captureExpiredRead(sessionID: target.entry.id, operation: operation)
            guard current.tab.id == target.tab.id, current.stashedTabID == target.stashedTabID,
                  current.entry.parentSessionID == target.entry.parentSessionID,
                  current.workspace.customStoragePath == target.workspace.customStoragePath
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: target.entry.id) }
        }
        // Qualify every carrier against the same final authority snapshot. A prior sidecar
        // read alone does not authorize using an ID whose tab changed during another read.
        let finalSnapshot = try await canonicalSnapshot()
        try validateReadTargets(targets, operation: operation, snapshot: finalSnapshot)
        if !expired.isEmpty {
            let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: finalSnapshot.document.documentBytes)
            for target in expired {
                guard target.carrier(in: workspace) != nil else {
                    throw AgentSessionTargetOperationGuard.denialError(sessionID: target.entry.id)
                }
                try authorizeExpiredRead(target, operation: operation)
            }
        }
        return value
    }

    func executeControlCancellation(_ args: [String: Value]) async throws -> Value {
        let sessionID = try Self.controlSessionID(Self.requireControlSessionReference(args))
        let targets = try await captureReadTargets([sessionID], operation: .runCancel)
        guard let target = targets.first, let executor = target.command.writer.scope.linkExecution,
              let cancellation = AgentRunCapturedCancellation(
                  sessionID: sessionID, session: target.command.writer.session,
                  runtime: target.runtime, executor: executor, requireOrigin: {
                      guard readTargetIsCurrent(target, operation: .runCancel) else {
                          throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
                      }
                  }
              ) else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        let read = readAccess(for: targets, operation: .runCancel)
        return try await makeHostToolService().executeResolvedCancellation(
            cancellation, metadata: invocation.metadata, snapshot: { await read.snapshot(sessionID) },
            revalidateOrigin: { try await requireReadTargets(targets, operation: .runCancel) }
        )
    }

    func executeControlResponse(_ args: [String: Value]) async throws -> Value {
        let sessionID = try Self.controlSessionID(Self.requireControlSessionReference(args))
        let targets = try await captureReadTargets([sessionID], operation: .runRespond)
        guard let target = targets.first, let interactions = target.command.writer.scope.installedInteractions else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
        let tools = makeHostToolService()
        let interactionID = try tools.requireUUID(args["interaction_id"], name: "interaction_id")
        let workflow = try tools.resolveWorkflow(args: args)
        let payload = try AgentRunMCPToolService.parseResponsePayload(args: args)
        try await requireReadTargets(targets, operation: .runRespond)
        let delivery = try await interactions.resolveMCPResponse(command: target.command, interactionID: interactionID, payload: payload) { text in
            try await submitExactActiveControlInput(target, text: text, workflow: workflow, operation: .runRespond, expectedInstructionID: interactionID)
        }
        await Task.yield()
        let candidate = await readAccess(for: targets, operation: .runRespond).snapshot(sessionID)
        let snapshot: AgentRunMCPSnapshot = if await (try? requireReadTargets(targets, operation: .runRespond)) != nil {
            candidate
        } else {
            // The response already settled on the exact interaction. Do not project a successor,
            // and do not misreport the accepted effect as a refusal to answer.
            AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)
        }
        return tools.decoratedRunValue(snapshot: snapshot, workflow: workflow, delivery: delivery)
    }

    func submitExactActiveControlInput(
        _ target: ReadTarget, text: String, workflow: AgentWorkflowDefinition?,
        operation: DomainAgentSessionTargetOperation, expectedInstructionID: UUID? = nil
    ) async throws -> AgentMCPInstructionDispatch {
        try await requireReadTargets([target], operation: operation)
        let scope = target.command.writer.scope
        let session = target.command.writer.session
        guard let targetHost = scope.executableHost, let executor = scope.linkExecution,
              let endpoint = executor.agentSessionLinkObserverEndpoint(tabID: session.tabID), endpoint.sessionID == target.sessionID
        else { throw MCPError.invalidParams("The requested agent run cannot receive active input.") }
        let currentInteraction = target.runtime.mcpPendingInteraction(for: session)
        if let currentInteraction, currentInteraction.kind != .instruction {
            throw MCPError.invalidParams("The run is waiting on \(currentInteraction.kind.rawValue). Use agent_run.respond instead.")
        }
        guard session.pendingApplyEditsReview == nil, session.pendingWorktreeMergeReview == nil else {
            throw MCPError.invalidParams("Resolve the protected review before submitting task input.")
        }
        guard let route = executor.agentSessionLinkManagedSteerRoute(for: session) else {
            throw MCPError.invalidParams("The requested agent run cannot receive active input.")
        }
        if let expectedInstructionID {
            guard currentInteraction?.id == expectedInstructionID, route == .waitingInstruction else {
                throw MCPError.invalidParams("The pending instruction prompt no longer matches interaction_id.")
            }
        }
        let origin = targetHost.canonicalInputEnvironment(for: session)
        func inputIsCurrent() -> Bool {
            guard origin.resourcesAreCurrent(), readTargetIsCurrent(target, operation: operation),
                  session.pendingApplyEditsReview == nil, session.pendingWorktreeMergeReview == nil else { return false }
            let pending = target.runtime.mcpPendingInteraction(for: session)
            if let expectedInstructionID {
                return pending?.kind == .instruction && pending?.id == expectedInstructionID
                    && executor.agentSessionLinkManagedSteerRoute(for: session) == .waitingInstruction
            }
            return pending == nil || pending?.kind == .instruction
        }
        let environment = AgentSessionLinkExecutionRuntime.ManagedInputEnvironment(
            workspaceID: origin.workspaceID, resourcesAreCurrent: inputIsCurrent,
            settings: origin.settings, tools: origin.tools, validateResources: { command in
                guard await origin.validateResources(command),
                      await (try? requireReadTargets([target], operation: operation)) != nil else { return false }
                return inputIsCurrent()
            }, captureProviderLaunchInput: origin.captureProviderLaunchInput
        )
        let sink = AgentSessionLinkManagedSteerSink()
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: text, sink: sink)
        guard executor.submitNoncomposerSteer(
            tabID: session.tabID, session: session, displayText: text, turn: turn,
            route: route, workflow: workflow, environment: environment, originatingCommand: target.command
        ) else { throw MCPError.invalidParams("The requested agent run changed before input could be submitted.") }
        let result = await sink.awaitOutcome(timeoutSeconds: AgentSessionLinkExecutionRuntime.agentSessionLinkManagedSteerOutcomeTimeoutSeconds)
        switch result {
        case let .delivered(state):
            switch state {
            case .deliveredToWaitingInstruction: return .deliveredIntoWaitingContinuation
            case .queuedFollowUp: return .queuedFollowUp
            case .queuedInterrupt: return route == .claudeInterrupt ? .queuedClaudeInterrupt : .queuedACPInterrupt
            default: return .dispatchedCodexTurn
            }
        case let .notAccepted(message), let .unconfirmed(message):
            throw MCPError.invalidParams(message)
        }
    }

    func executeControlSteer(_ args: [String: Value]) async throws -> Value {
        let sessionID = try Self.controlSessionID(Self.requireControlSessionReference(args))
        let tools = makeHostToolService()
        let text = try tools.resolveMessage(args["message"], name: "message")
        let workflow = try tools.resolveWorkflow(args: args)
        let manager = WindowStatesManager.shared
        var holdingPreparation = false
        defer { if holdingPreparation { manager.endPreparedOversightPreparation(sessionID) } }
        let initial: ReadTarget
        switch AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID) {
        case let .unique(writer):
            do {
                try AgentSessionTargetOperationGuard.require(
                    operation: .runSteer, caller: caller,
                    provenance: writer.session.hasLoadedPersistedState
                        ? .known(targetSessionID: sessionID, parentSessionID: writer.session.parentSessionID)
                        : .unknown(targetSessionID: sessionID),
                    reference: sessionID.uuidString
                )
            } catch {
                return try await host.forwardHostAgentRunSteer(args, invocation: invocation)
            }
            initial = try await requireSingleSteerTarget(sessionID)
            guard initial.command.writer.identity == writer.identity else {
                throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
            }
        case .unavailable(.absent):
            let saved: AgentSavedSessionTargetLoader.Target
            do {
                saved = try await captureExpiredRead(sessionID: sessionID, operation: .runSteer)
            } catch {
                try await requireCurrent()
                return try await host.forwardHostAgentRunSteer(args, invocation: invocation)
            }
            manager.beginPreparedOversightPreparation(sessionID)
            holdingPreparation = true
            let environment = try captureContinuationProviderEnvironment()
            let restored = try await manager.prepareSavedOversightTarget(
                sessionID, providerEnvironment: environment, isStillAuthorized: { sourceIsCurrent }
            ).get()
            initial = try await requireSingleSteerTarget(sessionID)
            guard initial.command.identity == restored.identity, initial.command.writer.session.tabID == saved.tab.id,
                  initial.command.writer.session.parentSessionID == saved.entry.parentSessionID
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        case .conflicting, .unavailable:
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }

        let session = initial.command.writer.session
        try AgentSessionMCPRuntime.requireSubscriptionAccountAdmission(session)
        let resident = AgentModeViewModel.isMCPResidentAppOwned(session)
        if resident {
            let shouldWait = AgentMCPToolHelpers.parseBool(args["wait"]) ?? (args["timeout_seconds"] != nil)
            guard !shouldWait else { throw MCPError.invalidParams(AgentModeViewModel.mcpResidentWaitError) }
            let frame = AgentModeViewModel.mcpResidentTaskFrame(text)
            let delivery = try await dispatchControlSteer(initial, text: frame, workflow: workflow, resident: true)
            try await requireReadTargets([initial], operation: .runSteer)
            let snap = residentStatusSnapshot(initial)
            return tools.decoratedRunValue(
                snapshot: snap,
                workflow: workflow,
                delivery: delivery,
                warning: args["timeout_seconds"] != nil ? "Ignoring timeout_seconds because wait=false; the steering instruction was accepted without waiting." : nil
            )
        }

        let target: ReadTarget
        let installed: AgentMCPControlContext?
        if initial.registration == nil {
            (target, installed) = try await reactivateSteerTarget(initial)
        } else {
            target = initial
            installed = nil
        }
        let delivery: AgentMCPInstructionDispatch
        do {
            delivery = try await dispatchControlSteer(target, text: text, workflow: workflow, resident: false, ownsPendingStart: installed != nil)
        } catch {
            if let installed, let live = session.mcpControlContext,
               live.activationID == installed.activationID, live.registration == installed.registration,
               !session.runState.isActive, let interactions = target.command.writer.scope.installedInteractions
            {
                _ = await target.runtime.deactivateControlContext(
                    session: session, expectedContext: live, approvalStore: interactions.approvalStore, cleanupRegistration: true
                )
            }
            throw error
        }
        await Task.yield()
        let current = try? await requireSingleSteerTarget(sessionID)
        let qualified = current.flatMap { read -> ReadTarget? in
            read.command.identity == target.command.identity && read.controlActivationID == target.controlActivationID ? read : nil
        }
        guard let qualified else { return tools.decoratedRunValue(snapshot: AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID), workflow: workflow, delivery: delivery) }
        if let targetHost = qualified.command.writer.scope.executableHost {
            manager.retainChildControl(qualified.command, host: targetHost)
        }
        let access = readAccess(for: [qualified], operation: .runSteer)
        let snapshot = await access.snapshot(sessionID)
        guard await (try? requireReadTargets([qualified], operation: .runSteer)) != nil else {
            return tools.decoratedRunValue(snapshot: AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID), workflow: workflow, delivery: delivery)
        }
        let value = try await makeHostToolService(waitTargets: [qualified], waitOperation: .runSteer).completeSteer(
            args, metadata: invocation.metadata, snapshot: snapshot, workflow: workflow, delivery: delivery, read: access
        )
        guard await (try? requireReadTargets([qualified], operation: .runSteer)) != nil else {
            return tools.decoratedRunValue(snapshot: AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID), workflow: workflow, delivery: delivery)
        }
        return value
    }

    private func requireSingleSteerTarget(_ sessionID: UUID) async throws -> ReadTarget {
        guard let target = try await captureReadTargets([sessionID], operation: .runSteer).first else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
        return target
    }

    private func reactivateSteerTarget(_ original: ReadTarget) async throws -> (ReadTarget, AgentMCPControlContext) {
        try await requireReadTargets([original], operation: .runSteer)
        let scope = original.command.writer.scope
        let session = original.command.writer.session
        guard !session.runState.isActive, session.mcpControlContext == nil,
              !AgentModeViewModel.isMCPResidentAppOwned(session),
              let targetHost = scope.executableHost, let interactions = scope.installedInteractions
        else { throw MCPError.invalidParams("The requested agent run is active but is not controlled by this MCP handle.") }
        let context = try await original.runtime.activateControlContext(
            command: original.command, activationID: UUID(), originatingConnectionID: connection.connectionID,
            taskLabelKind: nil, startPending: true, markSessionAsMCPOriginated: false, requireInactiveRunState: true,
            resources: .init(
                approvalStore: interactions.approvalStore,
                approvalScope: interactions.approvalScope(for: session),
                providerBindings: targetHost.providerBindingService,
                perfRecorder: session.perfRecorder
            ),
            revalidateAdmission: { _ in try requireTarget(original.command, for: .runSteer) }
        )
        do {
            let restored = try await requireSingleSteerTarget(original.sessionID)
            guard restored.command.identity == original.command.identity, restored.registration == context.registration,
                  restored.controlActivationID == context.activationID else { throw MCPFileToolAuthorityFailure.superseded }
            WindowStatesManager.shared.retainChildControl(restored.command, host: targetHost)
            return (restored, context)
        } catch {
            if session.mcpControlContext == context {
                _ = await original.runtime.deactivateControlContext(
                    session: session, expectedContext: context, approvalStore: interactions.approvalStore, cleanupRegistration: true
                )
            }
            throw error
        }
    }

    private func residentPoll(_ target: ReadTarget) async throws -> (AgentRunMCPSnapshot, Value) {
        let session = target.command.writer.session
        guard let executor = target.command.writer.scope.linkExecution,
              let endpoint = executor.agentSessionLinkObserverEndpoint(tabID: session.tabID), endpoint.sessionID == target.sessionID
        else { throw MCPError.invalidParams(AgentModeViewModel.mcpResidentTargetError) }
        let hasLinks = await executor.agentSessionLinkHasActiveOutboundLink(endpoint)
        try await requireReadTargets([target], operation: .runPoll)
        guard AgentModeViewModel.isMCPResidentAppOwned(session), executor.agentSessionLinkObserverEndpoint(tabID: session.tabID) == endpoint
        else { throw MCPError.invalidParams(AgentModeViewModel.mcpResidentTargetError) }
        let counts = try executor.mcpResidentLaneStateCounts(
            for: endpoint, hasOutboundLinks: hasLinks, props: executor.residentMonitorPropsBySessionID[target.sessionID]
        )
        return (residentStatusSnapshot(target), AgentModeViewModel.mcpResidentOverseerValue(session: session, endpoint: endpoint, counts: counts))
    }

    private func residentStatusSnapshot(_ target: ReadTarget) -> AgentRunMCPSnapshot {
        let writer = target.command.writer
        return AgentModeViewModel.mcpResidentStatusSnapshot(
            writer.session,
            sessionID: target.sessionID,
            title: writer.scope.persistence.composition?.displayName(writer.session.tabID) ?? "Agent Session"
        )
    }

    private func dispatchControlSteer(
        _ target: ReadTarget, text: String, workflow: AgentWorkflowDefinition?, resident: Bool, ownsPendingStart: Bool = false
    ) async throws -> AgentMCPInstructionDispatch {
        let session = target.command.writer.session
        if session.runState.isActive || session.instructionContinuation != nil {
            return try await submitExactActiveControlInput(target, text: text, workflow: workflow, operation: .runSteer)
        }
        return try await submitExactIdleControlInput(target, text: text, workflow: workflow, resident: resident, ownsPendingStart: ownsPendingStart)
    }

    private func submitExactIdleControlInput(
        _ target: ReadTarget, text: String, workflow: AgentWorkflowDefinition?, resident: Bool, ownsPendingStart: Bool
    ) async throws -> AgentMCPInstructionDispatch {
        let command = target.command
        let session = command.writer.session
        func requireAdmission() async throws {
            try await requireReadTargets([target], operation: .runSteer)
            try AgentSessionMCPRuntime.requireSubscriptionAccountAdmission(session)
        }
        try await requireAdmission()
        let scope = command.writer.scope
        guard let executor = scope.linkExecution, let targetHost = scope.executableHost,
              let programmatic = scope.submissions.programmaticTarget(command),
              resident || target.registration != nil, !session.runState.isActive,
              !session.mcpFollowUpRunPending || ownsPendingStart,
              target.runtime.mcpPendingInteraction(for: session) == nil,
              session.pendingApplyEditsReview == nil, session.pendingWorktreeMergeReview == nil
        else { throw MCPError.invalidParams("The requested Agent session is not ready for a new turn.") }
        let stopFence = AgentRunStartStopFence(session: session)
        func deliver() async throws -> AgentMCPInstructionDispatch {
            try await requireAdmission()
            guard session.autoEffortJudgmentID == nil else {
                throw MCPError.invalidParams("Auto effort is already choosing effort for this session. Retry after that turn starts.")
            }
            let policy = autoEffortPolicy(for: targetHost, command: command)
            let judgesEffort = AutoEffortModelPolicy.shouldJudgeMCPUserTurn(
                isEnabled: targetHost.modelRouterSettingsStore.autoEffortEnabled(),
                startsNewRun: !session.runState.isActive, hasPriorUserTurn: session.hasSentFirstMessage,
                isNativePreparedTurn: false, preserveRoutedInitialEffort: false
            )
            let effort = judgesEffort ? await policy.chooseAutoEffortForUserTurn(
                text: text, session: session, workflow: workflow,
                isCurrent: {
                    readTargetIsCurrent(target, operation: .runSteer) && stopFence.permitsStart(of: session)
                        && !session.subscriptionAccountBinding.blocksProviderOperations
                }
            ) : nil
            try await requireAdmission()
            guard stopFence.permitsStart(of: session), !session.runState.isActive,
                  let claim = executor.claimComposerSubmitAttempt(.init(
                      id: UUID(), target: programmatic, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
                  )) else { throw MCPFileToolAuthorityFailure.superseded }
            let providerText = workflow?.wrapUserText(
                text, includeBuiltInSessionCleanupGuidance: targetHost.modelRouterSettingsStore.showBuiltInWorkflowCleanupGuidance()
            ) ?? text
            let outcome = await executor.persistAndStartNoncomposerTurn(
                session: session, tabID: session.tabID, workspaceID: command.identity.workspaceID,
                claim: claim, displayText: text, providerMessage: providerText, workflow: workflow,
                attribution: nil, stopFence: stopFence, directStartOptions: .init(autoEffortSelection: effort?.selection),
                audit: effort.map { choice in { policy.auditForSubmittedTurn($0, session: session, autoEffort: choice.audit) } },
                revalidateBeforeDispatch: { try await requireAdmission() },
                dispatchIsCurrent: {
                    readTargetIsCurrent(target, operation: .runSteer) && stopFence.permitsStart(of: session)
                        && !session.subscriptionAccountBinding.blocksProviderOperations
                        && session.pendingApplyEditsReview == nil && session.pendingWorktreeMergeReview == nil
                }
            )
            switch outcome {
            case let .blocked(failure): throw MCPError.invalidParams(failure.message)
            case let .delivered(delivery):
                guard delivery.deliveryState == .runStarted || session.runState == .failed else {
                    throw MCPError.invalidParams("The instruction was saved, but the originating run did not start.")
                }
                if delivery.deliveryState == .runStarted, let selection = effort?.selection {
                    policy.recordSubmittedAutoEffort(selection, for: session)
                }
                return .startedRun
            }
        }
        if resident { return try await deliver() }
        target.runtime.setFollowUpRunPending(sessionID: target.sessionID, true)
        let openedAt = session.mcpFollowUpRunPendingUpdatedAt
        do {
            return try await target.runtime.withEpochTransition(command: command, kind: .steering, operation: deliver)
        } catch {
            if target.controlIsCurrent, session.mcpFollowUpRunPendingUpdatedAt == openedAt, !session.runState.isActive {
                target.runtime.setFollowUpRunPending(sessionID: target.sessionID, false)
            }
            throw error
        }
    }

    static func requireControlSessionReference(_ args: [String: Value]) throws -> String {
        guard let reference = AgentMCPToolHelpers.normalizedString(args["session_id"]) else {
            throw MCPError.invalidParams("session_id is required for agent_run control operations.")
        }
        return reference
    }

    static func controlSessionID(_ reference: String) throws -> UUID {
        // The existing session resolver accepts UUIDs, not name or prefix searches.
        guard let id = UUID(uuidString: reference) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found. Provide a full UUID.")
        }
        return id
    }

    func makeHostToolService(
        waitTargets: [ReadTarget] = [], waitOperation: DomainAgentSessionTargetOperation = .runWait
    ) -> AgentRunMCPToolService {
        let metadata = invocation.metadata
        return AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { metadata },
            requireTargetWindow: { throw MCPError.invalidRequest("This Agent route has no presenter") },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in source.writer.session.tabID },
            resolveSpawnParentSessionID: { _, _ in source.identity.sessionID },
            withHeartbeat: { connectionID, tool, stage, message, operation in
                try await MCPToolHeartbeat.runProgress(
                    connectionID: connectionID, tool: tool, stage: stage, message: message,
                    invocation: invocation, operation: operation
                )
            },
            beginAgentRunWait: { _, sessionIDs, timeout in
                beginReadWait(for: waitTargets.filter { sessionIDs.contains($0.sessionID) }, timeoutSeconds: timeout, operation: waitOperation)
            },
            endAgentRunWait: { token, completion in
                host.route.toolExecutionRuntime.endAgentRunWaitScope(token, completion: completion)
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("The presenter start adapter is not installed on this host")
            }
        )
    }
}
