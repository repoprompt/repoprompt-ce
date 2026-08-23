import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO

extension SQLiteServiceStore {
    public func authorityStore_commitRunTransition(
        _ mutation: RunTransitionMutation
    ) async throws -> RunTransitionCommitResult {
        let transition = mutation.transition
        try Self.validateTransitionIdentity(transition)
        return try await transaction(.bulk(estimatedEncodedBytes: 0)) {
            let transactionCursor = try await nextCursor()
            let persistedSession = mutation.session.replacing(cursor: transactionCursor)
            let persistedIdempotencyResponse = try Self.rebasedCommandReceipt(
                mutation.idempotencyResponse,
                cursor: transactionCursor
            )
            if let row = try await transitionRow(
                actorID: transition.actorID,
                operation: transition.operation,
                idempotencyKey: transition.idempotencyKey
            ) {
                let existing = try decodeTransition(row)
                guard existing.requestDigest == transition.requestDigest else {
                    throw ServiceAPIError(
                        code: .idempotencyConflict,
                        message: "Transition idempotency key was reused with different input",
                        retryable: false
                    )
                }
                guard existing.transitionID == transition.transitionID else {
                    return try await runTransitionCommitResult(transition: existing, events: [], replayed: true)
                }
                if existing.state == transition.state || existing.state == .finalized {
                    return try await runTransitionCommitResult(transition: existing, events: [], replayed: true)
                }
                guard Self.mayAdvanceTransition(from: existing.state, to: transition.state) else {
                    throw ServiceAPIError(code: .staleRevision, message: "Transition state is stale")
                }
            }

            if transition.state == .finalized,
               [.cancel, .complete, .fail, .interrupt].contains(transition.kind),
               let winner = try await database.query(
                   "SELECT transition_id FROM authority_transitions WHERE run_id=? AND state='finalized' AND kind IN ('cancel','complete','fail','interrupt') AND transition_id<>? LIMIT 1",
                   [.text(transition.runID.uuidString), .text(transition.transitionID.uuidString)]
               ).first?.column("transition_id")?.string
            {
                throw ServiceAPIError(
                    code: .staleRevision,
                    message: "A terminal transition already won for this run: \(winner)",
                    retryable: false
                )
            }
            if transition.state == .finalized,
               [.complete, .fail].contains(transition.kind),
               let fence = try await database.query(
                   "SELECT transition_id FROM authority_transitions WHERE run_id=? AND kind IN ('cancel','interrupt') AND state IN ('prepared','effectAcknowledged','reconciliationRequired') LIMIT 1",
                   [.text(transition.runID.uuidString)]
               ).first?.column("transition_id")?.string
            {
                throw ServiceAPIError(
                    code: .staleRevision,
                    message: "A committed cancellation fence owns terminal precedence: \(fence)",
                    retryable: false
                )
            }
            if !(transition.kind == .start && transition.state == .prepared) {
                guard let currentRun = try await database.query(
                    "SELECT state,generation,turn_epoch FROM runs WHERE run_id=?",
                    [.text(transition.runID.uuidString)]
                ).first,
                    Int64(currentRun.column("generation")?.integer ?? -1) == transition.expectedGeneration,
                    Int64(currentRun.column("turn_epoch")?.integer ?? -1) == transition.expectedTurnEpoch
                else {
                    throw ServiceAPIError(code: .staleRevision, message: "Transition run identity is stale")
                }
                let currentRunState = currentRun.column("state")?.string ?? ""
                if transition.kind == .start,
                   transition.state == .finalized,
                   !["launchReserved", "reconciliationRequired"].contains(currentRunState)
                {
                    throw ServiceAPIError(code: .staleRevision, message: "Provider launch reservation is no longer current")
                }
                if transition.kind == .cancel,
                   transition.state == .finalized,
                   currentRunState != "cancelRequested"
                {
                    throw ServiceAPIError(code: .staleRevision, message: "Cancellation request no longer owns the run")
                }
                if transition.kind == .interrupt,
                   transition.state == .finalized,
                   !["launchReserved", "running", "waiting", "reconciliationRequired", "cancelRequested"].contains(currentRunState)
                {
                    throw ServiceAPIError(code: .staleRevision, message: "Recovery interruption no longer owns the run")
                }
            }

            guard let currentRevision = try await database.query(
                "SELECT revision FROM sessions WHERE session_id=?",
                [.text(transition.sessionID.uuidString)]
            ).first?.column("revision")?.integer else {
                throw ServiceAPIError(code: .notFound, message: "Transition session does not exist")
            }
            let expectedCurrentRevision = persistedSession.revision - 1
            guard Int64(currentRevision) == expectedCurrentRevision else {
                throw ServiceAPIError(
                    code: .staleRevision,
                    message: "Transition session revision is stale",
                    currentRevision: Int64(currentRevision)
                )
            }
            try await hitFault(.afterAuthorityStateCAS)

            try await persistRunInTransition(mutation.run)
            try await hitFault(.afterAuthorityRunWrite)
            let now = transition.updatedAt.timeIntervalSince1970
            let evidence = transition.sideEffectEvidenceJSON?.base64EncodedString()
            let response = persistedIdempotencyResponse?.base64EncodedString()
            _ = try await database.query(
                "INSERT INTO authority_transitions(transition_id,actor_id,operation,idempotency_key,request_digest,kind,session_id,run_id,expected_session_revision,expected_generation,expected_turn_epoch,state,requested_terminal_state,side_effect_evidence_json,diagnostic_code,response_body,response_status,created_at,updated_at,finalized_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(transition_id) DO UPDATE SET state=excluded.state,side_effect_evidence_json=COALESCE(excluded.side_effect_evidence_json,authority_transitions.side_effect_evidence_json),diagnostic_code=COALESCE(excluded.diagnostic_code,authority_transitions.diagnostic_code),response_body=COALESCE(excluded.response_body,authority_transitions.response_body),response_status=COALESCE(excluded.response_status,authority_transitions.response_status),updated_at=excluded.updated_at,finalized_at=excluded.finalized_at",
                [
                    .text(transition.transitionID.uuidString),
                    .text(transition.actorID),
                    .text(transition.operation),
                    .text(transition.idempotencyKey),
                    .text(transition.requestDigest),
                    .text(transition.kind.rawValue),
                    .text(transition.sessionID.uuidString),
                    .text(transition.runID.uuidString),
                    .integer(Int(transition.expectedSessionRevision)),
                    .integer(Int(transition.expectedGeneration)),
                    .integer(Int(transition.expectedTurnEpoch)),
                    .text(transition.state.rawValue),
                    transition.requestedTerminalState.map(SQLiteData.text) ?? .null,
                    evidence.map(SQLiteData.text) ?? .null,
                    transition.diagnosticCode.map(SQLiteData.text) ?? .null,
                    response.map(SQLiteData.text) ?? .null,
                    persistedIdempotencyResponse == nil ? .null : .integer(202),
                    .float(transition.createdAt.timeIntervalSince1970),
                    .float(now),
                    transition.finalizedAt.map { .float($0.timeIntervalSince1970) } ?? .null,
                ]
            )
            try await hitFault(.afterAuthorityTransitionWrite)

            try await upsertRunPresentationInTransaction(mutation.presentation)
            try await hitFault(.afterAuthorityPresentationWrite)
            let sessionEvent = try await persistSessionInTransaction(
                persistedSession,
                eventType: mutation.sessionEventType,
                actor: mutation.actor,
                correlationID: mutation.sessionCorrelationID,
                idempotency: nil,
                idempotencyResponse: nil,
                initialSelection: nil
            )
            try await hitFault(.afterAuthoritySessionWrite)
            let agentEvent = try await persistAgentInTransaction(
                mutation.agent,
                projectID: persistedSession.projectID,
                actor: mutation.actor,
                correlationID: mutation.agentCorrelationID,
                eventType: mutation.agentEventType
            )
            try await hitFault(.afterAuthorityAgentWrite)
            if let semanticTerminalState = mutation.semanticTerminalState {
                _ = try await database.query(
                    "UPDATE semantic_turns SET terminal_state=COALESCE(terminal_state,?),settled_at=COALESCE(settled_at,?) WHERE run_id=?",
                    [
                        .text(String(semanticTerminalState.prefix(128))),
                        .float(now),
                        .text(transition.runID.uuidString),
                    ]
                )
            }
            if let idempotency = mutation.idempotency, let response = persistedIdempotencyResponse {
                try await saveIdempotency(idempotency, status: 202, response: response)
            }
            if transition.state == .finalized {
                _ = try await database.query(
                    "INSERT INTO idempotency_tombstones(actor_id,operation,idempotency_key,request_digest,terminal_identity,response_expires_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(actor_id,operation,idempotency_key) DO UPDATE SET request_digest=excluded.request_digest,terminal_identity=excluded.terminal_identity,updated_at=excluded.updated_at",
                    [
                        .text(transition.actorID),
                        .text(transition.operation),
                        .text(transition.idempotencyKey),
                        .text(transition.requestDigest),
                        .text(transition.transitionID.uuidString),
                        .float(transition.updatedAt.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970),
                        .float(transition.createdAt.timeIntervalSince1970),
                        .float(now),
                    ]
                )
            }
            return RunTransitionCommitResult(
                transition: transition,
                session: persistedSession,
                agent: mutation.agent,
                run: mutation.run,
                presentation: mutation.presentation,
                events: [sessionEvent, agentEvent],
                replayed: false
            )
        }
    }

    private func runTransitionCommitResult(
        transition: AuthorityTransitionSnapshot,
        events: [EventEnvelope],
        replayed: Bool
    ) async throws -> RunTransitionCommitResult {
        guard let sessionText = try await database.query(
            "SELECT snapshot_json FROM sessions WHERE session_id=?",
            [.text(transition.sessionID.uuidString)]
        ).first?.column("snapshot_json")?.string,
            let agentText = try await database.query(
                "SELECT snapshot_json FROM agents WHERE session_id=?",
                [.text(transition.sessionID.uuidString)]
            ).first?.column("snapshot_json")?.string,
            let runText = try await database.query(
                "SELECT snapshot_json FROM runs WHERE run_id=?",
                [.text(transition.runID.uuidString)]
            ).first?.column("snapshot_json")?.string,
            let presentationText = try await database.query(
                "SELECT snapshot_json FROM run_presentations WHERE session_id=? AND run_id=?",
                [.text(transition.sessionID.uuidString), .text(transition.runID.uuidString)]
            ).first?.column("snapshot_json")?.string
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Committed transition projections are incomplete")
        }
        return try RunTransitionCommitResult(
            transition: transition,
            session: decoder.decode(SessionSnapshot.self, from: Data(sessionText.utf8)),
            agent: decoder.decode(AgentSnapshot.self, from: Data(agentText.utf8)),
            run: decoder.decode(ProviderRunSnapshot.self, from: Data(runText.utf8)),
            presentation: decoder.decode(RunPresentationSnapshot.self, from: Data(presentationText.utf8)),
            events: events,
            replayed: replayed
        )
    }

    public func authorityStore_nonfinalAuthorityTransitions() async throws -> [AuthorityTransitionSnapshot] {
        try await database.query(
            "SELECT * FROM authority_transitions WHERE state<>'finalized' ORDER BY created_at,transition_id"
        ).map(decodeTransition)
    }

    public func authorityStore_applyProviderEvent(_ mutation: ProviderEventMutation) async throws -> ProviderEventCommitResult {
        let identity = mutation.identity
        guard !identity.providerEventID.isEmpty, identity.providerEventID.utf8.count <= 256,
              !identity.payloadDigest.isEmpty, identity.payloadDigest.utf8.count <= 128,
              identity.providerSequence > 0
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider event identity is invalid")
        }
        return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            if let row = try await database.query(
                "SELECT payload_digest,generation,turn_epoch,connection_generation,provider_sequence,event_kind FROM provider_event_receipts WHERE run_id=? AND connection_generation=? AND provider_event_id=?",
                [.text(identity.runID.uuidString), .integer(Int(identity.connectionGeneration)), .text(identity.providerEventID)]
            ).first {
                guard row.column("payload_digest")?.string == identity.payloadDigest,
                      Int64(row.column("generation")?.integer ?? -1) == identity.generation,
                      Int64(row.column("turn_epoch")?.integer ?? -1) == identity.turnEpoch,
                      Int64(row.column("connection_generation")?.integer ?? -1) == identity.connectionGeneration,
                      Int64(row.column("provider_sequence")?.integer ?? -1) == identity.providerSequence,
                      row.column("event_kind")?.string == identity.eventKind
                else {
                    throw ServiceAPIError(code: .idempotencyConflict, message: "Provider event identity was reused with different input", retryable: false)
                }
                return ProviderEventCommitResult(applied: false, events: [], session: nil)
            }
            guard let run = try await database.query(
                "SELECT generation,turn_epoch,state FROM runs WHERE run_id=?",
                [.text(identity.runID.uuidString)]
            ).first,
                Int64(run.column("generation")?.integer ?? -1) == identity.generation,
                Int64(run.column("turn_epoch")?.integer ?? -1) == identity.turnEpoch
            else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider event run identity is stale")
            }
            let lastSequence = Int64(try await database.query(
                "SELECT COALESCE(MAX(provider_sequence),0) AS value FROM provider_event_receipts WHERE run_id=? AND connection_generation=?",
                [.text(identity.runID.uuidString), .integer(Int(identity.connectionGeneration))]
            ).first?.column("value")?.integer ?? 0)
            guard identity.providerSequence == lastSequence + 1 else {
                throw ServiceAPIError(
                    code: identity.providerSequence <= lastSequence ? .staleRevision : .dependencyUnavailable,
                    message: identity.providerSequence <= lastSequence ? "Provider event sequence is stale" : "Provider event sequence has a gap",
                    retryable: identity.providerSequence > lastSequence
                )
            }
            _ = try await database.query(
                "INSERT INTO provider_event_receipts(run_id,provider_event_id,payload_digest,generation,turn_epoch,connection_generation,provider_sequence,event_kind,processed_at) VALUES(?,?,?,?,?,?,?,?,?)",
                [
                    .text(identity.runID.uuidString),
                    .text(identity.providerEventID),
                    .text(identity.payloadDigest),
                    .integer(Int(identity.generation)),
                    .integer(Int(identity.turnEpoch)),
                    .integer(Int(identity.connectionGeneration)),
                    .integer(Int(identity.providerSequence)),
                    .text(String(identity.eventKind.prefix(128))),
                    .float(Date().timeIntervalSince1970),
                ]
            )
            try await hitFault(.afterProviderEventReceiptInsert)
            var events: [EventEnvelope] = []
            if let run = mutation.run { try await persistRunInTransition(run); try await hitFault(.afterProviderRunWrite) }
            if let presentation = mutation.presentation { try await upsertRunPresentationInTransaction(presentation); try await hitFault(.afterProviderPresentationWrite) }
            for activity in mutation.semanticActivities { try await authorityStore_upsertSemanticActivity(activity) }
            for tool in mutation.semanticTools { try await authorityStore_upsertSemanticTool(tool) }
            if !mutation.semanticActivities.isEmpty || !mutation.semanticTools.isEmpty { try await hitFault(.afterProviderSemanticWrite) }
            if let value = mutation.agentEvent {
                events.append(try await persistAgentInTransaction(value.snapshot, projectID: value.projectID, actor: nil, correlationID: value.correlationID, eventType: value.eventType))
                try await hitFault(.afterProviderAgentWrite)
            }
            var persistedSession: SessionSnapshot?
            if let value = mutation.sessionEvent {
                let event = try await persistSessionInTransaction(value.snapshot, eventType: value.eventType, actor: nil, correlationID: value.correlationID, idempotency: nil, idempotencyResponse: nil, initialSelection: nil)
                persistedSession = try await session(id: value.snapshot.sessionID)
                events.append(event)
                try await hitFault(.afterProviderSessionWrite)
            }
            if let value = mutation.toolEvent {
                events.append(try await appendEvent(projectID: value.session.projectID, sessionID: value.session.sessionID, agentID: value.session.sessionID, parentAgentID: value.session.parentSessionID, rootSessionID: value.session.rootSessionID, runID: identity.runID, sessionSequence: nil, type: value.eventType, generation: value.session.runGeneration, turnEpoch: value.session.turnEpoch, actor: nil, correlationID: value.correlationID, payload: encoder.encode(value.snapshot)))
                try await hitFault(.afterProviderToolWrite)
            }
            if let value = mutation.interactionEvent {
                _ = try await database.query(
                    "INSERT INTO interactions(interaction_id,session_id,run_id,agent_id,schema_version,kind,state,payload_json,created_at,expires_at,settled_at,settled_actor_json,revision) VALUES(?,?,?,?,1,?,?,?,CURRENT_TIMESTAMP,?,?,NULL,?) ON CONFLICT(interaction_id) DO UPDATE SET state=excluded.state,payload_json=excluded.payload_json,settled_at=excluded.settled_at,revision=excluded.revision",
                    [.text(value.snapshot.interactionID.uuidString), .text(value.session.sessionID.uuidString), value.snapshot.runID.map { .text($0.uuidString) } ?? .null, value.snapshot.agentID.map { .text($0.uuidString) } ?? .null, .text(value.snapshot.kind.rawValue), .text(value.snapshot.state.rawValue), .text(value.snapshot.payload.base64EncodedString()), value.snapshot.expiresAt.map { .float($0.timeIntervalSince1970) } ?? .null, value.snapshot.state == .resolved ? .float(Date().timeIntervalSince1970) : .null, .integer(Int(value.snapshot.revision))]
                )
                events.append(try await appendEvent(projectID: value.session.projectID, sessionID: value.session.sessionID, rootSessionID: value.session.rootSessionID, runID: identity.runID, sessionSequence: nil, type: value.snapshot.state == .resolved ? .interactionResolved : .interactionRequested, generation: value.session.runGeneration, turnEpoch: value.session.turnEpoch, actor: nil, correlationID: value.correlationID, payload: encoder.encode(value.snapshot)))
                try await hitFault(.afterProviderInteractionWrite)
            }
            if let usage = mutation.contextUsage, let sessionID = mutation.contextUsageSessionID {
                if let base = try await session(id: sessionID) {
                    let next = base.replacing(contextUsage: usage.merging(onto: base.contextUsage))
                    _ = try await database.query("UPDATE sessions SET snapshot_json=?,updated_at=CURRENT_TIMESTAMP WHERE session_id=?", [.text(try encodeText(next)), .text(sessionID.uuidString)])
                }
                persistedSession = try await session(id: sessionID)
                try await hitFault(.afterProviderContextUsageWrite)
            }
            let first = events.first?.globalSequence
            let last = events.last?.globalSequence
            _ = try await database.query(
                "UPDATE provider_event_receipts SET first_global_sequence=?,last_global_sequence=? WHERE run_id=? AND connection_generation=? AND provider_event_id=?",
                [first.map { .integer(Int($0)) } ?? .null, last.map { .integer(Int($0)) } ?? .null, .text(identity.runID.uuidString), .integer(Int(identity.connectionGeneration)), .text(identity.providerEventID)]
            )
            return ProviderEventCommitResult(applied: true, events: events, session: persistedSession)
        }
    }

    private func persistRunInTransition(_ snapshot: ProviderRunSnapshot) async throws {
        _ = try await database.query(
            "INSERT INTO runs(run_id,session_id,schema_version,provider_kind,provider_session_id,state,generation,turn_epoch,start_reason,end_reason,started_at,ended_at) VALUES(?,?,1,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET provider_session_id=excluded.provider_session_id,state=excluded.state,turn_epoch=excluded.turn_epoch,end_reason=excluded.end_reason,ended_at=excluded.ended_at",
            [
                .text(snapshot.runID.uuidString),
                .text(snapshot.sessionID.uuidString),
                .text(snapshot.provider.rawValue),
                snapshot.providerSessionID.map(SQLiteData.text) ?? .null,
                .text(snapshot.state),
                .integer(Int(snapshot.generation)),
                .integer(Int(snapshot.turnEpoch)),
                .text(snapshot.startReason),
                snapshot.endReason.map(SQLiteData.text) ?? .null,
                .float(snapshot.startedAt.timeIntervalSince1970),
                snapshot.endedAt.map { .float($0.timeIntervalSince1970) } ?? .null,
            ]
        )
    }

    private func transitionRow(actorID: String, operation: String, idempotencyKey: String) async throws -> SQLiteRow? {
        try await database.query(
            "SELECT * FROM authority_transitions WHERE actor_id=? AND operation=? AND idempotency_key=?",
            [.text(actorID), .text(operation), .text(idempotencyKey)]
        ).first
    }

    private func decodeTransition(_ row: SQLiteRow) throws -> AuthorityTransitionSnapshot {
        guard let transitionID = UUID(uuidString: row.column("transition_id")?.string ?? ""),
              let kind = AuthorityTransitionKind(rawValue: row.column("kind")?.string ?? ""),
              let sessionID = UUID(uuidString: row.column("session_id")?.string ?? ""),
              let runID = UUID(uuidString: row.column("run_id")?.string ?? ""),
              let state = AuthorityTransitionState(rawValue: row.column("state")?.string ?? ""),
              let actorID = row.column("actor_id")?.string,
              let operation = row.column("operation")?.string,
              let idempotencyKey = row.column("idempotency_key")?.string,
              let requestDigest = row.column("request_digest")?.string
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted authority transition is invalid", retryable: false)
        }
        return AuthorityTransitionSnapshot(
            transitionID: transitionID,
            actorID: actorID,
            operation: operation,
            idempotencyKey: idempotencyKey,
            requestDigest: requestDigest,
            kind: kind,
            sessionID: sessionID,
            runID: runID,
            expectedSessionRevision: Int64(row.column("expected_session_revision")?.integer ?? 0),
            expectedGeneration: Int64(row.column("expected_generation")?.integer ?? 0),
            expectedTurnEpoch: Int64(row.column("expected_turn_epoch")?.integer ?? 0),
            state: state,
            requestedTerminalState: row.column("requested_terminal_state")?.string,
            sideEffectEvidenceJSON: row.column("side_effect_evidence_json")?.string.flatMap { Data(base64Encoded: $0) },
            diagnosticCode: row.column("diagnostic_code")?.string,
            createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0),
            finalizedAt: row.column("finalized_at")?.double.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func validateTransitionIdentity(_ transition: AuthorityTransitionSnapshot) throws {
        let idempotencyIdentity = transitionIdempotencyIdentity(transition)
        guard !transition.actorID.isEmpty, transition.actorID.utf8.count <= 256,
              !transition.operation.isEmpty, transition.operation.utf8.count <= 128,
              !idempotencyIdentity.isEmpty, idempotencyIdentity.utf8.count <= 256,
              !transition.requestDigest.isEmpty, transition.requestDigest.utf8.count <= 128
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Transition idempotency identity is invalid")
        }
    }

    private static func transitionIdempotencyIdentity(_ transition: AuthorityTransitionSnapshot) -> String {
        transition.idempotencyKey
    }

    private static func mayAdvanceTransition(
        from: AuthorityTransitionState,
        to: AuthorityTransitionState
    ) -> Bool {
        switch (from, to) {
        case (.prepared, .effectAcknowledged),
             (.prepared, .finalized),
             (.prepared, .reconciliationRequired),
             (.effectAcknowledged, .finalized),
             (.effectAcknowledged, .reconciliationRequired),
             (.reconciliationRequired, .finalized):
            true
        default:
            false
        }
    }

    private static func rebasedCommandReceipt(
        _ response: Data?,
        cursor: ServiceCursor
    ) throws -> Data? {
        guard let response else { return nil }
        guard let receipt = try? JSONDecoder.serviceDecoder.decode(CommandReceipt.self, from: response) else {
            return response
        }
        return try JSONEncoder.serviceEncoder.encode(CommandReceipt(
            commandID: receipt.commandID,
            sessionID: receipt.sessionID,
            operation: receipt.operation,
            acceptedCursor: cursor,
            status: receipt.status
        ))
    }
}
