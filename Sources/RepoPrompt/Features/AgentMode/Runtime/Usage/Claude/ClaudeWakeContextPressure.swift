import Foundation
import RepoPromptSettingsCore

/// Proactive maintenance is based on a live Claude occupancy count and a provider-vouched
/// window. No catalog defaults, transcript estimates, or aggregate billed usage are eligible.
struct ClaudeWakeContextPressure: Equatable {
    let used: Int
    let capacity: Int
    let effectiveWindow: Int

    struct Presentation: Equatable {
        let pressure: ClaudeWakeContextPressure?
        let episodeSpent: Bool

        @MainActor
        init?(session: AgentTabSession) {
            guard session.selectedAgent == .claudeCode, let conversation = session.providerSessionID else { return nil }
            pressure = ClaudeWakeContextPressure.current(for: session)
            episodeSpent = session.claudeWakeCompactionSpentConversation == conversation
        }
    }

    /// Auto-wake has no user attachments or tool results. Reserve for its bounded UTF-8 text
    /// at one estimated token per byte, plus space for fixed framing and the periodic instruction.
    static let wakeReserve = AgentSessionLinkPrompts.maximumRenderedBytes + AgentSessionLinkPrompts.maximumLocalInputDeltaBytes + 4096

    var hasRearmHeadroom: Bool {
        // Independent of the setting: turning the feature off or raising the threshold cannot
        // mint another attempt. Require a substantial measured margin below every threshold.
        ratio <= 0.60 && !needsReserve
    }

    func isHigh(thresholdPercent: Int) -> Bool {
        guard thresholdPercent > 0, used > 0, used <= capacity, effectiveWindow > 0 else { return false }
        return ratio >= Double(thresholdPercent) / 100 || needsReserve
    }

    private var ratio: Double {
        Double(used) / Double(effectiveWindow)
    }

    private var needsReserve: Bool {
        // Allow for the previous completion (provider occupancy is input-side), new output,
        // and provider-side framing/tool overhead. This is a planning margin, not a guarantee.
        effectiveWindow - used <= Self.wakeReserve + effectiveWindow / 10
    }

    @MainActor
    static func current(for session: AgentTabSession) -> Self? {
        guard session.selectedAgent == .claudeCode, session.claudeController != nil,
              let conversation = session.providerSessionID, !conversation.isEmpty,
              let snapshot = session.contextUsageSnapshot,
              let used = snapshot.used, used > 0,
              let capacity = session.identityValidContextWindowCapacity, used <= capacity,
              let window = snapshot.window, window > 0, window <= capacity,
              session.vouchedContextCountConfidence == .exact,
              session.vouchedContextCount == .init(agent: .claudeCode, tokens: used),
              session.vouchedContextWindow == .init(agent: .claudeCode, tokens: window),
              session.codexContextUsage?.awaitingPostCompactionUsage != true
        else { return nil }
        return Self(used: used, capacity: capacity, effectiveWindow: window)
    }
}

/// Evidence carried by the existing native control command; it creates no wake claim or receipt.
struct ClaudeWakeCompactionAdmission: Equatable {
    private let id = UUID()
    let wakeID: UUID
    let composerAttemptID: UUID
    let controllerID: ObjectIdentifier
    let model: String
    let pressure: ClaudeWakeContextPressure
    let boundaryID: UUID?
    let stopFence: AgentRunStartStopFence
    let wakeIsStillEligible: @MainActor () -> Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    @MainActor
    func isCurrent(for session: AgentTabSession) -> Bool {
        guard !Task.isCancelled, stopFence.permitsStart(of: session),
              session.permitsBoundOperationAndSave, !session.isChangingExecutionLocation,
              session.activeComposerSubmitAttempt?.id == composerAttemptID,
              let attempt = session.oversight.pendingAutoWake, attempt.wakeID == wakeID,
              !attempt.isManual, attempt.phase == .scheduled || attempt.phase == .awaitingSettlement,
              session.selectedModelRaw == model,
              session.claudeController.map({ ObjectIdentifier($0 as AnyObject) }) == controllerID,
              session.claudeCompactBoundaryID == boundaryID,
              ClaudeWakeContextPressure.current(for: session) == pressure,
              wakeIsStillEligible()
        else { return false }
        return pressure.isHigh(thresholdPercent: GlobalSettingsStore.shared.claudeWakeCompactionThresholdPercent())
    }
}
