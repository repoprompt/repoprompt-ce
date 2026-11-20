import Combine
import Foundation
import RepoPromptDomainRuntime

/// A retained join/recovery obligation over the existing scope, not a run or writer store.
/// Composition must pass its executable host as `owner` and request retirement only for an
/// authorized lifetime transition. Detach, Stop, and terminal publication do not call this.
@MainActor
final class AgentSessionHostDrainRuntime {
    enum Outcome: Equatable {
        case released, retained(String), timedOut, cancelled
    }

    /// Pure query plus the existing owner's exact-object join. These callbacks do not own
    /// tasks, infer cancellation, or re-resolve a session by persistent UUID.
    struct EffectJoin {
        let hasPending: @MainActor (AgentTabSession) -> Bool
        let drain: @MainActor (AgentTabSession) async -> Void
        let hasPendingInScope: @MainActor () -> Bool
        let drainScope: @MainActor () async -> Void

        static func selfCompact(_ links: AgentSessionLinkExecutionRuntime) -> Self {
            .init(hasPending: { links.hasPendingSelfCompactEffects(for: $0) }, drain: {
                await links.drainPendingSelfCompactEffects(for: $0)
            }, hasPendingInScope: {
                links.hasPendingSelfCompactEffects()
            }, drainScope: {
                await links.drainPendingSelfCompactEffects()
            })
        }

        /// Reuses the link owner's receipts, including objects removed from the live census.
        static func managedInput(_ links: AgentSessionLinkExecutionRuntime) -> Self {
            .init(hasPending: { session in
                links.pendingManagedInputEffects.values.contains { $0.sessionIdentity == ObjectIdentifier(session) }
            }, drain: { session in
                await links.drainPendingManagedInputEffects(for: session)
            }, hasPendingInScope: {
                !links.pendingManagedInputEffects.isEmpty
            }, drainScope: {
                await links.drainPendingManagedInputEffects(for: nil)
            })
        }
    }

    struct Adapters {
        let managedInput: EffectJoin?
        let selfCompact: EffectJoin?
        /// Join provider AND terminal teardown using their originating receipts, including
        /// any terminal barrier task whose completion has no readiness publication. This is
        /// a join, never implicit cancellation, and must not resolve a successor.
        struct Provider {
            let finish: @MainActor () async throws -> Void
            let probe: @MainActor (@escaping @MainActor () -> Bool) async throws -> Bool
        }

        let captureProvider: @MainActor (AgentTabSession) throws -> Provider

        init(
            managedInput: EffectJoin?, selfCompact: EffectJoin?,
            captureProvider: @escaping @MainActor (AgentTabSession) throws -> Provider
        ) {
            self.managedInput = managedInput
            self.selfCompact = selfCompact
            self.captureProvider = captureProvider
        }

        init(
            managedInput: EffectJoin?, selfCompact: EffectJoin?,
            finishProvider: @escaping @MainActor (AgentTabSession) async throws -> Void,
            probe: @escaping @MainActor (AgentTabSession, @escaping @MainActor () -> Bool) async throws -> Bool
        ) {
            self.init(managedInput: managedInput, selfCompact: selfCompact, captureProvider: { session in
                Provider(finish: { try await finishProvider(session) }, probe: { try await probe(session, $0) })
            })
        }

        /// Use only while captured controllers remain installed AND readable after the join.
        /// A retirement that closes transport must instead supply an exact positive closed-receipt
        /// probe (originating controller/run/binding, completed teardown, no domain registration).
        /// Read errors are failures, never idle evidence. Preserve controller identity through
        /// release; clearing/replacing a pointer is not an acknowledgement of its cleanup.
        static func live(
            managedInput: EffectJoin?,
            selfCompact: EffectJoin?,
            finishProvider: @escaping @MainActor (AgentTabSession) async throws -> Void
        ) -> Self {
            .init(managedInput: managedInput, selfCompact: selfCompact, finishProvider: finishProvider, probe: { session, current in
                let claude = session.claudeController
                let acp = session.acpController
                let codex = session.codexController
                if let claude {
                    let busy = await claude.hasTurnInFlight
                    guard current(), !busy else { return false }
                }
                if let acp {
                    let busy = await acp.hasExecutionInFlight
                    guard current(), !busy else { return false }
                }
                if let codex {
                    let snapshot = try await codex.readThreadSnapshot(includeTurns: false, timeout: 2)
                    guard current(), snapshot.runtimeStatus == .idle, !snapshot.hasActiveTurn else { return false }
                    let tools = await codex.outstandingBlockingNativeToolCallNames()
                    guard current(), tools.isEmpty else { return false }
                }
                if let id = session.activeAgentSessionID {
                    let registered = await AgentRunSessionStore.hasActiveRegistration(sessionID: id)
                    guard current(), !registered else { return false }
                }
                return current()
            })
        }
    }

    struct SessionOutcome {
        let membership: AgentSessionRuntimeStore.MembershipIdentity?
        let sessionID: UUID?
        let outcome: Outcome
    }

    private final class Participant {
        let session: AgentTabSession
        let membership: AgentSessionRuntimeStore.Membership?
        let sessionID: UUID?
        var provider: Adapters.Provider?
        var providerIsCurrent: (@MainActor () -> Bool)?

        init(session: AgentTabSession, membership: AgentSessionRuntimeStore.Membership?, sessionID: UUID?) {
            self.session = session
            self.membership = membership
            self.sessionID = sessionID
        }
    }

    let scope: AgentSessionRuntimeStore.Scope
    private var participants: [Participant]
    /// Exact acknowledgements returned by Scope.releaseWriterClaim, not elected writers.
    private var releasedParticipants: Set<ObjectIdentifier> = []
    private var retainedOwner: AnyObject?
    private var adapters: Adapters?
    private var releaseResources: (@MainActor () async -> Void)?
    private var task: Task<Void, Never>?
    private var shutdownPreparation: Task<Void, Never>?
    private var shutdownPreparationFinished = false
    private var observations: Set<AnyCancellable> = []
    private var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    private(set) var outcome: Outcome?
    /// Diagnostic receipts only; authority remains with the scope's exact membership.
    private(set) var sessionOutcomes: [UUID: SessionOutcome] = [:]

    var hasEffectCapabilities: Bool {
        adapters?.managedInput != nil && adapters?.selfCompact != nil
    }

    var hasPendingScopeEffects: Bool {
        guard let managedInput = adapters?.managedInput, let selfCompact = adapters?.selfCompact else { return true }
        return managedInput.hasPendingInScope() || selfCompact.hasPendingInScope()
    }

    /// Only a retained host opts into these stronger checks; legacy prepared release keeps its
    /// compatibility projection. Capability absence is not idle/provider completion evidence.
    func effectBlockers(for session: AgentTabSession) -> Set<AgentSessionRuntimeStore.Scope.Settlement.Blocker> {
        // Final app shutdown may normalize provider pointers through their original cancellation
        // owners. Do not capture a drain identity in the middle of that authorized transition.
        if shutdownPreparation != nil, !shutdownPreparationFinished { return [.drainCapability] }
        guard let managedInput = adapters?.managedInput, let selfCompact = adapters?.selfCompact else { return [.drainCapability] }
        return managedInput.hasPending(session) || selfCompact.hasPending(session) ? [.effects] : []
    }

    /// Repeated shutdown/recovery requests reuse the original owner and its adapters. They
    /// cannot construct competing coordinators or replace resources of a retained obligation.
    static func begin(
        scope: AgentSessionRuntimeStore.Scope, owner: AnyObject, adapters: Adapters,
        releaseResources: @escaping @MainActor () async -> Void = {}
    ) -> AgentSessionHostDrainRuntime {
        if let retained = scope.retainedDrain { return retained }
        return AgentSessionHostDrainRuntime(scope: scope, owner: owner, adapters: adapters, releaseResources: releaseResources)
    }

    /// Fences admission and installs strong retention synchronously, before any await.
    private init(
        scope: AgentSessionRuntimeStore.Scope, owner: AnyObject, adapters: Adapters,
        releaseResources: @escaping @MainActor () async -> Void
    ) {
        self.scope = scope
        retainedOwner = owner
        self.adapters = adapters
        self.releaseResources = releaseResources
        participants = scope.sessions.values.map {
            Participant(session: $0, membership: scope.membership(of: $0), sessionID: $0.activeAgentSessionID)
        }
        scope.beginRetirement()
        scope.retainDrain(self)
        for session in scope.sessions.values {
            session.monitorReadinessChangePublisher.sink { [weak scope] _ in
                Task { @MainActor [weak scope] in scope?.noteSettlementChanged() }
            }.store(in: &observations)
        }
    }

    /// Final shutdown alone installs this original producer. A deadline/cancelled waiter cannot
    /// cancel it, and repeated shutdown cannot replace it with a later session census. Ordinary
    /// presentation detach and provider logout never install a whole-host shutdown preparation.
    func prepareForFinalShutdown(
        withdrawScheduledStarts: @MainActor () -> Void = {},
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard outcome != .released, shutdownPreparation == nil else { return }
        shutdownPreparation = Task { [self] in
            await operation()
            shutdownPreparationFinished = true
            scope.noteSettlementChanged()
        }
        // Publish the original producer before synchronous withdrawal can notify another owner.
        // Its main-actor task cannot execute until this once-only admission boundary returns.
        withdrawScheduledStarts()
    }

    /// A failed attempt is retried only by this explicit action, never a timer or inventory read.
    func attemptRecovery() {
        guard outcome != .released else { return }
        if task != nil {
            // An explicit recovery action may recheck a non-published blocker, without
            // cancelling its originating joins or launching a second save attempt.
            scope.noteSettlementChanged()
            return
        }
        outcome = nil
        sessionOutcomes = sessionOutcomes.filter { $0.value.outcome == .released }
        task = Task { [self] in
            await shutdownPreparation?.value
            let result = await drain()
            if result == .released {
                // Keep the exact host and its release obligation retained until resource cleanup
                // itself completes. A cancelled/deadline waiter cannot skip this producer.
                await releaseResources?()
                releaseResources = nil
                shutdownPreparation = nil
            }
            task = nil
            outcome = result
            let completions = waiters.values
            waiters.removeAll()
            for completion in completions {
                completion.resume(returning: result)
            }
            if result == .released {
                observations.removeAll()
                // A host-supplied teardown closure can itself capture its owner/resources.
                adapters = nil
                participants.removeAll()
                releasedParticipants.removeAll()
                retainedOwner = nil
                scope.acknowledgeDrain()
            }
        }
    }

    /// Observer cancellation/deadline never cancels a producer or releases recovery ownership.
    /// A caller performing shutdown supplies the SAME deadline to every host in its snapshot.
    func wait(until deadline: ContinuousClock.Instant) async -> Outcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .cancelled)
                    return
                }
                if let outcome { continuation.resume(returning: outcome)
                    return
                }
                waiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    self?.waiters.removeValue(forKey: id)?.resume(returning: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: .cancelled)
            }
        }
    }

    /// One total budget; all hosts start before waiting on any one of them. The strong snapshot
    /// survives timeout; the canonical store retains unfinished hosts for explicit recovery.
    static func shutdown(_ hosts: [AgentSessionHostDrainRuntime]) async -> [Outcome] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        for host in hosts {
            host.attemptRecovery()
        }
        var results: [Outcome] = []
        for host in hosts {
            await results.append(host.wait(until: deadline))
        }
        return results
    }

    private func drain() async -> Outcome {
        if participants.isEmpty, !hasEffectCapabilities {
            return .retained("Exact managed-input or self-compaction drain capability is unavailable.")
        }
        let tasks = participants.filter { !releasedParticipants.contains(ObjectIdentifier($0.session)) }.map { participant in
            Task { @MainActor [self] in
                let result = await drainSession(participant)
                sessionOutcomes[participant.session.tabID] = .init(
                    membership: participant.membership?.identity, sessionID: participant.sessionID, outcome: result
                )
                return result
            }
        }
        var failure: Outcome?
        for task in tasks {
            let result = await task.value
            if result != .released { failure = result }
        }
        if let failure { return failure }
        // Scope resources may still have exact cleanup for an object removed before retirement.
        // Aggregate retention is distinct from each sibling's already acknowledged claim.
        guard let managedInput = adapters?.managedInput, let selfCompact = adapters?.selfCompact else {
            return .retained("Scope effect-join capabilities are unavailable.")
        }
        await scope.continuation.drainPendingStarts()
        await scope.attachments.waitForRetention()
        await scope.installedInteractions?.drainPendingEffects()
        await scope.linkExecution?.drainPendingSendEffects()
        await scope.linkExecution?.drainPendingStopEffects()
        await managedInput.drainScope()
        await selfCompact.drainScope()
        await scope.worktrees.waitForTransitions()
        // Queue completion only joins storage access. It is not a durable-save receipt for a
        // removed object, and cannot substitute for a participant's required final save.
        while let sessionID = scope.saveQueue.inFlightSessionIDs.first {
            await scope.persistence.waitForInFlightSave(sessionID: sessionID)
        }
        guard scope.releaseWriterClaimsAfterHostDrain() else { return .retained("Scope-wide work remains unsettled.") }
        return .released
    }

    private func drainSession(_ participant: Participant) async -> Outcome {
        let session = participant.session
        // Registration precedes every settlement check, including nonterminal producer joins.
        let (observationID, changes) = scope.observeSettlement()
        defer { scope.removeSettlementObserver(observationID) }
        var iterator = changes.makeAsyncIterator()
        guard let membership = participant.membership, let adapters else { return .retained("Missing scope membership or drain adapters.") }
        guard let managedInput = adapters.managedInput, let selfCompact = adapters.selfCompact else {
            return .retained("Exact managed-input or self-compaction drain capability is unavailable.")
        }
        while true {
            guard membership.isCurrent else { return .retained("The originating membership changed.") }
            let settlement = scope.settlement(for: session)
            if settlement.canJoinHostDrain { break }
            guard await iterator.next() != nil else { return .retained("Settlement observation ended.") }
        }
        let binding = session.currentRestorationBindingToken
        let ownership = session.activeRunOwnership
        let runID = session.runID, attemptID = session.activeRunAttemptID
        let claude = session.claudeController, acp = session.acpController, codex = session.codexController
        let current: @MainActor () -> Bool = {
            membership.isCurrent && session.currentRestorationBindingToken == binding
                && session.activeRunOwnership == ownership && session.runID == runID && session.activeRunAttemptID == attemptID
                && session.claudeController === claude && session.acpController === acp && session.codexController === codex
        }
        let provider: Adapters.Provider
        do {
            if let captured = participant.provider { provider = captured }
            else {
                provider = try adapters.captureProvider(session)
                participant.provider = provider
                participant.providerIsCurrent = current
            }
        } catch { return .retained("Provider receipt capture failed: \(error.localizedDescription)") }
        guard participant.providerIsCurrent?() == true else {
            return .retained("Recovery cannot adopt a replacement provider execution.")
        }
        await scope.continuation.drainPendingStarts(for: session)
        guard current() else { return .retained("Execution changed while joining starts.") }
        await scope.attachments.waitForRetention(for: session)
        guard current() else { return .retained("Execution changed while joining attachments.") }
        await scope.installedInteractions?.drainPendingEffects(for: session)
        guard current() else { return .retained("Execution changed while joining interactions.") }
        await scope.linkExecution?.drainPendingSendEffects(for: session)
        guard current() else { return .retained("Execution changed while joining sends.") }
        await scope.linkExecution?.drainPendingStopEffects(for: session)
        guard current() else { return .retained("Execution changed while joining Stops.") }
        // Separate from Send/Stop and terminal publication: these producers can themselves
        // await terminal settlement. Cancellation/state disappearance is not their exit.
        await managedInput.drain(session)
        guard current() else { return .retained("Execution changed while joining managed input.") }
        await selfCompact.drain(session)
        guard current() else { return .retained("Execution changed while joining self-compaction.") }
        await scope.worktrees.waitForTransitions()
        guard current() else { return .retained("Execution changed while joining worktrees.") }
        if let id = session.activeAgentSessionID {
            await scope.persistence.waitForInFlightSave(sessionID: id)
            guard current() else { return .retained("Execution changed while joining saves.") }
        }
        do {
            try await provider.finish()
            guard current() else { return .retained("Provider teardown changed the originating execution.") }
            let idle = try await provider.probe(current)
            guard current(), idle else { return .retained("Provider or domain execution remains unsettled.") }
        } catch {
            return .retained("Provider drain failed: \(error.localizedDescription)")
        }
        guard scope.settlement(for: session).isQuiescent else { return .retained("New mandatory work appeared during the probe.") }
        if scope.settlement(for: session).blockers.contains(.durability) {
            guard let id = session.activeAgentSessionID,
                  case let .unique(writer) = scope.resolveWriter(sessionID: id), writer.session === session,
                  writer.scope === scope else { return .retained("Final save has no exact originating writer.") }
            switch await scope.persistence.flushSaveRequired(writer: writer) {
            case .success: break
            case let .failure(failure): return .retained("Final save failed: \(failure.message)")
            }
            guard current() else { return .retained("The originating execution changed during final save.") }
        }
        guard current(), scope.releaseWriterClaim(for: session) else {
            return .retained("Final synchronous settlement did not acknowledge release.")
        }
        releasedParticipants.insert(ObjectIdentifier(session))
        return .released
    }
}
