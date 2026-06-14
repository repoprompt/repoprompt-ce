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

    init(
        id: UUID = UUID(),
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.createdAt = createdAt
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

    private var autoEditOverridesByScope: [ApplyEditsApprovalScope: Bool] = [:]
    private var pendingByScope: [ApplyEditsApprovalScope: PendingRecord] = [:]
    private var subscriptions: [ApplyEditsApprovalScope: [UUID: SnapshotContinuation]] = [:]

    func autoEditEnabled(for scope: ApplyEditsApprovalScope) -> Bool {
        autoEditOverridesByScope[scope] ?? Self.globalDefaultAutoEditEnabled()
    }

    func setAutoEditEnabled(
        _ enabled: Bool,
        for scope: ApplyEditsApprovalScope,
        updateGlobalDefault: Bool
    ) {
        autoEditOverridesByScope[scope] = enabled
        if updateGlobalDefault {
            Self.setGlobalDefaultAutoEditEnabled(enabled)
        }
        publishSnapshot(for: scope)
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
        }, onCancel: {
            Task {
                await self.cancelPendingReview(scope: scope, reason: cancellationReason)
            }
        })
        EditFlowPerf.end(
            EditFlowPerf.Stage.ApplyEdits.approvalWait,
            perfState,
            EditFlowPerf.Dimensions(outcome: decision.editFlowPerfOutcome)
        )
        return decision
    }

    func resolveReview(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        resolvePendingReviewIfMatching(scope: scope, reviewID: reviewID, decision: decision)
    }

    func cancelPendingReview(scope: ApplyEditsApprovalScope, reason: String) {
        guard let record = pendingByScope[scope] else { return }
        finishPendingReview(scope: scope, record: record, decision: .cancelled(reason: reason))
    }

    func cleanupScope(_ scope: ApplyEditsApprovalScope) {
        cancelPendingReview(scope: scope, reason: "Approval scope cleaned up")
        autoEditOverridesByScope.removeValue(forKey: scope)
        finishAndRemoveAllSubscriptions(for: scope)
    }

    func cleanupWindowScopes(windowID: Int, reason: String) {
        var scopesToCleanup = Set<ApplyEditsApprovalScope>()
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

    private func resolvePendingReviewIfMatching(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        guard let record = pendingByScope[scope], record.review.id == reviewID else { return }
        finishPendingReview(scope: scope, record: record, decision: decision)
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
            pendingReview: pendingByScope[scope]?.review
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
