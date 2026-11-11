import Foundation

struct ApplyEditsApprovalScope: Hashable {
    let windowID: Int
    let tabID: UUID
}

struct PendingApplyEditsReview: Identifiable, Hashable {
    let id: UUID
    let scope: ApplyEditsApprovalScope
    let path: String
    let unifiedDiff: String
    let createdAt: Date
    /// Process-local admission ordering, never wall-clock cancellation or persisted identity.
    let admissionTime: ContinuousClock.Instant

    init(
        id: UUID = UUID(),
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        createdAt: Date = Date(),
        admissionTime: ContinuousClock.Instant = .now
    ) {
        self.id = id
        self.scope = scope
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.createdAt = createdAt
        self.admissionTime = admissionTime
    }
}

enum ApplyEditsReviewDecision: Hashable {
    case accept
    case reject(reason: String)
    case timeout
    case cancelled(reason: String)

    var editFlowPerfOutcome: String {
        switch self {
        case .accept:
            "accept"
        case .reject:
            "reject"
        case .timeout:
            "timeout"
        case .cancelled:
            "cancelled"
        }
    }
}

struct ApplyEditsApprovalSnapshot: Equatable {
    let scope: ApplyEditsApprovalScope
    var autoEditEnabled: Bool
    var pendingReview: PendingApplyEditsReview?
    var syncLease: UUID?
}

actor ApplyEditsApprovalStore: Sendable {
    static let shared = ApplyEditsApprovalStore()

    private static let autoEditEnabledDefaultsKey = "agentModeAutoEditEnabled"

    nonisolated static func globalDefaultAutoEditEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: autoEditEnabledDefaultsKey) as? Bool {
            return value
        }
        return true
    }

    nonisolated static func setGlobalDefaultAutoEditEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoEditEnabledDefaultsKey)
    }

    private struct PendingRecord {
        let review: PendingApplyEditsReview
        let continuation: CheckedContinuation<ApplyEditsReviewDecision, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private typealias SnapshotContinuation = AsyncStream<ApplyEditsApprovalSnapshot>.Continuation

    /// One resource revision per existing scope entry. A nil value still follows the global
    /// default; preparing a conditional override does not freeze that fallback.
    private struct AutoEditEntry {
        var value: Bool?
        var revision = UUID()
        var owner: UUID?
        var restoreValue: Bool?
        var syncSeedOwner: UUID?
    }

    struct AutoEditOverride: Equatable {
        fileprivate let scope: ApplyEditsApprovalScope
        fileprivate let revision: UUID
        fileprivate let expectedValue: Bool
        let restoreValue: Bool
        fileprivate let id = UUID()
    }

    struct SyncPreparation {
        fileprivate let scope: ApplyEditsApprovalScope
        fileprivate let revision: UUID
        fileprivate let autoEditRevision: UUID?
    }

    /// Resource ownership, not session-writer authority. Preparation does not replace a
    /// lease or seed a value; admission is revalidated by the runtime before commit.
    private var syncRevisions: [ApplyEditsApprovalScope: UUID] = [:]
    private var syncLeases: [ApplyEditsApprovalScope: UUID] = [:]

    func prepareSync(scope: ApplyEditsApprovalScope) -> SyncPreparation {
        let revision = syncRevisions[scope] ?? UUID()
        syncRevisions[scope] = revision
        return .init(scope: scope, revision: revision, autoEditRevision: autoEditOverridesByScope[scope]?.revision)
    }

    func abandonSync(_ preparation: SyncPreparation) {
        guard syncRevisions[preparation.scope] == preparation.revision,
              syncLeases[preparation.scope] == nil else { return }
        syncRevisions.removeValue(forKey: preparation.scope)
    }

    /// Compare and commit without suspension. A competing begin or cleanup invalidates
    /// the preparation, including cleanup back to an absent entry (no nil/ nil ABA).
    func commitSync(
        _ preparation: SyncPreparation, initialValue: Bool,
        replacePayload: Bool
    ) -> (lease: UUID, id: UUID, stream: AsyncStream<ApplyEditsApprovalSnapshot>)? {
        let scope = preparation.scope
        guard syncRevisions[scope] == preparation.revision else { return nil }
        let entry = autoEditOverridesByScope[scope]
        // Ownership follows the actual store seed, not an intermediate runtime begin
        // that may never have committed. Manual writes clear this marker.
        let ownsSeed = entry?.syncSeedOwner != nil && entry?.syncSeedOwner == syncLeases[scope]
        let lease = UUID()
        syncRevisions[scope] = lease
        syncLeases[scope] = lease
        if entry == nil || (
            (replacePayload || ownsSeed)
                && entry?.owner == nil && entry?.revision == preparation.autoEditRevision
        ) {
            autoEditOverridesByScope[scope] = AutoEditEntry(value: initialValue, syncSeedOwner: lease)
        } else if var entry, entry.syncSeedOwner != nil {
            entry.syncSeedOwner = lease
            autoEditOverridesByScope[scope] = entry
        }
        publishSnapshot(for: scope)
        let subscription = subscribe(scope: scope)
        return (lease, subscription.id, subscription.stream)
    }

    @discardableResult
    func setAutoEditEnabled(_ enabled: Bool, for scope: ApplyEditsApprovalScope, lease: UUID, updateGlobalDefault: Bool) -> Bool {
        guard syncLeases[scope] == lease else { return false }
        setAutoEditEnabled(enabled, for: scope, updateGlobalDefault: updateGlobalDefault)
        return true
    }

    func cleanupSync(scope: ApplyEditsApprovalScope, lease: UUID, admittedAtOrBefore cutoff: ContinuousClock.Instant) {
        guard syncLeases[scope] == lease else { return }
        cancelPendingReview(scope: scope, reason: "Approval scope cleaned up", admittedAtOrBefore: cutoff)
        syncLeases.removeValue(forKey: scope)
        syncRevisions.removeValue(forKey: scope)
        // Work admitted after teardown remains independently settleable.
        if pendingByScope[scope] != nil {
            publishSnapshot(for: scope)
            return
        }
        autoEditOverridesByScope.removeValue(forKey: scope)
        finishAndRemoveAllSubscriptions(for: scope)
    }

    private var autoEditOverridesByScope: [ApplyEditsApprovalScope: AutoEditEntry] = [:]
    private var pendingByScope: [ApplyEditsApprovalScope: PendingRecord] = [:]
    private var subscriptions: [ApplyEditsApprovalScope: [UUID: SnapshotContinuation]] = [:]

    #if DEBUG
        private var test_beforeRequestCancellation: (@Sendable () async -> Void)?
        private var test_afterRequestCancellation: (@Sendable () -> Void)?
        private var test_onAutoEditOverridePrepared: (@Sendable (ApplyEditsApprovalScope) -> Void)?

        func test_setAutoEditOverridePreparedHook(_ hook: (@Sendable (ApplyEditsApprovalScope) -> Void)?) {
            test_onAutoEditOverridePrepared = hook
        }

        func test_setRequestCancellationHooks(
            before: (@Sendable () async -> Void)?, after: (@Sendable () -> Void)?
        ) {
            test_beforeRequestCancellation = before
            test_afterRequestCancellation = after
        }
    #endif

    func autoEditEnabled(for scope: ApplyEditsApprovalScope) -> Bool {
        autoEditOverridesByScope[scope]?.value ?? Self.globalDefaultAutoEditEnabled()
    }

    func setAutoEditEnabled(
        _ enabled: Bool,
        for scope: ApplyEditsApprovalScope,
        updateGlobalDefault: Bool
    ) {
        // Every ordinary write supersedes an outstanding override, including a same-value
        // manual write. Old cleanup cannot restore over that choice.
        autoEditOverridesByScope[scope] = AutoEditEntry(value: enabled)
        if updateGlobalDefault {
            Self.setGlobalDefaultAutoEditEnabled(enabled)
        }
        publishSnapshot(for: scope)
    }

    func prepareAutoEditOverride(for scope: ApplyEditsApprovalScope) -> AutoEditOverride {
        let entry = autoEditOverridesByScope[scope] ?? AutoEditEntry()
        autoEditOverridesByScope[scope] = entry
        let receipt = AutoEditOverride(
            scope: scope, revision: entry.revision,
            expectedValue: autoEditEnabled(for: scope),
            restoreValue: entry.restoreValue ?? autoEditEnabled(for: scope)
        )
        #if DEBUG
            test_onAutoEditOverridePrepared?(scope)
        #endif
        return receipt
    }

    /// No suspension between comparison and mutation. A cancelled, cleaned-up, or superseded
    /// request cannot arrive late and overwrite the next occupant of this resource address.
    func applyAutoEditOverride(_ receipt: AutoEditOverride) -> Bool {
        guard var entry = autoEditOverridesByScope[receipt.scope],
              entry.revision == receipt.revision,
              autoEditEnabled(for: receipt.scope) == receipt.expectedValue else { return false }
        entry.value = true
        entry.owner = receipt.id
        entry.restoreValue = receipt.restoreValue
        entry.revision = UUID()
        autoEditOverridesByScope[receipt.scope] = entry
        publishSnapshot(for: receipt.scope)
        return true
    }

    func releaseAutoEditOverride(_ receipt: AutoEditOverride) {
        guard var entry = autoEditOverridesByScope[receipt.scope] else { return }
        // Even a superseded restore must project the resource's actual value, rather than
        // leave the detached session's speculative restore visible in an attached presenter.
        defer { publishSnapshot(for: receipt.scope) }
        if entry.owner == receipt.id {
            entry.value = receipt.restoreValue
            entry.owner = nil
            entry.restoreValue = nil
            entry.revision = UUID()
            autoEditOverridesByScope[receipt.scope] = entry
        } else if entry.revision == receipt.revision {
            // Release may beat apply to the actor. Invalidate that pending request without
            // changing the effective value, retaining tombstones, or retrying on a successor.
            entry.revision = UUID()
            autoEditOverridesByScope[receipt.scope] = entry
        }
    }

    func requestReview(
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        timeoutSeconds: TimeInterval
    ) async -> ApplyEditsReviewDecision {
        let replaceReason = "Replaced by newer apply_edits preview"
        cancelPendingReview(scope: scope, reason: replaceReason)

        let review = PendingApplyEditsReview(
            scope: scope,
            path: path,
            unifiedDiff: unifiedDiff
        )
        let cancellationReason = "Cancelled while awaiting apply_edits review"
        let timeoutNanoseconds = timeoutIntervalToNanoseconds(timeoutSeconds)

        let perfState = EditFlowPerf.begin(EditFlowPerf.Stage.ApplyEdits.approvalWait)
        let decision: ApplyEditsReviewDecision = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled(reason: cancellationReason))
                    return
                }

                let timeoutTask = Task { [reviewID = review.id, scope, timeoutNanoseconds] in
                    if timeoutNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    }
                    self.resolvePendingReviewIfMatching(
                        scope: scope,
                        reviewID: reviewID,
                        decision: .timeout
                    )
                }

                pendingByScope[scope] = PendingRecord(
                    review: review,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                publishSnapshot(for: scope)
            }
        }, onCancel: { [reviewID = review.id] in
            Task {
                await self.cancelRequest(scope: scope, reviewID: reviewID, reason: cancellationReason)
            }
        })
        EditFlowPerf.end(
            EditFlowPerf.Stage.ApplyEdits.approvalWait,
            perfState,
            EditFlowPerf.Dimensions(outcome: decision.editFlowPerfOutcome)
        )
        return decision
    }

    /// Caller cancellation may arrive after replacement, response, or timeout. Its public
    /// address is not authority to cancel a later request in that same approval scope.
    private func cancelRequest(scope: ApplyEditsApprovalScope, reviewID: UUID, reason: String) async {
        #if DEBUG
            await test_beforeRequestCancellation?()
        #endif
        resolvePendingReviewIfMatching(scope: scope, reviewID: reviewID, decision: .cancelled(reason: reason))
        #if DEBUG
            test_afterRequestCancellation?()
        #endif
    }

    @discardableResult
    func resolveReview(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) -> Bool {
        resolvePendingReviewIfMatching(scope: scope, reviewID: reviewID, decision: decision)
    }

    func cancelPendingReview(
        scope: ApplyEditsApprovalScope,
        reason: String,
        admittedAtOrBefore cutoff: ContinuousClock.Instant? = nil
    ) {
        guard let record = pendingByScope[scope],
              cutoff.map({ record.review.admissionTime <= $0 }) != false else { return }
        finishPendingReview(scope: scope, record: record, decision: .cancelled(reason: reason))
    }

    func cleanupScope(_ scope: ApplyEditsApprovalScope) {
        syncLeases.removeValue(forKey: scope)
        syncRevisions.removeValue(forKey: scope)
        cancelPendingReview(scope: scope, reason: "Approval scope cleaned up")
        autoEditOverridesByScope.removeValue(forKey: scope)
        finishAndRemoveAllSubscriptions(for: scope)
    }

    func cleanupWindowScopes(windowID: Int, reason: String) {
        var scopesToCleanup = Set(syncRevisions.keys.filter { $0.windowID == windowID })
        for scope in autoEditOverridesByScope.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        for scope in pendingByScope.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        for scope in subscriptions.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        guard !scopesToCleanup.isEmpty else { return }
        for scope in scopesToCleanup {
            syncLeases.removeValue(forKey: scope)
            syncRevisions.removeValue(forKey: scope)
            cancelPendingReview(scope: scope, reason: reason)
            autoEditOverridesByScope.removeValue(forKey: scope)
            finishAndRemoveAllSubscriptions(for: scope)
        }
    }

    func subscribe(scope: ApplyEditsApprovalScope) -> (id: UUID, stream: AsyncStream<ApplyEditsApprovalSnapshot>) {
        let id = UUID()
        let streamPair = AsyncStream.makeStream(of: ApplyEditsApprovalSnapshot.self)
        let stream = streamPair.stream
        let continuation = streamPair.continuation
        var scopedSubscriptions = subscriptions[scope] ?? [:]
        scopedSubscriptions[id] = continuation
        subscriptions[scope] = scopedSubscriptions
        continuation.yield(snapshot(for: scope))
        continuation.onTermination = { [scope, id] _ in
            Task {
                await self.removeSubscription(scope: scope, id: id, finishContinuation: false)
            }
        }
        return (id, stream)
    }

    func unsubscribe(scope: ApplyEditsApprovalScope, id: UUID) {
        removeSubscription(scope: scope, id: id, finishContinuation: true)
    }

    #if DEBUG
        func test_subscriptionCount() -> Int {
            subscriptions.values.reduce(0) { $0 + $1.count }
        }
    #endif

    @discardableResult
    private func resolvePendingReviewIfMatching(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) -> Bool {
        guard let record = pendingByScope[scope], record.review.id == reviewID else { return false }
        finishPendingReview(scope: scope, record: record, decision: decision)
        return true
    }

    private func finishPendingReview(
        scope: ApplyEditsApprovalScope,
        record: PendingRecord,
        decision: ApplyEditsReviewDecision
    ) {
        record.timeoutTask?.cancel()
        pendingByScope.removeValue(forKey: scope)
        publishSnapshot(for: scope)
        record.continuation.resume(returning: decision)
    }

    private func snapshot(for scope: ApplyEditsApprovalScope) -> ApplyEditsApprovalSnapshot {
        ApplyEditsApprovalSnapshot(
            scope: scope,
            autoEditEnabled: autoEditEnabled(for: scope),
            pendingReview: pendingByScope[scope]?.review,
            syncLease: syncLeases[scope]
        )
    }

    private func publishSnapshot(for scope: ApplyEditsApprovalScope) {
        guard let scopedSubscriptions = subscriptions[scope], !scopedSubscriptions.isEmpty else { return }
        let nextSnapshot = snapshot(for: scope)
        for continuation in scopedSubscriptions.values {
            continuation.yield(nextSnapshot)
        }
    }

    private func removeSubscription(
        scope: ApplyEditsApprovalScope,
        id: UUID,
        finishContinuation: Bool
    ) {
        guard var scopedSubscriptions = subscriptions[scope] else { return }
        guard let continuation = scopedSubscriptions.removeValue(forKey: id) else { return }
        if scopedSubscriptions.isEmpty {
            subscriptions.removeValue(forKey: scope)
        } else {
            subscriptions[scope] = scopedSubscriptions
        }
        if finishContinuation {
            continuation.finish()
        }
    }

    private func finishAndRemoveAllSubscriptions(for scope: ApplyEditsApprovalScope) {
        guard let scopedSubscriptions = subscriptions.removeValue(forKey: scope) else { return }
        for continuation in scopedSubscriptions.values {
            continuation.finish()
        }
    }

    private func timeoutIntervalToNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        let normalizedSeconds = max(0, timeoutSeconds)
        let maxSafeSeconds = Double(UInt64.max) / 1_000_000_000
        let cappedSeconds = min(normalizedSeconds, maxSafeSeconds)
        return UInt64(cappedSeconds * 1_000_000_000)
    }
}
