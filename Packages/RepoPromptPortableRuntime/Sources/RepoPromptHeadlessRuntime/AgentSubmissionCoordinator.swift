import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public struct AcceptedAgentSubmission: Sendable {
    public let receipt: SubmissionReceipt
    public let canonicalUserTurn: CanonicalUserTurn
    public let providerInput: CompiledProviderTurnInput
    public let providerKind: ProviderKind
    public let providerModel: String
    public let executionPolicy: ProviderExecutionPolicy
    public let replayed: Bool
    public let newSessionEvents: NewAgentSessionAcceptanceEvents?

    public init(receipt: SubmissionReceipt, canonicalUserTurn: CanonicalUserTurn, providerInput: CompiledProviderTurnInput, providerKind: ProviderKind, providerModel: String, executionPolicy: ProviderExecutionPolicy, replayed: Bool, newSessionEvents: NewAgentSessionAcceptanceEvents? = nil) {
        self.receipt = receipt
        self.canonicalUserTurn = canonicalUserTurn
        self.providerInput = providerInput
        self.providerKind = providerKind
        self.providerModel = providerModel
        self.executionPolicy = executionPolicy
        self.replayed = replayed
        self.newSessionEvents = newSessionEvents
    }
}

public actor AgentSubmissionCoordinator {
    private struct StoredPreparedIntent: Codable {
        let canonicalUserTurn: CanonicalUserTurn
        let providerKind: ProviderKind
        let providerModel: String
        let executionPolicy: ProviderExecutionPolicy
    }

    private let store: any AgentSubmissionStore
    private let catalog: any AgentComposerCatalogProviding
    private let compiler: AgentTurnIntentCompiler
    private let attachments: AgentComposerAttachmentStore

    public init(store: any AgentSubmissionStore, catalog: any AgentComposerCatalogProviding, compiler: AgentTurnIntentCompiler, attachments: AgentComposerAttachmentStore) {
        self.store = store
        self.catalog = catalog
        self.compiler = compiler
        self.attachments = attachments
    }

    public func acceptFollowup(
        session: SessionSnapshot,
        activeRun: ProviderRunSnapshot?,
        actor: ExternalActor,
        publicSubmissionKey: String,
        requestDigest: String,
        submission: AgentTurnSubmissionWire,
        mcpControlled: Bool = false,
        now: Date = Date()
    ) async throws -> AcceptedAgentSubmission {
        try await accept(session: session, activeRun: activeRun, actor: actor, publicSubmissionKey: publicSubmissionKey, requestDigest: requestDigest, submission: submission, operation: "submitTurn", targetKey: "session:\(session.sessionID.uuidString.lowercased())", receiptSession: nil, catalogContextKind: .session, mcpControlled: mcpControlled, now: now)
    }

    public func replayStartIfAccepted(
        projectID: UUID,
        actor: ExternalActor,
        publicSubmissionKey: String,
        requestDigest: String
    ) async throws -> AcceptedAgentSubmission? {
        guard UUID(uuidString: publicSubmissionKey) != nil else {
            throw ServiceAPIError(code: .invalidRequest, message: "Idempotency-Key must be the submission UUID")
        }
        let targetKey = "project:\(projectID.uuidString.lowercased())"
        guard let prior = try await store.agentSubmission(actorID: actor.userID, targetKey: targetKey, operation: "startSession", publicKey: publicSubmissionKey) else { return nil }
        guard prior.requestDigest == requestDigest else {
            throw ServiceAPIError(code: .idempotencyConflict, message: "Submission key was reused with different content")
        }
        switch prior.state {
        case .accepted: return try decodeAccepted(prior, replayed: true)
        case .preparing: throw ServiceAPIError(code: .dependencyUnavailable, message: "submission_in_progress", retryable: true)
        case .rejected: throw ServiceAPIError(code: .authorizationDecisionRejected, message: prior.rejectionCode ?? "Submission was rejected")
        }
    }

    public func acceptStart(
        newSession: PreparedNewAgentSession,
        actor: ExternalActor,
        publicSubmissionKey: String,
        requestDigest: String,
        submission: AgentTurnSubmissionWire,
        selectedMessageContext: SelectedMessageContext? = nil,
        now: Date = Date()
    ) async throws -> AcceptedAgentSubmission {
        let session = newSession.snapshot
        return try await accept(session: session, activeRun: nil, actor: actor, publicSubmissionKey: publicSubmissionKey, requestDigest: requestDigest, submission: submission, operation: "startSession", targetKey: "project:\(session.projectID.uuidString.lowercased())", receiptSession: session, catalogContextKind: .project, compilerSessionID: nil, selectedMessageContext: selectedMessageContext, newSession: newSession, mcpControlled: false, now: now)
    }

    private func accept(
        session: SessionSnapshot,
        activeRun: ProviderRunSnapshot?,
        actor: ExternalActor,
        publicSubmissionKey: String,
        requestDigest: String,
        submission: AgentTurnSubmissionWire,
        operation: String,
        targetKey: String,
        receiptSession: SessionSnapshot?,
        catalogContextKind: ComposerContextKind,
        compilerSessionID: UUID? = nil,
        selectedMessageContext: SelectedMessageContext? = nil,
        newSession: PreparedNewAgentSession? = nil,
        mcpControlled: Bool = false,
        now: Date = Date()
    ) async throws -> AcceptedAgentSubmission {
        guard let submissionID = UUID(uuidString: publicSubmissionKey) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Idempotency-Key must be the submission UUID")
        }
        if let prior = try await store.agentSubmission(actorID: actor.userID, targetKey: targetKey, operation: operation, publicKey: publicSubmissionKey) {
            guard prior.requestDigest == requestDigest else { throw ServiceAPIError(code: .idempotencyConflict, message: "Submission key was reused with different content") }
            switch prior.state {
            case .accepted:
                return try decodeAccepted(prior, replayed: true)
            case .preparing:
                throw ServiceAPIError(code: .dependencyUnavailable, message: "submission_in_progress", retryable: true)
            case .rejected:
                throw ServiceAPIError(code: .authorizationDecisionRejected, message: prior.rejectionCode ?? "Submission was rejected")
            }
        }
        guard activeRun == nil || activeRun?.endedAt != nil else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A configurable follow-up cannot start during an active run")
        }
        if let presentation = try await store.runPresentation(sessionID: session.sessionID), presentation.terminalSettlementCode == nil {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A configurable follow-up is already being prepared")
        }
        guard submission.expectedSessionRevision == nil || submission.expectedSessionRevision == session.revision else {
            throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: session.revision)
        }

        let identity = CanonicalTurnIdentity(
            requestAnchorID: UUID(),
            runID: UUID(),
            generation: session.runGeneration + 1,
            turnEpoch: session.turnEpoch + 1,
            turnID: UUID(),
            responseSpanID: UUID()
        )
        let initial = AgentSubmissionRecord(
            submissionID: submissionID,
            actorID: actor.userID,
            targetKey: targetKey,
            operation: operation,
            publicKey: publicSubmissionKey,
            requestDigest: requestDigest,
            state: .preparing,
            sessionID: session.sessionID,
            identity: identity,
            createdAt: now,
            updatedAt: now
        )
        let prepared = try await store.prepareAgentSubmission(initial)
        guard prepared.submissionID == submissionID else { throw ServiceAPIError(code: .idempotencyConflict, message: "Submission identity is inconsistent") }
        if prepared.identity != identity {
            switch prepared.state {
            case .accepted: return try decodeAccepted(prepared, replayed: true)
            case .preparing: throw ServiceAPIError(code: .dependencyUnavailable, message: "submission_in_progress", retryable: true)
            case .rejected: throw ServiceAPIError(code: .authorizationDecisionRejected, message: prepared.rejectionCode ?? "Submission was rejected")
            }
        }

        do {
            let context = ComposerCatalogContext(kind: catalogContextKind, projectID: session.projectID, sessionID: catalogContextKind == .session ? session.sessionID : nil, actorID: actor.userID, activeRun: false, mcpControlled: mcpControlled)
            let (effective, providerConfiguration, _, catalogWorkflowGuidance) = try await catalog.validate(submission.configuration, context: context, acceptedAt: now)
            guard session.provider == providerConfiguration.runtimeKind else {
                throw ServiceAPIError(code: .capabilityMissing, message: "Session provider does not match the accepted configuration")
            }
            var workflowGuidance = catalogWorkflowGuidance
            var userTextConsumedByWorkflow = false
            if let workflowID = effective.workflowID {
                let repository = try await store.workflowRepositorySnapshot()
                if let workflow = repository.workflows.first(where: { $0.workflowID == workflowID && $0.enabled }) {
                    workflowGuidance = WorkflowCatalogConsume.wrap(
                        template: workflow.definition,
                        userText: submission.content.text,
                        source: workflow.source,
                        includeBuiltinCleanup: repository.includeSessionCleanupGuidance
                    )
                    userTextConsumedByWorkflow = true
                }
            }
            let manifest = try await attachments.prepareAcceptance(
                attachmentIDs: submission.content.attachmentIDs,
                submissionID: submissionID,
                actorID: actor.userID,
                projectID: session.projectID,
                sessionID: session.sessionID,
                turnID: identity.turnID,
                supportsNativeImages: providerConfiguration.supportsNativeImages,
                now: now
            )
            let compilation = try await compiler.compile(.init(
                projectID: session.projectID,
                sessionID: compilerSessionID ?? (newSession == nil ? session.sessionID : nil),
                identity: identity,
                content: submission.content,
                selectedMessageContext: selectedMessageContext,
                effectiveConfiguration: effective,
                providerConfiguration: providerConfiguration,
                attachmentManifest: manifest,
                workflowGuidance: workflowGuidance,
                userTextConsumedByWorkflow: userTextConsumedByWorkflow
            ))
            let preparedIntent = StoredPreparedIntent(canonicalUserTurn: compilation.canonicalUserTurn, providerKind: providerConfiguration.runtimeKind, providerModel: providerConfiguration.providerRawModelValue, executionPolicy: providerConfiguration.executionPolicy)
            let canonicalJSON = try JSONEncoder.serviceEncoder.encode(compilation.canonicalUserTurn)
            let manifestJSON = try JSONEncoder.serviceEncoder.encode(manifest.attachments)
            let compiledJSON = try JSONEncoder.serviceEncoder.encode(compilation.providerInput)
            let sequence = (session.transcript.last?.sessionSequence ?? 0) + 1
            let semanticTurn = SemanticTurnRecord(
                sessionID: session.sessionID,
                identity: identity,
                firstSequence: sequence,
                lastSequence: sequence,
                canonicalUserTurnJSON: canonicalJSON,
                effectiveConfiguration: effective,
                attachmentManifestJSON: manifestJSON,
                taggedFiles: submission.content.taggedFiles,
                createdAt: now,
                acceptedAt: now
            )
            let acceptedNewSession = newSession.map {
                $0.replacingSnapshot(Self.acceptedSessionSnapshot($0.snapshot, canonicalUserTurn: compilation.canonicalUserTurn, actor: actor, identity: identity, at: now))
            }
            let previousDefaults = try await store.nextTurnDefaults(sessionID: session.sessionID)
            let nextDefaults = SessionNextTurnDefaultsRecord(sessionID: session.sessionID, revision: (previousDefaults?.revision ?? 0) + 1, configuration: effective, updatedAt: now)
            let runPresentation = RunPresentationSnapshot(sessionID: session.sessionID, runID: identity.runID, generation: identity.generation, turnEpoch: identity.turnEpoch, phase: .preparing, phaseRevision: 1, runningStatusCode: HeadlessRunStatusCopy.thinkingCode, runningStatusText: HeadlessRunStatusCopy.initializing, runStartedAt: now)
            let selected = AgentTurnConfigurationWire(catalogRevision: effective.catalogRevision, providerID: effective.providerID, modelID: effective.modelID, effortID: effective.effortID, workflowID: effective.workflowID, permissionID: effective.permissionID, toolValues: effective.toolValues.mapValues(Self.wireValue))
            let receiptSessionSnapshot = (acceptedNewSession?.snapshot ?? receiptSession).map {
                Self.acceptedReceiptSessionSnapshot($0, effective: effective, nextDefaults: nextDefaults, runPresentation: runPresentation)
            }
            let receipt = SubmissionReceipt(
                submissionID: submissionID,
                acceptedAt: now,
                operation: operation,
                sessionID: session.sessionID,
                sessionRevision: acceptedNewSession?.snapshot.revision ?? session.revision + 1,
                requestAnchorID: identity.requestAnchorID,
                runID: identity.runID,
                generation: identity.generation,
                turnEpoch: identity.turnEpoch,
                runPhase: RunPresentationPhase.preparing.rawValue,
                runStartedAt: now,
                consumedAttachmentIDs: manifest.attachments.map(\.attachmentID),
                consumedTaggedFiles: submission.content.taggedFiles,
                selectedConfiguration: selected,
                session: receiptSessionSnapshot
            )
            let durableReceipt = try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: JSONEncoder.serviceEncoder.encode(receipt))
            let durableNewSession = acceptedNewSession.map { prepared in
                prepared.replacingSnapshot(durableReceipt.session ?? prepared.snapshot)
            }
            let durablePrepared = try JSONDecoder.serviceDecoder.decode(StoredPreparedIntent.self, from: JSONEncoder.serviceEncoder.encode(preparedIntent))
            let durableCompiled = try JSONDecoder.serviceDecoder.decode(CompiledProviderTurnInput.self, from: compiledJSON)
            let committing = try AgentSubmissionRecord(
                submissionID: prepared.submissionID,
                actorID: prepared.actorID,
                targetKey: prepared.targetKey,
                operation: prepared.operation,
                publicKey: prepared.publicKey,
                requestDigest: prepared.requestDigest,
                state: .preparing,
                sessionID: session.sessionID,
                identity: identity,
                preparedJSON: JSONEncoder.serviceEncoder.encode(preparedIntent),
                compiledInputJSON: compiledJSON,
                createdAt: prepared.createdAt,
                updatedAt: now
            )
            let newSessionEvents = try await store.commitAgentSubmission(record: committing, turn: semanticTurn, nextDefaults: nextDefaults, runPresentation: runPresentation, receipt: durableReceipt, newSession: durableNewSession)
            try? await attachments.finalizeCommittedAcceptance(manifest: manifest, sessionID: session.sessionID, turnID: identity.turnID, now: now)
            return .init(receipt: durableReceipt, canonicalUserTurn: durablePrepared.canonicalUserTurn, providerInput: durableCompiled, providerKind: durablePrepared.providerKind, providerModel: durablePrepared.providerModel, executionPolicy: durablePrepared.executionPolicy, replayed: false, newSessionEvents: newSessionEvents)
        } catch {
            try? await attachments.releasePreparation(submissionID: submissionID, now: now)
            let code = (error as? ServiceAPIError)?.code.rawValue ?? "submission_rejected"
            try? await store.rejectAgentSubmission(submissionID: submissionID, code: code, at: now)
            throw error
        }
    }

    public func markDispatched(submissionID: UUID, at date: Date = Date()) async throws {
        try await store.markSubmissionDispatch(submissionID: submissionID, state: "dispatched", at: date)
    }

    public func markLaunchFailed(submissionID: UUID, message: String, at date: Date = Date()) async throws {
        guard let submission = try await store.agentSubmission(submissionID: submissionID), submission.state == .accepted, let sessionID = submission.sessionID else { return }
        try await store.markSubmissionDispatch(submissionID: submissionID, state: "launch_failed", at: date)
        if let current = try await store.runPresentation(sessionID: sessionID), current.runID == submission.identity.runID {
            try await store.upsertRunPresentation(current.settling(code: "provider_launch_failed", at: date))
        }
        let bounded = String(message.prefix(2048))
        let sequence = try await (store.semanticTurn(runID: submission.identity.runID)?.lastSequence ?? 0) + 1
        try await store.upsertSemanticActivity(.init(activityID: UUID(), sessionID: sessionID, identity: submission.identity, canonicalSequence: sequence, revision: 1, kind: .error, content: bounded, status: "provider_launch_failed", createdAt: date, updatedAt: date))
        try await store.settleSemanticTurn(runID: submission.identity.runID, terminalState: "failed", at: date)
    }

    public func acceptedForRecovery(_ record: AgentSubmissionRecord) throws -> AcceptedAgentSubmission {
        guard record.state == .accepted, record.dispatchState == "pending" else { throw ServiceAPIError(code: .staleRevision, message: "Submission does not require recovery") }
        return try decodeAccepted(record, replayed: false)
    }

    public func recover(now: Date = Date()) async throws -> [AgentSubmissionRecord] {
        let preparing = try await store.agentSubmissions(state: .preparing, dispatchState: nil, limit: 500)
        for submission in preparing {
            try await attachments.releasePreparation(submissionID: submission.submissionID, now: now)
            try await store.rejectAgentSubmission(submissionID: submission.submissionID, code: "service_restart_during_prepare", at: now)
        }
        return try await store.agentSubmissions(state: .accepted, dispatchState: "pending", limit: 500)
    }

    private func decodeAccepted(_ record: AgentSubmissionRecord, replayed: Bool) throws -> AcceptedAgentSubmission {
        guard let receiptJSON = record.receiptJSON,
              let preparedJSON = record.preparedJSON,
              let compiledJSON = record.compiledInputJSON
        else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Accepted submission is incomplete") }
        let receipt = try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: receiptJSON)
        let prepared = try JSONDecoder.serviceDecoder.decode(StoredPreparedIntent.self, from: preparedJSON)
        let compiled = try JSONDecoder.serviceDecoder.decode(CompiledProviderTurnInput.self, from: compiledJSON)
        return .init(receipt: receipt, canonicalUserTurn: prepared.canonicalUserTurn, providerInput: compiled, providerKind: prepared.providerKind, providerModel: prepared.providerModel, executionPolicy: prepared.executionPolicy, replayed: replayed)
    }

    private static func acceptedSessionSnapshot(_ session: SessionSnapshot, canonicalUserTurn: CanonicalUserTurn, actor: ExternalActor, identity: CanonicalTurnIdentity, at date: Date) -> SessionSnapshot {
        let sequence = (session.transcript.last?.sessionSequence ?? 0) + 1
        let human = TranscriptEntry(entryID: identity.turnID, sessionSequence: sequence, kind: .human, content: canonicalUserTurn.text, actor: actor, timestamp: date)
        return session.replacing(
            revision: session.revision + 1,
            transcript: session.transcript + [human]
        )
    }

    private static func acceptedReceiptSessionSnapshot(
        _ session: SessionSnapshot,
        effective: EffectiveTurnConfigurationRecord,
        nextDefaults: SessionNextTurnDefaultsRecord,
        runPresentation: RunPresentationSnapshot
    ) -> SessionSnapshot {
        session.replacing(
            effectiveTurnConfiguration: EffectiveTurnConfigurationWireSnapshot(effective),
            nextTurnDefaults: SessionNextTurnDefaultsWireSnapshot(nextDefaults),
            runPresentation: runPresentation.wireSnapshot
        )
    }

    private static func wireValue(_ value: AgentControlValue) -> ComposerControlValueWire {
        switch value { case let .boolean(v): .boolean(v)
        case let .choice(v): .choice(v)
        case let .choices(v): .choices(v) }
    }
}
