import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

@MainActor
struct OracleBackgroundCaller {
    let window: WindowState
    let session: AgentTabSession
    let owner: OracleBackgroundInvocationRegistry.Owner
    let runID: UUID
    let bindingTransitionGeneration: UInt64
    let stopFence: AgentRunStartStopFence

    var isCurrent: Bool {
        !window.isClosing && !WindowStatesManager.shared.isTerminating && !window.workspaceManager.isSwitchingWorkspace
            && !session.bindingTransitionInProgress && !session.worktreeBindingTransitionInProgress && !session.isChangingExecutionLocation
            && !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: owner.binding.sessionID)
            && !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: owner.binding.sessionID)
            && window.workspaceManager.activeWorkspaceID == owner.workspaceID
            && window.agentModeViewModel.session(for: owner.binding.tabID, createIfNeeded: false) === session
            && session.persistentSessionBindingIdentity == owner.binding
    }

    var admitsStart: Bool {
        isCurrent && session.bindingTransitionGeneration == bindingTransitionGeneration
            && session.runID == runID && session.runState.isActive && stopFence.permitsStart(of: session)
    }
}

extension MCPOracleToolService {
    private var backgroundRegistry: OracleBackgroundInvocationRegistry {
        AppDomainRuntimeComposition.shared.oracleBackgroundInvocations
    }

    func backgroundCaller(args: [String: Value], invocation: ToolInvocationContext, tool: String) async throws -> OracleBackgroundCaller? {
        guard let connectionID = invocation.connectionID, await liveRunPurpose(connectionID) == .agentModeRun else { return nil }
        guard let context = try? await requireCurrentTabContext(tool),
              let tabID = try? await resolveTabIDForAgentMode(args, connectionID),
              let window = try? requireTargetWindow()
        else { return nil }
        guard context.tabID == tabID, let workspaceID = context.workspaceID,
              window.workspaceManager.activeWorkspaceID == workspaceID,
              let sessionID = context.activeAgentSessionID, let runID = context.runID,
              let session = window.agentModeViewModel.session(for: tabID, createIfNeeded: false),
              session.activeAgentSessionID == sessionID, session.runID == runID,
              session.permitsBoundOperationAndSave, !session.bindingTransitionInProgress,
              let binding = session.persistentSessionBindingIdentity,
              session.authoritativeHydratedBinding == binding,
              session.authoritativeHydratedBindingTransitionGeneration == session.bindingTransitionGeneration
        else { return nil }
        let owner = OracleBackgroundInvocationRegistry.Owner(workspaceID: workspaceID, binding: binding)
        return OracleBackgroundCaller(window: window, session: session, owner: owner, runID: runID, bindingTransitionGeneration: session.bindingTransitionGeneration, stopFence: .init(session: session))
    }

    func startBackgroundOracle(args: [String: Value], tabContext: OracleViewModel.OracleSendTabContext, caller: OracleBackgroundCaller, invocationID: UUID) async throws -> Value {
        guard caller.admitsStart else { return Self.backgroundEnvelope(.unsupported, reason: "session") }
        let registry = backgroundRegistry
        let context = OracleViewModel.backgroundOracleContext(tabContext)
        let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: caller.owner.workspaceID)
        do {
            let prepared = try await oracleVM.prepareConfiguredOracleRoster(args: args, promptVM: promptVM, tabContext: context, capturedProfile: profile, freezeGroupLanes: true)
            guard prepared.isGrouped else { return Self.backgroundEnvelope(.unsupported, reason: "group") }
            guard caller.admitsStart else { return Self.backgroundEnvelope(.unsupported, reason: "session") }
            if let group = prepared.existingGroup, let busy = authorizedLiveBackground(groupID: group.group.id, caller: caller) {
                return Self.backgroundEnvelope(.busy, reference: busy.reference, caller: caller)
            }
            let admits = { caller.admitsStart && oracleVM.oracleBackgroundHistoryAdmissionIsOpen(workspaceID: caller.owner.workspaceID, groupID: prepared.existingGroup?.group.id) }
            guard admits() else { return Self.backgroundEnvelope(.busy, caller: caller) }
            if let previous = caller.session.oracleBackgroundOwner, previous != caller.owner, !registry.isDrained(previous) {
                return Self.backgroundEnvelope(.busy, caller: caller)
            }
            if registry.admissionIsClosed(for: caller.owner) {
                try registry.reopen(caller.owner, admissionIsCurrent: admits)
            }
            // Install only after preparation/validation, without a suspension before registry reservation.
            // A different binding's outstanding drain must never lose its session Stop pointer.
            caller.session.oracleBackgroundOwner = caller.owner
            let reference = try await registry.start(owner: caller.owner, runID: caller.runID, invocationID: invocationID, admissionIsCurrent: admits) { [oracleVM, promptVM, window = caller.window] job in
                // The worker owns captured composition independently of parent-run disposal.
                defer { withExtendedLifetime(window) {} }
                _ = try await oracleVM.executePreparedOracleGroup(prepared, args: args, promptVM: promptVM, tabContext: context, backgroundJob: job)
            }
            var receipt = Self.backgroundIdentity(reference, caller: caller)
            receipt.merge([
                "status": .string("running"), "chat_id": .string(reference.members[0].publicChatID),
                "oracle_count": .int(reference.members.count), "mode": args["mode"] ?? .string("chat"),
                "lanes": .array(reference.members.map { member in .object(Self.backgroundLane(member, status: "running")) })
            ]) { _, new in new }
            return .object(receipt)
        } catch let error as ChatToolError where error.code == .invalidParams { throw error }
        catch let error as OracleBackgroundInvocationRegistry.RegistryError {
            return Self.backgroundEnvelope(error == .limit ? .limit : error == .staleOwner ? .unsupported : error == .busy ? .busy : .unavailable, caller: caller, reason: error == .staleOwner ? "session" : nil)
        } catch is CancellationError { throw CancellationError() }
        catch OracleGroupClaimError.conflict { return await backgroundBusyAfterClaim(args: args, caller: caller) ?? Self.backgroundEnvelope(.busy, caller: caller) }
        catch { return Self.backgroundEnvelope(.unavailable, caller: caller) }
    }

    func backgroundBusyAfterClaim(args: [String: Value], caller: OracleBackgroundCaller?) async -> Value? {
        if let caller, let chatID = args["chat_id"]?.stringValue,
           let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID),
           let lookup = try? OracleMemberLookup(publicChatID: chatID),
           let group = try? await AppDomainRuntimeComposition.shared.oracleConversationStore.load(member: lookup, owner: owner),
           caller.isCurrent, let turn = group.turns.last, turn.state == .prepared, let provenance = turn.backgroundExecution,
           provenance.agentSessionID == caller.owner.binding.sessionID,
           backgroundProjectionMatches(group, provenance: provenance, caller: caller)
        {
            let reference = OracleBackgroundInvocationRegistry.Reference(groupID: group.group.id, turnID: turn.id, members: group.members, provenance: provenance)
            return Self.backgroundEnvelope(.busy, reference: reference, caller: caller)
        }
        return nil
    }

    func authorizedLiveBackground(groupID: OracleGroupID, caller: OracleBackgroundCaller) -> OracleBackgroundInvocationRegistry.Snapshot? {
        backgroundRegistry.snapshot(for: caller.owner, includeFinished: false).invocations.first { $0.reference.groupID == groupID }
    }

    func backgroundBusyContinuation(chatID: String, caller: OracleBackgroundCaller) async -> Value? {
        guard let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID),
              let lookup = try? OracleMemberLookup(publicChatID: chatID),
              let group = try? await AppDomainRuntimeComposition.shared.oracleConversationStore.load(member: lookup, owner: owner),
              caller.isCurrent, let live = authorizedLiveBackground(groupID: group.group.id, caller: caller),
              backgroundProjectionMatches(group, provenance: live.reference.provenance, caller: caller)
        else { return nil }
        return Self.backgroundEnvelope(.busy, reference: live.reference, caller: caller)
    }

    func executeBackgroundOracleControl(args: [String: Value], invocation: ToolInvocationContext, cancel: Bool) async throws -> Value {
        let allowed = cancel ? ["op", "oracle_group_id", "oracle_turn_id"] : ["op", "oracle_group_id", "oracle_turn_id", "chat_id", "include_finished"]
        let unsupported = args.keys.filter { !$0.hasPrefix("_") && !allowed.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams("\(cancel ? askOracleToolName : oracleChatLogToolName) only accepts: \(allowed.joined(separator: ", ")). Unsupported args: \(unsupported.joined(separator: ", "))")
        }
        let groupID = try OracleBackgroundContract.uuid(args, "oracle_group_id").map(OracleGroupID.init(rawValue:))
        let turnID = try OracleBackgroundContract.uuid(args, "oracle_turn_id").map(OracleTurnID.init(rawValue:))
        let includeFinished = try OracleBackgroundContract.boolean(args, "include_finished", default: true)
        let chatID: String?
        if let value = args["chat_id"] {
            guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OracleBackgroundContract.invalid("chat_id", expected: "non-empty string") }
            chatID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { chatID = nil }
        if cancel, groupID == nil || turnID == nil { throw OracleBackgroundContract.invalidConstraint("cancel needs both Oracle IDs") }
        if turnID != nil, groupID == nil, chatID == nil { throw OracleBackgroundContract.invalidConstraint("turn ID needs group ID or chat_id") }
        if args["include_finished"] != nil, groupID != nil || chatID != nil || turnID != nil { throw OracleBackgroundContract.invalidConstraint("include_finished needs no selector") }
        guard let caller = try await backgroundCaller(args: args, invocation: invocation, tool: cancel ? askOracleToolName : oracleChatLogToolName), caller.isCurrent else {
            return Self.backgroundEnvelope(.unsupported, reason: "session")
        }
        if groupID == nil, chatID == nil {
            return backgroundList(caller: caller, includeFinished: includeFinished)
        }
        let canonicalOwner = try OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID)
        var document: OracleGroupDocument?
        let beforeLoad = backgroundRegistry.awarenessVersion(for: caller.owner).generation
        do {
            let store = AppDomainRuntimeComposition.shared.oracleConversationStore
            if let groupID { document = try await store.load(groupID: groupID, owner: canonicalOwner) }
            else if let chatID { document = try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: canonicalOwner) }
            else { document = nil }
            // A completed worker can publish, release its claim and be evicted during the load.
            // Reload only this target once; uncertainty must not masquerade as interruption.
            if document?.turns.last?.state == .prepared,
               backgroundRegistry.awarenessVersion(for: caller.owner).generation != beforeLoad,
               let id = document?.group.id
            {
                let beforeReload = backgroundRegistry.awarenessVersion(for: caller.owner).generation
                document = try await store.load(groupID: id, owner: canonicalOwner)
                if document?.turns.last?.state == .prepared,
                   backgroundRegistry.awarenessVersion(for: caller.owner).generation != beforeReload
                {
                    return Self.backgroundEnvelope(.unavailable, caller: caller)
                }
            }
        } catch OraclePersistenceError.ownerMismatch { return Self.backgroundEnvelope(.notFound, caller: caller) }
        catch OraclePersistenceError.ambiguousMemberAlias { return Self.backgroundEnvelope(.notFound, caller: caller) }
        catch { return Self.backgroundEnvelope(.unavailable, caller: caller) }
        guard caller.isCurrent, let document,
              let turn = turnID.flatMap({ id in document.turns.first { $0.id == id } }) ?? (turnID == nil ? document.turns.last : nil),
              let provenance = turn.backgroundExecution,
              provenance.agentSessionID == caller.owner.binding.sessionID,
              backgroundProjectionMatches(document, provenance: provenance, caller: caller)
        else { return Self.backgroundEnvelope(.notFound, caller: caller) }
        if let chatID, !document.members.contains(where: { $0.publicChatID == chatID }) {
            throw OracleBackgroundContract.invalidConstraint("group ID and chat_id must match")
        }
        let reference = OracleBackgroundInvocationRegistry.Reference(groupID: document.group.id, turnID: turn.id, members: document.members, provenance: provenance)
        let current = backgroundRegistry.snapshot(for: caller.owner).invocations.first { $0.reference == reference }
        if cancel {
            if turn.state != .terminal, current?.phase.isLive == true {
                do { _ = try backgroundRegistry.cancel(owner: caller.owner, reference: reference) }
                catch { return Self.backgroundEnvelope(.notFound, caller: caller) }
                return Self.backgroundEnvelope(.cancelling, reference: reference, caller: caller)
            }
            return Self.backgroundEnvelope(.notRunning, reference: reference, caller: caller)
        }
        if turn.state == .terminal {
            return try backgroundTerminalValue(document: document, turn: turn, reference: reference, caller: caller)
        }
        if current?.groupStatus != nil {
            return await backgroundReloadPublished(reference: reference, caller: caller)
        }
        guard let current, current.phase.isLive else {
            if current?.phase == .orphaned { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
            guard case var .object(interrupted) = Self.backgroundEnvelope(.interrupted, reference: reference, caller: caller) else { preconditionFailure() }
            interrupted["chat_id"] = .string(reference.members[0].publicChatID)
            interrupted["mode"] = .string(turn.input.mode.rawValue)
            interrupted["lanes"] = .array(reference.members.map { member in
                var lane = Self.backgroundLane(member, status: "interrupted")
                lane["answer_ready"] = .bool(false)
                lane["partial"] = .bool(false)
                lane["truncated"] = .bool(false)
                return .object(lane)
            })
            return .object(interrupted)
        }
        var lanes: [Value] = [], unavailable = false
        for member in reference.members {
            let index = member.laneID.index
            var status = current.laneOutcomes[index]?.rawValue ?? "running"
            var response: String?, partial = false
            if let query = current.queries[index] {
                let (outcome, message) = await oracleVM.backgroundOracleQuerySnapshot(query)
                if case .providerCompleted? = outcome, message?.isFinalized == true {
                    status = "completed"
                    response = message?.content
                    if response?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { unavailable = true
                        response = nil
                    }
                } else if let outcome {
                    if case .cancelled = outcome { status = "cancelled" } else { status = "failed" }
                    response = message?.content
                    partial = response?.isEmpty == false
                } else if status == "completed" { unavailable = true }
            } else if status == "completed" { unavailable = true }
            var lane = Self.backgroundLane(member, status: status)
            lane["answer_ready"] = .bool(status == "completed" && response != nil)
            lane["partial"] = .bool(partial)
            lane["truncated"] = .bool((response?.count ?? 0) > 8000)
            if let response {
                let text = String(response.prefix(8000))
                if partial { lane["error"] = .object(["partial_response": .string(text)]) }
                else { lane["response"] = .string(text) }
            }
            lanes.append(.object(lane))
        }
        guard caller.isCurrent else { return Self.backgroundEnvelope(.notFound, caller: caller) }
        let latest = backgroundRegistry.snapshot(for: caller.owner).invocations.first { $0.reference == reference }
        if latest?.groupStatus != nil || latest?.phase.isLive != true {
            return await backgroundReloadPublished(reference: reference, caller: caller)
        }
        var object = Self.backgroundIdentity(reference, caller: caller)
        object["status"] = .string(latest?.phase == .cancelling ? "cancelling" : "running")
        object["mode"] = .string(turn.input.mode.rawValue)
        object["chat_id"] = .string(reference.members[0].publicChatID)
        object["lanes"] = .array(lanes)
        if unavailable, case let .object(envelope) = Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) { object.merge(envelope) { _, new in new } }
        return .object(object)
    }

    private func backgroundReloadPublished(reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) async -> Value {
        do {
            let owner = try OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID)
            let loaded = try await AppDomainRuntimeComposition.shared.oracleConversationStore.load(groupID: reference.groupID, owner: owner)
            guard caller.isCurrent else { return Self.backgroundEnvelope(.notFound, caller: caller) }
            guard let document = loaded, let turn = document.turns.first(where: { $0.id == reference.turnID }),
                  turn.backgroundExecution == reference.provenance,
                  backgroundProjectionMatches(document, provenance: reference.provenance, caller: caller), turn.state == .terminal
            else { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
            return try backgroundTerminalValue(document: document, turn: turn, reference: reference, caller: caller)
        } catch { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
    }

    private func backgroundTerminalValue(document: OracleGroupDocument, turn: OracleTurnRecord, reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) throws -> Value {
        guard let status = turn.status, turn.results.count == document.members.count else { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
        let result = try OracleGroupResult(groupID: document.group.id, status: status, oracleResults: turn.results, warnings: turn.warnings)
        var object = OracleViewModel.oracleGroupValue(result, mode: turn.input.mode.rawValue, tabContext: nil, reconciliationGuidance: GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: caller.owner.workspaceID).oracleReconciliationGuidance)
        object.merge(Self.backgroundIdentity(reference, caller: caller)) { _, new in new }
        return .object(object)
    }

    private func backgroundProjectionMatches(_ group: OracleGroupDocument, provenance: OracleBackgroundExecution, caller: OracleBackgroundCaller) -> Bool {
        for member in group.members {
            do {
                if let index = try oracleVM.validatedOracleProjectionIndex(member: member, group: group, workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID) {
                    let projection = oracleVM.sessions[index]
                    guard projection.agentModeSessionID == provenance.agentSessionID,
                          projection.agentModeRunID == provenance.agentRunID else { return false }
                }
            } catch { return false }
        }
        return true
    }

    private func backgroundList(caller: OracleBackgroundCaller, includeFinished: Bool) -> Value {
        let snapshot = backgroundRegistry.snapshot(for: caller.owner, includeFinished: includeFinished)
        let open = snapshot.invocations.filter(\.phase.isLive)
        let ready = open.reduce(0) { $0 + $1.laneOutcomes.values.count(where: { $0 == .completed }) }
        var object: [String: Value] = [
            "status": .string(snapshot.invocations.isEmpty ? "empty" : "listed"), "scope": .string("current_process"),
            "count": .int(snapshot.invocations.count), "open_count": .int(open.count), "answer_ready_count": .int(ready),
            "retention_limit": .int(OracleBackgroundInvocationRegistry.inactiveSessionLimit), "history_truncated": .bool(snapshot.historyTruncated),
            "backend": .string("app"), "context_id": .string(caller.owner.binding.tabID.uuidString), "agent_session_id": .string(caller.owner.binding.sessionID.uuidString),
            "turns": .array(snapshot.invocations.map { item in
                var turn = Self.backgroundIdentity(item.reference, caller: caller)
                turn["status"] = .string(item.phase == .orphaned ? "unavailable" : item.phase == .cancelling ? "cancelling" : item.phase.isLive ? "running" : item.groupStatus?.rawValue ?? "unavailable")
                turn["lanes"] = .array(item.reference.members.map { member in
                    var lane = Self.backgroundLane(member, status: item.laneOutcomes[member.laneID.index]?.rawValue ?? (item.phase.isLive ? "running" : "interrupted"))
                    lane["answer_ready"] = .bool(item.phase.isLive && item.laneOutcomes[member.laneID.index] == .completed)
                    return .object(lane)
                })
                return .object(turn)
            })
        ]
        if snapshot.invocations.isEmpty {
            object["code"] = .string("oracle_background_empty")
            object["message"] = .string(OracleBackgroundContract.ResultCode.empty.message)
            object["next_action"] = .null
        }
        return .object(object)
    }

    private static func backgroundLane(_ member: OracleGroupMember, status: String) -> [String: Value] {
        ["lane_index": .int(member.laneID.index), "chat_id": .string(member.publicChatID), "model_id": .string(member.model.modelID), "status": .string(status)]
    }

    static func backgroundIdentity(_ reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) -> [String: Value] {
        [
            "oracle_group_id": .string(reference.groupID.rawValue.uuidString),
            "oracle_turn_id": .string(reference.turnID.rawValue.uuidString),
            "agent_session_id": .string(reference.provenance.agentSessionID.uuidString),
            "agent_run_id": .string(reference.provenance.agentRunID.uuidString),
            "backend": .string("app"),
            "context_id": .string(caller.owner.binding.tabID.uuidString)
        ]
    }

    static func backgroundEnvelope(_ code: OracleBackgroundContract.ResultCode, reference: OracleBackgroundInvocationRegistry.Reference? = nil, caller: OracleBackgroundCaller? = nil, reason: String? = nil) -> Value {
        var object: [String: Value] = ["status": .string(code.status), "code": .string("oracle_background_" + code.rawValue), "message": .string(code.message), "next_action": .null]
        if let caller {
            object.merge(["backend": .string("app"), "context_id": .string(caller.owner.binding.tabID.uuidString), "agent_session_id": .string(caller.owner.binding.sessionID.uuidString)]) { _, new in new }
            if let reference { object.merge(backgroundIdentity(reference, caller: caller)) { _, new in new } }
        }
        if let reason { object["reason"] = .string(reason) }
        if [.busy, .notFound, .notRunning, .cancelling, .unavailable].contains(code) {
            var args: [String: Value] = ["op": .string("collect")]
            if let reference {
                args["oracle_group_id"] = .string(reference.groupID.rawValue.uuidString)
                args["oracle_turn_id"] = .string(reference.turnID.rawValue.uuidString)
            }
            object["next_action"] = .object(["tool": .string("oracle_chat_log"), "arguments": .object(args)])
        }
        return .object(object)
    }
}
