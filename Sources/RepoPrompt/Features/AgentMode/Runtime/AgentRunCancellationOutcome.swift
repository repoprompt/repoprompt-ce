import Foundation

/// Runtime-only cancellation generation and binding-qualified managed-stop gate.
struct AgentRunStopState {
    private(set) var cancellationGeneration = UUID()
    private(set) var cancellationCount: UInt64 = 0
    /// Advanced only by an explicit user or managed Stop. Queued cross-session deliveries key
    /// on this, so internal lifecycle cancellations (location change, instruction timeout,
    /// runtime shutdown) never withdraw an overseer's queued message as stopped.
    private(set) var explicitStopGeneration = UUID()
    private(set) var activeManagedStopID: UUID?
    private(set) var activeManagedStopBinding: AgentPersistentSessionBindingIdentity?
    private(set) var managedStopCleanupClaimed = false
    private(set) var managedStopCleanupStarted = false
    private(set) var managedStopClaimedAt: Date?

    mutating func invalidateScheduledStarts() {
        cancellationGeneration = UUID()
        cancellationCount &+= 1
    }

    mutating func invalidateQueuedDeliveries() {
        explicitStopGeneration = UUID()
    }

    mutating func claimManagedStop(id: UUID, binding: AgentPersistentSessionBindingIdentity) -> Bool {
        // An in-place rebind retires the previous gate even if its cleanup timed out. Its
        // late release still carries the old binding and cannot release this successor.
        if activeManagedStopBinding != binding {
            clearManagedStop()
        }
        guard activeManagedStopID == nil else { return false }
        activeManagedStopID = id
        activeManagedStopBinding = binding
        managedStopCleanupClaimed = true
        managedStopCleanupStarted = false
        managedStopClaimedAt = Date()
        return true
    }

    mutating func releaseManagedStop(id: UUID, binding: AgentPersistentSessionBindingIdentity) -> Bool {
        guard activeManagedStopID == id, activeManagedStopBinding == binding else { return false }
        clearManagedStop()
        return true
    }

    private mutating func clearManagedStop() {
        activeManagedStopID = nil
        activeManagedStopBinding = nil
        managedStopCleanupClaimed = false
        managedStopCleanupStarted = false
        managedStopClaimedAt = nil
    }

    mutating func markCleanupStarted(id: UUID, binding: AgentPersistentSessionBindingIdentity) {
        guard activeManagedStopID == id, activeManagedStopBinding == binding else { return }
        managedStopCleanupStarted = true
    }

    mutating func markCleanupUnclaimedIfNeverStarted(id: UUID, binding: AgentPersistentSessionBindingIdentity) {
        guard activeManagedStopID == id, activeManagedStopBinding == binding,
              !managedStopCleanupStarted
        else { return }
        managedStopCleanupClaimed = false
    }

    mutating func forceRetireUnclaimedStop(
        binding: AgentPersistentSessionBindingIdentity?,
        runIsTerminal: Bool = false,
        now: Date = Date(),
        deadlineSeconds: TimeInterval = 30
    ) -> Bool {
        guard activeManagedStopID != nil, activeManagedStopBinding == binding else { return false }
        let startedTeardownTimedOut = runIsTerminal && managedStopCleanupStarted
            && managedStopClaimedAt.map { now.timeIntervalSince($0) >= deadlineSeconds } == true
        guard !managedStopCleanupClaimed || startedTeardownTimedOut else { return false }
        clearManagedStop()
        return true
    }

    func isStopping(binding: AgentPersistentSessionBindingIdentity?) -> Bool {
        activeManagedStopID != nil && activeManagedStopBinding == binding
    }

    #if DEBUG
        mutating func test_ageManagedStopClaim(by interval: TimeInterval) {
            managedStopClaimedAt = managedStopClaimedAt?.addingTimeInterval(-interval)
        }
    #endif
}

/// Captured before a deferred producer creates a task; never refreshed by that producer.
struct AgentRunStartStopFence: Equatable {
    let binding: AgentPersistentSessionBindingIdentity?
    let cancellationGeneration: UUID
    let cancellationCount: UInt64
    let explicitStopGeneration: UUID

    @MainActor
    init(session: AgentTabSession) {
        binding = session.persistentSessionBindingIdentity
        cancellationGeneration = session.stopState.cancellationGeneration
        cancellationCount = session.stopState.cancellationCount
        explicitStopGeneration = session.stopState.explicitStopGeneration
    }

    @MainActor
    func permitsStart(of session: AgentTabSession) -> Bool {
        binding == session.persistentSessionBindingIdentity
            && cancellationGeneration == session.stopState.cancellationGeneration
            && !session.stopState.isStopping(binding: binding)
    }

    /// A queued inbound send survives internal lifecycle cancellations; only an explicit
    /// Stop (or a rebind or in-flight managed Stop) withdraws it.
    @MainActor
    func permitsQueuedDelivery(to session: AgentTabSession) -> Bool {
        binding == session.persistentSessionBindingIdentity
            && explicitStopGeneration == session.stopState.explicitStopGeneration
            && !session.stopState.isStopping(binding: binding)
    }
}

/// Exact-object claim installed synchronously after the management fence.
@MainActor
struct AgentRunCancellationAdmission {
    enum Scope {
        case activeRun
        case pendingStart
    }

    let scope: Scope
    let session: AgentTabSession
    let binding: AgentPersistentSessionBindingIdentity
    let expectedOwnership: AgentRunOwnership?
    let expectedRunID: UUID?
    let cancellationGeneration: UUID
    let pendingStartFence: AgentRunStartStopFence?
    let validateAndClaim: @MainActor () -> Bool

    func claim(for candidate: AgentTabSession) -> Bool {
        guard candidate === session,
              candidate.persistentSessionBindingIdentity == binding,
              candidate.stopState.cancellationGeneration == cancellationGeneration
        else { return false }
        switch scope {
        case .activeRun:
            guard let expectedOwnership, let expectedRunID,
                  candidate.runState.isActive,
                  !candidate.terminalCommitInProgress,
                  candidate.activeRunOwnership == expectedOwnership,
                  candidate.runID == expectedRunID
            else { return false }
        case .pendingStart:
            guard candidate.activeRunOwnership == nil,
                  candidate.mcpFollowUpRunPending || !candidate.pendingInstructions.isEmpty,
                  pendingStartFence?.permitsStart(of: candidate) ?? true
            else { return false }
        }
        return validateAndClaim()
    }
}

/// Causal observation of this cancellation's primary terminal commit, not a lifecycle re-read.
@MainActor
final class AgentRunCancellationOutcomeRecorder {
    let expectedOwnership: AgentRunOwnership
    let expectedRunID: UUID?
    let expectedBinding: AgentPersistentSessionBindingIdentity
    var onAcceptedPrimaryPublication: ((AgentRunTerminalCommitRevision) -> Void)?

    private(set) var initiatedCancellation = false
    private(set) var primaryRevision: AgentRunTerminalCommitRevision?
    private(set) var publicationResult: AgentRunTerminalPublicationResult?
    private(set) var teardownCompleted = false

    init(
        expectedOwnership: AgentRunOwnership,
        expectedRunID: UUID?,
        expectedBinding: AgentPersistentSessionBindingIdentity,
        onAcceptedPrimaryPublication: ((AgentRunTerminalCommitRevision) -> Void)? = nil
    ) {
        self.expectedOwnership = expectedOwnership
        self.expectedRunID = expectedRunID
        self.expectedBinding = expectedBinding
        self.onAcceptedPrimaryPublication = onAcceptedPrimaryPublication
    }

    func recordCancellationInitiated() {
        initiatedCancellation = true
    }

    func recordPrimaryPublication(
        revision: AgentRunTerminalCommitRevision,
        result: AgentRunTerminalPublicationResult,
        session: AgentTabSession
    ) {
        guard initiatedCancellation,
              primaryRevision == nil,
              revision.ownership == expectedOwnership,
              revision.expectedRunID == expectedRunID,
              revision.terminalState == .cancelled
        else { return }
        primaryRevision = revision
        publicationResult = result
        if case .accepted = result, session.persistentSessionBindingIdentity == expectedBinding {
            onAcceptedPrimaryPublication?(revision)
        }
    }

    func recordTeardownCompleted() {
        teardownCompleted = true
    }
}
