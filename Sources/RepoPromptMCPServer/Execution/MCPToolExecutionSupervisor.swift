// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptShared

/// Supervises the one host invocation; permits and settlement remain domain-owned.
package struct MCPToolExecutionSupervisor: Sendable {
    private let toolName: String
    private let connectionID: UUID
    private let invocationID: UUID
    private let isPromptExport: Bool
    private let selectedExecutionContract: MCPToolExecutionContract?
    private let promptExportExecutionEnvelope: PromptExportExecutionEnvelope?
    private let fence: MCPToolDispatchFence
    private let effects: MCPToolExecutionEffects
    private let codeStructureSettlementRegistry: MCPCodeStructureSettlementRegistry
    private let executionWatchdogEnvironment: MCPToolExecutionWatchdogEnvironment
    private let executionSink: any MCPToolExecutionEventSink
    private let handlerPhaseRecorder: any MCPToolExecutionHandlerPhaseRecording
    private let executionTraceOrigin: Duration
    private let evidenceOperationIdentity: MCPDomainToolOperationIdentity
    private let observerRunIDForCallbacksFinal: UUID?
    private let resolvedRequestIdentity: MCPRequestTimelineIdentity?
    private let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    private let promptExportMutationObservation: PromptExportMutationSettlementObservation?

    package init(
        toolName: String,
        connectionID: UUID,
        invocationID: UUID,
        isPromptExport: Bool,
        selectedExecutionContract: MCPToolExecutionContract?,
        promptExportExecutionEnvelope: PromptExportExecutionEnvelope?,
        fence: MCPToolDispatchFence,
        effects: MCPToolExecutionEffects,
        codeStructureSettlementRegistry: MCPCodeStructureSettlementRegistry,
        executionWatchdogEnvironment: MCPToolExecutionWatchdogEnvironment,
        executionSink: any MCPToolExecutionEventSink,
        handlerPhaseRecorder: any MCPToolExecutionHandlerPhaseRecording,
        executionTraceOrigin: Duration,
        evidenceOperationIdentity: MCPDomainToolOperationIdentity,
        observerRunIDForCallbacksFinal: UUID?,
        resolvedRequestIdentity: MCPRequestTimelineIdentity?,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        promptExportMutationObservation: PromptExportMutationSettlementObservation?
    ) {
        self.toolName = toolName
        self.connectionID = connectionID
        self.invocationID = invocationID
        self.isPromptExport = isPromptExport
        self.selectedExecutionContract = selectedExecutionContract
        self.promptExportExecutionEnvelope = promptExportExecutionEnvelope
        self.fence = fence
        self.effects = effects
        self.codeStructureSettlementRegistry = codeStructureSettlementRegistry
        self.executionWatchdogEnvironment = executionWatchdogEnvironment
        self.executionSink = executionSink
        self.handlerPhaseRecorder = handlerPhaseRecorder
        self.executionTraceOrigin = executionTraceOrigin
        self.evidenceOperationIdentity = evidenceOperationIdentity
        self.observerRunIDForCallbacksFinal = observerRunIDForCallbacksFinal
        self.resolvedRequestIdentity = resolvedRequestIdentity
        self.lifecycleCorrelation = lifecycleCorrelation
        self.promptExportMutationObservation = promptExportMutationObservation
    }

    package func dispatch(
        _ operation: @escaping @Sendable (PromptExportProviderEntryBridge?, ToolInvocationContext) async throws -> Value,
        invocationContext: ToolInvocationContext
    ) async throws -> Value {
        try await fence.validate(invocationContext.dispatchAuthorization)
        guard let contract = selectedExecutionContract else {
            throw MCPToolExecutionDispatchError.missingContract(toolName: toolName)
        }

        let settlementAdmission: (
            cleanupDisposition: MCPToolExecutionCleanupDisposition?,
            slot: MCPCodeStructureSettlementRegistry.Slot?
        )
        if contract.cleanupDisposition == .detachAndSettle,
           toolName != MCPWindowToolName.fileActions
        {
            guard let windowID = invocationContext.dispatchAuthorization?.windowIdentity?.windowID else {
                throw MCPToolExecutionDispatchError.structureSettlementWindowUnresolved
            }
            switch codeStructureSettlementRegistry.admit(
                windowID: windowID,
                connectionID: connectionID,
                invocationID: invocationID,
                toolName: toolName,
                now: executionWatchdogEnvironment.now(),
                handlerPhase: {
                    handlerPhaseRecorder.snapshot()?.phase.rawValue
                }
            ) {
            case let .admitted(slot):
                await effects.clearAfterAdmission(windowID)
                settlementAdmission = (.detachAndSettle, slot)
            case let .busy(context):
                throw MCPToolExecutionDispatchError.structureSettlementBusy(
                    windowID: windowID,
                    context: context
                )
            }
        } else {
            settlementAdmission = (contract.cleanupDisposition, nil)
        }

        defer {
            _ = settlementAdmission.slot?.closeBeforeExecutionExit()
        }

        @Sendable func emitExecutionTrace(
            _ phase: MCPToolExecutionDiagnosticEvent.Phase,
            resolvedCleanupDisposition: MCPToolExecutionCleanupDisposition? = nil,
            cancellationRequested: Bool? = nil,
            cancellationOutcome: MCPToolExecutionSettlement? = nil,
            cancellationOrigin: MCPToolExecutionCancellationOrigin? = nil,
            settlement: MCPToolExecutionDiagnosticEvent.Settlement? = nil,
            graceOutcome: MCPToolExecutionDiagnosticEvent.GraceOutcome? = nil,
            escalationReason: MCPToolExecutionDiagnosticEvent.EscalationReason? = nil
        ) async {
            let now = executionWatchdogEnvironment.now()
            let handlerPhase = handlerPhaseRecorder.snapshot()
            let handlerPhaseAgeMilliseconds = handlerPhase.map {
                max(0, now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds - $0.elapsedMilliseconds)
            }
            executionSink.record(MCPToolExecutionDiagnosticEvent(
                toolName: toolName,
                canonicalTool: evidenceOperationIdentity.canonicalTool,
                normalizedOperation: evidenceOperationIdentity.normalizedOperation,
                connectionID: connectionID,
                invocationID: invocationID,
                runID: observerRunIDForCallbacksFinal,
                requestIdentity: resolvedRequestIdentity,
                contractKind: .init(contract.kind),
                executionDeadlineSeconds: contract.deadline?.mcpSeconds,
                cleanupGraceSeconds: contract.cancellationGrace?.mcpSeconds,
                cleanupDisposition: (resolvedCleanupDisposition ?? settlementAdmission.cleanupDisposition).map(MCPToolExecutionDiagnosticEvent.CleanupDisposition.init),
                phase: phase,
                elapsedMilliseconds: max(0, now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds),
                cancellationRequested: cancellationRequested,
                cancellationOutcome: cancellationOutcome.map(MCPToolExecutionDiagnosticEvent.Outcome.init),
                cancellationOrigin: cancellationOrigin.map(MCPToolExecutionDiagnosticEvent.CancellationOrigin.init),
                settlement: settlement,
                graceOutcome: graceOutcome,
                escalationReason: escalationReason,
                handlerPhase: handlerPhase,
                handlerPhaseAgeMilliseconds: handlerPhaseAgeMilliseconds
            ))
        }

        await emitExecutionTrace(.contractSelected)
        try promptExportExecutionEnvelope?.admissionDeadline.check()
        await emitExecutionTrace(.started)
        try promptExportExecutionEnvelope?.admissionDeadline.check()
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderBegan,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(toolName: toolName)
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                toolName: toolName,
                windowID: invocationContext.dispatchAuthorization?.windowIdentity?.windowID,
                runID: observerRunIDForCallbacksFinal?.uuidString,
                providerActive: true,
                networkScopeActive: invocationContext.dispatchAuthorization?.windowIdentity != nil,
                permitActive: true,
                publicationPending: false,
                terminalBarrier: false
            )
        )

        let tracedOperation: @Sendable (PromptExportProviderEntryBridge?) async throws -> Value = { providerEntryBridge in
            try await fence.validate(invocationContext.dispatchAuthorization)
            return try await MCPToolExecutionHandlerPhaseContext.$recorder.withValue(handlerPhaseRecorder) {
                let executeOperation = {
                    try promptExportExecutionEnvelope?.admissionDeadline.check()
                    return try await EditFlowPerf.measure(
                        EditFlowPerf.Stage.MCPToolCall.resolvedProviderDispatch,
                        EditFlowPerf.Dimensions(toolName: toolName),
                        operation: { try await operation(providerEntryBridge, invocationContext) }
                    )
                }
                guard let promptExportMutationObservation else {
                    return try await executeOperation()
                }
                return try await MCPDomainProtectedMutationSettlementContext.$observer.withValue(
                    { promptExportMutationObservation.record($0) },
                    operation: executeOperation
                )
            }
        }

        @Sendable func recordSynchronousSettlement(
            _ providerSettlement: MCPToolExecutionSettlement
        ) async {
            if let slot = settlementAdmission.slot {
                await effects.clearAfterSettlement(slot)
            }
            let outcome = providerSettlement.rawValue
            await emitExecutionTrace(.handlerCompleted, cancellationOutcome: providerSettlement)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(toolName: toolName, outcome: outcome)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: providerSettlement == .success ? "provider_completed" : outcome,
                    windowID: invocationContext.dispatchAuthorization?.windowIdentity?.windowID,
                    runID: observerRunIDForCallbacksFinal?.uuidString,
                    providerActive: false,
                    networkScopeActive: invocationContext.dispatchAuthorization?.windowIdentity != nil,
                    permitActive: true,
                    publicationPending: true,
                    terminalBarrier: false
                )
            )
        }

        @Sendable func recordDetachedSettlement(
            _ providerSettlement: MCPToolExecutionSettlement
        ) async {
            if let slot = settlementAdmission.slot {
                await effects.clearAfterSettlement(slot)
            }
            await emitExecutionTrace(
                .detachedSettled,
                cancellationRequested: true,
                cancellationOutcome: providerSettlement,
                cancellationOrigin: .watchdogDeadline,
                settlement: .detached,
                graceOutcome: .expired
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: "detached_settled_\(providerSettlement.rawValue)"
                )
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: "detached_settled",
                    windowID: settlementAdmission.slot?.windowID,
                    runID: observerRunIDForCallbacksFinal?.uuidString,
                    providerActive: false,
                    networkScopeActive: false,
                    permitActive: false,
                    publicationPending: false,
                    terminalBarrier: false
                )
            )
        }

        @Sendable func recordAbandonedSettlement(
            _ providerSettlement: MCPToolExecutionSettlement
        ) async {
            MCPLifecycleDiagnostics.shared.record(.abandonedSettlement, connectionID: connectionID, invocationID: invocationID)
            if let slot = settlementAdmission.slot {
                await effects.clearAfterSettlement(slot)
            }
            await emitExecutionTrace(
                .handlerCompleted,
                cancellationRequested: true,
                cancellationOutcome: providerSettlement,
                cancellationOrigin: .requestCancellation
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: "request_cancelled_settled_\(providerSettlement.rawValue)"
                )
            )
        }

        @Sendable func recordForceDisconnectedSettlement(
            _ providerSettlement: MCPToolExecutionSettlement
        ) async {
            MCPLifecycleDiagnostics.shared.record(.forceDisconnectedSettlement, connectionID: connectionID, invocationID: invocationID)
            if let slot = settlementAdmission.slot {
                await effects.clearAfterSettlement(slot)
            }
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.resolvedProviderEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    toolName: toolName,
                    outcome: "force_disconnected_settled_\(providerSettlement.rawValue)"
                )
            )
        }

        switch contract {
        case let .bounded(deadline, cancellationGrace, _):
            do {
                let watchdogEnvironment: MCPToolExecutionWatchdogEnvironment
                let cleanupNotAfter: Duration?
                let operationCompletionInstant: @Sendable () -> Duration?
                let watchdogOperation: @Sendable () async throws -> Value
                if isPromptExport {
                    // Host validation runs in one task before the watchdog supervises
                    // that same task from the exact provider-entry instant. Outer-envelope
                    // cleanup policy remains absent for explicit client timeout modes.
                    let providerEntryBridge = PromptExportProviderEntryBridge(
                        environment: executionWatchdogEnvironment,
                        executionDeadline: deadline,
                        cancellationGrace: cancellationGrace,
                        outerCleanupNotAfter: promptExportExecutionEnvelope?.cleanupNotAfter
                    )
                    #if DEBUG
                        let debugHostCompletion = await effects.debugHostCompletion?()
                    #endif
                    let hostTask = Task<Value, Error> {
                        defer {
                            // Supervision can begin after this task finishes, so completion time
                            // must be captured here rather than when Task.value is observed.
                            let completionInstant = executionWatchdogEnvironment.now()
                            providerEntryBridge.hostDidComplete(at: completionInstant)
                            #if DEBUG
                                debugHostCompletion?(connectionID, toolName, completionInstant)
                            #endif
                        }
                        return try await tracedOperation(providerEntryBridge)
                    }
                    let initialEvent = await withTaskCancellationHandler {
                        await providerEntryBridge.waitForInitialEvent()
                    } onCancel: {
                        providerEntryBridge.cancel()
                        hostTask.cancel()
                    }
                    switch initialEvent {
                    case let .providerEntered(providerEntry):
                        #if DEBUG
                            await effects.debugProviderEntry?(
                                connectionID,
                                toolName
                            )
                        #endif
                        // Once provider entry wins the bridge, the watchdog must retain
                        // cleanup ownership even when request cancellation is already pending.
                        if Task.isCancelled {
                            hostTask.cancel()
                        }
                        watchdogEnvironment = providerEntry.watchdogEnvironment
                        cleanupNotAfter = providerEntry.cleanupNotAfter
                        operationCompletionInstant = {
                            providerEntryBridge.recordedHostCompletionInstant()
                        }
                        watchdogOperation = {
                            try await withTaskCancellationHandler {
                                try await hostTask.value
                            } onCancel: {
                                hostTask.cancel()
                            }
                        }
                    case .providerEntryRejected, .hostCompleted:
                        try Task.checkCancellation()
                        return try await hostTask.value
                    case .cancelled:
                        hostTask.cancel()
                        throw CancellationError()
                    }
                } else {
                    watchdogEnvironment = executionWatchdogEnvironment
                    cleanupNotAfter = nil
                    operationCompletionInstant = { nil }
                    watchdogOperation = { try await tracedOperation(nil) }
                }

                return try await MCPToolExecutionWatchdog.execute(
                    deadline: deadline,
                    cancellationGrace: cancellationGrace,
                    cleanupNotAfter: cleanupNotAfter,
                    cleanupDisposition: settlementAdmission.cleanupDisposition ?? .forceDisconnect,
                    settlementSlot: settlementAdmission.slot,
                    environment: watchdogEnvironment,
                    onEvent: { event in
                        switch event {
                        case .deadlineExpired:
                            await emitExecutionTrace(.deadlineExpired)
                        case let .cancellationRequested(origin):
                            MCPLifecycleDiagnostics.shared.record(
                                origin == .requestCancellation ? .requestCancellation : .deadlineCancellation,
                                connectionID: connectionID,
                                invocationID: invocationID
                            )
                            await emitExecutionTrace(
                                .cancellationRequested,
                                cancellationRequested: true,
                                cancellationOrigin: origin
                            )
                        case let .settledDuringGrace(settlement, cancellationRequested):
                            MCPLifecycleDiagnostics.shared.record(.settledDuringGrace, connectionID: connectionID, invocationID: invocationID)
                            await emitExecutionTrace(
                                .settledDuringGrace,
                                cancellationRequested: cancellationRequested,
                                cancellationOutcome: settlement,
                                cancellationOrigin: cancellationRequested ? .watchdogDeadline : nil,
                                graceOutcome: cancellationRequested ? .settled : .lateCompletion
                            )
                        case .cleanupGraceCappedByOuterEnvelope:
                            MCPLifecycleDiagnostics.shared.record(.cleanupGraceExpired, connectionID: connectionID, invocationID: invocationID)
                            await emitExecutionTrace(
                                .cleanupGraceExpired,
                                resolvedCleanupDisposition: .forceDisconnect,
                                cancellationRequested: true,
                                cancellationOrigin: .watchdogDeadline,
                                graceOutcome: .capped,
                                escalationReason: .outerEnvelopeCleanupCap
                            )
                        case let .cleanupGraceExpired(resolvedDisposition):
                            MCPLifecycleDiagnostics.shared.record(.cleanupGraceExpired, connectionID: connectionID, invocationID: invocationID)
                            await emitExecutionTrace(
                                .cleanupGraceExpired,
                                resolvedCleanupDisposition: resolvedDisposition,
                                cancellationRequested: true,
                                cancellationOrigin: .watchdogDeadline,
                                graceOutcome: .expired,
                                escalationReason: .handlerIgnoredCancellation
                            )
                        case .detachedForSettlement:
                            await emitExecutionTrace(
                                .detachedForSettlement,
                                resolvedCleanupDisposition: .detachAndSettle,
                                cancellationRequested: true,
                                cancellationOrigin: .watchdogDeadline,
                                settlement: .detached,
                                graceOutcome: .expired,
                                escalationReason: .detachDispositionHandlerIgnoredCancellation
                            )
                        }
                    },
                    onSynchronousSettlement: recordSynchronousSettlement,
                    onDetachedSettlement: recordDetachedSettlement,
                    onAbandonedSettlement: recordAbandonedSettlement,
                    onForceDisconnectedSettlement: recordForceDisconnectedSettlement,
                    operationCompletionInstant: operationCompletionInstant,
                    operation: watchdogOperation
                )
            } catch MCPToolExecutionWatchdogError.cleanupUnresponsive {
                await emitExecutionTrace(
                    .connectionForceDisconnectRequested,
                    resolvedCleanupDisposition: .forceDisconnect,
                    cancellationRequested: true,
                    cancellationOrigin: .watchdogDeadline,
                    graceOutcome: .expired,
                    escalationReason: .handlerIgnoredCancellation
                )
                throw MCPToolExecutionWatchdogError.cleanupUnresponsive
            }
        case .longSynchronousCancellable,
             .lifecycleManagedCancellable,
             .interactiveCancellable,
             .workspaceLifecycleCancellable:
            do {
                let value = try await tracedOperation(nil)
                await recordSynchronousSettlement(.success)
                return value
            } catch {
                let providerSettlement: MCPToolExecutionSettlement = MCPToolExecutionCancelledError.matches(error)
                    ? .cancellation
                    : .error
                await recordSynchronousSettlement(providerSettlement)
                throw error
            }
        }
    }

    package func reportPostProviderPhase(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started
    ) async {
        guard isPromptExport, let contract = selectedExecutionContract else { return }
        let snapshot = await MCPToolExecutionHandlerPhaseContext.report(
            phase,
            transition: transition,
            using: handlerPhaseRecorder
        )
        let now = executionWatchdogEnvironment.now()
        executionSink.record(MCPToolExecutionDiagnosticEvent(
            toolName: toolName,
            canonicalTool: evidenceOperationIdentity.canonicalTool,
            normalizedOperation: evidenceOperationIdentity.normalizedOperation,
            connectionID: connectionID,
            invocationID: invocationID,
            runID: observerRunIDForCallbacksFinal,
            requestIdentity: resolvedRequestIdentity,
            contractKind: .init(contract.kind),
            executionDeadlineSeconds: contract.deadline?.mcpSeconds,
            cleanupGraceSeconds: contract.cancellationGrace?.mcpSeconds,
            cleanupDisposition: contract.cleanupDisposition.map(MCPToolExecutionDiagnosticEvent.CleanupDisposition.init),
            phase: .handlerPhaseTransition,
            elapsedMilliseconds: max(
                0,
                now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds
            ),
            cancellationRequested: nil,
            cancellationOutcome: nil,
            cancellationOrigin: nil,
            settlement: nil,
            graceOutcome: nil,
            escalationReason: nil,
            handlerPhase: snapshot,
            handlerPhaseAgeMilliseconds: max(
                0,
                now.mcpMilliseconds - executionTraceOrigin.mcpMilliseconds
                    - snapshot.elapsedMilliseconds
            )
        ))
    }
}
