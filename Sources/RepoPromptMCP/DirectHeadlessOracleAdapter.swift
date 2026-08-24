import Foundation
import MCP
import RepoPromptDomainRuntime

protocol DirectHeadlessOracleStore: OracleGroupStore, OracleArtifactStore {
    func loadMostRecentConversation(owner: OracleConversationOwner) async throws -> OracleStoredConversation?
}

extension DomainOracleConversationStore: DirectHeadlessOracleStore {}

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
        case direct(modelID: String, implicitConversationID: UUID?)
        case startGroup(group: OracleGroupDescriptor, roster: OracleRoster, members: [OracleGroupMember])
        case continueGroup(groupID: OracleGroupID, expectedRevision: UInt64, roster: OracleRoster)
    }

    enum PreparedRoute {
        case direct(modelID: String, implicitConversationID: UUID?)
        case group
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
    private let store: any DirectHeadlessOracleStore
    private let claimManager: OracleGroupClaimManager
    private let provider: DirectHeadlessProviderCoordinator
    private let coordinator = OracleGroupCoordinator()
    private var plansByInvocationID: [UUID: InvocationPlan] = [:]
    private var isShuttingDown = false

    init(
        profileIdentifier: String,
        rosterResolver: DirectHeadlessOracleRosterResolver,
        store: any DirectHeadlessOracleStore,
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
            invocationID: securityContext.invocationID,
            runID: securityContext.principal.runID ?? UUID()
        )
        plansByInvocationID[plan.invocationID] = plan
        return plan.childLaunchPlan
    }

    func consumePreparedRoute(request: DomainPhysicalToolRequest) throws -> PreparedRoute {
        guard let invocationID = request.securityContext?.invocationID,
              let plan = plansByInvocationID[invocationID]
        else {
            throw AdapterError.missingPreparedInvocation
        }
        guard plan.claimID != nil else {
            plansByInvocationID.removeValue(forKey: invocationID)
            guard case let .direct(modelID, implicitConversationID) = plan.route else {
                throw AdapterError.missingPreparedInvocation
            }
            return .direct(modelID: modelID, implicitConversationID: implicitConversationID)
        }
        return .group
    }

    func discardPreparedInvocation(plan: DomainChildLaunchPlan) {
        let launchIDs = plan.lanes.map(\.launchID)
        guard let invocationID = plansByInvocationID.first(where: {
            $0.value.runID == plan.runID && $0.value.childLaunchPlan.lanes.map(\.launchID) == launchIDs
        })?.key else { return }
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
            throw AdapterError.unknownChatID
        }

        let latestDirect = await provider.latestConversationReference()
        guard let latest = try await store.loadMostRecentConversation(owner: owner) else {
            return try await provider.conversationLog(id: nil, limit: limit)
        }
        if case let .group(group) = latest {
            guard Self.prefersGroup(group, overDirectUpdatedAt: latestDirect?.updatedAt) else {
                return try await provider.conversationLog(id: nil, limit: limit)
            }
            return groupLog(group, laneIndex: 0, limit: limit)
        }
        return try await provider.conversationLog(id: nil, limit: limit)
    }

    func isGroupChat(chatID: String) async throws -> Bool {
        try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: owner) != nil
    }

    func shutdown() {
        isShuttingDown = true
        plansByInvocationID.removeAll()
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
            return plan
        }
        guard request.securityContext == nil else { throw AdapterError.missingPreparedInvocation }
        return try await makeInvocationPlan(
            toolName: toolName,
            arguments: arguments,
            invocationID: UUID(),
            runID: UUID()
        )
    }

    private func makeInvocationPlan(
        toolName: String,
        arguments: [String: Value],
        invocationID: UUID,
        runID: UUID
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
            if roster.count == 1, arguments["context_pack_ref"]?.stringValue != nil {
                throw AdapterError.contextPackRequired
            }

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
                modelOverride: arguments["model"]?.stringValue,
                whenMissingChatID: toolName == "oracle_send" ? .continueCurrent : .startNew
            )
            resolvedStartRoster = nil
        }

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
                let childPlan = try Self.childPlan(runID: runID, roster: roster)
                return InvocationPlan(
                    invocationID: invocationID,
                    runID: runID,
                    claimID: nil,
                    input: input,
                    route: .direct(modelID: roster.primary.modelID, implicitConversationID: nil),
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
                return try await groupContinuationPlan(
                    group: group,
                    configuredRoster: configured,
                    invocationID: invocationID,
                    runID: runID,
                    input: input
                )
            }
            if configured.count == 1 {
                try await provider.validateOracleRoster(configured)
                let childPlan = try Self.childPlan(runID: runID, roster: configured)
                return InvocationPlan(
                    invocationID: invocationID,
                    runID: runID,
                    claimID: nil,
                    input: input,
                    route: .direct(modelID: configured.primary.modelID, implicitConversationID: nil),
                    childLaunchPlan: childPlan
                )
            }
            throw AdapterError.unknownChatID

        case .implicitContinuation:
            let configured = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(newChat: false))
            let latestDirect = await provider.latestConversationReference()
            if case let .group(group)? = try await store.loadMostRecentConversation(owner: owner),
               Self.prefersGroup(group, overDirectUpdatedAt: latestDirect?.updatedAt)
            {
                return try await groupContinuationPlan(
                    group: group,
                    configuredRoster: configured,
                    invocationID: invocationID,
                    runID: runID,
                    input: input
                )
            }
            let directRoster = try OracleRoster(primary: configured.primary)
            try await provider.validateOracleRoster(directRoster)
            return try InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: nil,
                input: input,
                route: .direct(
                    modelID: directRoster.primary.modelID,
                    implicitConversationID: latestDirect?.id
                ),
                childLaunchPlan: Self.childPlan(runID: runID, roster: directRoster)
            )
        }
    }

    private static func prefersGroup(
        _ group: OracleGroupDocument,
        overDirectUpdatedAt latestDirectAt: Date?
    ) -> Bool {
        latestDirectAt.map { $0 <= group.updatedAt } ?? true
    }

    private func groupContinuationPlan(
        group: OracleGroupDocument,
        configuredRoster: OracleRoster,
        invocationID: UUID,
        runID: UUID,
        input: OracleInput
    ) async throws -> InvocationPlan {
        guard configuredRoster == group.roster else { throw AdapterError.rosterConflict }
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

    private func execute(_ plan: InvocationPlan, request: DomainPhysicalToolRequest) async throws -> Value {
        switch plan.route {
        case .direct:
            throw AdapterError.missingPreparedInvocation
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
        guard let observed = try await store.load(groupID: groupID, owner: owner),
              observed.revision >= expectedRevision,
              observed.roster == roster,
              let claimID = plan.claimID
        else {
            throw AdapterError.rosterConflict
        }
        let bundle = try groupCarrierBundle(for: plan, group: observed.group)
        let claim = try await claimManager.acquire(
            group: observed,
            owner: owner,
            invocationID: plan.invocationID,
            runID: plan.runID,
            claimID: claimID
        )
        defer { claim.release() }
        guard var current = try await store.load(groupID: groupID, owner: owner),
              current.group == observed.group,
              current.revision >= observed.revision,
              current.roster == roster
        else {
            throw AdapterError.rosterConflict
        }
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
        _ = try await OracleGroupTerminalPublisher.publish(
            terminal: terminal,
            expectedRevision: prepared.revision,
            store: store
        )
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
