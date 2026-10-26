import SwiftUI

// These types split AgentModeChatDetailView's transcript scroll state into
// low-frequency reactive view state and high-frequency engine state.

struct AgentTranscriptScrollViewState {
    var presentation = TranscriptPresentationViewState()
    var attachment = FollowAttachmentState()
    var bottomAffordance = AgentTranscriptBottomAffordanceState()
}

// MARK: - 2a. TranscriptPresentationViewState

struct TranscriptPresentationViewState {
    var legacyIsNearBottom = false
    var transcriptScrollResetRevision = 0
    var activationRepaintRemountKey: AgentTranscriptRehydrateRetryKey?
    var activationRepaintRemountCount = 0
    var showCompressedHistory = false
    var transcriptBlockExpansion: [String: Bool] = [:]
    var transcriptBlockDefaultExpansion: [String: Bool] = [:]
    var composerBottomInset: CGFloat = 0
    var transcriptBottomClearance: CGFloat = 0
    var didChatChange = false
}

struct AgentTranscriptBottomAffordanceState: Equatable {
    var isNearBottom = true

    @discardableResult
    mutating func update(distanceToBottom: CGFloat, threshold: CGFloat) -> Bool {
        let nextIsNearBottom = distanceToBottom <= threshold
        guard nextIsNearBottom != isNearBottom else { return false }
        isNearBottom = nextIsNearBottom
        return true
    }
}

/// Non-reactive scroll engine that owns high-frequency orchestration state.
/// Stored as `@StateObject` for stable identity, but has NO `@Published`
/// properties — mutations must never trigger SwiftUI view invalidation.
@MainActor
final class AgentTranscriptScrollEngine: ObservableObject {
    var scrollMetrics = AgentTranscriptScrollMetrics()
    var pendingCompressionRestoreStrategy: AgentTranscriptCompressionRestoreStrategy?
    var hasUserInteractedWithScroll = false
    var isUserInteractingWithScroll = false
    var pinnedMaintenance = PinnedMaintenanceState()
    var smoothSend = SmoothSendEnvelopeState()
    var rehydrate = RehydrateRestoreState()
    var detachedRebase = DetachedRebaseCaptureState()
    var userScroll = UserScrollInteractionState()
    var bottomScrollOutcome = BottomScrollOutcomeState()
    var programmaticScrollGate = ProgrammaticScrollGate()
    #if DEBUG
        var stressTelemetryState = AgentChatStressTelemetryState()
        var lastTelemetryDistanceToBottom: CGFloat?
    #endif

    func cancelScheduledWork() {
        programmaticScrollGate.cancel()
        pinnedMaintenance.gate.cancel()
        pinnedMaintenance.pendingRequest = nil
        pinnedMaintenance.deferredRequestAfterSmoothSend = nil
        smoothSend.launchGate.cancel()
        bottomScrollOutcome.reset()
    }

    nonisolated deinit {
        // Defensive cleanup. deinit does not run on the main actor.
        // Task.cancel() is safe from any thread; DispatchWorkItem.cancel()
        // is also thread-safe. Access the underlying cancellables directly.
        bottomScrollOutcome.deferredResolveTask?.cancel()
    }
}

// MARK: - 2b. FollowAttachmentState

struct FollowAttachmentState {
    var isPinnedToLiveBottom = true
    var userDetachedAutoFollow = false
    var shouldRestorePinnedBottomAfterBlocker = false
    var manualDetachOverrideUntil: Date?
    var repinGraceState: RepinGraceState?
}

// MARK: - 2c. PinnedMaintenanceState

struct PinnedMaintenanceState {
    var gate = WorkItemGate()
    var generation: UInt64 = 0
    var pendingRequest: AgentTranscriptPinnedMaintenanceRequest?
    var deferredRequestAfterSmoothSend: AgentTranscriptPinnedMaintenanceRequest?
    var lastRequestAt: Date?
    var lastSettleAt: Date?
    var bottomClearanceSuppressionUntil: Date?
    var protectionUntil: Date?
    var transcriptChangeSuppressionUntil: Date?
    var idleTransitionManualDetachUntil: Date?
    var lastTranscriptChangeRevision: Int?

    mutating func invalidate(reason _: AgentTranscriptPinnedMaintenanceInvalidationReason) {
        generation &+= 1
        gate.cancel()
        pendingRequest = nil
        deferredRequestAfterSmoothSend = nil
    }

    mutating func makeRequest(
        source: PinnedBottomRequestSource,
        now: Date = Date()
    ) -> AgentTranscriptPinnedMaintenanceRequest {
        .init(source: source, generation: generation, requestedAt: now)
    }

    func isCurrent(_ request: AgentTranscriptPinnedMaintenanceRequest?) -> Bool {
        guard let request else { return false }
        return request.generation == generation
    }

    mutating func reset() {
        invalidate(reason: .staleSuppression)
        bottomClearanceSuppressionUntil = nil
        idleTransitionManualDetachUntil = nil
    }
}

// MARK: - 2d. SmoothSendEnvelopeState

struct SmoothSendEnvelopeState {
    var state: SmoothPinnedSendState?
    var launchGate = WorkItemGate()
    var lastSeenUserMessageID: UUID?
}

// MARK: - 2e. RehydrateRestoreState

struct RehydrateRestoreState {
    var phase: AgentTranscriptRehydrateRestorePhase = .idle
    var layoutPassToken: UInt64 = 0
    var lastSettledRetryKey: AgentTranscriptRehydrateRetryKey?
    var currentLayoutSampleKey: AgentTranscriptRehydrateRetryKey?
    var coldRestoreStartedAt: Date?
    var scrollResponsivenessSuppressedUntil: Date?
    var pinnedJumpTelemetrySuppressedUntil: Date?

    var isActive: Bool {
        phase != .idle
    }

    mutating func reset() {
        phase = .idle
        layoutPassToken = 0
        lastSettledRetryKey = nil
        currentLayoutSampleKey = nil
        coldRestoreStartedAt = nil
        // Note: suppressions intentionally NOT cleared here — they have their own TTL.
        // Suppression ownership will move into the coordinator when extracted.
    }
}

// MARK: - 2g. DetachedRebaseCaptureState

struct DetachedRebaseCaptureState {
    var pendingSettleCapture = false
    var pendingSettleTurnID: UUID?
    var pendingSettleBlockID: String?
    var pendingSettleMinY: CGFloat?
    var pendingSettleStablePassCount = 0
    var candidateKey: AgentDetachedRebaseKey?
    var candidateFirstSeenAt: CFAbsoluteTime?
    var lastRestoreKey: AgentDetachedRebaseKey?
    var missingLiveAuthorityCount = 0
    var presentationRevisionCheckToken: UInt64 = 0

    mutating func clearSettleCapture() {
        pendingSettleCapture = false
        pendingSettleTurnID = nil
        pendingSettleBlockID = nil
        pendingSettleMinY = nil
        pendingSettleStablePassCount = 0
        candidateKey = nil
        candidateFirstSeenAt = nil
    }

    mutating func clearAll() {
        self = DetachedRebaseCaptureState()
    }
}

// MARK: - 2h. UserScrollInteractionState

struct UserScrollInteractionState {
    var phase: AgentTranscriptUserScrollPhase = .idle
    var session: AgentTranscriptUserScrollSession?
    var lastCompletedSession: AgentTranscriptCompletedUserScrollSession?
    var lastIntent: DetachedManualScrollDirection = .unknown
    var lastIntentAt: Date?

    var isSessionActive: Bool {
        session != nil
    }

    mutating func reset() {
        phase = .idle
        session = nil
        lastCompletedSession = nil
        lastIntent = .unknown
        lastIntentAt = nil
    }
}

// MARK: - 2i. BottomScrollOutcomeState

struct BottomScrollOutcomeState {
    var pendingOutcome: PendingBottomScrollOutcome?
    var lastLayoutMutationAt: Date?
    var generationToken: UInt64 = 0
    var deferredResolveTask: Task<Void, Never>?

    mutating func prepareForNewPendingOutcome() {
        generationToken &+= 1
        deferredResolveTask?.cancel()
        deferredResolveTask = nil
        lastLayoutMutationAt = nil
    }

    mutating func reset() {
        generationToken &+= 1
        deferredResolveTask?.cancel()
        deferredResolveTask = nil
        pendingOutcome = nil
        lastLayoutMutationAt = nil
    }
}
