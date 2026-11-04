import Foundation
import os
import RepoPromptDomainRuntime

/// A request can abort only an uncommitted handoff. Session Stop can cancel either side.
/// Continuations and worker cancellation always run outside the lock.
final class OracleBackgroundHandoff: Sendable {
    private enum Decision: Equatable { case pending, committed, aborted }
    private struct State {
        var decision = Decision.pending
        var cancelled = false
        var waiter: CheckedContinuation<Void, Error>?
        var worker: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var isCommitted: Bool {
        state.withLock { $0.decision == .committed }
    }

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func install(_ worker: Task<Void, Never>) {
        let cancelled = state.withLock { state in
            state.worker = worker
            return state.cancelled
        }
        if cancelled { worker.cancel() }
    }

    func releaseWorker() {
        state.withLock { $0.worker = nil }
    }

    @discardableResult
    func commit() -> Bool {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
            guard state.decision == .pending, !state.cancelled else { return (false, nil) }
            state.decision = .committed
            let waiter = state.waiter
            state.waiter = nil
            return (true, waiter)
        }
        result.1?.resume()
        return result.0
    }

    func abortPending() {
        cancel(pendingOnly: true)
    }

    func cancel() {
        cancel(pendingOnly: false)
    }

    private func cancel(pendingOnly: Bool) {
        let actions = state.withLock { state -> (Task<Void, Never>?, CheckedContinuation<Void, Error>?) in
            guard !state.cancelled, !pendingOnly || state.decision == .pending else { return (nil, nil) }
            state.cancelled = true
            if state.decision == .pending { state.decision = .aborted }
            let waiter = state.waiter
            state.waiter = nil
            return (state.worker, waiter)
        }
        actions.0?.cancel()
        actions.1?.resume(throwing: CancellationError())
    }

    func waitForCommit() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = state.withLock { state in
                    if state.cancelled { return .failure(CancellationError()) }
                    if state.decision == .committed { return .success(()) }
                    precondition(state.waiter == nil)
                    state.waiter = waiter
                    return nil
                }
                if let result { waiter.resume(with: result) }
            }
        } onCancel: {
            self.cancel()
        }
    }
}

/// Process-local execution/discovery references only. Answers and terminal outcomes stay canonical.
@MainActor
final class OracleBackgroundInvocationRegistry {
    static let activeLimit = 4
    static let inactiveSessionLimit = 64
    static let inactiveProcessLimit = 256

    struct Owner: Hashable {
        let workspaceID: UUID
        /// A refused route attempt advances its transient transition counter without rebinding.
        /// Execution authority follows this persisted binding incarnation until a real rebind drains it.
        let binding: AgentPersistentSessionBindingIdentity

        fileprivate var sessionKey: [UUID] {
            [workspaceID, binding.tabID, binding.sessionID]
        }
    }

    enum RegistryError: Error, Equatable { case busy, limit, staleOwner, notFound, invalidExecution }
    enum Phase: Equatable {
        case preparing, awaitingHandoff, running, cancelling, settled, orphaned
        var isLive: Bool {
            switch self {
            case .preparing, .awaitingHandoff, .running, .cancelling: true
            case .settled, .orphaned: false
            }
        }
    }

    struct Reference: Equatable {
        let groupID: OracleGroupID
        let turnID: OracleTurnID
        let members: [OracleGroupMember]
        let provenance: OracleBackgroundExecution
    }

    struct QueryIdentity: Equatable {
        let sessionID: UUID
        let queryID: UUID
        let oracleGeneration: UInt64
    }

    struct Snapshot {
        let reference: Reference
        let phase: Phase
        let createdAt: Date
        let laneOutcomes: [Int: OracleLaneResultStatus]
        let queries: [Int: QueryIdentity]
        let groupStatus: OracleGroupStatus?
    }

    struct OwnerSnapshot {
        let epoch: UUID?
        let generation: UInt64
        let historyTruncated: Bool
        let invocations: [Snapshot]
    }

    @MainActor
    final class Job {
        let owner: Owner
        let provenance: OracleBackgroundExecution
        fileprivate let epoch: UUID
        fileprivate let handoff = OracleBackgroundHandoff()
        private weak var registry: OracleBackgroundInvocationRegistry?

        fileprivate init(registry: OracleBackgroundInvocationRegistry, owner: Owner, epoch: UUID, runID: UUID, invocationID: UUID) {
            self.registry = registry
            self.owner = owner
            self.epoch = epoch
            provenance = OracleBackgroundExecution(agentSessionID: owner.binding.sessionID, agentRunID: runID, invocationID: invocationID)
        }

        var isCancellationRequested: Bool {
            handoff.isCancelled
        }

        /// Compose after the app's projection callback, before the runtime may construct lanes.
        func prepared(_ document: OracleGroupDocument) async throws {
            guard let registry else { throw RegistryError.invalidExecution }
            try registry.prepared(self, document: document)
            try await handoff.waitForCommit()
        }

        /// Called from the existing onQueryCreated hook. The capability must target this exact
        /// query/generation, including revalidation inside any suspension-prone provider cleanup.
        func registerQuery(
            laneIndex: Int,
            identity: QueryIdentity,
            isCurrent: @escaping @MainActor (QueryIdentity) -> Bool,
            cancel: @escaping @MainActor (QueryIdentity) async -> Void
        ) throws {
            guard let registry else { throw RegistryError.invalidExecution }
            try registry.registerQuery(self, laneIndex: laneIndex, identity: identity, isCurrent: isCurrent, cancel: cancel)
        }

        func retainQueryWork(laneIndex: Int, task: Task<Void, Never>, cancelOnStop: Bool = false) {
            guard let query = registry?.entry(for: self)?.queries[laneIndex] else { return }
            query.work.append(task)
            if cancelOnStop {
                query.producer = task
                if isCancellationRequested { task.cancel() }
            }
        }

        func cancelExecution() {
            guard let registry, let entry = registry.entry(for: self) else { return }
            registry.cancel(entry)
        }

        func cancelQuery(laneIndex: Int) {
            guard let registry, let query = registry.entry(for: self)?.queries[laneIndex] else { return }
            registry.scheduleCleanup(query)
        }

        func joinQueryCleanup(laneIndex: Int) async {
            guard let query = registry?.entry(for: self)?.queries[laneIndex] else { return }
            await query.cleanup?.value
            var index = 0
            while index < query.work.count {
                await query.work[index].value
                index += 1
            }
            await query.cleanup?.value
        }

        /// After runtime.execute returns (including claim release), accept only metadata from
        /// its exact canonical publication, not a groupSettled event.
        func recordPublishedTurn(_ document: OracleGroupDocument) throws {
            guard let registry, let entry = registry.entry(for: self), !entry.finishing,
                  let reference = entry.reference, document.group.id == reference.groupID,
                  document.members == reference.members,
                  try document.owner == (OracleViewModel.oracleGroupOwner(workspaceID: owner.workspaceID, tabID: owner.binding.tabID)),
                  let turn = document.turns.last, turn.id == reference.turnID, turn.state == .terminal,
                  turn.backgroundExecution == provenance, turn.status != nil, turn.finishedAt != nil,
                  turn.results.count == reference.members.count
            else { throw RegistryError.invalidExecution }
            let outcomes = Dictionary(uniqueKeysWithValues: turn.results.map { ($0.laneIndex, $0.status) })
            if entry.published {
                guard entry.outcomes == outcomes else { throw RegistryError.invalidExecution }
                return
            }
            entry.published = true
            entry.groupStatus = turn.status
            entry.outcomes = outcomes
            registry.changed(owner)
        }

        func recordLaneOutcome(_ outcome: OracleLaneResultStatus, laneIndex: Int, sequence: UInt64) {
            guard let registry, let entry = registry.entry(for: self), !entry.finishing,
                  entry.reference?.members.indices.contains(laneIndex) == true,
                  entry.outcomes[laneIndex] == nil, sequence > entry.sequences[laneIndex, default: 0],
                  outcome != .completed || entry.queries[laneIndex] != nil
            else { return }
            entry.sequences[laneIndex] = sequence
            entry.outcomes[laneIndex] = outcome
            registry.changed(owner)
        }
    }

    @MainActor
    private final class Query {
        let identity: QueryIdentity
        let isCurrent: @MainActor (QueryIdentity) -> Bool
        let cancel: @MainActor (QueryIdentity) async -> Void
        var cleanup: Task<Void, Never>?
        var work: [Task<Void, Never>] = []
        var producer: Task<Void, Never>?
        init(identity: QueryIdentity, isCurrent: @escaping @MainActor (QueryIdentity) -> Bool, cancel: @escaping @MainActor (QueryIdentity) async -> Void) {
            self.identity = identity
            self.isCurrent = isCurrent
            self.cancel = cancel
        }
    }

    @MainActor
    private final class Entry {
        let job: Job
        let createdAt: Date
        var phase = Phase.preparing
        var reference: Reference?
        var task: Task<Void, Never>?
        var ready: CheckedContinuation<Reference, Error>?
        var queries: [Int: Query] = [:]
        var sequences: [Int: UInt64] = [:]
        var outcomes: [Int: OracleLaneResultStatus] = [:]
        var finishing = false
        var published = false
        var groupStatus: OracleGroupStatus?
        init(job: Job, createdAt: Date) {
            self.job = job
            self.createdAt = createdAt
        }
    }

    @MainActor
    private final class OwnerState {
        var epoch = UUID()
        var closed = false
        var drained = false
        var drain: Task<Void, Never>?
        var generation: UInt64 = 0
        var historyTruncated = false
    }

    private(set) var isShuttingDown = false
    private var shutdownDrain: Task<Void, Never>?
    private var entries: [UUID: Entry] = [:]
    private var owners: [Owner: OwnerState] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func hasLiveOwner(_ owner: Owner) -> Bool {
        entries.values.contains { $0.job.owner == owner && $0.phase.isLive }
    }

    func hasLiveGroup(_ groupID: OracleGroupID) -> Bool {
        entries.values.contains { $0.reference?.groupID == groupID && $0.phase.isLive }
    }

    func removeSettledGroup(_ groupID: OracleGroupID) {
        guard !hasLiveGroup(groupID) else { return }
        let affected = entries.values.filter { $0.reference?.groupID == groupID }.map(\.job.owner)
        entries = entries.filter { $0.value.reference?.groupID != groupID }
        affected.forEach { changed($0) }
    }

    func removeSettledWorkspace(_ workspaceID: UUID) {
        let selected = owners.keys.filter { $0.workspaceID == workspaceID }
        for owner in selected {
            try? remove(owner)
        }
    }

    func removeSettledSession(_ sessionID: UUID) {
        let selected = owners.keys.filter { $0.binding.sessionID == sessionID }
        for owner in selected {
            try? remove(owner)
        }
    }

    /// Admission and logical receipt commit both revalidate the initiating run. After commit,
    /// execution and cleanup use only the captured session binding/epoch, never a later run.
    func start(
        owner: Owner,
        runID: UUID,
        invocationID: UUID,
        admissionIsCurrent: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor @Sendable (Job) async throws -> Void
    ) async throws -> Reference {
        guard !isShuttingDown, admissionIsCurrent() else { throw RegistryError.staleOwner }
        guard owners[owner]?.closed != true, entries[invocationID] == nil else { throw RegistryError.busy }
        let live = entries.values.filter(\.phase.isLive)
        guard !live.contains(where: {
            $0.job.owner != owner && $0.job.owner.workspaceID == owner.workspaceID && $0.job.owner.binding.tabID == owner.binding.tabID
        }) else { throw RegistryError.busy }
        guard live.count(where: { $0.job.owner.sessionKey == owner.sessionKey }) < Self.activeLimit else { throw RegistryError.limit }
        let state = ownerState(owner)
        let job = Job(registry: self, owner: owner, epoch: state.epoch, runID: runID, invocationID: invocationID)
        let entry = Entry(job: job, createdAt: now())
        entries[invocationID] = entry
        // No inherited MCP task-local authority or request cancellation lifetime.
        let worker = Task.detached { @MainActor in
            do {
                try await operation(job)
                await self.finish(job, error: nil)
            } catch {
                await self.finish(job, error: error)
            }
        }
        entry.task = worker
        job.handoff.install(worker)
        let handoff = job.handoff
        return try await withTaskCancellationHandler {
            do {
                let reference = try await withCheckedThrowingContinuation { entry.ready = $0 }
                guard !Task.isCancelled, admissionIsCurrent(), owners[owner] === state, !state.closed else {
                    throw CancellationError()
                }
                guard job.handoff.commit() else { throw CancellationError() }
                entry.phase = .running
                changed(owner)
                return reference
            } catch {
                job.handoff.abortPending()
                await worker.value
                throw error
            }
        } onCancel: {
            handoff.abortPending()
        }
    }

    /// Synchronous Stop fence, including idle sessions and starts still preparing. The returned
    /// coalesced ticket joins full worker exit, not merely a lane/group progress event.
    func close(_ owner: Owner) -> Task<Void, Never> {
        let state = ownerState(owner)
        if let drain = state.drain { return drain }
        state.closed = true
        state.epoch = UUID()
        changed(owner)
        let owned = entries.values.filter { $0.job.owner == owner && $0.phase.isLive }
        for entry in owned {
            cancel(entry)
        }
        let tasks = owned.compactMap(\.task)
        // Synchronous binders can replace an already-settled owner on this actor turn.
        // Live workers remain fenced until their retained drain actually exits.
        state.drained = tasks.isEmpty
        let drain = Task.detached { @MainActor in
            for task in tasks {
                await task.value
            }
            state.drained = true
        }
        state.drain = drain
        return drain
    }

    func isDrained(_ owner: Owner) -> Bool {
        owners[owner]?.drained == true
    }

    func closeAll(workspaceID: UUID? = nil, tabID: UUID? = nil, sessionID: UUID? = nil) -> Task<Void, Never> {
        let selected = owners.keys.filter {
            (workspaceID == nil || $0.workspaceID == workspaceID) && (tabID == nil || $0.binding.tabID == tabID)
                && (sessionID == nil || $0.binding.sessionID == sessionID)
        }
        let drains = selected.map { close($0) }
        return Task.detached { @MainActor in for drain in drains {
            await drain.value
        } }
    }

    func drainGroup(_ groupID: OracleGroupID) -> Task<Void, Never> {
        let selected = entries.values.filter { $0.reference?.groupID == groupID && $0.phase.isLive }
        selected.forEach { cancel($0) }
        let tasks = selected.compactMap(\.task)
        return Task.detached { @MainActor in for task in tasks {
            await task.value
        } }
    }

    func beginShutdown() -> Task<Void, Never> {
        if let shutdownDrain { return shutdownDrain }
        isShuttingDown = true
        let drain = closeAll()
        shutdownDrain = drain
        return drain
    }

    /// Uses the existing bounded-stop completion signal. Timeout abandons only the waiter;
    /// registry ownership of the worker, exact-query cleanup and composition remains intact.
    static func awaitDrain(_ drain: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        let signal = AgentSessionLinkStopSignal<Bool>()
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, timeout))) } catch { return }
            signal.finish(false)
        }
        Task { @MainActor in await drain.value
            signal.finish(true)
        }
        let result = await signal.value()
        timer.cancel()
        return result
    }

    /// Only an explicit new start may reopen a stopped epoch, after its drain completed.
    func reopen(_ owner: Owner, admissionIsCurrent: @MainActor () -> Bool) throws {
        guard !isShuttingDown, admissionIsCurrent() else { throw RegistryError.staleOwner }
        guard let prior = owners[owner], prior.closed, prior.drained else { throw RegistryError.busy }
        let next = OwnerState()
        next.generation = prior.generation &+ 1
        next.historyTruncated = prior.historyTruncated
        owners[owner] = next
    }

    @discardableResult
    func cancel(owner: Owner, reference: Reference) throws -> Bool {
        guard let entry = entries.values.first(where: { $0.reference == reference && $0.job.owner.sessionKey == owner.sessionKey }) else { throw RegistryError.notFound }
        guard entry.phase.isLive else { return false }
        guard entry.job.owner == owner else { throw RegistryError.notFound }
        cancel(entry)
        return true
    }

    /// Constant-time version check for a future cached next-input supplement; no list or I/O.
    func awarenessVersion(for owner: Owner) -> (epoch: UUID?, generation: UInt64) {
        (owners[owner]?.epoch, owners[owner]?.generation ?? 0)
    }

    func admissionIsClosed(for owner: Owner) -> Bool {
        owners[owner]?.closed == true
    }

    /// Internal teardown join; public collect and cancel never await this method.
    func join(owner: Owner, reference: Reference) async throws {
        guard let entry = entries.values.first(where: { $0.reference == reference && $0.job.owner == owner }) else { throw RegistryError.notFound }
        await entry.task?.value
    }

    /// Settled discovery follows persisted session identity, like canonical provenance. Live
    /// resources remain fenced to the exact binding incarnation until its drain completes.
    func snapshot(for owner: Owner, includeFinished: Bool = true) -> OwnerSnapshot {
        let selected = entries.values.filter {
            $0.job.owner.sessionKey == owner.sessionKey && (!$0.phase.isLive || $0.job.owner == owner)
                && $0.job.handoff.isCommitted && (includeFinished || $0.phase.isLive)
        }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? older(lhs, rhs) : lhs.createdAt > rhs.createdAt
        }
        return OwnerSnapshot(
            epoch: owners[owner]?.epoch, generation: owners[owner]?.generation ?? 0,
            historyTruncated: owners.contains { $0.key.sessionKey == owner.sessionKey && $0.value.historyTruncated },
            invocations: selected.compactMap { entry in
                entry.reference.map {
                    Snapshot(reference: $0, phase: entry.phase, createdAt: entry.createdAt, laneOutcomes: entry.outcomes, queries: entry.queries.mapValues(\.identity), groupStatus: entry.groupStatus)
                }
            }
        )
    }

    /// Destructive lifecycle callers close and join before dropping references or history.
    func remove(_ owner: Owner) throws {
        guard owners[owner]?.drained == true,
              !entries.values.contains(where: { $0.job.owner.sessionKey == owner.sessionKey && $0.phase.isLive })
        else { throw RegistryError.busy }
        entries = entries.filter { $0.value.job.owner.sessionKey != owner.sessionKey }
        owners = owners.filter { $0.key.sessionKey != owner.sessionKey }
    }

    private func ownerState(_ owner: Owner) -> OwnerState {
        if let state = owners[owner] { return state }
        let state = OwnerState()
        owners[owner] = state
        return state
    }

    private func changed(_ owner: Owner) {
        owners[owner]?.generation &+= 1
    }

    private func entry(for job: Job) -> Entry? {
        guard let entry = entries[job.provenance.invocationID], entry.job === job else { return nil }
        return entry
    }

    private func prepared(_ job: Job, document: OracleGroupDocument) throws {
        guard let entry = entry(for: job), !entry.finishing, entry.reference == nil, document.group.size >= 2,
              let turn = document.turns.last, turn.state == .prepared,
              turn.backgroundExecution == job.provenance,
              try document.owner == (OracleViewModel.oracleGroupOwner(workspaceID: job.owner.workspaceID, tabID: job.owner.binding.tabID))
        else { throw RegistryError.invalidExecution }
        let reference = Reference(groupID: document.group.id, turnID: turn.id, members: document.members, provenance: job.provenance)
        entry.reference = reference
        entry.phase = job.isCancellationRequested ? .cancelling : .awaitingHandoff
        entry.ready?.resume(returning: reference)
        entry.ready = nil
    }

    private func registerQuery(_ job: Job, laneIndex: Int, identity: QueryIdentity, isCurrent: @escaping @MainActor (QueryIdentity) -> Bool, cancel: @escaping @MainActor (QueryIdentity) async -> Void) throws {
        guard let entry = entry(for: job), !entry.finishing, job.handoff.isCommitted,
              let members = entry.reference?.members, members.indices.contains(laneIndex),
              members[laneIndex].memberID.rawValue == identity.sessionID
        else { throw RegistryError.invalidExecution }
        if let query = entry.queries[laneIndex] {
            guard query.identity == identity else { throw RegistryError.invalidExecution }
            return
        }
        let query = Query(identity: identity, isCurrent: isCurrent, cancel: cancel)
        entry.queries[laneIndex] = query
        if job.isCancellationRequested { scheduleCleanup(query) }
    }

    private func scheduleCleanup(_ query: Query) {
        guard query.cleanup == nil else { return }
        query.producer?.cancel()
        query.cleanup = Task.detached { @MainActor in
            if query.isCurrent(query.identity) { await query.cancel(query.identity) }
        }
    }

    private func cancel(_ entry: Entry) {
        let changedPhase = entry.phase != .cancelling
        entry.job.handoff.cancel()
        entry.phase = .cancelling
        for query in entry.queries.values {
            scheduleCleanup(query)
        }
        if changedPhase { changed(entry.job.owner) }
    }

    private func finish(_ job: Job, error: Error?) async {
        guard let entry = entry(for: job) else { return }
        entry.finishing = true
        job.handoff.abortPending()
        if error != nil || job.isCancellationRequested {
            for query in entry.queries.values {
                scheduleCleanup(query)
            }
        }
        for index in entry.queries.keys.sorted() {
            await job.joinQueryCleanup(laneIndex: index)
        }
        entry.queries.removeAll()
        entry.task = nil
        job.handoff.releaseWorker()
        entry.ready?.resume(throwing: error ?? RegistryError.invalidExecution)
        entry.ready = nil
        if job.handoff.isCommitted {
            entry.phase = entry.published ? .settled : .orphaned
            changed(job.owner)
        } else {
            entries.removeValue(forKey: job.provenance.invocationID)
        }
        prune()
    }

    private func older(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        let left = lhs.reference.map { $0.groupID.rawValue.uuidString + $0.turnID.rawValue.uuidString } ?? lhs.job.provenance.invocationID.uuidString
        let right = rhs.reference.map { $0.groupID.rawValue.uuidString + $0.turnID.rawValue.uuidString } ?? rhs.job.provenance.invocationID.uuidString
        return left < right
    }

    private func prune() {
        var retained: [[UUID]: Int] = [:]
        var total = 0
        for entry in entries.values.filter({ !$0.phase.isLive }).sorted(by: older).reversed() {
            let key = entry.job.owner.sessionKey
            if retained[key, default: 0] >= Self.inactiveSessionLimit || total >= Self.inactiveProcessLimit {
                entries.removeValue(forKey: entry.job.provenance.invocationID)
                owners[entry.job.owner]?.historyTruncated = true
                changed(entry.job.owner)
            } else {
                retained[key, default: 0] += 1
                total += 1
            }
        }
    }
}
