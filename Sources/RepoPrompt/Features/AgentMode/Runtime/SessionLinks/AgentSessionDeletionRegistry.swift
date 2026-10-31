import Foundation
import RepoPromptInstrumentation
import RepoPromptPersistence
import RepoPromptShared

/// Provenance follows the admitted deletion attempt, including dependency-injected callers.
struct AgentSessionDeletionOrigin: Equatable {
    let kind: OverseerScopeEnding.DeletionOrigin
    let actorSessionID: UUID?
    static let unknown = Self(kind: .unknown, actorSessionID: nil)
    static func mcpClient(_ caller: UUID? = nil) -> Self {
        .init(kind: .mcpClient, actorSessionID: caller)
    }

    static let userUI = Self(kind: .userUI, actorSessionID: nil)
    static let automaticDiscard = Self(kind: .automaticDiscard, actorSessionID: nil)
    static let composeTabBatch = Self(kind: .composeTabBatch, actorSessionID: nil)
    static func agentCleanup(_ caller: UUID) -> Self {
        .init(kind: .agentCleanup, actorSessionID: caller)
    }

    static let currentTaskLocal = BoxedTaskLocal<Self>(.unknown)
    static var current: Self {
        currentTaskLocal.get()
    }
}

/// Process-owned record of which agent sessions are being, or have been, durably deleted.
///
/// Oversight needs this because deletion is not atomic with respect to the rest of the app: the
/// session file is removed first, and the view-model teardown that finally makes the endpoint
/// disappear from the candidate sweep happens several awaits later. In that window the session still
/// looks like a perfectly good oversight endpoint, so a manual Add or an automatic restore could
/// grant oversight of a transcript that no longer exists.
///
/// A committed tombstone is retained for the whole process lifetime. Deletion is irreversible, so
/// "this UUID was deleted" can never stop being true, and forgetting it would let a stale saved
/// intent reauthorize against a resurrected binding that reused the identifier.
@MainActor
final class AgentSessionDeletionRegistry {
    static let shared = AgentSessionDeletionRegistry(
        scopePersistenceMode: AppLaunchConfiguration.isUnitTestProcess ? .ephemeral : .requiresStore
    )

    private var restorePerfRecorder: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder()

    func installRestorePerfRecorder(_ recorder: any WorkspaceRestorePerfRecording) {
        restorePerfRecorder = recorder
    }

    enum State: Equatable {
        /// A durable deletion is running. New oversight is transiently blocked, but existing intent
        /// and grants remain ordinary because this attempt can still fail.
        case inProgress(attemptID: UUID)
        /// The file is gone (or was already absent). Permanent for this process.
        case committed
    }

    enum AdmissionError: LocalizedError {
        case scopePersistenceUnavailable(String)

        var errorDescription: String? {
            switch self {
            case let .scopePersistenceUnavailable(reason): reason
            }
        }
    }

    /// Identifies one deletion attempt so a failure can clear *only* its own in-progress mark.
    ///
    /// A retry after a failure allocates a new attempt, and a late failure report from the previous
    /// attempt must not reopen a session the retry already committed.
    struct AttemptToken: Equatable {
        let sessionID: UUID
        let attemptID: UUID
        var origin: AgentSessionDeletionOrigin = .unknown
    }

    private var statesBySession: [UUID: State] = [:]
    /// Every admitted physical deletion, including overlaps and retries of an already-committed UUID.
    private var activeAttemptIDsBySession: [UUID: Set<UUID>] = [:]
    /// Shared completion for committed cleanup. Duplicate commit callers await the same authority/store work.
    private var commitTasksBySession: [UUID: Task<Void, Never>] = [:]
    /// The first termination proof is permanent: settling later cannot make an uncertain freeze clean.
    private var terminationFreezeAllowsRestoration: Bool?
    private let scopePersistenceMode: DelegationScopeRuntime.PersistenceMode
    private var scopePersistenceAdmission: (@MainActor () -> String?)?
    /// Establishments that were already admitted before deletion began wait here for its reversible
    /// phase to settle. Fresh Add/restore never waits: admission refuses `.inProgress` immediately.
    private var settlementWaitersBySession: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Installed by the runtime bridge. Fired after the tombstone is recorded, so anything the
    /// observer does already sees the session as permanently gone.
    ///
    /// Deliberately `async` and awaited by the commit phase. A fire-and-forget task would let the
    /// deleting caller return — and go on to metadata cleanup, the next batch file, or view-model
    /// teardown — while the runtime authority for that UUID was still live and its saved intent
    /// still on disk.
    var commitObserver: (@MainActor (UUID, AgentSessionDeletionOrigin, Bool?) async -> Void)?
    /// Fired on every transition so candidate eligibility and launch reconciliation can re-read.
    var changeObserver: (@MainActor () -> Void)?

    private init(scopePersistenceMode: DelegationScopeRuntime.PersistenceMode) {
        self.scopePersistenceMode = scopePersistenceMode
    }

    /// The existing scope owner decides readiness live; a missing owner never permits deletion.
    func installScopePersistenceAdmission(for scopes: DelegationScopeRuntime) {
        scopePersistenceAdmission = { [weak scopes] in
            guard let scopes else {
                return "Session deletion is unavailable because scope authority persistence is not ready."
            }
            return scopes.durableDeletionUnavailableReason
        }
    }

    private var scopePersistenceUnavailableReason: String? {
        if let scopePersistenceAdmission { return scopePersistenceAdmission() }
        switch scopePersistenceMode {
        case .ephemeral: return nil
        case .requiresStore:
            return "Session deletion is unavailable because scope authority persistence is not ready."
        }
    }

    // MARK: - Reporter phases

    /// Closes reported per-session deletion admission and proves that those removals have settled.
    /// Whole-workspace deletion and storage replacement do not report through this registry.
    ///
    /// An admitted removal or its committed callback can still revoke scope authority after the
    /// caller freezes it. If either is pending, this launch must leave its scope file open instead.
    /// The proof and admission fence are synchronous on MainActor, and repeated calls keep the first
    /// result even after pending work settles.
    func freezeNewDeletionAdmissionForTermination() -> Bool {
        if let terminationFreezeAllowsRestoration { return terminationFreezeAllowsRestoration }
        let allowsRestoration = activeAttemptIDsBySession.isEmpty && commitTasksBySession.isEmpty
        terminationFreezeAllowsRestoration = allowsRestoration
        return allowsRestoration
    }

    /// Marks a deletion in progress **before** any irreversible work begins.
    ///
    /// Already-committed sessions stay committed: a second delete of the same UUID must not downgrade
    /// a permanent tombstone back to a reversible in-progress mark.
    /// Throws `CancellationError` after termination closes admission; no token is admitted then.
    @discardableResult
    func beginDurableDeletion(sessionID: UUID, origin: AgentSessionDeletionOrigin = .current) throws -> AttemptToken {
        guard terminationFreezeAllowsRestoration == nil else { throw CancellationError() }
        if let reason = scopePersistenceUnavailableReason {
            throw AdmissionError.scopePersistenceUnavailable(reason)
        }
        let token = AttemptToken(sessionID: sessionID, attemptID: UUID(), origin: origin)
        activeAttemptIDsBySession[sessionID, default: []].insert(token.attemptID)
        guard statesBySession[sessionID] != .committed else { return token }
        if statesBySession[sessionID] == nil { ServerNetworkManager.catalogAdvertisementDidChange() }
        statesBySession[sessionID] = .inProgress(attemptID: token.attemptID)
        #if DEBUG
            logTransition("begin", sessionID: sessionID)
        #endif
        changeObserver?()
        return token
    }

    /// Clears only the matching attempt. Durable intent is preserved: nothing was deleted.
    func didFailDurableDeletion(_ token: AttemptToken) {
        guard activeAttemptIDsBySession[token.sessionID]?.remove(token.attemptID) != nil else { return }
        if statesBySession[token.sessionID] == .committed {
            if activeAttemptIDsBySession[token.sessionID]?.isEmpty == true {
                activeAttemptIDsBySession.removeValue(forKey: token.sessionID)
            }
            return
        }
        if let remaining = activeAttemptIDsBySession[token.sessionID], let attemptID = remaining.first {
            statesBySession[token.sessionID] = .inProgress(attemptID: attemptID)
            return
        }
        activeAttemptIDsBySession.removeValue(forKey: token.sessionID)
        ServerNetworkManager.catalogAdvertisementDidChange()
        statesBySession.removeValue(forKey: token.sessionID)
        resumeSettlementWaiters(for: token.sessionID)
        #if DEBUG
            logTransition("failed", sessionID: token.sessionID)
        #endif
        changeObserver?()
    }

    /// Records the permanent tombstone. Deliberately nonthrowing and total.
    ///
    /// Whatever the observer does with the news — revoking authority, removing durable intent,
    /// terminalizing launch entries — a failure there cannot pretend the deletion rolled back, so
    /// this method has no failure channel to offer it.
    func didCommitDurableDeletion(_ token: AttemptToken, fileRemoved: Bool? = nil) async {
        if statesBySession[token.sessionID] == .committed {
            await commitTasksBySession[token.sessionID]?.value
            activeAttemptIDsBySession[token.sessionID]?.remove(token.attemptID)
            if activeAttemptIDsBySession[token.sessionID]?.isEmpty == true {
                activeAttemptIDsBySession.removeValue(forKey: token.sessionID)
            }
            return
        }
        guard activeAttemptIDsBySession[token.sessionID]?.contains(token.attemptID) == true else { return }
        ServerNetworkManager.catalogAdvertisementDidChange()
        statesBySession[token.sessionID] = .committed
        activeAttemptIDsBySession[token.sessionID]?.remove(token.attemptID)
        if activeAttemptIDsBySession[token.sessionID]?.isEmpty == true {
            activeAttemptIDsBySession.removeValue(forKey: token.sessionID)
        }
        // Release in-flight establishment fences before awaiting the bridge's commit observer. They
        // will observe `.committed`, abandon/revoke their own work, and therefore cannot deadlock the
        // observer that is waiting to invalidate the same UUID process-wide.
        resumeSettlementWaiters(for: token.sessionID)
        #if DEBUG
            logTransition("committed", sessionID: token.sessionID)
        #endif
        let observer = commitObserver
        let changeObserver = changeObserver
        let task = Task { @MainActor in
            await observer?(token.sessionID, token.origin, fileRemoved)
            changeObserver?()
        }
        commitTasksBySession[token.sessionID] = task
        await task.value
        if commitTasksBySession[token.sessionID] == task {
            commitTasksBySession.removeValue(forKey: token.sessionID)
        }
    }

    #if DEBUG
        /// Debug-only, opt-in tombstone transitions. The session is identified by a truncated prefix
        /// only: a tombstone is a fact about a lifecycle, and the full UUID would make this log an
        /// index of the user's deleted transcripts.
        private func logTransition(_ transition: String, sessionID: UUID) {
            restorePerfRecorder.event(
                "oversight.deletion",
                fields: [
                    "transition": transition,
                    "session": restorePerfRecorder.shortID(sessionID),
                    "tracked": String(statesBySession.count)
                ]
            )
        }
    #endif

    // MARK: - Queries

    func state(forSessionID sessionID: UUID) -> State? {
        statesBySession[sessionID]
    }

    /// Whether this session is mid-deletion.
    ///
    /// Transient by construction: the removal can still fail, and `didFailDurableDeletion` restores
    /// ordinary eligibility. Nothing durable — no revocation, no intent removal, no terminal launch
    /// entry — may be decided from this alone.
    func isDeletionInProgress(sessionID: UUID) -> Bool {
        if case .inProgress = statesBySession[sessionID] { return true }
        return false
    }

    /// Whether oversight must refuse to *start* anything for this session.
    ///
    /// True while a deletion is merely running as well as after it commits, because a transcript that
    /// is being destroyed is not something new oversight may be granted against. This is the check
    /// for admission — Add, restoration, and operation-time authorization — never for retirement.
    func blocksNewOversight(sessionID: UUID) -> Bool {
        statesBySession[sessionID] != nil
    }

    /// Whether this session is permanently gone.
    ///
    /// The *only* deletion state that may end a saved relationship or revoke a live grant. An
    /// in-progress attempt that later fails must leave both exactly as they were.
    func isPermanentlyDeleted(sessionID: UUID) -> Bool {
        statesBySession[sessionID] == .committed
    }

    /// Waits only for an already-running deletion attempt to resolve, then returns its stable state.
    ///
    /// Used between suspension points of an establishment that was admitted before deletion began.
    /// A failed attempt returns `nil` and lets the same establishment continue; a committed one is a
    /// permanent fence. There is no polling and no timeout—the deletion reporter must always publish
    /// failure or commit for the irreversible operation it bracketed.
    func waitForDeletionAttemptToSettle(sessionID: UUID) async -> State? {
        while case .inProgress = statesBySession[sessionID] {
            let waiterID = UUID()
            await withCheckedContinuation { continuation in
                // MainActor is reentrant, so recheck synchronously while registering: the attempt may
                // have settled between the loop condition and this continuation body.
                guard case .inProgress = statesBySession[sessionID] else {
                    continuation.resume()
                    return
                }
                settlementWaitersBySession[sessionID, default: [:]][waiterID] = continuation
            }
        }
        return statesBySession[sessionID]
    }

    private func resumeSettlementWaiters(for sessionID: UUID) {
        guard let waiters = settlementWaitersBySession.removeValue(forKey: sessionID) else { return }
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    #if DEBUG
        static func test_instance(
            scopePersistenceMode: DelegationScopeRuntime.PersistenceMode
        ) -> AgentSessionDeletionRegistry {
            AgentSessionDeletionRegistry(scopePersistenceMode: scopePersistenceMode)
        }

        /// Test seam. Tombstones are permanent by design, so only tests may clear them.
        func test_reset() {
            terminationFreezeAllowsRestoration = nil
            scopePersistenceAdmission = nil
            if !statesBySession.isEmpty { ServerNetworkManager.catalogAdvertisementDidChange() }
            statesBySession.removeAll()
            activeAttemptIDsBySession.removeAll()
            commitTasksBySession.removeAll()
            let sessions = Array(settlementWaitersBySession.keys)
            for sessionID in sessions {
                resumeSettlementWaiters(for: sessionID)
            }
        }
    #endif
}

/// MainActor-hopping façade for the non-isolated deletion paths.
///
/// `AgentSessionDataService` is an actor and the MCP cleanup service runs off the main actor, but the
/// registry has to be MainActor-isolated because everything that consumes it — candidate
/// construction, the runtime bridge, the launch coordinator — already is.
enum AgentSessionDurableDeletionReporter {
    static func beginDurableDeletion(sessionID: UUID, origin: AgentSessionDeletionOrigin = .current) async throws -> AgentSessionDeletionRegistry.AttemptToken {
        try await MainActor.run { try AgentSessionDeletionRegistry.shared.beginDurableDeletion(sessionID: sessionID, origin: origin) }
    }

    static func didFailDurableDeletion(_ token: AgentSessionDeletionRegistry.AttemptToken) async {
        await MainActor.run { AgentSessionDeletionRegistry.shared.didFailDurableDeletion(token) }
    }

    static func didCommitDurableDeletion(_ token: AgentSessionDeletionRegistry.AttemptToken, fileRemoved: Bool? = nil) async {
        await AgentSessionDeletionRegistry.shared.didCommitDurableDeletion(token, fileRemoved: fileRemoved)
    }
}

/// Refused at the destructive commit point: the caller's authority no longer holds.
struct AgentSessionDestructiveCommitRefused: Error, Equatable {}

extension AgentSessionDataService {
    /// Caller-supplied authority fence evaluated at the destructive commit point, after admission
    /// and writer draining and immediately before the file is removed. A delete authorized earlier
    /// (for example under Overseer full access) must not proceed if that authority ended meanwhile.
    nonisolated static let destructiveCommitFence = BoxedTaskLocal<(@Sendable () async -> Bool)?>(nil)
}
