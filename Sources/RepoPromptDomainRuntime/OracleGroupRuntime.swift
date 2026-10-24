import Foundation

package struct OracleGroupRuntime: Sendable {
    private let store: any OracleGroupStore
    private let claimManager: OracleGroupClaimManager
    private let coordinator = OracleGroupCoordinator()
    private let now: @Sendable () -> Date

    package init(
        store: any OracleGroupStore,
        claimManager: OracleGroupClaimManager,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.claimManager = claimManager
        self.now = now
    }

    package func execute(
        _ request: Request,
        callbacks: Callbacks
    ) async throws -> Completion {
        switch request.intent {
        case let .start(start):
            return try await executeStart(request, start: start, callbacks: callbacks)
        case let .continuation(continuation):
            return try await executeContinuation(request, continuation: continuation, callbacks: callbacks)
        }
    }
}

package extension OracleGroupRuntime {
    struct Request: Sendable {
        package let invocationID: UUID
        package let runID: UUID
        package let claimID: UUID
        package let input: OracleInput
        package let intent: Intent

        package init(
            invocationID: UUID,
            runID: UUID,
            claimID: UUID,
            input: OracleInput,
            intent: Intent
        ) {
            self.invocationID = invocationID
            self.runID = runID
            self.claimID = claimID
            self.input = input
            self.intent = intent
        }
    }

    enum Intent: Sendable {
        case start(Start)
        case continuation(Continuation)
    }

    struct Start: Sendable {
        package let group: OracleGroupDescriptor
        package let owner: OracleConversationOwner
        package let name: String
        package let roster: OracleRoster
        package let members: [OracleGroupMember]

        package init(
            group: OracleGroupDescriptor,
            owner: OracleConversationOwner,
            name: String,
            roster: OracleRoster,
            members: [OracleGroupMember]
        ) {
            self.group = group
            self.owner = owner
            self.name = name
            self.roster = roster
            self.members = members
        }
    }

    struct Continuation: Sendable {
        package let group: OracleGroupDescriptor
        package let owner: OracleConversationOwner
        package let observedRevision: UInt64
        package let expectedRoster: OracleRoster

        package init(
            group: OracleGroupDescriptor,
            owner: OracleConversationOwner,
            observedRevision: UInt64,
            expectedRoster: OracleRoster
        ) {
            self.group = group
            self.owner = owner
            self.observedRevision = observedRevision
            self.expectedRoster = expectedRoster
        }
    }

    struct LaneInvocation: Sendable {
        package let member: OracleGroupMember
        package let priorTerminalTurns: [OracleTurnRecord]
        package let context: OracleLaneExecutionContext

        package init(
            member: OracleGroupMember,
            priorTerminalTurns: [OracleTurnRecord],
            context: OracleLaneExecutionContext
        ) {
            self.member = member
            self.priorTerminalTurns = priorTerminalTurns
            self.context = context
        }
    }

    struct Callbacks: Sendable {
        package let prepared: @Sendable (OracleGroupDocument) async throws -> Void
        package let executeLane: @Sendable (LaneInvocation) async throws -> OracleLaneExecutionResponse
        package let progress: OracleGroupCoordinator.ProgressHandler

        package init(
            prepared: @escaping @Sendable (OracleGroupDocument) async throws -> Void = { _ in },
            executeLane: @escaping @Sendable (LaneInvocation) async throws -> OracleLaneExecutionResponse,
            progress: @escaping OracleGroupCoordinator.ProgressHandler = { _ in }
        ) {
            self.prepared = prepared
            self.executeLane = executeLane
            self.progress = progress
        }
    }

    struct Completion: Sendable {
        package let terminalDocument: OracleGroupDocument
        package let result: OracleGroupResult
    }

    enum RuntimeError: Error, LocalizedError, Equatable, Sendable {
        case singleLaneBypassRequired
        case continuationMissing
        case continuationChanged
        case rosterConflict
        case invalidPreparedTurn
        case settlementFailed(execution: String, settlement: String)

        package var errorDescription: String? {
            switch self {
            case .singleLaneBypassRequired:
                "Single-Oracle execution must bypass OracleGroupRuntime."
            case .continuationMissing:
                "Oracle group continuation target was not found."
            case .continuationChanged:
                "Oracle group changed before continuation ownership was acquired."
            case .rosterConflict:
                "The configured Oracle roster differs from this durable conversation."
            case .invalidPreparedTurn:
                "Oracle group is not prepared."
            case let .settlementFailed(execution, settlement):
                "Oracle group settlement failed after \(execution): \(settlement)"
            }
        }
    }
}

extension OracleGroupRuntime {
    private func executeStart(
        _ request: Request,
        start: Start,
        callbacks: Callbacks
    ) async throws -> Completion {
        try Task.checkCancellation()
        try validateStart(start)
        let timestamp = now()
        let prepared = try OracleGroupDocument(
            group: start.group,
            owner: start.owner,
            name: start.name,
            revision: 1,
            createdAt: timestamp,
            updatedAt: timestamp,
            roster: start.roster,
            members: start.members,
            turns: [OracleTurnRecord(input: request.input, state: .prepared, startedAt: timestamp)]
        )
        let claim = try await claimManager.acquire(
            group: prepared,
            owner: start.owner,
            invocationID: request.invocationID,
            runID: request.runID,
            claimID: request.claimID
        )
        defer { claim.release() }
        try Task.checkCancellation()
        try await store.create(prepared)
        return try await finishPrepared(prepared, callbacks: callbacks)
    }

    private func executeContinuation(
        _ request: Request,
        continuation: Continuation,
        callbacks: Callbacks
    ) async throws -> Completion {
        try Task.checkCancellation()
        guard let observed = try await store.load(
            groupID: continuation.group.id,
            owner: continuation.owner
        ) else {
            throw RuntimeError.continuationMissing
        }
        try validateContinuation(continuation, document: observed)
        let claim = try await claimManager.acquire(
            group: observed,
            owner: continuation.owner,
            invocationID: request.invocationID,
            runID: request.runID,
            claimID: request.claimID
        )
        defer { claim.release() }
        guard let loaded = try await store.load(
            groupID: continuation.group.id,
            owner: continuation.owner
        ) else {
            throw RuntimeError.continuationChanged
        }
        var current = loaded
        try validateContinuation(continuation, document: current)
        if current.turns.last?.state == .prepared {
            current = try await publishInterrupted(current)
        }
        try Task.checkCancellation()
        guard current.turns.last?.state == .terminal else {
            throw RuntimeError.invalidPreparedTurn
        }
        let timestamp = now()
        let prepared = try OracleGroupDocument(
            schemaVersion: current.schemaVersion,
            group: current.group,
            owner: current.owner,
            name: current.name,
            revision: current.revision &+ 1,
            createdAt: current.createdAt,
            updatedAt: timestamp,
            roster: current.roster,
            members: current.members,
            turns: current.turns + [OracleTurnRecord(input: request.input, state: .prepared, startedAt: timestamp)]
        )
        try await store.save(prepared, expectedRevision: current.revision)
        return try await finishPrepared(prepared, callbacks: callbacks)
    }

    private func finishPrepared(
        _ prepared: OracleGroupDocument,
        callbacks: Callbacks
    ) async throws -> Completion {
        do {
            try await callbacks.prepared(prepared)
        } catch {
            try await settlePrepared(prepared, error: error)
            throw error
        }
        guard let turn = prepared.turns.last, turn.state == .prepared else {
            throw RuntimeError.invalidPreparedTurn
        }
        let priorTurns = Array(prepared.turns.dropLast())
        let plans = try prepared.members.map { member in
            let lane = try OracleLaneDescriptor(
                group: prepared.group,
                laneID: member.laneID,
                model: member.model
            )
            return try OracleLanePlan(
                lane: lane,
                publicChatID: member.publicChatID
            ) { context in
                try await callbacks.executeLane(
                    LaneInvocation(
                        member: member,
                        priorTerminalTurns: priorTurns,
                        context: context
                    )
                )
            }
        }
        let result: OracleGroupResult
        do {
            result = try await coordinator.execute(
                group: prepared.group,
                turnID: turn.id,
                input: turn.input,
                plans: plans,
                progress: callbacks.progress
            )
        } catch {
            try await settlePrepared(prepared, error: error)
            throw error
        }
        let terminal = try prepared.settling(result, finishedAt: now())
        let published = try await OracleGroupTerminalPublisher.publish(
            terminal: terminal,
            expectedRevision: prepared.revision,
            store: store
        )
        return Completion(terminalDocument: published, result: result)
    }

    private func publishInterrupted(_ prepared: OracleGroupDocument) async throws -> OracleGroupDocument {
        let terminal = try prepared.settlingInterrupted(
            status: .failed,
            code: "interrupted",
            message: "The previous Oracle execution was interrupted before completion.",
            finishedAt: now()
        )
        return try await OracleGroupTerminalPublisher.publish(
            terminal: terminal,
            expectedRevision: prepared.revision,
            store: store
        )
    }

    private func settlePrepared(
        _ prepared: OracleGroupDocument,
        error: Error
    ) async throws {
        let store = store
        let cancelled = error is CancellationError || Task.isCancelled
        let executionDescription = String(describing: error)
        let finishedAt = now()
        do {
            try await Task.detached(priority: Task.currentPriority) {
                guard let current = try await store.load(
                    groupID: prepared.group.id,
                    owner: prepared.owner
                ),
                    current.revision == prepared.revision,
                    current.turns.last?.id == prepared.turns.last?.id,
                    current.turns.last?.state == .prepared
                else { return }
                let rawMessage = String(executionDescription.prefix(512))
                let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Oracle group execution failed."
                    : rawMessage
                let terminal = try current.settlingInterrupted(
                    status: cancelled ? .cancelled : .failed,
                    code: cancelled ? "cancelled" : "execution_failed",
                    message: cancelled ? "Oracle provider was cancelled." : message,
                    finishedAt: finishedAt
                )
                _ = try await OracleGroupTerminalPublisher.publish(
                    terminal: terminal,
                    expectedRevision: current.revision,
                    store: store
                )
            }.value
        } catch {
            throw RuntimeError.settlementFailed(
                execution: executionDescription,
                settlement: String(describing: error)
            )
        }
    }

    private func validateStart(_ start: Start) throws {
        guard start.group.size >= 2,
              start.roster.count >= 2,
              start.members.count >= 2
        else {
            throw RuntimeError.singleLaneBypassRequired
        }
        guard start.group.size == start.roster.count,
              start.members.count == start.group.size,
              start.members.map(\.laneID.index) == Array(start.members.indices),
              start.members.map(\.model) == start.roster.orderedModels,
              Set(start.members.map(\.memberID)).count == start.members.count,
              Set(start.members.map(\.publicChatID)).count == start.members.count
        else {
            throw OracleGroupContractError.invalidGroupResult
        }
    }

    private func validateContinuation(
        _ continuation: Continuation,
        document: OracleGroupDocument
    ) throws {
        guard document.group.size >= 2 else {
            throw RuntimeError.singleLaneBypassRequired
        }
        guard document.group == continuation.group,
              document.owner == continuation.owner,
              document.revision >= continuation.observedRevision
        else {
            throw RuntimeError.continuationChanged
        }
        guard document.roster == continuation.expectedRoster else {
            throw RuntimeError.rosterConflict
        }
    }
}
