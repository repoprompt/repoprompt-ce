import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

public extension SQLiteServiceStore {
    func authorityStore_prepareAgentSubmission(_ record: AgentSubmissionRecord) async throws -> AgentSubmissionRecord {
        let retainedBytes = try retainedInputBytes(record)
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            if let existing = try await agentSubmission(actorID: record.actorID, targetKey: record.targetKey, operation: record.operation, publicKey: record.publicKey) {
                guard existing.requestDigest == record.requestDigest else {
                    throw ServiceAPIError(code: .idempotencyConflict, message: "Submission key was reused with different content")
                }
                return existing
            }
            _ = try await database.query(
                "INSERT INTO agent_submissions(submission_id,actor_id,target_key,operation,public_key,request_digest,state,session_id,request_anchor_id,run_id,generation,turn_epoch,turn_id,response_span_id,prepared_json,compiled_input_json,receipt_json,rejection_code,dispatch_state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                submissionBindings(record)
            )
            return record
        }
    }

    func authorityStore_agentSubmission(actorID: String, targetKey: String, operation: String, publicKey: String) async throws -> AgentSubmissionRecord? {
        guard let row = try await database.query("SELECT * FROM agent_submissions WHERE actor_id=? AND target_key=? AND operation=? AND public_key=?", [.text(actorID), .text(targetKey), .text(operation), .text(publicKey)]).first else { return nil }
        return try decodeSubmission(row)
    }

    func authorityStore_agentSubmission(submissionID: UUID) async throws -> AgentSubmissionRecord? {
        guard let row = try await database.query("SELECT * FROM agent_submissions WHERE submission_id=?", [.text(submissionID.uuidString)]).first else { return nil }
        return try decodeSubmission(row)
    }

    func authorityStore_agentSubmissions(state: AgentSubmissionState? = nil, dispatchState: String? = nil, limit: Int = 500) async throws -> [AgentSubmissionRecord] {
        let bounded = max(1, min(limit, 1_000))
        let rows: [SQLiteRow]
        switch (state, dispatchState) {
        case let (.some(state), .some(dispatchState)):
            rows = try await database.query("SELECT * FROM agent_submissions WHERE state=? AND dispatch_state=? ORDER BY created_at LIMIT ?", [.text(state.rawValue), .text(dispatchState), .integer(bounded)])
        case let (.some(state), nil):
            rows = try await database.query("SELECT * FROM agent_submissions WHERE state=? ORDER BY created_at LIMIT ?", [.text(state.rawValue), .integer(bounded)])
        case let (nil, .some(dispatchState)):
            rows = try await database.query("SELECT * FROM agent_submissions WHERE dispatch_state=? ORDER BY created_at LIMIT ?", [.text(dispatchState), .integer(bounded)])
        case (nil, nil):
            rows = try await database.query("SELECT * FROM agent_submissions ORDER BY created_at LIMIT ?", [.integer(bounded)])
        }
        return try rows.map { try decodeSubmission($0) }
    }

    func authorityStore_rejectAgentSubmission(submissionID: UUID, code: String, at date: Date) async throws {
        _ = try await database.query("UPDATE agent_submissions SET state='rejected',rejection_code=?,updated_at=? WHERE submission_id=? AND state='preparing'", [.text(code), .float(date.timeIntervalSince1970), .text(submissionID.uuidString)])
    }

    func authorityStore_markSubmissionDispatch(submissionID: UUID, state: String, at date: Date) async throws {
        _ = try await database.query("UPDATE agent_submissions SET dispatch_state=?,updated_at=? WHERE submission_id=? AND state='accepted'", [.text(state), .float(date.timeIntervalSince1970), .text(submissionID.uuidString)])
    }

    func authorityStore_commitAgentSubmission(
        record: AgentSubmissionRecord,
        turn: SemanticTurnRecord,
        nextDefaults: SessionNextTurnDefaultsRecord,
        runPresentation: RunPresentationSnapshot,
        receipt: SubmissionReceipt,
        newSession: PreparedNewAgentSession? = nil
    ) async throws -> NewAgentSessionAcceptanceEvents? {
        var additionalBytes = try checkedRetainedByteSum(
            retainedEncodedBytes(turn),
            retainedEncodedBytes(nextDefaults),
            retainedEncodedBytes(runPresentation),
            retainedEncodedBytes(receipt)
        )
        let retainedBytes: Int
        if let newSession {
            additionalBytes = try checkedRetainedByteSum(
                additionalBytes,
                retainedEncodedBytes(record),
                retainedEncodedBytes(newSession.agent),
                retainedEncodedBytes(newSession.expectedProjectRootIDs),
                retainedEncodedBytes(newSession.initialSelection),
                retainedEncodedBytes(newSession.initialPermissions),
                retainedEncodedBytes(newSession.initialCollaboration),
                retainedEncodedBytes(newSession.initialWorktrees)
            )
            retainedBytes = try sessionRetainedBytes(newSession.snapshot, additional: additionalBytes)
        } else {
            retainedBytes = try retainedInputBytes(record, additional: additionalBytes)
        }
        return try await transaction(.bulk(estimatedEncodedBytes: retainedBytes)) {
            guard let current = try await agentSubmission(submissionID: record.submissionID), current.state == .preparing else {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Submission is not preparing")
            }
            let newSessionEvents: NewAgentSessionAcceptanceEvents?
            if let newSession {
                guard newSession.snapshot.sessionID == turn.sessionID,
                      newSession.snapshot.sessionID == receipt.sessionID,
                      receipt.session == newSession.snapshot,
                      newSession.snapshot.parentSessionID == nil
                else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Prepared session does not match accepted turn identity") }
                guard let project = try await project(id: newSession.snapshot.projectID),
                      project.revision == newSession.expectedProjectRevision,
                      project.roots.map(\.rootID) == newSession.expectedProjectRootIDs
                else { throw ServiceAPIError(code: .staleRevision, message: "Project repositories changed during session preparation") }
                let events = try await persistNewSessionInTransaction(
                    newSession.snapshot,
                    agent: newSession.agent,
                    actor: newSession.snapshot.creator,
                    correlationID: newSession.sessionCorrelationID,
                    agentCorrelationID: newSession.agentCorrelationID,
                    idempotency: nil,
                    initialSelection: newSession.initialSelection,
                    initialPermissions: newSession.initialPermissions,
                    initialCollaboration: newSession.initialCollaboration,
                    initialWorktrees: newSession.initialWorktrees
                )
                newSessionEvents = .init(session: events.session, agent: events.agent, worktrees: events.worktrees)
            } else {
                newSessionEvents = nil
            }
            let configurationJSON = try encodedText(turn.effectiveConfiguration)
            _ = try await database.query("INSERT INTO effective_turn_configurations(turn_id,session_id,request_anchor_id,schema_version,configuration_json,accepted_at) VALUES(?,?,?,?,?,?)", [.text(turn.identity.turnID.uuidString), .text(turn.sessionID.uuidString), .text(turn.identity.requestAnchorID.uuidString), .integer(turn.effectiveConfiguration.schemaVersion), .text(configurationJSON), .float(turn.acceptedAt.timeIntervalSince1970)])
            _ = try await database.query("INSERT INTO session_next_turn_defaults(session_id,schema_version,revision,configuration_json,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET schema_version=excluded.schema_version,revision=excluded.revision,configuration_json=excluded.configuration_json,updated_at=excluded.updated_at", [.text(nextDefaults.sessionID.uuidString), .integer(nextDefaults.schemaVersion), .integer(Int(nextDefaults.revision)), .text(try encodedText(nextDefaults.configuration)), .float(nextDefaults.updatedAt.timeIntervalSince1970)])
            try await upsertSemanticTurnInTransaction(turn)
            try await upsertRunPresentationInTransaction(runPresentation)
            let manifestAttachments = try decoder.decode([ComposerAttachmentWire].self, from: turn.attachmentManifestJSON)
            let leasedRows = try await database.query("SELECT attachment_id,byte_size FROM composer_attachments WHERE lease_submission_id=? AND lifecycle='staged'", [.text(record.submissionID.uuidString)])
            let leasedIDs = Set(leasedRows.compactMap { $0.column("attachment_id")?.string.flatMap(UUID.init(uuidString:)) })
            guard leasedIDs == Set(manifestAttachments.map(\.attachmentID)) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Prepared attachment claim set does not match the semantic turn")
            }
            let totalAttachmentBytes = leasedRows.reduce(0) { $0 + ($1.column("byte_size")?.integer ?? 0) }
            _ = try await database.query("UPDATE composer_attachments SET lifecycle='accepted',expires_at=NULL,lease_submission_id=NULL,updated_at=? WHERE lease_submission_id=? AND lifecycle='staged'", [.float(receipt.acceptedAt.timeIntervalSince1970), .text(record.submissionID.uuidString)])
            _ = try await database.query("INSERT INTO accepted_attachment_manifests(turn_id,session_id,schema_version,manifest_json,total_bytes,created_at) VALUES(?,?,1,?,?,?)", [.text(turn.identity.turnID.uuidString), .text(turn.sessionID.uuidString), .text(String(decoding: turn.attachmentManifestJSON, as: UTF8.self)), .integer(totalAttachmentBytes), .float(receipt.acceptedAt.timeIntervalSince1970)])
            let receiptJSON = try encoder.encode(receipt)
            _ = try await database.query("UPDATE agent_submissions SET state='accepted',session_id=?,prepared_json=?,compiled_input_json=?,receipt_json=?,updated_at=? WHERE submission_id=? AND state='preparing'", [.text(turn.sessionID.uuidString), record.preparedJSON.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null, record.compiledInputJSON.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null, .text(String(decoding: receiptJSON, as: UTF8.self)), .float(receipt.acceptedAt.timeIntervalSince1970), .text(record.submissionID.uuidString)])
            return newSessionEvents
        }
    }

    func effectiveTurnConfiguration(turnID: UUID) async throws -> EffectiveTurnConfigurationRecord? {
        guard let text = try await database.query("SELECT configuration_json FROM effective_turn_configurations WHERE turn_id=?", [.text(turnID.uuidString)]).first?.column("configuration_json")?.string else { return nil }
        return try decoder.decode(EffectiveTurnConfigurationRecord.self, from: Data(text.utf8))
    }

    func authorityStore_nextTurnDefaults(sessionID: UUID) async throws -> SessionNextTurnDefaultsRecord? {
        guard let row = try await database.query("SELECT schema_version,revision,configuration_json,updated_at FROM session_next_turn_defaults WHERE session_id=?", [.text(sessionID.uuidString)]).first,
              let text = row.column("configuration_json")?.string
        else { return nil }
        return try SessionNextTurnDefaultsRecord(schemaVersion: row.column("schema_version")?.integer ?? 1, sessionID: sessionID, revision: Int64(row.column("revision")?.integer ?? 0), configuration: decoder.decode(EffectiveTurnConfigurationRecord.self, from: Data(text.utf8)), updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }

    func authorityStore_upsertRunPresentation(_ snapshot: RunPresentationSnapshot) async throws {
        let retainedBytes = try retainedInputBytes(snapshot)
        try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) { try await upsertRunPresentationInTransaction(snapshot) }
    }

    func authorityStore_runPresentation(sessionID: UUID) async throws -> RunPresentationSnapshot? {
        guard let text = try await database.query("SELECT snapshot_json FROM run_presentations WHERE session_id=? ORDER BY generation DESC LIMIT 1", [.text(sessionID.uuidString)]).first?.column("snapshot_json")?.string else { return nil }
        return try decoder.decode(RunPresentationSnapshot.self, from: Data(text.utf8))
    }

    func upsertSemanticTurn(_ record: SemanticTurnRecord) async throws {
        let retainedBytes = try retainedInputBytes(record)
        try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) { try await upsertSemanticTurnInTransaction(record) }
    }

    func authorityStore_semanticTurn(runID: UUID) async throws -> SemanticTurnRecord? {
        guard let row = try await database.query("SELECT * FROM semantic_turns WHERE run_id=? ORDER BY accepted_at DESC LIMIT 1", [.text(runID.uuidString)]).first else { return nil }
        return try decodeSemanticTurn(row)
    }

    func authorityStore_settleSemanticTurn(runID: UUID, terminalState: String, at date: Date) async throws {
        _ = try await database.query("UPDATE semantic_turns SET terminal_state=COALESCE(terminal_state,?),settled_at=COALESCE(settled_at,?) WHERE run_id=?", [.text(String(terminalState.prefix(128))), .float(date.timeIntervalSince1970), .text(runID.uuidString)])
    }

    func authorityStore_latestSemanticSequence(sessionID: UUID) async throws -> Int64 {
        Int64(try await database.query("SELECT MAX(last_sequence) AS sequence FROM semantic_turns WHERE session_id=?", [.text(sessionID.uuidString)]).first?.column("sequence")?.integer ?? 0)
    }

    func authorityStore_semanticTurns(sessionID: UUID, beforeSequence: Int64? = nil, limit: Int = 50) async throws -> [SemanticTurnRecord] {
        let bounded = max(1, min(limit, 100))
        let rows = if let beforeSequence {
            try await database.query("SELECT * FROM semantic_turns WHERE session_id=? AND first_sequence<? ORDER BY first_sequence DESC LIMIT ?", [.text(sessionID.uuidString), .integer(Int(beforeSequence)), .integer(bounded)])
        } else {
            try await database.query("SELECT * FROM semantic_turns WHERE session_id=? ORDER BY first_sequence DESC LIMIT ?", [.text(sessionID.uuidString), .integer(bounded)])
        }
        return try rows.map(decodeSemanticTurn)
    }

    func authorityStore_upsertSemanticActivity(_ record: SemanticActivityRecord) async throws {
        let content = record.content.map { String($0.prefix(262_144)) }
        let summary = record.summary.map { String($0.prefix(16_384)) }
        let anchor = try record.interactionAnchor.map(encodedText)
        _ = try await database.query("INSERT INTO semantic_activities(activity_id,turn_id,session_id,request_anchor_id,run_id,generation,turn_epoch,response_span_id,canonical_sequence,revision,kind,content,summary,status,interaction_anchor_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(activity_id) DO UPDATE SET canonical_sequence=CASE WHEN excluded.revision>=revision THEN excluded.canonical_sequence ELSE canonical_sequence END,revision=MAX(revision,excluded.revision),kind=CASE WHEN excluded.revision>=revision THEN excluded.kind ELSE kind END,content=CASE WHEN excluded.revision>=revision THEN excluded.content ELSE content END,summary=CASE WHEN excluded.revision>=revision THEN excluded.summary ELSE summary END,status=CASE WHEN excluded.revision>=revision THEN excluded.status ELSE status END,interaction_anchor_json=CASE WHEN excluded.revision>=revision THEN excluded.interaction_anchor_json ELSE interaction_anchor_json END,updated_at=MAX(updated_at,excluded.updated_at)", [.text(record.activityID.uuidString), .text(record.identity.turnID.uuidString), .text(record.sessionID.uuidString), .text(record.identity.requestAnchorID.uuidString), .text(record.identity.runID.uuidString), .integer(Int(record.identity.generation)), .integer(Int(record.identity.turnEpoch)), .text(record.identity.responseSpanID.uuidString), .integer(Int(record.canonicalSequence)), .integer(Int(record.revision)), .text(record.kind.rawValue), content.map(SQLiteData.text) ?? .null, summary.map(SQLiteData.text) ?? .null, record.status.map(SQLiteData.text) ?? .null, anchor.map(SQLiteData.text) ?? .null, .float(record.createdAt.timeIntervalSince1970), .float(record.updatedAt.timeIntervalSince1970)])
        _ = try await database.query("UPDATE semantic_turns SET last_sequence=MAX(last_sequence,?) WHERE turn_id=?", [.integer(Int(record.canonicalSequence)), .text(record.identity.turnID.uuidString)])
        try await advanceSemanticWatermark(sessionID: record.sessionID, semanticSequence: record.canonicalSequence, legacySequence: record.canonicalSequence, gapDetected: false, at: record.updatedAt)
    }

    func authorityStore_semanticActivity(activityID: UUID) async throws -> SemanticActivityRecord? {
        guard let row = try await database.query("SELECT * FROM semantic_activities WHERE activity_id=?", [.text(activityID.uuidString)]).first else { return nil }
        return try decodeSemanticActivity(row)
    }

    func authorityStore_semanticActivities(turnID: UUID) async throws -> [SemanticActivityRecord] {
        try await database.query("SELECT * FROM semantic_activities WHERE turn_id=? ORDER BY canonical_sequence,activity_id", [.text(turnID.uuidString)]).map { try decodeSemanticActivity($0) }
    }

    func authorityStore_upsertSemanticTool(_ record: SemanticToolRecord) async throws {
        let terminal = [AgentPresentationToolStatus.success, .warning, .failed, .cancelled]
        if let current = try await semanticTool(executionID: record.executionID), current.revision > record.revision || (terminal.contains(current.status) && !terminal.contains(record.status)) { return }
        _ = try await database.query("INSERT INTO semantic_tools(execution_id,activity_id,turn_id,session_id,canonical_sequence,revision,normalized_name,status,display_arguments,display_result,summary,key_paths_json,process_id,exit_code,error_code,argument_digest,result_digest,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(execution_id) DO UPDATE SET activity_id=excluded.activity_id,canonical_sequence=excluded.canonical_sequence,revision=excluded.revision,normalized_name=excluded.normalized_name,status=excluded.status,display_arguments=excluded.display_arguments,display_result=excluded.display_result,summary=excluded.summary,key_paths_json=excluded.key_paths_json,process_id=excluded.process_id,exit_code=excluded.exit_code,error_code=excluded.error_code,argument_digest=excluded.argument_digest,result_digest=excluded.result_digest,updated_at=excluded.updated_at", [.text(record.executionID), .text(record.activityID.uuidString), .text(record.turnID.uuidString), .text(record.sessionID.uuidString), .integer(Int(record.canonicalSequence)), .integer(Int(record.revision)), .text(record.normalizedName), .text(record.status.rawValue), record.displayArguments.map { .text(String($0.prefix(32_768))) } ?? .null, record.displayResult.map { .text(String($0.prefix(65_536))) } ?? .null, record.summary.map { .text(String($0.prefix(16_384))) } ?? .null, .text(try encodedText(record.keyPaths)), record.processID.map(SQLiteData.integer) ?? .null, record.exitCode.map(SQLiteData.integer) ?? .null, record.errorCode.map(SQLiteData.text) ?? .null, record.argumentDigest.map(SQLiteData.text) ?? .null, record.resultDigest.map(SQLiteData.text) ?? .null, .float(record.createdAt.timeIntervalSince1970), .float(record.updatedAt.timeIntervalSince1970)])
    }

    func authorityStore_semanticTools(turnID: UUID) async throws -> [SemanticToolRecord] {
        try await database.query("SELECT * FROM semantic_tools WHERE turn_id=? ORDER BY canonical_sequence,execution_id", [.text(turnID.uuidString)]).map(decodeSemanticTool)
    }

    func authorityStore_semanticWatermark(sessionID: UUID) async throws -> SemanticIngestionWatermark? {
        guard let row = try await database.query("SELECT * FROM semantic_ingestion_watermarks WHERE session_id=?", [.text(sessionID.uuidString)]).first else { return nil }
        return SemanticIngestionWatermark(sessionID: sessionID, lastLegacySequence: Int64(row.column("last_legacy_sequence")?.integer ?? 0), lastSemanticSequence: Int64(row.column("last_semantic_sequence")?.integer ?? 0), presentationRevision: Int64(row.column("presentation_revision")?.integer ?? 0), gapDetected: row.column("gap_detected")?.bool ?? false, updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }

    func authorityStore_advanceSemanticWatermark(sessionID: UUID, semanticSequence: Int64, legacySequence: Int64, gapDetected: Bool, at date: Date) async throws {
        _ = try await database.query("INSERT INTO semantic_ingestion_watermarks(session_id,last_legacy_sequence,last_semantic_sequence,presentation_revision,gap_detected,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET last_legacy_sequence=MAX(last_legacy_sequence,excluded.last_legacy_sequence),last_semantic_sequence=MAX(last_semantic_sequence,excluded.last_semantic_sequence),presentation_revision=presentation_revision+1,gap_detected=gap_detected OR excluded.gap_detected,updated_at=excluded.updated_at", [.text(sessionID.uuidString), .integer(Int(legacySequence)), .integer(Int(semanticSequence)), .integer(1), .integer(gapDetected ? 1 : 0), .float(date.timeIntervalSince1970)])
    }

    func upsertRunPresentationInTransaction(_ snapshot: RunPresentationSnapshot) async throws {
        _ = try await database.query("INSERT INTO run_presentations(run_id,session_id,schema_version,generation,turn_epoch,phase,phase_revision,status_code,status_text,run_started_at,prior_active_phase,terminal_code,terminal_at,snapshot_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET turn_epoch=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.turn_epoch ELSE turn_epoch END,phase=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.phase ELSE phase END,phase_revision=MAX(phase_revision,excluded.phase_revision),status_code=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.status_code ELSE status_code END,status_text=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.status_text ELSE status_text END,prior_active_phase=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.prior_active_phase ELSE prior_active_phase END,terminal_code=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.terminal_code ELSE terminal_code END,terminal_at=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.terminal_at ELSE terminal_at END,snapshot_json=CASE WHEN excluded.phase_revision>=phase_revision THEN excluded.snapshot_json ELSE snapshot_json END", [.text(snapshot.runID.uuidString), .text(snapshot.sessionID.uuidString), .integer(snapshot.schemaVersion), .integer(Int(snapshot.generation)), .integer(Int(snapshot.turnEpoch)), snapshot.phase.map { .text($0.rawValue) } ?? .null, .integer(Int(snapshot.phaseRevision)), snapshot.runningStatusCode.map(SQLiteData.text) ?? .null, snapshot.runningStatusText.map { .text(String($0.prefix(512))) } ?? .null, .float(snapshot.runStartedAt.timeIntervalSince1970), snapshot.priorActivePhase.map { .text($0.rawValue) } ?? .null, snapshot.terminalSettlementCode.map(SQLiteData.text) ?? .null, snapshot.terminalSettledAt.map { .float($0.timeIntervalSince1970) } ?? .null, .text(try encodedText(snapshot))])
    }

    private func upsertSemanticTurnInTransaction(_ record: SemanticTurnRecord) async throws {
        _ = try await database.query("INSERT INTO semantic_turns(turn_id,session_id,request_anchor_id,run_id,generation,turn_epoch,response_span_id,provider_turn_id,first_sequence,last_sequence,terminal_state,canonical_user_turn_json,effective_configuration_json,attachment_manifest_json,tagged_files_json,created_at,accepted_at,settled_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(turn_id) DO UPDATE SET provider_turn_id=COALESCE(excluded.provider_turn_id,provider_turn_id),last_sequence=MAX(last_sequence,excluded.last_sequence),terminal_state=COALESCE(excluded.terminal_state,terminal_state),settled_at=COALESCE(excluded.settled_at,settled_at)", [.text(record.identity.turnID.uuidString), .text(record.sessionID.uuidString), .text(record.identity.requestAnchorID.uuidString), .text(record.identity.runID.uuidString), .integer(Int(record.identity.generation)), .integer(Int(record.identity.turnEpoch)), .text(record.identity.responseSpanID.uuidString), record.providerTurnID.map(SQLiteData.text) ?? .null, .integer(Int(record.firstSequence)), .integer(Int(record.lastSequence)), record.terminalState.map(SQLiteData.text) ?? .null, .text(String(decoding: record.canonicalUserTurnJSON, as: UTF8.self)), .text(try encodedText(record.effectiveConfiguration)), .text(String(decoding: record.attachmentManifestJSON, as: UTF8.self)), .text(try encodedText(record.taggedFiles)), .float(record.createdAt.timeIntervalSince1970), .float(record.acceptedAt.timeIntervalSince1970), record.settledAt.map { .float($0.timeIntervalSince1970) } ?? .null])
        try await advanceSemanticWatermark(sessionID: record.sessionID, semanticSequence: record.lastSequence, legacySequence: record.lastSequence, gapDetected: false, at: record.acceptedAt)
    }

    private func semanticTool(executionID: String) async throws -> SemanticToolRecord? {
        guard let row = try await database.query("SELECT * FROM semantic_tools WHERE execution_id=?", [.text(executionID)]).first else { return nil }
        return try decodeSemanticTool(row)
    }

    private func encodedText<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func submissionBindings(_ value: AgentSubmissionRecord) -> [SQLiteData] {
        [.text(value.submissionID.uuidString), .text(value.actorID), .text(value.targetKey), .text(value.operation), .text(value.publicKey), .text(value.requestDigest), .text(value.state.rawValue), value.sessionID.map { .text($0.uuidString) } ?? .null, .text(value.identity.requestAnchorID.uuidString), .text(value.identity.runID.uuidString), .integer(Int(value.identity.generation)), .integer(Int(value.identity.turnEpoch)), .text(value.identity.turnID.uuidString), .text(value.identity.responseSpanID.uuidString), value.preparedJSON.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null, value.compiledInputJSON.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null, value.receiptJSON.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null, value.rejectionCode.map(SQLiteData.text) ?? .null, .text(value.dispatchState), .float(value.createdAt.timeIntervalSince1970), .float(value.updatedAt.timeIntervalSince1970)]
    }

    private func decodeSubmission(_ row: SQLiteRow) throws -> AgentSubmissionRecord {
        guard let submissionID = row.column("submission_id")?.string.flatMap(UUID.init(uuidString:)), let requestAnchorID = row.column("request_anchor_id")?.string.flatMap(UUID.init(uuidString:)), let runID = row.column("run_id")?.string.flatMap(UUID.init(uuidString:)), let turnID = row.column("turn_id")?.string.flatMap(UUID.init(uuidString:)), let responseSpanID = row.column("response_span_id")?.string.flatMap(UUID.init(uuidString:)), let state = AgentSubmissionState(rawValue: row.column("state")?.string ?? "") else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Submission record is invalid") }
        return .init(submissionID: submissionID, actorID: row.column("actor_id")?.string ?? "", targetKey: row.column("target_key")?.string ?? "", operation: row.column("operation")?.string ?? "", publicKey: row.column("public_key")?.string ?? "", requestDigest: row.column("request_digest")?.string ?? "", state: state, sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)), identity: .init(requestAnchorID: requestAnchorID, runID: runID, generation: Int64(row.column("generation")?.integer ?? 0), turnEpoch: Int64(row.column("turn_epoch")?.integer ?? 0), turnID: turnID, responseSpanID: responseSpanID), preparedJSON: row.column("prepared_json")?.string.map { Data($0.utf8) }, compiledInputJSON: row.column("compiled_input_json")?.string.map { Data($0.utf8) }, receiptJSON: row.column("receipt_json")?.string.map { Data($0.utf8) }, rejectionCode: row.column("rejection_code")?.string, dispatchState: row.column("dispatch_state")?.string ?? "pending", createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0), updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }

    private func decodeSemanticTurn(_ row: SQLiteRow) throws -> SemanticTurnRecord {
        guard let sessionID = row.column("session_id")?.string.flatMap(UUID.init(uuidString:)), let requestAnchorID = row.column("request_anchor_id")?.string.flatMap(UUID.init(uuidString:)), let runID = row.column("run_id")?.string.flatMap(UUID.init(uuidString:)), let turnID = row.column("turn_id")?.string.flatMap(UUID.init(uuidString:)), let responseSpanID = row.column("response_span_id")?.string.flatMap(UUID.init(uuidString:)), let canonical = row.column("canonical_user_turn_json")?.string, let configuration = row.column("effective_configuration_json")?.string, let manifest = row.column("attachment_manifest_json")?.string, let tagged = row.column("tagged_files_json")?.string else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Semantic turn record is invalid") }
        return try .init(sessionID: sessionID, identity: .init(requestAnchorID: requestAnchorID, runID: runID, generation: Int64(row.column("generation")?.integer ?? 0), turnEpoch: Int64(row.column("turn_epoch")?.integer ?? 0), turnID: turnID, responseSpanID: responseSpanID), providerTurnID: row.column("provider_turn_id")?.string, firstSequence: Int64(row.column("first_sequence")?.integer ?? 0), lastSequence: Int64(row.column("last_sequence")?.integer ?? 0), terminalState: row.column("terminal_state")?.string, canonicalUserTurnJSON: Data(canonical.utf8), effectiveConfiguration: decoder.decode(EffectiveTurnConfigurationRecord.self, from: Data(configuration.utf8)), attachmentManifestJSON: Data(manifest.utf8), taggedFiles: decoder.decode([ComposerTaggedFileReferenceWire].self, from: Data(tagged.utf8)), createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0), acceptedAt: Date(timeIntervalSince1970: row.column("accepted_at")?.double ?? 0), settledAt: row.column("settled_at")?.double.map(Date.init(timeIntervalSince1970:)))
    }

    private func decodeSemanticActivity(_ row: SQLiteRow) throws -> SemanticActivityRecord {
        guard let activityID = row.column("activity_id")?.string.flatMap(UUID.init(uuidString:)), let sessionID = row.column("session_id")?.string.flatMap(UUID.init(uuidString:)), let requestAnchorID = row.column("request_anchor_id")?.string.flatMap(UUID.init(uuidString:)), let runID = row.column("run_id")?.string.flatMap(UUID.init(uuidString:)), let turnID = row.column("turn_id")?.string.flatMap(UUID.init(uuidString:)), let responseSpanID = row.column("response_span_id")?.string.flatMap(UUID.init(uuidString:)), let kind = SemanticActivityKind(rawValue: row.column("kind")?.string ?? "") else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Semantic activity record is invalid") }
        return try .init(activityID: activityID, sessionID: sessionID, identity: .init(requestAnchorID: requestAnchorID, runID: runID, generation: Int64(row.column("generation")?.integer ?? 0), turnEpoch: Int64(row.column("turn_epoch")?.integer ?? 0), turnID: turnID, responseSpanID: responseSpanID), canonicalSequence: Int64(row.column("canonical_sequence")?.integer ?? 0), revision: Int64(row.column("revision")?.integer ?? 0), kind: kind, content: row.column("content")?.string, summary: row.column("summary")?.string, status: row.column("status")?.string, interactionAnchor: row.column("interaction_anchor_json")?.string.map { try decoder.decode(SemanticInteractionAnchor.self, from: Data($0.utf8)) }, createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0), updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }

    private func decodeSemanticTool(_ row: SQLiteRow) throws -> SemanticToolRecord {
        guard let activityID = row.column("activity_id")?.string.flatMap(UUID.init(uuidString:)), let turnID = row.column("turn_id")?.string.flatMap(UUID.init(uuidString:)), let sessionID = row.column("session_id")?.string.flatMap(UUID.init(uuidString:)), let status = AgentPresentationToolStatus(rawValue: row.column("status")?.string ?? ""), let keyPaths = row.column("key_paths_json")?.string else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Semantic tool record is invalid") }
        return try .init(executionID: row.column("execution_id")?.string ?? "", activityID: activityID, turnID: turnID, sessionID: sessionID, canonicalSequence: Int64(row.column("canonical_sequence")?.integer ?? 0), revision: Int64(row.column("revision")?.integer ?? 0), normalizedName: row.column("normalized_name")?.string ?? "", status: status, displayArguments: row.column("display_arguments")?.string, displayResult: row.column("display_result")?.string, summary: row.column("summary")?.string, keyPaths: decoder.decode([String].self, from: Data(keyPaths.utf8)), processID: row.column("process_id")?.integer, exitCode: row.column("exit_code")?.integer, errorCode: row.column("error_code")?.string, argumentDigest: row.column("argument_digest")?.string, resultDigest: row.column("result_digest")?.string, createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0), updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }
}
