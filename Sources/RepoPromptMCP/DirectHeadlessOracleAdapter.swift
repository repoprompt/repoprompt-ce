import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessOracleAdapter {
    enum AdapterError: Error, LocalizedError, Equatable {
        case contextPackRequired
        case unsupportedProviderOverride
        case unknownChatID
        case rosterConflict
        case missingPreparedInvocation
        case childCarrierMismatch

        var errorDescription: String? {
            switch self {
            case .contextPackRequired:
                "context_pack_required: grouped Context Builder execution requires a frozen canonical context pack."
            case .unsupportedProviderOverride:
                "Direct Oracle provider overrides are unsupported; select a model or start a new chat."
            case .unknownChatID:
                "Unknown Oracle chat_id. Start a new chat with ask_oracle and new_chat=true."
            case .rosterConflict:
                "The configured Oracle roster differs from this durable conversation. Start a new chat with new_chat=true."
            case .missingPreparedInvocation:
                "Oracle launch preparation was not available for this invocation."
            case .childCarrierMismatch:
                "Prepared Oracle child-launch carriers do not match the frozen lane plan."
            }
        }
    }

    private enum Route {
        case startSingle(publicChatID: String, model: OracleModelReference)
        case continueSingle(publicChatID: String, expectedRevision: UInt64, model: OracleModelReference)
        case startGroup(group: OracleGroupDescriptor, roster: OracleRoster, members: [OracleGroupMember])
        case continueGroup(groupID: OracleGroupID, expectedRevision: UInt64, roster: OracleRoster)
    }

    private struct InvocationPlan {
        let invocationID: UUID
        let runID: UUID
        let claimID: UUID?
        let input: OracleInput
        let route: Route
        let childLaunchPlan: DomainChildLaunchPlan
    }

    private let owner: OracleConversationOwner
    private let rosterResolver: DirectHeadlessOracleRosterResolver
    private let store: DomainOracleConversationStore
    private let claimManager: OracleGroupClaimManager
    private let provider: DirectHeadlessProviderCoordinator
    private let coordinator = OracleGroupCoordinator()
    private var plansByInvocationID: [UUID: InvocationPlan] = [:]
    private var invocationIDsByRunID: [UUID: UUID] = [:]
    private var isShuttingDown = false

    init(
        profileIdentifier: String,
        rosterResolver: DirectHeadlessOracleRosterResolver,
        store: DomainOracleConversationStore,
        claimManager: OracleGroupClaimManager,
        provider: DirectHeadlessProviderCoordinator
    ) throws {
        owner = try OracleConversationOwner(kind: "direct-headless", identifier: profileIdentifier)
        self.rosterResolver = rosterResolver
        self.store = store
        self.claimManager = claimManager
        self.provider = provider
    }

    func resolveChildLaunchPlan(
        toolName: String,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchPlan {
        guard !isShuttingDown else { throw CancellationError() }
        let plan = try await makeInvocationPlan(
            toolName: toolName,
            arguments: arguments,
            invocationID: securityContext.invocationID
        )
        plansByInvocationID[plan.invocationID] = plan
        invocationIDsByRunID[plan.runID] = plan.invocationID
        return plan.childLaunchPlan
    }

    func discardPreparedInvocation(runID: UUID) {
        guard let invocationID = invocationIDsByRunID.removeValue(forKey: runID) else { return }
        plansByInvocationID.removeValue(forKey: invocationID)
    }

    func start(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "ask_oracle", arguments: arguments, request: request)
        return try await execute(plan, request: request)
    }

    func `continue`(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "oracle_send", arguments: arguments, request: request)
        return try await execute(plan, request: request)
    }

    func buildContext(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "context_builder", arguments: arguments, request: request)
        return try await execute(plan, request: request)
    }

    func log(chatID: String?, limit: Int) async throws -> Value {
        let limit = max(1, min(limit, 50))
        if let chatID {
            let lookup = try OracleMemberLookup(publicChatID: chatID)
            if let group = try await store.load(member: lookup, owner: owner) {
                guard let laneIndex = group.members.firstIndex(where: { $0.publicChatID == chatID }) else {
                    throw AdapterError.unknownChatID
                }
                return groupLog(group, laneIndex: laneIndex, limit: limit)
            }
            if let single = try await store.load(publicChatID: chatID, owner: owner) {
                return singleLog(single, limit: limit)
            }
            throw AdapterError.unknownChatID
        }

        guard let latest = try await store.loadMostRecentConversation(owner: owner) else {
            return .object(["messages": .array([])])
        }
        switch latest {
        case let .single(single):
            return singleLog(single, limit: limit)
        case let .group(group):
            return groupLog(group, laneIndex: 0, limit: limit)
        }
    }

    func shutdown() {
        isShuttingDown = true
        plansByInvocationID.removeAll()
        invocationIDsByRunID.removeAll()
    }

    private func consumePlan(
        toolName: String,
        arguments: [String: Value],
        request: DomainPhysicalToolRequest
    ) async throws -> InvocationPlan {
        guard !isShuttingDown else { throw CancellationError() }
        if let invocationID = request.securityContext?.invocationID,
           let plan = plansByInvocationID.removeValue(forKey: invocationID)
        {
            invocationIDsByRunID.removeValue(forKey: plan.runID)
            return plan
        }
        guard request.securityContext == nil else { throw AdapterError.missingPreparedInvocation }
        return try await makeInvocationPlan(
            toolName: toolName,
            arguments: arguments,
            invocationID: UUID()
        )
    }

    private func makeInvocationPlan(
        toolName: String,
        arguments: [String: Value],
        invocationID: UUID
    ) async throws -> InvocationPlan {
        if arguments["provider"] != nil { throw AdapterError.unsupportedProviderOverride }
        let route: OracleConversationRoute
        let input: OracleInput
        let resolvedStartRoster: OracleRoster?
        if toolName == "context_builder" {
            let mode = Self.contextBuilderMode(arguments["response_type"]?.stringValue)
            let roster = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(
                primaryModelOverride: arguments["model"]?.stringValue,
                newChat: true
            ))
            if let rawReference = arguments["context_pack_ref"]?.stringValue {
                guard arguments["instructions"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                else {
                    throw MCPError.invalidParams(
                        "context_builder accepts either instructions or context_pack_ref, not both."
                    )
                }
                let reference = try OracleFrozenPackReference(rawValue: rawReference)
                let data = try await store.loadArtifact(id: reference.artifactID)
                let pack = try OracleFrozenContextPack.decodeCanonical(data)
                guard pack.mode == mode else {
                    throw MCPError.invalidParams(
                        "context_pack_ref response mode does not match response_type."
                    )
                }
                input = try OracleInput(
                    mode: mode,
                    userMessage: pack.content,
                    context: OracleContextEnvelope(
                        content: .durableArtifact(id: reference.artifactID),
                        sha256: reference.artifactID,
                        provenance: pack.provenance
                    )
                )
            } else {
                guard let instructions = arguments["instructions"]?.stringValue else {
                    throw MCPError.invalidParams("context_builder requires instructions or context_pack_ref")
                }
                guard roster.count == 1 else { throw AdapterError.contextPackRequired }
                input = try OracleInput(mode: mode, userMessage: instructions)
            }
            route = .start(primaryModelOverride: arguments["model"]?.stringValue)
            resolvedStartRoster = roster
        } else {
            guard let message = arguments["message"]?.stringValue else {
                throw MCPError.invalidParams("\(toolName) requires message")
            }
            input = try OracleInput(mode: Self.oracleMode(arguments["mode"]?.stringValue), userMessage: message)
            route = try OracleConversationRoute.resolve(
                chatID: arguments["chat_id"]?.stringValue,
                newChat: arguments["new_chat"]?.boolValue == true,
                modelOverride: arguments["model"]?.stringValue
            )
            resolvedStartRoster = nil
        }

        let runID = UUID()
        switch route {
        case let .start(primaryModelOverride):
            let roster = if let resolvedStartRoster {
                resolvedStartRoster
            } else {
                try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(
                    primaryModelOverride: primaryModelOverride,
                    newChat: true
                ))
            }
            try await provider.validateOracleRoster(roster)
            if roster.count == 1 {
                let publicChatID = UUID().uuidString
                let childPlan = try Self.childPlan(runID: runID, roster: roster)
                return InvocationPlan(
                    invocationID: invocationID,
                    runID: runID,
                    claimID: nil,
                    input: input,
                    route: .startSingle(publicChatID: publicChatID, model: roster.primary),
                    childLaunchPlan: childPlan
                )
            }
            let group = try OracleGroupDescriptor(size: roster.count)
            let members = try roster.orderedModels.enumerated().map { laneIndex, model in
                try OracleGroupMember(
                    laneID: OracleLaneID(index: laneIndex),
                    publicChatID: UUID().uuidString,
                    model: model
                )
            }
            let claimID = UUID()
            let childPlan = try Self.childPlan(
                runID: runID,
                group: group,
                claimID: claimID,
                roster: roster
            )
            return InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: claimID,
                input: input,
                route: .startGroup(group: group, roster: roster, members: members),
                childLaunchPlan: childPlan
            )

        case let .continuation(chatID):
            let configured = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(newChat: false))
            if let group = try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: owner) {
                guard configured == group.roster else { throw AdapterError.rosterConflict }
                try await provider.validateOracleRoster(group.roster)
                let claimID = UUID()
                let childPlan = try Self.childPlan(
                    runID: runID,
                    group: group.group,
                    claimID: claimID,
                    roster: group.roster
                )
                return InvocationPlan(
                    invocationID: invocationID,
                    runID: runID,
                    claimID: claimID,
                    input: input,
                    route: .continueGroup(
                        groupID: group.group.id,
                        expectedRevision: group.revision,
                        roster: group.roster
                    ),
                    childLaunchPlan: childPlan
                )
            }
            guard let single = try await store.load(publicChatID: chatID, owner: owner) else {
                throw AdapterError.unknownChatID
            }
            guard configured.count == 1, configured.primary == single.model else {
                throw AdapterError.rosterConflict
            }
            try await provider.validateOracleRoster(configured)
            return try InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: nil,
                input: input,
                route: .continueSingle(
                    publicChatID: chatID,
                    expectedRevision: single.revision,
                    model: single.model
                ),
                childLaunchPlan: Self.childPlan(runID: runID, roster: configured)
            )
        }
    }

    private func execute(_ plan: InvocationPlan, request: DomainPhysicalToolRequest) async throws -> Value {
        switch plan.route {
        case let .startSingle(publicChatID, model):
            try await executeSingleStart(
                plan: plan,
                publicChatID: publicChatID,
                model: model,
                request: request
            )
        case let .continueSingle(publicChatID, expectedRevision, model):
            try await executeSingleContinuation(
                plan: plan,
                publicChatID: publicChatID,
                expectedRevision: expectedRevision,
                model: model,
                request: request
            )
        case let .startGroup(group, roster, members):
            try await executeGroupStart(
                plan: plan,
                group: group,
                roster: roster,
                members: members,
                request: request
            )
        case let .continueGroup(groupID, expectedRevision, roster):
            try await executeGroupContinuation(
                plan: plan,
                groupID: groupID,
                expectedRevision: expectedRevision,
                roster: roster,
                request: request
            )
        }
    }

    private func executeSingleStart(
        plan: InvocationPlan,
        publicChatID: String,
        model: OracleModelReference,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let carrier = try singleCarrier(for: plan, secured: request.securityContext != nil)
        let claim = try await claimManager.acquireSingle(publicChatID: publicChatID, owner: owner)
        defer { claim.release() }
        let now = Date()
        let prepared = try OracleSingleConversationDocument(
            publicChatID: publicChatID,
            owner: owner,
            model: model,
            revision: 1,
            createdAt: now,
            updatedAt: now,
            turns: [OracleTurnRecord(input: plan.input, state: .prepared, startedAt: now)]
        )
        try await store.create(prepared)
        return try await executeSingle(
            plan: plan,
            prepared: prepared,
            request: request,
            carrier: carrier
        )
    }

    private func executeSingleContinuation(
        plan: InvocationPlan,
        publicChatID: String,
        expectedRevision: UInt64,
        model: OracleModelReference,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        guard var current = try await store.load(publicChatID: publicChatID, owner: owner),
              current.revision == expectedRevision,
              current.model == model
        else { throw AdapterError.rosterConflict }
        let carrier = try singleCarrier(for: plan, secured: request.securityContext != nil)
        let claim = try await claimManager.acquireSingle(publicChatID: publicChatID, owner: owner)
        defer { claim.release() }
        if current.turns.last?.state == .prepared {
            current = try await settleInterruptedSingle(current)
        }
        guard current.turns.last?.state == .terminal else { throw AdapterError.rosterConflict }
        let now = Date()
        let prepared = try OracleSingleConversationDocument(
            schemaVersion: current.schemaVersion,
            publicChatID: current.publicChatID,
            owner: current.owner,
            model: current.model,
            providerConversationID: current.providerConversationID,
            revision: current.revision &+ 1,
            createdAt: current.createdAt,
            updatedAt: now,
            turns: current.turns + [OracleTurnRecord(input: plan.input, state: .prepared, startedAt: now)]
        )
        try await store.save(prepared, expectedRevision: current.revision)
        return try await executeSingle(
            plan: plan,
            prepared: prepared,
            request: request,
            carrier: carrier
        )
    }

    private func executeSingle(
        plan: InvocationPlan,
        prepared: OracleSingleConversationDocument,
        request: DomainPhysicalToolRequest,
        carrier: DomainChildLaunchCarrier?
    ) async throws -> Value {
        let prompt = Self.prompt(turns: Array(prepared.turns.dropLast()), laneIndex: 0, next: plan.input.userMessage)
        let response: String
        do {
            response = try await provider.runProviderOnce(
                message: prompt,
                providerID: prepared.model.providerID,
                model: prepared.model.modelID,
                request: request,
                purpose: .oracle,
                carrierEnvironment: carrier?.environment
            )
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OracleLaneFailure(code: "empty_response", message: "Oracle provider returned an empty response.")
            }
        } catch is CancellationError {
            let result = try OracleLaneResult(
                laneIndex: 0,
                chatID: prepared.publicChatID,
                providerID: prepared.model.providerID,
                modelID: prepared.model.modelID,
                status: .cancelled,
                error: OracleLaneError(code: "cancelled", message: "Oracle provider was cancelled.")
            )
            let store = store
            try await Task.detached(priority: Task.currentPriority) {
                try await Self.saveSingleTerminal(prepared, result: result, store: store)
            }.value
            throw CancellationError()
        } catch {
            let failure = error as? OracleLaneFailure
            let result = try OracleLaneResult(
                laneIndex: 0,
                chatID: prepared.publicChatID,
                providerID: prepared.model.providerID,
                modelID: prepared.model.modelID,
                status: .failed,
                error: OracleLaneError(
                    code: failure?.code ?? "provider_error",
                    message: failure?.message ?? String(String(describing: error).prefix(512)),
                    partialResponse: failure?.partialResponse
                )
            )
            let store = store
            try await Task.detached(priority: Task.currentPriority) {
                try await Self.saveSingleTerminal(prepared, result: result, store: store)
            }.value
            throw error
        }
        let result = try OracleLaneResult(
            laneIndex: 0,
            chatID: prepared.publicChatID,
            providerID: prepared.model.providerID,
            modelID: prepared.model.modelID,
            status: .completed,
            response: response
        )
        try await saveSingleTerminal(prepared, result: result)
        return .object([
            "chat_id": .string(prepared.publicChatID),
            "response": .string(response),
            "backend": .string("headless")
        ])
    }

    private func saveSingleTerminal(
        _ prepared: OracleSingleConversationDocument,
        result: OracleLaneResult
    ) async throws {
        try await Self.saveSingleTerminal(prepared, result: result, store: store)
    }

    private static func saveSingleTerminal(
        _ prepared: OracleSingleConversationDocument,
        result: OracleLaneResult,
        store: DomainOracleConversationStore
    ) async throws {
        guard let turn = prepared.turns.last else { throw OraclePersistenceError.invalidDocument("missing_prepared_turn") }
        let terminalTurn = OracleTurnRecord(
            id: turn.id,
            input: turn.input,
            state: .terminal,
            startedAt: turn.startedAt,
            finishedAt: Date(),
            results: [result]
        )
        let terminal = try OracleSingleConversationDocument(
            schemaVersion: prepared.schemaVersion,
            publicChatID: prepared.publicChatID,
            owner: prepared.owner,
            model: prepared.model,
            providerConversationID: prepared.providerConversationID,
            revision: prepared.revision &+ 1,
            createdAt: prepared.createdAt,
            updatedAt: Date(),
            turns: Array(prepared.turns.dropLast()) + [terminalTurn]
        )
        try await store.save(terminal, expectedRevision: prepared.revision)
    }

    private func executeGroupStart(
        plan: InvocationPlan,
        group: OracleGroupDescriptor,
        roster: OracleRoster,
        members: [OracleGroupMember],
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let now = Date()
        let prepared = try OracleGroupDocument(
            group: group,
            owner: owner,
            name: String(plan.input.userMessage.prefix(80)),
            revision: 1,
            createdAt: now,
            updatedAt: now,
            roster: roster,
            members: members,
            turns: [OracleTurnRecord(input: plan.input, state: .prepared, startedAt: now)]
        )
        guard let claimID = plan.claimID else { throw AdapterError.childCarrierMismatch }
        let bundle = try groupCarrierBundle(for: plan, group: group)
        let claim = try await claimManager.acquire(
            group: prepared,
            owner: owner,
            invocationID: plan.invocationID,
            runID: plan.runID,
            claimID: claimID
        )
        defer { claim.release() }
        try await store.create(prepared)
        return try await executeGroup(
            plan: plan,
            prepared: prepared,
            request: request,
            bundle: bundle
        )
    }

    private func executeGroupContinuation(
        plan: InvocationPlan,
        groupID: OracleGroupID,
        expectedRevision: UInt64,
        roster: OracleRoster,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        guard var current = try await store.load(groupID: groupID, owner: owner),
              current.revision == expectedRevision,
              current.roster == roster,
              let claimID = plan.claimID
        else {
            throw AdapterError.rosterConflict
        }
        let bundle = try groupCarrierBundle(for: plan, group: current.group)
        let claim = try await claimManager.acquire(
            group: current,
            owner: owner,
            invocationID: plan.invocationID,
            runID: plan.runID,
            claimID: claimID
        )
        defer { claim.release() }
        if current.turns.last?.state == .prepared {
            current = try await settleInterruptedGroup(current)
        }
        guard current.turns.last?.state == .terminal else { throw AdapterError.rosterConflict }
        let now = Date()
        let prepared = try OracleGroupDocument(
            schemaVersion: current.schemaVersion,
            group: current.group,
            owner: current.owner,
            name: current.name,
            revision: current.revision &+ 1,
            createdAt: current.createdAt,
            updatedAt: now,
            roster: current.roster,
            members: current.members,
            turns: current.turns + [OracleTurnRecord(input: plan.input, state: .prepared, startedAt: now)]
        )
        try await store.save(prepared, expectedRevision: current.revision)
        return try await executeGroup(
            plan: plan,
            prepared: prepared,
            request: request,
            bundle: bundle
        )
    }

    private func executeGroup(
        plan: InvocationPlan,
        prepared: OracleGroupDocument,
        request: DomainPhysicalToolRequest,
        bundle: DomainChildLaunchCarrierBundle
    ) async throws -> Value {
        let result: OracleGroupResult
        do {
            let priorTurns = Array(prepared.turns.dropLast())
            let plans = try prepared.members.map { member in
                let lane = try OracleLaneDescriptor(
                    group: prepared.group,
                    laneID: member.laneID,
                    model: member.model
                )
                guard let carrier = bundle.carrier(for: member.laneID) else {
                    throw AdapterError.childCarrierMismatch
                }
                let prompt = Self.prompt(
                    turns: priorTurns,
                    laneIndex: member.laneID.index,
                    next: plan.input.userMessage
                )
                return try OracleLanePlan(lane: lane, publicChatID: member.publicChatID) { [provider] _ in
                    let response = try await provider.runProviderOnce(
                        message: prompt,
                        providerID: member.model.providerID,
                        model: member.model.modelID,
                        request: request,
                        purpose: .oracle,
                        carrierEnvironment: carrier.environment
                    )
                    return OracleLaneExecutionResponse(response: response)
                }
            }
            guard let turnID = prepared.turns.last?.id else {
                throw OraclePersistenceError.invalidDocument("missing_prepared_turn")
            }
            result = try await coordinator.execute(
                group: prepared.group,
                turnID: turnID,
                input: plan.input,
                plans: plans
            )
        } catch {
            try await settlePreparedGroupIfNeeded(prepared, error: error)
            throw error
        }
        let terminal = try prepared.settling(result)
        let store = store
        try await Task.detached(priority: Task.currentPriority) {
            try await store.save(terminal, expectedRevision: prepared.revision)
        }.value
        try Task.checkCancellation()
        return Self.groupValue(result)
    }

    private func settlePreparedGroupIfNeeded(
        _ prepared: OracleGroupDocument,
        error: Error
    ) async throws {
        let store = store
        let status: OracleLaneResultStatus = error is CancellationError ? .cancelled : .failed
        let code = error is CancellationError ? "cancelled" : "execution_failed"
        let message = error is CancellationError
            ? "Oracle provider was cancelled."
            : String(String(describing: error).prefix(512))
        try await Task.detached(priority: Task.currentPriority) {
            guard let current = try await store.load(groupID: prepared.group.id, owner: prepared.owner),
                  current.revision == prepared.revision,
                  current.turns.last?.state == .prepared
            else { return }
            let terminal = try current.settlingInterrupted(status: status, code: code, message: message)
            try await store.save(terminal, expectedRevision: current.revision)
        }.value
    }

    private func settleInterruptedGroup(_ prepared: OracleGroupDocument) async throws -> OracleGroupDocument {
        let terminal = try prepared.settlingInterrupted(
            status: .failed,
            code: "interrupted",
            message: "The previous Oracle execution was interrupted before completion."
        )
        try await store.save(terminal, expectedRevision: prepared.revision)
        return terminal
    }

    private func settleInterruptedSingle(
        _ prepared: OracleSingleConversationDocument
    ) async throws -> OracleSingleConversationDocument {
        let member = try OracleLaneResult(
            laneIndex: 0,
            chatID: prepared.publicChatID,
            providerID: prepared.model.providerID,
            modelID: prepared.model.modelID,
            status: .failed,
            error: OracleLaneError(
                code: "interrupted",
                message: "The previous Oracle execution was interrupted before completion."
            )
        )
        try await saveSingleTerminal(prepared, result: member)
        return try await store.load(publicChatID: prepared.publicChatID, owner: prepared.owner) ?? prepared
    }

    private func singleCarrier(
        for plan: InvocationPlan,
        secured: Bool
    ) throws -> DomainChildLaunchCarrier? {
        guard let bundle = DomainChildLaunchContext.bundle else {
            let carrier = DomainChildLaunchContext.current
            guard !secured || carrier != nil else {
                throw AdapterError.childCarrierMismatch
            }
            if let carrier {
                guard let lane = plan.childLaunchPlan.lanes.first,
                      plan.childLaunchPlan.lanes.count == 1,
                      carrier.runID == plan.runID,
                      carrier.launchID == lane.launchID,
                      carrier.providerIdentifier == lane.providerIdentifier,
                      carrier.oracleGroupID == nil,
                      carrier.oracleLaneID == nil,
                      carrier.oracleGroupClaimID == nil
                else {
                    throw AdapterError.childCarrierMismatch
                }
            }
            return carrier
        }
        guard bundle.plan.runID == plan.runID,
              bundle.plan.oracleGroupID == nil,
              bundle.plan.oracleGroupClaimID == nil,
              bundle.plan.lanes.count == 1,
              bundle.plan.lanes.map(\.launchID) == plan.childLaunchPlan.lanes.map(\.launchID),
              bundle.plan.lanes.map(\.providerIdentifier) == plan.childLaunchPlan.lanes.map(\.providerIdentifier),
              bundle.plan.lanes.allSatisfy({ $0.oracleLaneID == nil }),
              let carrier = bundle.singleCarrier
        else {
            throw AdapterError.childCarrierMismatch
        }
        return carrier
    }

    private func groupCarrierBundle(
        for plan: InvocationPlan,
        group: OracleGroupDescriptor
    ) throws -> DomainChildLaunchCarrierBundle {
        guard let bundle = DomainChildLaunchContext.bundle,
              bundle.plan.runID == plan.runID,
              bundle.plan.oracleGroupID == group.id,
              bundle.plan.oracleGroupClaimID == plan.claimID,
              bundle.carriers.count == group.size,
              bundle.plan.lanes.map(\.launchID) == plan.childLaunchPlan.lanes.map(\.launchID),
              bundle.plan.lanes.map(\.providerIdentifier) == plan.childLaunchPlan.lanes.map(\.providerIdentifier),
              bundle.plan.lanes.map(\.oracleLaneID) == plan.childLaunchPlan.lanes.map(\.oracleLaneID)
        else {
            throw AdapterError.childCarrierMismatch
        }
        return bundle
    }

    private func singleLog(_ conversation: OracleSingleConversationDocument, limit: Int) -> Value {
        .object([
            "chat_id": .string(conversation.publicChatID),
            "messages": .array(Array(Self.messages(turns: conversation.turns, laneIndex: 0).suffix(limit)))
        ])
    }

    private func groupLog(_ group: OracleGroupDocument, laneIndex: Int, limit: Int) -> Value {
        let member = group.members[laneIndex]
        return .object([
            "chat_id": .string(member.publicChatID),
            "messages": .array(Array(Self.messages(turns: group.turns, laneIndex: laneIndex).suffix(limit))),
            "oracle_group_id": .string(group.group.id.rawValue.uuidString),
            "lane_index": .int(laneIndex),
            "oracle_count": .int(group.group.size),
            "root_chat_id": .string(group.members[0].publicChatID)
        ])
    }

    private static func childPlan(
        runID: UUID,
        group: OracleGroupDescriptor? = nil,
        claimID: UUID? = nil,
        roster: OracleRoster
    ) throws -> DomainChildLaunchPlan {
        let lanes = try roster.orderedModels.enumerated().map { index, model in
            try DomainChildLaunchLanePlan(
                providerIdentifier: model.providerID ?? DirectHeadlessOracleRosterResolver.providerID,
                oracleLaneID: group == nil ? nil : OracleLaneID(index: index)
            )
        }
        return try DomainChildLaunchPlan(
            runID: runID,
            oracleGroupID: group?.id,
            oracleGroupClaimID: claimID,
            lanes: lanes,
            approvalMetadata: ["oracle_count": "\(roster.count)"]
        )
    }

    private static func prompt(turns: [OracleTurnRecord], laneIndex: Int, next: String) -> String {
        var messages: [(String, String)] = []
        for turn in turns where turn.state == .terminal {
            messages.append(("user", turn.input.userMessage))
            guard turn.results.indices.contains(laneIndex) else { continue }
            let result = turn.results[laneIndex]
            if let response = result.response ?? result.error?.partialResponse {
                messages.append(("assistant", response))
            }
        }
        guard !messages.isEmpty else { return next }
        return messages.map { "\($0.0): \($0.1)" }.joined(separator: "\n\n") + "\n\nuser: " + next
    }

    private static func messages(turns: [OracleTurnRecord], laneIndex: Int) -> [Value] {
        var values: [Value] = []
        for turn in turns where turn.state == .terminal {
            values.append(.object(["role": .string("user"), "text": .string(turn.input.userMessage)]))
            guard turn.results.indices.contains(laneIndex) else { continue }
            let result = turn.results[laneIndex]
            if let response = result.response ?? result.error?.partialResponse {
                values.append(.object(["role": .string("assistant"), "text": .string(response)]))
            }
        }
        return values
    }

    private static func oracleMode(_ raw: String?) throws -> OracleMode {
        guard let raw else { return .chat }
        guard let mode = OracleMode(rawValue: raw) else {
            throw MCPError.invalidParams("Oracle mode must be chat, plan, or review.")
        }
        return mode
    }

    private static func contextBuilderMode(_ raw: String?) -> OracleMode {
        switch raw {
        case "plan": .plan
        case "review": .review
        default: .chat
        }
    }

    private static func groupValue(_ result: OracleGroupResult) -> Value {
        var object = OracleGroupMCPCodec.groupFields(result)
        object.merge([
            "chat_id": .string(result.primary.chatID),
            "response": result.primary.response.map(Value.string) ?? .null,
            "backend": .string("headless")
        ]) { _, new in new }
        return .object(object)
    }
}
